#!/usr/bin/env bash
# 20261107-GX05 — login/network audit and Brick 12 handoff.
#
# Verifies:
#   - GX01-GX04 codemod records exist
#   - Gitea host/container topology
#   - persistent gitea:3000 host bridge from GX04
#   - Gitea human admin API login
#   - Woodpecker login endpoints
#   - optional saved Woodpecker bot session
#   - Brick 12 DB/webhook readiness
#
# Modes:
#   audit     default, read-only except ledger row
#   brick12   runs EX37 if present after audit
#
# No secret values are printed.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="gx05-login-audit-and-brick12-handoff-v1"
MODE="${1:-audit}"

REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"
PGDB="woodpecker"
SERVICE="aether-gitea-loop-3000.service"

ADMIN_U_FILE="$SEC/gitea-admin.user"
ADMIN_P_FILE="$SEC/gitea-admin.pass"
ADMIN_E_FILE="$SEC/gitea-admin.email"
BOT_U_FILE="$SEC/gitea-wp-bot.user"
BOT_P_FILE="$SEC/gitea-wp-bot.pass"
SESSION="$SEC/woodpecker-session.json"
EX37="$CD/20261107-EX37-robust-wait-loop-brick12-close.sh"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD" "$SEC"
touch "$IDX"

ADMIN_PASS="$(tr -d '\n\r' < "$ADMIN_P_FILE" 2>/dev/null || true)"
BOT_PASS="$(tr -d '\n\r' < "$BOT_P_FILE" 2>/dev/null || true)"
BOT="$(tr -d '\n\r' < "$BOT_U_FILE" 2>/dev/null || true)"
ADMIN_USER="$(tr -d '\n\r' < "$ADMIN_U_FILE" 2>/dev/null || true)"

export ADMIN_PASS BOT_PASS WP_COOKIE="" REPO_HASH="" HOOK_TOKEN=""

mask(){
  python3 -c '
import os, re, sys
secrets = []
for k in ("ADMIN_PASS","BOT_PASS","WP_COOKIE","REPO_HASH","HOOK_TOKEN"):
    v = os.environ.get(k, "")
    if v:
        secrets.append(v)

for line in sys.stdin:
    for s in secrets:
        line = line.replace(s, "[REDACTED]")
    line = re.sub(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}", "[JWT]", line)
    line = re.sub(r"[0-9a-fA-F]{40,}", "[HEX]", line)
    sys.stdout.write(line)
'
}

ledger(){
  local gate="$1"
  local desc="$2"
  local row_token="${TOKEN}:${gate}"
  if ! grep -qF "$row_token" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=%s | %s |\n' \
      "$(date +%F)" "$row_token" "$gate" "$desc" >> "$IDX"
    say "ledger row appended: $row_token"
  else
    say "ledger row already exists: $row_token"
  fi
}

http_code(){
  curl -sS -m 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000
}

is_ok_http(){
  case "${1:-000}" in
    2??|3??) return 0 ;;
    *) return 1 ;;
  esac
}

psql_wp(){
  podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true
}

hr "A0 codemod inventory"
say "recent codemod scripts:"
find "$CD" -maxdepth 1 -type f \( -name '*GX*.sh' -o -name '*EX*.sh' \) -printf '%TY-%Tm-%Td %TH:%TM %f\n' 2>/dev/null |
  sort |
  tail -50 |
  sed 's/^/    /' || true

say ""
say "recent ledger rows:"
grep -E 'gx0[1-9]|ex3[0-9]' "$IDX" 2>/dev/null | tail -50 | sed 's/^/    /' || say "    none"

hr "A1 Gitea/Woodpecker topology"
GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
GT_HOST_PORT="${GT_HOST_PORT:-3001}"
GT="http://127.0.0.1:$GT_HOST_PORT"

say "gitea container:3000 -> host $GT"
say "woodpecker host URL  = $WP"
say "woodpecker internal  = http://woodpecker-server:8000"

SERVICE_STATE="unknown"
if systemctl --user is-active --quiet "$SERVICE"; then
  SERVICE_STATE="active"
elif systemctl --user is-enabled --quiet "$SERVICE" 2>/dev/null; then
  SERVICE_STATE="enabled-but-inactive"
else
  SERVICE_STATE="inactive"
fi
say "GX04 service state = $SERVICE_STATE"

say ""
say "hosts resolution:"
getent hosts gitea 2>/dev/null | sed 's/^/    /' || say "    gitea does not resolve"

GITEA_LOCAL_CODE="$(http_code "$GT/")"
GITEA_ALIAS_CODE="$(http_code "http://127.0.0.2:3000/")"
GITEA_DNS_CODE="$(http_code "http://gitea:3000/")"
WP_ROOT_CODE="$(http_code "$WP/")"
WP_LOGIN_CODE="$(http_code "$WP/login")"
WP_API_USER_CODE="$(http_code "$WP/api/user")"

