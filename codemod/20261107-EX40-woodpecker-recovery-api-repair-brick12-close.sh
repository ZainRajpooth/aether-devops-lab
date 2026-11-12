#!/usr/bin/env bash
# 20261107-EX40 — Brick 12 closure with Woodpecker recovery gate.
#
# Fixes EX39's premature halt by first diagnosing/recovering woodpecker-server.
# Then:
#   - ensures bot is Woodpecker admin by login name
#   - uses Playwright OAuth login via Gitea
#   - calls authenticated repair API from page context
#   - verifies Gitea webhook creation
#   - rewrites webhook host to internal woodpecker-server:8000 if needed
#   - pushes real commit
#   - gates on Woodpecker Postgres pipelines.status=success
#
# No paid services. No public exposure. Secrets masked. Codemod-recorded.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
APP="$HOME_/DevOps/aether/apps/playwright"
IDX="$CD/INDEX.md"

TOKEN="ex40-woodpecker-recovery-api-repair-brick12-close-v1"
REPO="woodpecker-proof"
PGU="devops"
PGDB="woodpecker"
GTDB="gitea"

BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

PW_HEADLESS="${PW_HEADLESS:-1}"
MODE="${1:-run}"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
FWD_PID=""
WP_HOST_PORT="8000"
WP="http://127.0.0.1:${WP_HOST_PORT}"

