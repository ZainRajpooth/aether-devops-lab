#!/usr/bin/env bash
# 20261107-EX35 — definitive Brick 12 closure.
#
# Fixes EX34's mechanical failure and the real remaining defect:
#   - delete bad session-JWT webhook from Gitea
#   - call Woodpecker repair API to regenerate proper hook token
#   - if repair generates 127.0.0.1 host, rewrite only host to woodpecker-server:8000
#   - push real commit
#   - gate on Woodpecker Postgres pipelines.status=success
#
# No gRPC change. No DB mutation. Secrets/JWTs masked. Codemod-recorded.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
APP="$HOME_/DevOps/aether/apps/playwright"
IDX="$CD/INDEX.md"
SESSION="$SEC/woodpecker-session.json"
BEARER_FILE="$SEC/woodpecker-bearer.token"
LOGIN_JS="$APP/wp-login.mjs"
REPAIR_JS="$APP/wp-repair.mjs"

TOKEN="ex35-repair-webhook-internal-host-brick12-close-v1"
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
FWD_PID=""
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
  [ -n "$GTDB" ] || return 0
  podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc "$1" 2>/dev/null || true
}

gitea_sql(){
  [ -n "$GTDB" ] || { say "    gitea DB not detected"; return 0; }
  podman exec postgres psql -U "$PGU" -d "$GTDB" -X --pset=pager=off -c "$1" 2>&1 | mask_all
}

code(){
  curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true
}

envval(){
  podman inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    awk -F= -v k="$2" '$1==k { sub(/^[^=]+=/, ""); print; exit }'
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
' "${PASS:-}" "${PASS_ENC:-}" "${REPO_HASH:-}" "${USER_SESS:-}" "${API_TOKEN:-}" "${HOOK_TOKEN:-}" "${WP_SECRET:-}"
}

mask_str(){
  printf '%s\n' "$1" | mask_all
}

extract_user_sess(){
  [ -s "$SESSION" ] || return 0
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for c in d.get("cookies", []) or []:
    if c.get("name") == "user_sess":
        print(c.get("value", ""))
        break
' "$SESSION"
}

cookies_from_session(){
  [ -s "$SESSION" ] || return 0
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
parts = []
for c in d.get("cookies", []) or []:
    dom = (c.get("domain") or "").lstrip(".")
    if dom in ("127.0.0.1", "localhost", ""):
        parts.append(f"{c.get(\"name\")}={c.get(\"value\")}")
print("; ".join(parts))
' "$SESSION"
}

pipe_max_id(){
  psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n'
}