say ""
say "HTTP checks:"
say "    $GT/                         = $GITEA_LOCAL_CODE"
say "    http://127.0.0.2:3000/       = $GITEA_ALIAS_CODE"
say "    http://gitea:3000/           = $GITEA_DNS_CODE"
say "    $WP/                  = $WP_ROOT_CODE"
say "    $WP/login             = $WP_LOGIN_CODE"
say "    $WP/api/user          = $WP_API_USER_CODE (401 expected when unauthenticated)"

NET_OK=no
if [ "$SERVICE_STATE" = active ] && is_ok_http "$GITEA_DNS_CODE"; then
  NET_OK=yes
fi

if [ "$NET_OK" != yes ]; then
  say ""
  say "--- recent GX04 service logs ---"
  journalctl --user -u "$SERVICE" -n 40 --no-pager 2>&1 | sed 's/^/    /' || true
fi

hr "A2 Gitea human admin API login"
ADMIN_OK=no
if [ -s "$ADMIN_U_FILE" ] && [ -s "$ADMIN_P_FILE" ]; then
  say "username file = $ADMIN_U_FILE"
  say "password file = $ADMIN_P_FILE"
  say "email file    = $ADMIN_E_FILE"

  GT_URL="$GT" GITEA_ADMIN_USER_FILE="$ADMIN_U_FILE" GITEA_ADMIN_PASS_FILE="$ADMIN_P_FILE" python3 - <<'PY' > "$TMP/admin.out" 2>&1
import base64, json, os, urllib.request, urllib.error

uf = os.environ.get("GITEA_ADMIN_USER_FILE", "")
pf = os.environ.get("GITEA_ADMIN_PASS_FILE", "")
base = os.environ.get("GT_URL", "").rstrip("/")

try:
    user = open(uf, "r", encoding="utf-8").read().strip()
    pwd = open(pf, "r", encoding="utf-8").read().strip()
except Exception as e:
    print("admin_api_error= credential file read failed:", e)
    raise SystemExit(0)

if not user or not base:
    print("admin_api_error= missing user or URL")
    raise SystemExit(0)

token = base64.b64encode(f"{user}:{pwd}".encode()).decode()
req = urllib.request.Request(base + "/api/v1/user", headers={"Authorization": "Basic " + token})

try:
    with urllib.request.urlopen(req, timeout=10) as r:
        d = json.load(r)
        print("admin_api_status=", r.status)
        print("login=", d.get("login"))
        print("id=", d.get("id"))
        print("is_admin=", d.get("is_admin"))
        print("active=", d.get("active"))
except urllib.error.HTTPError as e:
    print("admin_api_status=", e.code)
    body = e.read().decode("utf-8", "replace")[:220]
    print("admin_api_body=", body.replace("\n", " "))
except Exception as e:
    print("admin_api_error=", type(e).__name__, str(e)[:180])
PY

  mask < "$TMP/admin.out" | sed 's/^/    /' || true
  if grep -q 'admin_api_status= 200' "$TMP/admin.out" || grep -q 'admin_api_status=200' "$TMP/admin.out"; then
    ADMIN_OK=yes
  fi
else
  say "missing Gitea admin credential files; run GX02 first"
fi

hr "A3 Woodpecker saved bot session check"
WP_SESSION_OK="skipped"
if [ -s "$SESSION" ]; then
  WP_COOKIE="$(WP_SESSION_FILE="$SESSION" python3 -c '
import json, os
p = os.environ.get("WP_SESSION_FILE", "")
try:
    d = json.load(open(p, "r", encoding="utf-8"))
except Exception:
    raise SystemExit(0)
parts = []
for c in d.get("cookies", []) or []:
    dom = (c.get("domain") or "").lstrip(".")
    if dom in ("127.0.0.1", "localhost", ""):
        parts.append(f"{c.get(\"name\")}={c.get(\"value\")}")
print("; ".join(parts))
' 2>/dev/null || true)"
  export WP_COOKIE

  if [ -n "$WP_COOKIE" ]; then
    WP_URL="$WP" WP_COOKIE="$WP_COOKIE" python3 - <<'PY' > "$TMP/wp_session.out" 2>&1
import json, os, urllib.request, urllib.error

base = os.environ.get("WP_URL", "").rstrip("/")
cookie = os.environ.get("WP_COOKIE", "")

if not base or not cookie:
    print("wp_session_error= missing URL or cookie")
    raise SystemExit(0)

req = urllib.request.Request(base + "/api/user", headers={"Cookie": cookie})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        d = json.load(r)
        print("wp_session_status=", r.status)
        print("login=", d.get("login"))
        print("id=", d.get("id"))
        print("admin=", d.get("admin"))
except urllib.error.HTTPError as e:
    print("wp_session_status=", e.code)
except Exception as e:
    print("wp_session_error=", type(e).__name__, str(e)[:180])
PY
    mask < "$TMP/wp_session.out" | sed 's/^/    /' || true
    if grep -Eq 'wp_session_status= ?200' "$TMP/wp_session.out"; then
      WP_SESSION_OK=yes
    else
      WP_SESSION_OK=no
    fi
  else
    say "no usable 127.0.0.1 cookies in session file"
    WP_SESSION_OK=no
  fi
