#!/usr/bin/env bash
# 20261107-EX37 — fixes EX36's premature Playwright launch.
# Uses a robust wait loop for woodpecker-server startup (checks for 200/401) and dumps
# container logs if it fails to start within 80s.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
APP="$HOME_/DevOps/aether/apps/playwright"
IDX="$CD/INDEX.md"
SESSION="$SEC/woodpecker-session.json"

TOKEN="ex37-robust-wait-loop-brick12-close-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
INTERNAL_WP="http://woodpecker-server:8000"
PGU="devops"
PGDB="woodpecker"
GTDB=""

BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

PW_HEADLESS="${PW_HEADLESS:-1}"
MODE="${1:-run}"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

psql_wp(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
gitea_sql_raw(){ [ -n "$GTDB" ] || return 0; podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc "$1" 2>/dev/null || true; }
gitea_sql(){ [ -n "$GTDB" ] || { say "    gitea DB not detected"; return 0; }; podman exec postgres psql -U "$PGU" -d "$GTDB" -X --pset=pager=off -c "$1" 2>&1 | mask_all; }

mask_all(){
  python3 -c '
import sys, re
vals = [v for v in sys.argv[1:] if v]
for line in sys.stdin:
    for v in vals: line = line.replace(v, "[REDACTED]")
    line = re.sub(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}", "[JWT]", line)
    line = re.sub(r"[0-9a-fA-F]{40,}", "[HEX]", line)
    sys.stdout.write(line)
' "${PASS:-}" "${PASS_ENC:-}" "${REPO_HASH:-}" "${HOOK_TOKEN:-}"
}
mask_str(){ printf '%s\n' "$1" | mask_all; }

pipe_max_id(){ psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n'; }
latest_pipeline_row(){ psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1"; }

ledger(){
  local gate="$1" desc="$2" row_token="${TOKEN}:${1}"
  mkdir -p "$CD"; touch "$IDX"
  if ! grep -qF "$row_token" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$row_token" "$gate" "$desc" >> "$IDX"
    say "ledger row appended: $row_token"
  fi
}

delete_gitea_hooks(){
  curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_list.json" 2>/dev/null || echo '[]' > "$TMP/hooks_list.json"
  python3 - "$TMP/hooks_list.json" > "$TMP/delete_ids.txt" <<'PYDEL'
import sys, json
try: hooks = json.load(open(sys.argv[1]))
except Exception: hooks = []
for h in hooks:
    if isinstance(h, dict) and h.get("id") is not None: print(str(h["id"]))
PYDEL
  local n hid; n="$(wc -l < "$TMP/delete_ids.txt" | tr -d ' \n')"
  say "deleting $n existing Gitea hook(s)"
  while IFS= read -r hid; do
    [ -n "$hid" ] || continue
    curl -sS -m 10 -u "$BOT:$PASS" -X DELETE "$GT/api/v1/repos/$BOT/$REPO/hooks/$hid" >/dev/null 2>&1 || true
  done < "$TMP/delete_ids.txt"
}

create_gitea_hook(){
  local url="$1" secret="$2"
  python3 - "$url" "$secret" > "$TMP/hook_create.json" <<'PYHOOK'
import json, sys
url, secret = sys.argv[1:3]
cfg = {"url": url, "content_type": "json"}
if secret: cfg["secret"] = secret
print(json.dumps({"type": "gitea", "active": True, "events": ["push"], "config": cfg}))
PYHOOK
  local hc
  hc="$(curl -sS -m 15 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d @"$TMP/hook_create.json" -X POST -o "$TMP/hook_create_resp.json" -w '%{http_code}' "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo 000)"
  say "create hook http=$hc url=$(mask_str "$url")"
  case "$hc" in 200|201|204) return 0 ;; *) return 1 ;; esac
}

hr "X0 preflight"
for c in python3 curl git podman awk sed grep base64 node; do command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"; done
for c in woodpecker-server woodpecker-agent gitea postgres; do podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"; done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
[ -s "$SESSION" ] || halt "missing Woodpecker session file"
mkdir -p "$CD" "$SEC" "$APP"; touch "$IDX"

BOT="$(cat "$BOT_FILE" | tr -d '\n\r')"
PASS="$(cat "$PASS_FILE" | tr -d '\n\r')"
GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"

REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"
ROW="$(psql_wp "SELECT hash||'|'||forge_remote_id FROM repos WHERE id=$REPO_ID LIMIT 1")"
REPO_HASH="${ROW%%|*}"
[ -n "$REPO_HASH" ] || halt "could not extract repo hash"

BOT_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PASS")"