cleanup(){
  [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

psql_wp(){
  podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true
}

gitea_sql_raw(){
  podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc "$1" 2>/dev/null || true
}

http_code(){
  curl -sS -m "${2:-8}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000
}

mask_all(){
  python3 -c '
import sys, re
vals = [v for v in sys.argv[1:] if v]
for line in sys.stdin:
    for v in vals:
        line = line.replace(v, "[REDACTED]")
    line = re.sub(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}", "[JWT]", line)
    line = re.sub(r"[0-9a-fA-F]{40,}", "[HEX]", line)
    sys.stdout.write(line)
' "${PASS:-}" "${PASS_ENC:-}" "${REPO_HASH:-}" "${HOOK_TOKEN:-}"
}

mask_str(){
  printf '%s\n' "$1" | mask_all
}

ledger(){
  local gate="$1"
  local desc="$2"
  local row_token="${TOKEN}:${gate}"
  mkdir -p "$CD"
  touch "$IDX"
  if ! grep -qF "$row_token" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=%s | %s |\n' \
      "$(date +%F)" "$row_token" "$gate" "$desc" >> "$IDX"
    say "ledger row appended: $row_token"
  else
    say "ledger row already exists: $row_token"
  fi
}

pipe_max_id(){
  psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n'
}

latest_pipeline_row(){
  psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1"
}

detect_wp_port(){
  podman port woodpecker-server 8000/tcp 2>/dev/null |
    head -1 |
    awk -F: '{print $NF}' |
    tr -d '\r\n' || true
}

wait_wp_ready(){
  local attempts="${1:-90}"
  local i p c
  for i in $(seq 1 "$attempts"); do
    p="$(detect_wp_port)"
    if [ -n "$p" ]; then
      c="$(http_code "http://127.0.0.1:$p/api/user" 3)"
      if [ "$c" = 200 ] || [ "$c" = 401 ]; then
        WP_HOST_PORT="$p"
        WP="http://127.0.0.1:$WP_HOST_PORT"
        say "woodpecker-server ready: $WP/api/user = $c"
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

dump_woodpecker_diagnostics(){
  hr "DIAG woodpecker-server"
  say "--- podman ps filtered ---"
  podman ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null |
    grep -E 'woodpecker|gitea|postgres' |
    sed 's/^/    /' || true

  say "--- woodpecker inspect state ---"
  podman inspect woodpecker-server \
    --format 'status={{.State.Status}} exitCode={{.State.ExitCode}} startedAt={{.State.StartedAt}} finishedAt={{.State.FinishedAt}} error={{.State.Error}}' \
    2>/dev/null | sed 's/^/    /' || true

  say "--- woodpecker port 8000/tcp ---"
  podman port woodpecker-server 8000/tcp 2>/dev/null | sed 's/^/    /' || say "    no port mapping"

  say "--- systemd user unit status ---"
  systemctl --user status woodpecker-server.service --no-pager -l 2>&1 | sed 's/^/    /' || true

  say "--- journalctl user woodpecker-server.service last 120 ---"
  journalctl --user -u woodpecker-server.service -n 120 --no-pager 2>&1 | mask_all | sed 's/^/    /' || true

  say "--- podman logs woodpecker-server last 160 ---"
  podman logs --tail 160 woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true

  say "--- postgres readiness ---"
  podman exec postgres pg_isready -U "$PGU" -d "$PGDB" -q 2>&1 | sed 's/^/    /' || true
  podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc 'SELECT 1' 2>&1 | sed 's/^/    /' || true
}

ensure_postgres_ready(){
  hr "R1 ensure Postgres is running/ready"
  podman inspect postgres >/dev/null 2>&1 || halt "container missing: postgres"

  local st
  st="$(podman inspect postgres --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
  say "postgres status=$st"
  if [ "$st" != running ]; then
    say "starting postgres"
    systemctl --user restart postgres.service 2>/dev/null || podman start postgres || true
  fi

  local i ok=no
  for i in $(seq 1 60); do
    if podman exec postgres pg_isready -U "$PGU" -d "$PGDB" -q >/dev/null 2>&1; then
      ok=yes
      say "postgres ready after ${i} checks"
      break
    fi
    sleep 2
  done
  [ "$ok" = yes ] || {
    say "postgres not ready"
    podman logs --tail 80 postgres 2>&1 | sed 's/^/    /' || true
    halt "postgres not ready"
  }
}

recover_woodpecker(){
  hr "R2 recover Woodpecker server"
  podman inspect woodpecker-server >/dev/null 2>&1 || halt "container missing: woodpecker-server"

  if wait_wp_ready 5; then
    say "Woodpecker was already reachable; no restart needed"
    return 0
  fi

  say "Woodpecker not reachable; collecting pre-recovery diagnostics"
  dump_woodpecker_diagnostics

  local st
  st="$(podman inspect woodpecker-server --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
  say "woodpecker-server status=$st"

  if systemctl --user cat woodpecker-server.service >/dev/null 2>&1; then
    say "systemd user unit woodpecker-server.service exists; using systemd first"
    systemctl --user reset-failed woodpecker-server.service 2>/dev/null || true
    systemctl --user restart woodpecker-server.service 2>/dev/null || true
  else
    say "no systemd user unit found; using Podman directly"
    podman restart woodpecker-server 2>/dev/null || podman start woodpecker-server 2>/dev/null || true
  fi

  local i running=no
  for i in $(seq 1 30); do
    st="$(podman inspect woodpecker-server --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
    if [ "$st" = running ]; then
      running=yes
      say "woodpecker-server running after ${i} checks"
      break
    fi
    sleep 2
  done

  if [ "$running" != yes ]; then
    say "container did not reach running state; trying podman start fallback"
    podman start woodpecker-server 2>&1 | sed 's/^/    /' || true
  fi

  if ! wait_wp_ready 90; then
    say "Woodpecker still not reachable after recovery"
    dump_woodpecker_diagnostics
    ledger "FAIL" "EX40 woodpecker-server not reachable after recovery"
    halt "woodpecker-server not reachable"
  fi
}

ensure_gitea_browser_bridge(){
  hr "R3 ensure Gitea browser/OAuth reachability"
  local c
  c="$(http_code http://127.0.0.2:3000/ 5)"
  say "http://127.0.0.2:3000/ = $c"

  if [ "$c" != 000 ]; then
    say "using existing 127.0.0.2:3000 bridge (GX04 or prior forwarder)"
    return 0
  fi

  say "starting transient fallback forwarder 127.0.0.2:3000 -> 127.0.0.1:$GT_HOST_PORT"
  cat > "$TMP/fwd.py" <<'FWDEOF'
import socket, threading, sys, select
LH,LP,UH,UP = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
def pipe(a,b):
    try:
        while True:
            r,_,_ = select.select([a,b],[],[],30)
            if not r: break
            for s in r:
                d = s.recv(65536)
                if not d:
                    for x in (a,b):
                        try: x.close()
                        except: pass
                    return
                (b if s is a else a).sendall(d)
    except Exception:
        for x in (a,b):
            try: x.close()
            except: pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((LH, LP)); srv.listen(128)
sys.stderr.write("fwd %s:%d -> %s:%d\n" % (LH,LP,UH,UP)); sys.stderr.flush()
while True:
    c,_ = srv.accept()
    u = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try: u.connect((UH, UP))
    except Exception:
        try: c.close()
        except: pass
        continue
    threading.Thread(target=pipe, args=(c,u), daemon=True).start()
    threading.Thread(target=pipe, args=(u,c), daemon=True).start()
FWDEOF

  python3 "$TMP/fwd.py" 127.0.0.2 3000 127.0.0.1 "$GT_HOST_PORT" >"$TMP/fwd.log" 2>&1 &
  FWD_PID=$!
  say "transient forwarder pid=$FWD_PID"

  local i up=no
  for i in $(seq 1 20); do
    c="$(http_code http://127.0.0.2:3000/ 5)"
    if [ "$c" != 000 ]; then
      up=yes
      say "transient forwarder live: http://127.0.0.2:3000/ = $c"
      break
    fi
    kill -0 "$FWD_PID" 2>/dev/null || {
      say "forwarder died; log:"
      sed 's/^/    /' "$TMP/fwd.log" 2>/dev/null || true
      halt "transient Gitea forwarder exited"
    }
    sleep 1
  done
  [ "$up" = yes ] || {
    sed 's/^/    /' "$TMP/fwd.log" 2>/dev/null || true
    halt "transient Gitea forwarder not live"
  }
}

delete_gitea_hooks(){
  curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_list.json" 2>/dev/null || echo '[]' > "$TMP/hooks_list.json"

  python3 - "$TMP/hooks_list.json" > "$TMP/delete_ids.txt" <<'PYDEL'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    hooks = []
if not isinstance(hooks, list):
    hooks = []
for h in hooks:
    if isinstance(h, dict) and h.get("id") is not None:
        print(str(h["id"]))
PYDEL

  local n hid
  n="$(wc -l < "$TMP/delete_ids.txt" | tr -d ' \n')"
  say "deleting $n existing Gitea hook(s)"
  while IFS= read -r hid; do
    [ -n "$hid" ] || continue
    curl -sS -m 10 -u "$BOT:$PASS" -X DELETE "$GT/api/v1/repos/$BOT/$REPO/hooks/$hid" >/dev/null 2>&1 || true
  done < "$TMP/delete_ids.txt"
}

create_gitea_hook(){
  local url="$1"
  local secret="$2"

  python3 - "$url" "$secret" > "$TMP/hook_create.json" <<'PYHOOK'
import json, sys
url, secret = sys.argv[1:3]
cfg = {"url": url, "content_type": "json"}
if secret:
    cfg["secret"] = secret
print(json.dumps({
    "type": "gitea",
    "active": True,
    "events": ["push"],
    "config": cfg
}))
PYHOOK

  local hc
  hc="$(
    curl -sS -m 15 -u "$BOT:$PASS" \
      -H 'Content-Type: application/json' \
      -d @"$TMP/hook_create.json" \
      -X POST \
      -o "$TMP/hook_create_resp.json" \
      -w '%{http_code}' \
      "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo 000
  )"
  say "create hook http=$hc url=$(mask_str "$url")"
  mask_all < "$TMP/hook_create_resp.json" | sed 's/^/    /' || true

  case "$hc" in
    200|201|204) return 0 ;;
    *) return 1 ;;
  esac
}