latest_pipeline_row(){
  psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1"
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

start_forwarder(){
  local fwd="$TMP/fwd.py" log="$TMP/fwd.log"
  cat > "$fwd" <<'FWDEOF'
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
  python3 "$fwd" 127.0.0.2 3000 127.0.0.1 "$GT_HOST_PORT" >"$log" 2>&1 &
  FWD_PID=$!
  say "forwarder pid=$FWD_PID"
  local up=no i b
  for i in $(seq 1 20); do
    b="$(code http://127.0.0.2:3000/)"
    if [ "$b" != 000 ]; then up=yes; say "forwarder live: 127.0.0.2:3000 = $b"; break; fi
    kill -0 "$FWD_PID" 2>/dev/null || { sed 's/^/    /' "$log" || true; halt "forwarder died"; }
    sleep 1
  done
  [ "$up" = yes ] || { sed 's/^/    /' "$log" || true; halt "forwarder not live"; }
}

refresh_session_if_needed(){
  local st
  st="$(curl -sS -m 10 -o "$TMP/user_check.json" -w '%{http_code}' -H "Cookie: user_sess=$USER_SESS" "$WP/api/user" 2>/dev/null || echo 000)"
  if [ "$st" = 200 ]; then
    say "session valid (/api/user=200)"
    return 0
  fi
  say "session invalid (/api/user=$st); refreshing via wp-login.mjs"
  [ -f "$LOGIN_JS" ] || halt "missing $LOGIN_JS; run EX18 first"
  start_forwarder
  local rc=0
  (
    cd "$APP" || exit 1
    WP_URL="$WP" GT_USER="$BOT" GT_PASS="$PASS" REPO="$REPO" \
    SESSION_PATH="$SESSION" BEARER_FILE="$BEARER_FILE" PW_HEADLESS="$PW_HEADLESS" \
    node "$LOGIN_JS"
  ) 2>&1 | sed 's/^/    /' || rc=$?
  [ "$rc" = 0 ] || halt "session refresh failed rc=$rc"
  USER_SESS="$(extract_user_sess)"
  [ -n "$USER_SESS" ] || halt "user_sess still missing after refresh"
  st="$(curl -sS -m 10 -o "$TMP/user_check2.json" -w '%{http_code}' -H "Cookie: user_sess=$USER_SESS" "$WP/api/user" 2>/dev/null || echo 000)"
  [ "$st" = 200 ] || halt "session still invalid after refresh (/api/user=$st)"
  say "session refreshed OK"
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
  local url="$1" secret="$2"
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

try_repair_curl(){
  local url="$1" body="$2" auth="$3"
  local args=(
    -sS -m 20
    -o "$TMP/repair_resp.txt"
    -w '%{http_code}'
    -X POST
    -H 'Content-Type: application/json'
    -H "Origin: $WP"
    -H "Referer: $WP/repos"
    -H 'X-Requested-With: XMLHttpRequest'
  )
  case "$auth" in
    cookie) args+=(-H "Cookie: user_sess=$USER_SESS") ;;
    bearer) args+=(-H "Authorization: Bearer $USER_SESS") ;;
    both) args+=(-H "Cookie: user_sess=$USER_SESS" -H "Authorization: Bearer $USER_SESS") ;;
    apitoken) [ -n "$API_TOKEN" ] || return 1; args+=(-H "Authorization: Bearer $API_TOKEN") ;;
    *) return 1 ;;
  esac
  printf '%s' "$body" > "$TMP/repair_body.json"
  args+=(--data @"$TMP/repair_body.json")
  local hc
  hc="$(curl "${args[@]}" "$url" 2>"$TMP/repair_err.txt" || true)"
  [ -n "$hc" ] || hc=000
  local snippet
  snippet="$(head -c 220 "$TMP/repair_resp.txt" 2>/dev/null | tr '\n\r' '  ' | mask_all || true)"
  say "REPAIR_TRY auth=$auth url=$(mask_str "$url") status=$hc body=${snippet:-}"
  if [ "$hc" != 000 ]; then
    head -c 180 "$TMP/repair_err.txt" 2>/dev/null | mask_all | sed 's/^/    err: /' || true
  fi
  case "$hc" in
    2*) REPAIR_OK=yes; REPAIR_DETAIL="curl:$auth:$url:$hc"; return 0 ;;
    *) return 1 ;;
  esac
}

try_create_token_curl(){
  local auth="$1" body="$2"
  local args=(
    -sS -m 20
    -o "$TMP/token_resp.txt"
    -w '%{http_code}'
    -X POST
    -H 'Content-Type: application/json'
    -H "Origin: $WP"
    -H "Referer: $WP/settings"
    -H 'X-Requested-With: XMLHttpRequest'
  )
  case "$auth" in
    cookie) args+=(-H "Cookie: user_sess=$USER_SESS") ;;
    bearer) args+=(-H "Authorization: Bearer $USER_SESS") ;;
    both) args+=(-H "Cookie: user_sess=$USER_SESS" -H "Authorization: Bearer $USER_SESS") ;;
    *) return 1 ;;
  esac
  printf '%s' "$body" > "$TMP/token_body.json"
  args+=(--data @"$TMP/token_body.json")
  local hc
  hc="$(curl "${args[@]}" "$WP/api/user/token" 2>/dev/null || echo 000)"
  local snippet
  snippet="$(head -c 180 "$TMP/token_resp.txt" 2>/dev/null | tr '\n\r' '  ' | mask_all || true)"
  say "TOKEN_TRY auth=$auth status=$hc body=${snippet:-}"
  if case "$hc" in 2*) true ;; *) false ;; esac; then
    API_TOKEN="$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