say "bot=$BOT gitea_url=$GT woodpecker_repo_id=$REPO_ID"

if [ "$MODE" = check ]; then hr "X1 plan"; say "1) Admin grant + robust WP wait loop 2) Delete hooks 3) Playwright repair 4) Rewrite host 5) Push"; say "[RESULT] EX37 CHECK"; exit 0; fi

hr "X1 grant Woodpecker admin rights and restart server"
podman exec postgres psql -U "$PGU" -d "$PGDB" -c "UPDATE users SET admin = true WHERE id = 1;" >/dev/null
say "granted admin to user id=1"
systemctl --user restart woodpecker-server.service 2>/dev/null || podman restart woodpecker-server
say "restarting woodpecker-server..."

# EX37: ROBUST WAIT LOOP
WP_UP=no
for i in $(seq 1 40); do
  C="$(curl -sS -m 2 -o /dev/null -w '%{http_code}' "$WP/api/user" 2>/dev/null || echo 000)"
  if [ "$C" = 200 ] || [ "$C" = 401 ]; then
    say "woodpecker-server up: $WP = $C"
    WP_UP=yes
    break
  fi
  sleep 2
done
[ "$WP_UP" = yes ] || {
  say "woodpecker-server failed to start after 80s. Container status:"
  podman ps -a --filter name=woodpecker-server --format "{{.Status}}" | sed 's/^/    /'
  say "--- woodpecker-server logs ---"
  podman logs --tail 30 woodpecker-server 2>&1 | sed 's/^/    /'
  halt "woodpecker-server not reachable"
}

hr "X2 detect Gitea DB"
GTDB="gitea"
if ! podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc 'SELECT 1' >/dev/null 2>&1; then
  GTDB=""
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    if podman exec postgres psql -U "$PGU" -d "$db" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='webhook' LIMIT 1" 2>/dev/null | grep -q 1; then
      GTDB="$db"; break
    fi
  done < <(podman exec postgres psql -U "$PGU" -d postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)
fi
say "gitea_db=${GTDB:-none}"

hr "X3 delete existing Gitea hooks"
delete_gitea_hooks

hr "X4 Playwright repair"
cat > "$APP/wp-repair-admin.mjs" <<'NODE37EOF'
import { chromium } from 'playwright';
const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const SESSION = process.env.SESSION_PATH || '';
const OWNER = process.env.GT_USER || '';
const REPO = process.env.REPO || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';
const log = (...a) => console.log('   ', ...a);
const browser = await chromium.launch({ headless: HEADLESS });
const context = await browser.newContext({ storageState: SESSION });
const page = await context.newPage();
page.on('response', async resp => { try { if (resp.url().includes('/api/')) log('APIRESP', resp.request().method(), resp.status(), resp.url()); } catch {} });
try {
  log('navigating to repo settings');
  await page.goto(`${WP}/repos/${encodeURIComponent(OWNER)}/${encodeURIComponent(REPO)}/settings`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(3000);
  const btns = await page.getByRole('button').allTextContents().catch(() => []);
  log('settings buttons=', JSON.stringify(btns.slice(0, 40)));
  const repairBtn = page.getByRole('button', { name: /repair/i }).first();
  if (await repairBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
    log('found Repair button, clicking');
    await repairBtn.click();
    await page.waitForTimeout(5000);
    log('Repair clicked successfully');
  } else {
    log('Repair button still not found after admin grant');
    await page.screenshot({ path: '/tmp/wp-repair-admin-fail.png' }).catch(() => {});
    await browser.close(); process.exit(1);
  }
  await browser.close().catch(() => {}); process.exit(0);
} catch (e) {
  log('FAIL:', String(e && e.message || e));
  await page.screenshot({ path: '/tmp/wp-repair-admin-fail.png' }).catch(() => {});
  await browser.close().catch(() => {}); process.exit(1);
}
NODE37EOF
chmod 600 "$APP/wp-repair-admin.mjs"
UI_RC=0
( cd "$APP" || exit 1; WP_URL="$WP" SESSION_PATH="$SESSION" GT_USER="$BOT" REPO="$REPO" PW_HEADLESS="$PW_HEADLESS" node wp-repair-admin.mjs ) 2>&1 | sed 's/^/  /' || UI_RC=$?
say "playwright repair rc=$UI_RC"
[ "$UI_RC" = 0 ] || halt "Playwright repair failed"

hr "X5 verify generated webhook and rewrite host to internal"
HOOK_ROW="$(gitea_sql_raw "SELECT id||'|'||url FROM webhook ORDER BY id DESC LIMIT 1")"
[ -n "$HOOK_ROW" ] || halt "no webhook after repair"
HOOK_ID="${HOOK_ROW%%|*}"
HOOK_URL="${HOOK_ROW#*|}"
HOOK_URL="${HOOK_URL//&amp;/&}"
HOOK_TOKEN="$(python3 -c 'import sys, urllib.parse; u=sys.argv[1]; q=urllib.parse.urlparse(u).query; d=urllib.parse.parse_qs(q); print((d.get("access_token") or [""])[0])' "$HOOK_URL" 2>/dev/null || true)"
say "generated hook id=$HOOK_ID url=$(mask_str "$HOOK_URL") token_present=$([ -n "$HOOK_TOKEN" ] && echo yes || echo no)"

NEED_REWRITE=no
case "$HOOK_URL" in *woodpecker-server:8000*) NEED_REWRITE=no ;; *) NEED_REWRITE=yes ;; esac
if [ "$NEED_REWRITE" = yes ]; then
  [ -n "$HOOK_TOKEN" ] || halt "generated hook lacks token for internal rewrite"
  PATH_QUERY="$(python3 -c 'import sys, urllib.parse; u=sys.argv[1].replace("&amp;","&"); p=urllib.parse.urlparse(u); print(p.path + (("?" + p.query) if p.query else ""))' "$HOOK_URL")"
  NEW_URL="$INTERNAL_WP$PATH_QUERY"
  say "rewriting hook host to internal: $(mask_str "$NEW_URL")"
  delete_gitea_hooks
  create_gitea_hook "$NEW_URL" "$REPO_HASH" || halt "create rewritten hook failed"
  HOOK_URL="$NEW_URL"