hr "X0 preflight"
for c in python3 curl git podman awk sed grep base64 node systemctl journalctl; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"
done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
mkdir -p "$CD" "$SEC" "$APP"
touch "$IDX"

BOT="$(cat "$BOT_FILE" | tr -d '\n\r')"
PASS="$(cat "$PASS_FILE" | tr -d '\n\r')"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"

REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"

ROW="$(psql_wp "SELECT hash||'|'||forge_remote_id FROM repos WHERE id=$REPO_ID LIMIT 1")"
REPO_HASH="${ROW%%|*}"
FORGE_ID="${ROW##*|}"
[ -n "$REPO_HASH" ] || halt "could not extract repo hash"
[ -n "$FORGE_ID" ] || halt "could not extract forge_remote_id"
GITEA_REPO_ID="$FORGE_ID"

BOT_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PASS")"
BOT_SQL="${BOT//\'/\'\'}"
HOOK_TOKEN=""

say "bot=$BOT"
say "gitea_url=$GT"
say "woodpecker_repo_id=$REPO_ID"
say "gitea_repo_id=$GITEA_REPO_ID"
say "repo_hash_mask=$(mask_str "${REPO_HASH:0:6}...len=${#REPO_HASH}")"

if [ "$MODE" = check ]; then
  hr "X1 plan (check mode)"
  say "  1) snapshot Woodpecker/Gitea/Postgres state"
  say "  2) ensure Postgres ready"
  say "  3) recover/wait for Woodpecker HTTP readiness"
  say "  4) ensure bot is Woodpecker admin by login"
  say "  5) ensure Gitea OAuth browser bridge"
  say "  6) Playwright OAuth + authenticated repair API"
  say "  7) verify/rewrite webhook, push, DB-gate pipeline success"
  say "[RESULT] EX40 CHECK - nothing written."
  exit 0
fi

hr "X1 state snapshot"
dump_woodpecker_diagnostics

hr "X2 ensure Postgres ready"
ensure_postgres_ready

hr "X3 recover Woodpecker"
recover_woodpecker
say "Woodpecker base URL now=$WP"

hr "X4 ensure bot is Woodpecker admin"
ADMIN="$(psql_wp "SELECT admin FROM users WHERE login='$BOT_SQL' LIMIT 1" | tr -d ' \n')"
say "bot_admin_raw=${ADMIN:-none}"
case "$ADMIN" in
  t|true|1|yes)
    say "bot already has Woodpecker admin=true"
    ;;
  *)
    say "granting Woodpecker admin=true to login=$BOT"
    psql_wp "UPDATE users SET admin = true WHERE login = '$BOT_SQL';" >/dev/null
    say "restarting woodpecker-server to apply admin change"
    if systemctl --user cat woodpecker-server.service >/dev/null 2>&1; then
      systemctl --user restart woodpecker-server.service 2>/dev/null || true
    else
      podman restart woodpecker-server 2>/dev/null || true
    fi
    if ! wait_wp_ready 90; then
      dump_woodpecker_diagnostics
      ledger "FAIL" "EX40 woodpecker-server not reachable after admin grant restart"
      halt "woodpecker-server not reachable after admin grant"
    fi
    ;;