if isinstance(d, dict):
    for k in ("token", "access_token", "sha", "secret"):
        v = d.get(k)
        if isinstance(v, str) and len(v) >= 20:
            print(v)
            break
' "$TMP/token_resp.txt" 2>/dev/null || true)"
    if [ -n "$API_TOKEN" ]; then
      say "TOKEN_CREATED len=${#API_TOKEN}"
      return 0
    fi
  fi
  return 1
}

hr "X0 preflight"
for c in python3 curl git podman awk sed grep base64 node; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"
done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
[ -s "$SESSION" ] || halt "missing Woodpecker session file"
mkdir -p "$CD" "$SEC" "$APP"
touch "$IDX"

BOT="$(cat "$BOT_FILE" | tr -d '\n\r')"
PASS="$(cat "$PASS_FILE" | tr -d '\n\r')"
WP_SECRET="$(envval woodpecker-server WOODPECKER_GITEA_SECRET)"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"

REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"

ROW="$(psql_wp "SELECT hash||'|'||forge_remote_id FROM repos WHERE id=$REPO_ID LIMIT 1")"
REPO_HASH="${ROW%%|*}"
FORGE_ID="${ROW##*|}"
[ -n "$REPO_HASH" ] || halt "could not extract repo hash"

USER_SESS="$(extract_user_sess)"
[ -n "$USER_SESS" ] || halt "could not extract user_sess from session"

BOT_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PASS")"

API_TOKEN=""
HOOK_TOKEN=""
REPAIR_OK=no
REPAIR_DETAIL=""