fi
say "final hook url=$(mask_str "$HOOK_URL")"

hr "X6 clean real push"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BEFORE_PUSH_PIPE="$(pipe_max_id)"
WORK="$TMP/git"; rm -rf "$WORK"
REPO_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" 2>/dev/null || echo '{}')"
DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin) if sys.stdin else {}; print(d.get("default_branch","main"))' 2>/dev/null || echo main)"
git clone -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "$WORK" || halt "clone failed"
cd "$WORK" || halt "cd worktree failed"
git config user.email "${BOT}@local"; git config user.name "Woodpecker Proof"
cat > .woodpecker.yml <<'YML'
steps:
  - name: hello-world
    image: alpine:latest
    commands: [ 'echo "Hello from Woodpecker CI!"', 'date', 'whoami' ]
YML
git add .woodpecker.yml
[ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ] && git commit -q -m "ci: ex37 real push $(date -Is)" || git commit -q --allow-empty -m "ci: ex37 retrigger $(date -Is)"
git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "HEAD:$DEFAULT_BRANCH" || halt "push failed"
PUSH_SHA="$(git rev-parse HEAD)"; say "pushed SHA=$PUSH_SHA"; cd / || true

hr "X7 poll for NEW pipeline"
NEW_ID=""; PIPE_NUM=""; PIPE_STATUS=""; SUCCESS=no
for i in $(seq 1 80); do
  ROW="$(latest_pipeline_row)"
  if [ -n "$ROW" ]; then
    read -r NEW_ID PIPE_NUM PIPE_STATUS <<<"$ROW"
    if [ "${NEW_ID:-0}" -gt "${BEFORE_PUSH_PIPE:-0}" ]; then
      say "new pipeline id=$NEW_ID number=#${PIPE_NUM:-?} status=${PIPE_STATUS:-none}"
      if [ "$PIPE_STATUS" = success ]; then SUCCESS=yes; break; fi
      case "$PIPE_STATUS" in failure|error|killed) break ;; esac
    fi
  fi
  sleep 3
done

hr "X8 Gitea delivery evidence"
gitea_sql "SELECT id, repo_id, url, is_active FROM webhook ORDER BY id DESC LIMIT 5;" | sed 's/^/    /'
say "--- hook_task receipts ---"
gitea_sql "SELECT * FROM hook_task ORDER BY id DESC LIMIT 3;" | sed 's/^/    /'

if [ "$SUCCESS" != yes ]; then
  hr "X9 failure diagnostics"
  say "latest pipeline id=${NEW_ID:-none} #${PIPE_NUM:-none} status=${PIPE_STATUS:-none}"
  say "--- woodpecker-server logs since $SINCE ---"
  podman logs --since "$SINCE" woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX37 push SHA=$PUSH_SHA; pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none}."
  halt "pipeline did not succeed"
fi

hr "X10 RESULT"
say "[RESULT] EX37 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
ledger "PASS" "EX37: robust WP wait loop, admin repair, internal rewrite, pipeline #$PIPE_NUM success. Brick 12 CLOSED."
exit 0