esac

hr "X5 ensure Gitea OAuth browser bridge"
ensure_gitea_browser_bridge

hr "X6 Playwright OAuth login + authenticated repair API"
cat > "$APP/wp-repair-ex40.mjs" <<'NODE40EOF'
import { chromium } from 'playwright';

const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const BOT = process.env.BOT_USER || '';
const PASS = process.env.BOT_PASS || '';
const REPO = process.env.REPO || '';
const REPO_ID = process.env.REPO_ID || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';

const log = (...a) => console.log('   ', ...a);

function redact(s) {
  return String(s || '')
    .replace(/eyJ[A-Za-z0-9_.-]{10,}/g, '[JWT]')
    .replace(/[0-9a-fA-F]{40,}/g, '[HEX]')
    .replace(/\s+/g, ' ')
    .slice(0, 260);
}

const browser = await chromium.launch({
  headless: HEADLESS,
  args: ['--host-resolver-rules=MAP gitea 127.0.0.2'],
});
const context = await browser.newContext();
const page = await context.newPage();

page.on('framenavigated', f => { try { log('NAV', f.url().replace(/access_token=[^&]+/, 'access_token=[REDACTED]')); } catch {} });
page.on('response', async resp => {
  try {
    const u = resp.url();
    if (u.includes('/api/')) {
      log('APIRESP', resp.request().method(), resp.status(), u.replace(/access_token=[^&]+/, 'access_token=[REDACTED]'));
    }
  } catch {}
});