say "bot=$BOT"
say "gitea_url=$GT"
say "woodpecker_repo_id=$REPO_ID forge_remote_id=$FORGE_ID"
say "user_sess_present=yes len=${#USER_SESS}"
say "repo_hash_mask=$(mask_str "${REPO_HASH:0:6}...len=${#REPO_HASH}")"

if [ "$MODE" = check ]; then
  hr "X1 plan (check mode)"
  say "  1) validate/refresh Woodpecker session"
  say "  2) delete existing bad Gitea hooks"
  say "  3) call Woodpecker repair API (curl, then Playwright fallback)"
  say "  4) if generated hook uses 127.0.0.1, rewrite host to woodpecker-server:8000 preserving token"
  say "  5) push real commit and gate on WP Postgres pipelines.status=success"
  say "[RESULT] EX35 CHECK - nothing written."
  exit 0
fi

hr "X1 detect Gitea DB and read-only repo/user state"
GTDB="gitea"
if ! podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc 'SELECT 1' >/dev/null 2>&1; then
  GTDB=""
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    if podman exec postgres psql -U "$PGU" -d "$db" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='webhook' LIMIT 1" 2>/dev/null | grep -q 1; then
      GTDB="$db"
      break
    fi
  done < <(podman exec postgres psql -U "$PGU" -d postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)
fi
say "gitea_db=${GTDB:-none}"

say "--- Woodpecker repo state ---"
psql_wp "SELECT id, owner, name, active, require_approval, config_path FROM repos WHERE id=$REPO_ID" | sed 's/^/    /' || true
say "--- Woodpecker user state ---"
psql_wp "SELECT id, login, admin, forge_id FROM users ORDER BY id LIMIT 5" | sed 's/^/    /' || true

hr "X2 ensure session valid"
refresh_session_if_needed

hr "X3 delete existing Gitea hooks (remove bad session-JWT webhook)"
delete_gitea_hooks

hr "X4 attempt Woodpecker repair via curl"
for auth in cookie bearer both; do
  if try_repair_curl "$WP/api/repos/$REPO_ID/repair" '{}' "$auth"; then break; fi
done

if [ "$REPAIR_OK" != yes ]; then
  for auth in cookie bearer both; do
    if try_repair_curl "$WP/api/repos/repair" "{\"repo_id\":$REPO_ID}" "$auth"; then break; fi
  done
fi

if [ "$REPAIR_OK" != yes ]; then
  say "repair not accepted yet; attempting API token creation"
  for auth in cookie bearer both; do
    for body in \
      '{"name":"brick12","scopes":["admin:repo"]}' \
      '{"name":"brick12","scope":"admin:repo"}' \
      '{"name":"brick12"}' \
      '{}'; do
      if try_create_token_curl "$auth" "$body"; then break 2; fi
    done
  done
  if [ -n "$API_TOKEN" ]; then
    try_repair_curl "$WP/api/repos/$REPO_ID/repair" '{}' "apitoken" || true
  fi
fi

say "curl repair result: ok=$REPAIR_OK detail=${REPAIR_DETAIL:-none}"

if [ "$REPAIR_OK" != yes ]; then
  hr "X5 Playwright repair fallback"
  cat > "$REPAIR_JS" <<'NODE35EOF'
import { chromium } from 'playwright';

const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const SESSION = process.env.SESSION_PATH || '';
const REPO_ID = process.env.REPO_ID || '';
const OWNER = process.env.GT_USER || '';
const REPO = process.env.REPO || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';

const log = (...a) => console.log('   ', ...a);

function safeBody(s) {
  return String(s || '').replace(/eyJ[A-Za-z0-9_.-]{10,}/g, '[JWT]').slice(0, 220).replace(/\s+/g, ' ');
}

const browser = await chromium.launch({ headless: HEADLESS });
const context = await browser.newContext({ storageState: SESSION });
const page = await context.newPage();

page.on('response', async resp => {
  try {
    const u = resp.url();
    if (u.includes('/api/')) log('APIRESP', resp.request().method(), resp.status(), u);
  } catch {}
});

async function postApi(path, body, extraHeaders = {}) {
  return await page.evaluate(async ({ path, body, extraHeaders }) => {
    try {
      const headers = {
        'Content-Type': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        ...extraHeaders
      };
      const r = await fetch(path, {
        method: 'POST',
        credentials: 'include',
        headers,
        body: JSON.stringify(body || {})
      });
      const t = await r.text();
      let token = '';
      try {
        const j = JSON.parse(t);
        for (const k of ['token','access_token','sha','secret']) {
          if (typeof j?.[k] === 'string' && j[k].length >= 20) { token = j[k]; break; }
        }
      } catch {}
      return { status: r.status, body: t.slice(0, 300), token };
    } catch (e) {
      return { status: 0, body: 'ERR:' + String(e), token: '' };
    }
  }, { path, body, extraHeaders });
}

try {
  await page.goto(WP, { waitUntil: 'domcontentloaded', timeout: 30000 });
  const me = await context.request.get(WP + '/api/user');
  log('api/user status=', me.status());

  let res = await postApi(`/api/repos/${REPO_ID}/repair`, {});
  log('repair repo_id status=', res.status, 'body=', safeBody(res.body));

  if (![200,201,204].includes(res.status)) {
    res = await postApi('/api/repos/repair', { repo_id: Number(REPO_ID) });
    log('repair global status=', res.status, 'body=', safeBody(res.body));
  }

  if (![200,201,204].includes(res.status)) {
    const tok = await postApi('/api/user/token', { name: 'brick12', scopes: ['admin:repo'] });
    log('token create status=', tok.status, 'token_present=', Boolean(tok.token), 'len=', tok.token ? tok.token.length : 0);
    if (tok.token) {
      res = await postApi(`/api/repos/${REPO_ID}/repair`, {}, { Authorization: 'Bearer ' + tok.token });
      log('repair bearer-token status=', res.status, 'body=', safeBody(res.body));
    }
  }

  if (![200,201,204].includes(res.status)) {
    log('UI fallback: navigating to settings');
    await page.goto(`${WP}/repos/${encodeURIComponent(OWNER)}/${encodeURIComponent(REPO)}/settings`, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
    await page.waitForTimeout(3000);
    const btns = await page.getByRole('button').allTextContents().catch(() => []);
    log('settings buttons=', JSON.stringify(btns.slice(0, 40)));
    const loc = page.getByRole('button', { name: /repair|save|enable|activate/i }).first();
    if (await loc.isVisible().catch(() => false)) {
      log('clicking UI repair/save control');
      await loc.click().catch(() => {});
      await page.waitForTimeout(5000);
    }
  }

  await browser.close().catch(() => {});
  process.exit(0);
} catch (e) {
  log('FAIL:', String(e && e.message || e));
  await page.screenshot({ path: '/tmp/wp-repair-fail.png' }).catch(() => {});
  await browser.close().catch(() => {});
  process.exit(1);
}
NODE35EOF
  chmod 600 "$REPAIR_JS"

  UI_RC=0
  (
    cd "$APP" || exit 1
    WP_URL="$WP" SESSION_PATH="$SESSION" REPO_ID="$REPO_ID" GT_USER="$BOT" REPO="$REPO" PW_HEADLESS="$PW_HEADLESS" \
    node "$REPAIR_JS"
  ) 2>&1 | sed 's/^/  /' || UI_RC=$?
  say "playwright repair rc=$UI_RC"
fi

hr "X6 verify generated webhook and rewrite host to internal if needed"
HOOK_ROW="$(gitea_sql_raw "SELECT id||'|'||url FROM webhook ORDER BY id DESC LIMIT 1")"
[ -n "$HOOK_ROW" ] || {
  say "--- woodpecker-server logs tail 40 ---"
  podman logs --tail 40 woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX35 repair attempted ($REPAIR_DETAIL) but no Gitea webhook exists afterward."
  halt "no webhook after repair"
}

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

if [ -n "$USER_SESS" ] && [ "$HOOK_TOKEN" = "$USER_SESS" ]; then
  say "generated hook still uses user session JWT; deleting and failing"
  delete_gitea_hooks
  ledger "PARTIAL" "EX35 repair produced bad user-session webhook; deleted."
  halt "repair produced user-session token"
fi

NEED_REWRITE=no
case "$HOOK_URL" in
  *woodpecker-server:8000*) NEED_REWRITE=no ;;
  *) NEED_REWRITE=yes ;;