else
  say "no Woodpecker session file yet: $SESSION"
fi

hr "A4 Brick 12 DB/webhook readiness"
REPO_PRESENT=no
PIPE_MAX_ID=0
SUCCESS_COUNT=0
WEBHOOK_COUNT=0

if [ -n "$BOT" ]; then
  BOT_SQL="${BOT//\'/\'\'}"
  REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(owner)=lower('${BOT_SQL}') AND lower(name)=lower('${REPO}') LIMIT 1" | tr -d ' \n')"
  if [[ "$REPO_ID" =~ ^[0-9]+$ ]]; then
    REPO_PRESENT=yes
    say "woodpecker repo id=$REPO_ID owner=$BOT name=$REPO"
    psql_wp "SELECT id, owner, name, active, forge_remote_id FROM repos WHERE id=$REPO_ID" | mask | sed 's/^/    /' || true
    PIPE_MAX_ID="$(psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n')"
    SUCCESS_COUNT="$(psql_wp "SELECT COUNT(*) FROM pipelines WHERE repo_id=$REPO_ID AND status='success'" | tr -d ' \n')"
    say "pipeline_max_id=${PIPE_MAX_ID:-0} success_count=${SUCCESS_COUNT:-0}"
    psql_wp "SELECT id, number, status, event, branch FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 5" | mask | sed 's/^/    /' || true
  else
    say "Woodpecker repo row not found for $BOT/$REPO"
  fi
else
  say "missing bot username file; cannot check repo ownership"
fi

GTDB="gitea"
if ! podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc 'SELECT 1' >/dev/null 2>&1; then
  GTDB=""
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    if podman exec postgres psql -U "$PGU" -d "$db" -tAc \
      "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='webhook' LIMIT 1" \
      2>/dev/null | grep -q 1; then
      GTDB="$db"
      break
    fi
  done < <(podman exec postgres psql -U "$PGU" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)
fi

say "gitea_db=${GTDB:-none}"
if [ -n "$GTDB" ]; then
  WEBHOOK_COUNT="$(podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc "SELECT COUNT(*) FROM webhook" 2>/dev/null | tr -d ' \n')"
  say "gitea webhook_count=${WEBHOOK_COUNT:-0}"
  podman exec postgres psql -U "$PGU" -d "$GTDB" -X --pset=pager=off -c \
    "SELECT id, repo_id, url, is_active FROM webhook ORDER BY id DESC LIMIT 5;" 2>&1 |
    mask | sed 's/^/    /' || true
fi

BRICK12_READY=no
if [ "$REPO_PRESENT" = yes ] && [ "${SUCCESS_COUNT:-0}" -ge 1 ]; then
  BRICK12_READY=yes
fi

hr "A5 RESULT"
say "GX04 persistent bridge: $NET_OK"
say "Gitea adminX API login:  $ADMIN_OK"
say "Woodpecker bot session:  $WP_SESSION_OK"
say "Brick 12 DB success:     $BRICK12_READY"
say ""
say "Use this URL in your normal browser:"
say "  $WP/login"
say "Do NOT use localhost for this flow; use 127.0.0.1 because the OAuth redirect_uri is 127.0.0.1."
say ""
say "If your browser still says gitea:3000 unreachable:"
say "  1. Fully close all browser windows, then reopen."
say "  2. Try incognito/private mode."
say "  3. Disable browser Secure DNS / DNS-over-HTTPS temporarily."
say "  4. Verify in terminal:"
say "       getent hosts gitea"
say "       curl -I http://gitea:3000/"
say "       systemctl --user status $SERVICE --no-pager"

if [ "$MODE" = brick12 ]; then
  hr "A6 Brick 12 handoff"
  if [ -f "$EX37" ]; then
    say "running EX37: $EX37"
    bash "$EX37" run 2>&1 | tee "${OUT%.out}.brick12.out"
  else
    say "EX37 not found at:"
    say "  $EX37"
    say "Create/run EX37 next; it is the robust Woodpecker repair + push + DB-gate script."
  fi
fi

GATE="PARTIAL"
if [ "$NET_OK" = yes ] && [ "$ADMIN_OK" = yes ] && [ "$BRICK12_READY" = yes ]; then
  GATE="PASS"
elif [ "$NET_OK" = yes ] && [ "$ADMIN_OK" = yes ]; then
  GATE="LOGIN-OK-BRICK12-OPEN"
fi

ledger "$GATE" "GX05 audit: net=$NET_OK admin_login=$ADMIN_OK wp_session=$WP_SESSION_OK repo_present=$REPO_PRESENT success_count=${SUCCESS_COUNT:-0} webhook_count=${WEBHOOK_COUNT:-0} mode=$MODE"
say "saved: ${OUT%.out}.brick12.out (if brick12 mode ran)"
exit 0