async function api(method, path, body) {
  try {
    const r = await fetch(path, {
      method,
      credentials: 'include',
      headers: {
        'Content-Type': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const t = await r.text();
    return { status: r.status, body: t };
  } catch (e) {
    return { status: 0, body: 'FETCH_ERR:' + String(e) };
  }
}

try {
  log('navigating to Woodpecker login:', WP + '/login');
  await page.goto(WP + '/login', { waitUntil: 'domcontentloaded', timeout: 30000 });

  const giteaBtn = page.getByRole('button', { name: /gitea/i }).first();
  await giteaBtn.waitFor({ state: 'visible', timeout: 15000 });
  log('clicking Gitea login button');
  await giteaBtn.click();

  log('waiting for Gitea login page');
  await page.waitForURL(/gitea:3000|127\.0\.0\.2:3000/, { timeout: 20000 });

  const user = page.locator('input[name="user_name"], input[name="username"], input#user_name, input[type="text"]').first();
  await user.waitFor({ state: 'visible', timeout: 15000 });
  await user.fill(BOT);

  const pw = page.locator('input[name="password"], input#password, input[type="password"]').first();
  await pw.waitFor({ state: 'visible', timeout: 10000 });
  await pw.fill(PASS);

  const submit = page.getByRole('button', { name: /^\s*sign\s+in\s*$/i }).first();
  await submit.waitFor({ state: 'visible', timeout: 15000 });
  log('submitting Gitea login');
  await submit.click();

  try {
    await page.waitForURL(/\/login\/oauth\/authorize|\/authorize\b/, { timeout: 10000 });
    const consent = page.getByRole('button', { name: /authorize|grant|allow|approve|confirm/i }).first();
    if (await consent.isVisible().catch(() => false)) {
      log('clicking OAuth consent');
      await consent.click();
    }
  } catch {
    log('no consent page; already authorized');
  }

  await page.waitForURL(new RegExp(WP.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), { timeout: 20000 });
  log('logged into Woodpecker successfully; url=', page.url());

  const settingsUrl = `${WP}/repos/${encodeURIComponent(BOT)}/${encodeURIComponent(REPO)}/settings`;
  log('navigating to repo settings:', settingsUrl);
  await page.goto(settingsUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(2500);

  log('attempting authenticated repair API from page context');
  let res = await api('POST', `/api/repos/${REPO_ID}/repair`, {});
  log('repair repo_id status=', res.status, 'body=', redact(res.body));

  if (![200, 201, 204].includes(res.status)) {
    res = await api('POST', `/api/repos/${encodeURIComponent(BOT)}/${encodeURIComponent(REPO)}/repair`, {});
    log('repair owner/repo status=', res.status, 'body=', redact(res.body));
  }

  if (![200, 201, 204].includes(res.status)) {
    // Some builds may require a repo PATCH to resync hooks. This is a fallback, not the primary path.
    res = await api('PATCH', `/api/repos/${REPO_ID}`, { active: true });
    log('fallback PATCH repo active status=', res.status, 'body=', redact(res.body));
  }

  if (![200, 201, 204].includes(res.status)) {
    const btns = await page.getByRole('button').allTextContents().catch(() => []);
    log('repair API failed; buttons on page=', JSON.stringify(btns.slice(0, 50)));
    await page.screenshot({ path: '/tmp/wp-repair-ex40-fail.png' }).catch(() => {});
    await browser.close().catch(() => {});
    process.exit(1);
  }

  log('repair API accepted');
  await page.waitForTimeout(3000);
  await browser.close().catch(() => {});
  process.exit(0);
} catch (e) {
  log('FAIL:', String(e && e.message || e));
  await page.screenshot({ path: '/tmp/wp-repair-ex40-fail.png' }).catch(() => {});
  await browser.close().catch(() => {});
  process.exit(1);
}
NODE40EOF
chmod 600 "$APP/wp-repair-ex40.mjs"

UI_RC=0
(
  cd "$APP" || exit 1
  WP_URL="$WP" BOT_USER="$BOT" BOT_PASS="$PASS" REPO="$REPO" REPO_ID="$REPO_ID" PW_HEADLESS="$PW_HEADLESS" \
  node wp-repair-ex40.mjs
) 2>&1 | sed 's/^/  /' || UI_RC=$?
say "playwright repair rc=$UI_RC"
[ "$UI_RC" = 0 ] || {
  say "--- woodpecker-server logs tail 80 ---"
  podman logs --tail 80 woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX40 Playwright repair failed rc=$UI_RC; Woodpecker was reachable. Paste X6 + logs."
  halt "Playwright repair failed"
}

hr "X7 verify Gitea webhook creation"
WEBHOOK_COUNT="$(gitea_sql_raw "SELECT COUNT(*) FROM webhook WHERE repo_id=$GITEA_REPO_ID" | tr -d ' \n')"
say "gitea webhook_count=$WEBHOOK_COUNT"
if [ "${WEBHOOK_COUNT:-0}" -eq 0 ]; then
  say "--- woodpecker-server logs tail 100 ---"
  podman logs --tail 100 woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX40 repair accepted but no Gitea webhook row exists. Paste X7."
  halt "webhook not created after repair"
fi

HOOK_ROW="$(gitea_sql_raw "SELECT id||'|'||url FROM webhook WHERE repo_id=$GITEA_REPO_ID ORDER BY id DESC LIMIT 1")"
[ -n "$HOOK_ROW" ] || halt "could not read webhook row"
HOOK_ID="${HOOK_ROW%%|*}"
HOOK_URL="${HOOK_ROW#*|}"
HOOK_URL="${HOOK_URL//&amp;/&}"

HOOK_TOKEN="$(python3 -c '
import sys, urllib.parse
u = sys.argv[1]
q = urllib.parse.urlparse(u).query
d = urllib.parse.parse_qs(q)
print((d.get("access_token") or [""])[0])
' "$HOOK_URL" 2>/dev/null || true)"

say "generated hook id=$HOOK_ID url=$(mask_str "$HOOK_URL") token_present=$([ -n "$HOOK_TOKEN" ] && echo yes || echo no)"

INTERNAL_WP="http://woodpecker-server:8000"
case "$HOOK_URL" in
  *woodpecker-server:8000*)
    say "hook already uses internal Woodpecker host"
    ;;
  *)
    [ -n "$HOOK_TOKEN" ] || {
      say "hook is not internal and has no access_token; cannot safely rewrite"
      ledger "PARTIAL" "EX40 generated non-internal hook without token: $(mask_str "$HOOK_URL")"
      halt "generated hook lacks token for internal rewrite"
    }

    PATH_QUERY="$(python3 -c '
import sys, urllib.parse
u = sys.argv[1].replace("&amp;", "&")
p = urllib.parse.urlparse(u)
print(p.path + (("?" + p.query) if p.query else ""))
' "$HOOK_URL")"

    NEW_URL="$INTERNAL_WP$PATH_QUERY"
    say "rewriting hook host to internal: $(mask_str "$NEW_URL")"
    delete_gitea_hooks
    create_gitea_hook "$NEW_URL" "$REPO_HASH" || {
      ledger "PARTIAL" "EX40 could not create internal rewritten hook"
      halt "create rewritten hook failed"
    }
    HOOK_URL="$NEW_URL"
    ;;
esac

say "final hook url=$(mask_str "$HOOK_URL")"

hr "X8 clean real push"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BEFORE_PUSH_PIPE="$(pipe_max_id)"
say "since=$SINCE before_push_pipeline_max_id=$BEFORE_PUSH_PIPE"

WORK="$TMP/git"
rm -rf "$WORK"

REPO_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" 2>/dev/null || echo '{}')"
DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print((d.get("default_branch") or "main") if isinstance(d, dict) else "main")
' 2>/dev/null || echo main)"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"

git clone -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "$WORK" || halt "clone failed"
cd "$WORK" || halt "cd worktree failed"

git config user.email "${BOT}@local"
git config user.name "Woodpecker Proof"

cat > .woodpecker.yml <<'YML'
steps:
  - name: hello-world
    image: alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
YML

git add .woodpecker.yml
if [ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ]; then
  git commit -q -m "ci: ex40 real push $(date -Is)" || halt "commit failed"
else
  git commit -q --allow-empty -m "ci: ex40 retrigger $(date -Is)" || halt "empty commit failed"
fi

git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "HEAD:$DEFAULT_BRANCH" || halt "push failed"
PUSH_SHA="$(git rev-parse HEAD)"
say "pushed SHA=$PUSH_SHA"
cd / || true

hr "X9 poll for NEW pipeline"
NEW_ID=""
PIPE_NUM=""
PIPE_STATUS=""
SUCCESS=no

for i in $(seq 1 80); do
  ROW="$(latest_pipeline_row)"
  if [ -n "$ROW" ]; then
    read -r NEW_ID PIPE_NUM PIPE_STATUS <<<"$ROW"
    if [ "${NEW_ID:-0}" -gt "${BEFORE_PUSH_PIPE:-0}" ]; then
      say "new pipeline id=$NEW_ID number=#${PIPE_NUM:-?} status=${PIPE_STATUS:-none}"
      if [ "$PIPE_STATUS" = success ]; then
        SUCCESS=yes
        break
      fi
      case "$PIPE_STATUS" in
        failure|error|killed)
          break
          ;;
      esac
    fi
  fi
  sleep 3
done

hr "X10 Gitea delivery evidence"
gitea_sql_raw "SELECT id, repo_id, url, is_active FROM webhook WHERE repo_id=$GITEA_REPO_ID ORDER BY id DESC LIMIT 5;" | mask_all | sed 's/^/    /' || true
say "--- hook_task receipts ---"
gitea_sql_raw "SELECT * FROM hook_task ORDER BY id DESC LIMIT 3;" | mask_all | sed 's/^/    /' || true

if [ "$SUCCESS" != yes ]; then
  hr "X11 failure diagnostics"
  say "latest pipeline id=${NEW_ID:-none} #${PIPE_NUM:-none} status=${PIPE_STATUS:-none}"
  say "--- woodpecker-server logs since $SINCE ---"
  podman logs --since "$SINCE" woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  say "--- woodpecker-agent logs since $SINCE ---"
  podman logs --since "$SINCE" woodpecker-agent 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX40 webhook final=$(mask_str "$HOOK_URL"); push SHA=$PUSH_SHA; pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none}. Paste X10-X11."
  halt "pipeline did not succeed"
fi

hr "X12 RESULT"
say "[RESULT] EX40 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
say "  repo: $BOT/$REPO"
say "  woodpecker_repo_id: $REPO_ID"
say "  final_hook_url: $(mask_str "$HOOK_URL")"
say "  pipeline: #${PIPE_NUM:-?}"
say "  status: success"
say "  push SHA: $PUSH_SHA"

ledger "PASS" "EX40: recovered Woodpecker, granted admin by login, authenticated repair API created webhook, internal host rewrite when needed, real push created pipeline #$PIPE_NUM status=success. Brick 12 CLOSED."
exit 0