esac

if [ "$NEED_REWRITE" = yes ]; then
  [ -n "$HOOK_TOKEN" ] || {
    say "generated hook is not internal and has no access_token; cannot safely rewrite"
    ledger "PARTIAL" "EX35 generated non-internal hook without access_token: $(mask_str "$HOOK_URL")"
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
    ledger "PARTIAL" "EX35 could not create internal rewritten hook."
    halt "create rewritten hook failed"
  }
  HOOK_URL="$NEW_URL"
fi

ACTIVE="$(gitea_sql_raw "SELECT is_active FROM webhook WHERE id=$HOOK_ID LIMIT 1" | tr -d ' \n')"
if [ "$ACTIVE" != "t" ]; then
  say "hook inactive; recreating active internal hook"
  delete_gitea_hooks
  create_gitea_hook "$HOOK_URL" "$REPO_HASH" || halt "recreate active hook failed"
fi

say "final hook url=$(mask_str "$HOOK_URL")"

hr "X7 clean real push"
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
  git commit -q -m "ci: ex35 real push $(date -Is)" || halt "commit failed"
else
  git commit -q --allow-empty -m "ci: ex35 retrigger $(date -Is)" || halt "empty commit failed"
fi

git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "HEAD:$DEFAULT_BRANCH" || halt "push failed"
PUSH_SHA="$(git rev-parse HEAD)"
say "pushed SHA=$PUSH_SHA"
cd / || true

hr "X8 poll for NEW pipeline"
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

hr "X9 Gitea delivery evidence"
gitea_sql "SELECT id, repo_id, url, is_active FROM webhook ORDER BY id DESC LIMIT 5;" | sed 's/^/    /'
say "--- hook_task receipts (SELECT *) ---"
gitea_sql "SELECT * FROM hook_task ORDER BY id DESC LIMIT 5;" | sed 's/^/    /'

if [ "$SUCCESS" != yes ]; then
  hr "X10 failure diagnostics"
  say "latest pipeline id=${NEW_ID:-none} #${PIPE_NUM:-none} status=${PIPE_STATUS:-none}"
  if [ -n "${NEW_ID:-}" ]; then
    say "--- pipeline row ---"
    psql_wp "SELECT id, number, status, event, branch, commit, message, errors::text FROM pipelines WHERE id=$NEW_ID" | sed 's/^/    /' || true
    say "--- workflows ---"
    psql_wp "SELECT id, pipeline_id, name, state, error FROM workflows WHERE pipeline_id=$NEW_ID" | sed 's/^/    /' || true
  fi
  say "--- woodpecker-server logs since $SINCE ---"
  podman logs --since "$SINCE" woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  say "--- woodpecker-agent logs since $SINCE ---"
  podman logs --since "$SINCE" woodpecker-agent 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX35 repair_detail=${REPAIR_DETAIL:-none}; hook=$(mask_str "$HOOK_URL"); push SHA=$PUSH_SHA; pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none}. Paste X9-X10."
  halt "pipeline did not succeed"
fi

hr "X11 best-effort log proof"
LOG_PROOF=""
CK="$(cookies_from_session)"
try_log(){
  local path="$1" auth="$2"
  local args=(-sS -m 15 -o "$TMP/logs.txt" -w '%{http_code}')
  case "$auth" in
    cookie) [ -n "$CK" ] && args+=(-b "$CK") ;;
    apitoken) [ -n "$API_TOKEN" ] && args+=(-H "Authorization: Bearer $API_TOKEN") ;;
    usertoken) [ -n "$USER_SESS" ] && args+=(-H "Authorization: Bearer $USER_SESS") ;;
  esac
  local hc
  hc="$(curl "${args[@]}" "$path" 2>/dev/null || echo 000)"
  local hit
  hit="$(grep -a 'Hello from Woodpecker CI!' "$TMP/logs.txt" 2>/dev/null | head -1 || true)"
  say "LOG_TRY auth=$auth status=$hc path=$(mask_str "$path")"
  if [ -n "$hit" ]; then LOG_PROOF="$hit"; return 0; fi
  return 1
}

if [ -n "$PIPE_NUM" ]; then
  for path in \
    "$WP/api/repos/$BOT/$REPO/pipelines/$PIPE_NUM/logs" \
    "$WP/api/repos/$BOT/$REPO/builds/$PIPE_NUM/logs" \
    "$WP/api/repos/$REPO_ID/pipelines/$PIPE_NUM/logs" \
    "$WP/api/repos/$REPO_ID/logs/$PIPE_NUM"; do
    for auth in cookie apitoken usertoken; do
      try_log "$path" "$auth" && break 2
    done
  done
fi

[ -z "$LOG_PROOF" ] && LOG_PROOF="$(podman logs --since "$SINCE" woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
say "log proof: ${LOG_PROOF:-none (DB success is the gate)}"

hr "X12 RESULT"
say "[RESULT] EX35 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
say "  repo: $BOT/$REPO"
say "  woodpecker_repo_id: $REPO_ID"
say "  repair_detail: ${REPAIR_DETAIL:-playwright-or-hook-verified}"
say "  final_hook_url: $(mask_str "$HOOK_URL")"
say "  pipeline: #${PIPE_NUM:-?}"
say "  status: success"
say "  push SHA: $PUSH_SHA"
say "  log proof: ${LOG_PROOF:-n/a}"

ledger "PASS" "EX35: deleted bad session-JWT webhook; repaired/regenerated Woodpecker hook token; rewrote host to internal woodpecker-server:8000 when needed; real push created pipeline #$PIPE_NUM status=success; log_proof=$([ -n "$LOG_PROOF" ] && echo yes || echo no). Brick 12 CLOSED."

exit 0
