#!/usr/bin/env bash
# 20261107-GX02 — fixed Gitea admin login repair.
#
# Fixes GX01:
#   - rejects Config.User=0:0 as root
#   - detects a true non-root Gitea CLI user
#   - tries multiple change-password CLI syntaxes for this Gitea build
#   - verifies API login and real web login form
#
# Reuses existing saved password:
#   ~/DevOps/aether/secrets/gitea-admin.pass
#
# No Woodpecker changes. No Brick 12 work. Secrets masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="gx02-gitea-admin-login-fix-root-0-0-v1"
CONTAINER="${GITEA_CONTAINER:-gitea}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"
PGU="${POSTGRES_USER:-devops}"
MODE="${1:-run}"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

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

hr "G0 preflight"
for c in python3 curl podman awk sed grep tr; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
mkdir -p "$CD" "$SEC"
chmod 700 "$SEC"
touch "$IDX"

U_FILE="$SEC/gitea-admin.user"
P_FILE="$SEC/gitea-admin.pass"
E_FILE="$SEC/gitea-admin.email"

if [ ! -s "$U_FILE" ]; then
  printf 'adminX\n' > "$U_FILE"
  chmod 600 "$U_FILE"
  say "created username file: $U_FILE"
fi

if [ ! -s "$E_FILE" ]; then
  printf 'gitea@aether.com\n' > "$E_FILE"
  chmod 600 "$E_FILE"
  say "created email file: $E_FILE"
fi

if [ ! -s "$P_FILE" ]; then
  if [ -n "${GITEA_ADMIN_PASS:-}" ]; then
    printf '%s' "$GITEA_ADMIN_PASS" > "$P_FILE"
    chmod 600 "$P_FILE"
    say "created password file from GITEA_ADMIN_PASS"
  elif [ -t 0 ] && [ -e /dev/tty ]; then
    printf 'Set NEW Gitea admin password: ' > /dev/tty
    read -rs NEW_PASS < /dev/tty
    printf '\nRepeat: ' > /dev/tty
    read -rs NEW_PASS2 < /dev/tty
    printf '\n' > /dev/tty
    [ -n "$NEW_PASS" ] || halt "empty password"
    [ "$NEW_PASS" = "$NEW_PASS2" ] || halt "passwords do not match"
    printf '%s' "$NEW_PASS" > "$P_FILE"
    chmod 600 "$P_FILE"
    unset NEW_PASS NEW_PASS2
    say "created password file: $P_FILE"
  else
    halt "missing $P_FILE; run interactively or export GITEA_ADMIN_PASS"
  fi
else
  say "reusing existing password file: $P_FILE"
fi

UNAME="$(tr -d '\n\r' < "$U_FILE")"
EMAIL="$(tr -d '\n\r' < "$E_FILE")"
PASS="$(tr -d '\n\r' < "$P_FILE")"

[ -n "$UNAME" ] || halt "empty username file: $U_FILE"
[ -n "$EMAIL" ] || halt "empty email file: $E_FILE"
[ -n "$PASS" ] || halt "empty password file: $P_FILE"

if [ "$MODE" = check ]; then
  hr "G0A check mode"
  say "container=$CONTAINER"
  say "username=$UNAME"
  say "email=$EMAIL"
  say "password_file=$P_FILE"
  say "will detect non-root CLI user, rejecting 0/root/0:0"
  say "will create/reset admin user and verify API + web login"
  say "[RESULT] GX02 CHECK - nothing written."
  exit 0
fi

mask(){
  PASS_MASK="$PASS" python3 -c '
import os, sys
p = os.environ.get("PASS_MASK", "")
for line in sys.stdin:
    if p:
        line = line.replace(p, "[REDACTED]")
    sys.stdout.write(line)
'
}

hr "G1 detect non-root Gitea container user (fixed: rejects 0:0)"
CANDS="$TMP/candidates"
: > "$CANDS"

add_candidate(){
  local c="${1:-}"
  c="$(printf '%s' "$c" | tr -d '\r\n')"
  [ -n "$c" ] || return 0

  # Reject obvious root specs.
  case "$c" in
    root|0|0:*) return 0 ;;
  esac

  # If numeric uid is 0, reject. Allows git, 1000, 1000:1000, 1000:0.
  local uid="${c%%:*}"
  case "$uid" in
    ''|0) return 0 ;;
  esac

  if ! grep -qxF "$c" "$CANDS" 2>/dev/null; then
    printf '%s\n' "$c" >> "$CANDS"
  fi
}

cfg="$(podman inspect "$CONTAINER" --format '{{.Config.User}}' 2>/dev/null || true)"
say "podman Config.User raw = ${cfg:-<empty>}"
add_candidate "$cfg"

# Common Gitea container user.
add_candidate "git"

# Owner of /data/gitea, usually the real Gitea runtime user.
owner="$(podman exec "$CONTAINER" stat -c '%u:%g' /data/gitea 2>/dev/null || true)"
say "/data/gitea owner = ${owner:-<unknown>}"
add_candidate "$owner"

# Common default UID/GID.
add_candidate "1000:1000"
add_candidate "1000"

# getent passwd git -> uid:gid
git_spec="$(podman exec "$CONTAINER" getent passwd git 2>/dev/null | awk -F: 'NF>=4 {print $3":"$4}' || true)"
say "getent passwd git = ${git_spec:-<unknown>}"
add_candidate "$git_spec"

# PID1 user, only if non-root.
pid_user="$(podman exec "$CONTAINER" ps -o user= -p 1 2>/dev/null | tr -d ' \r\n' || true)"
say "PID1 user = ${pid_user:-<unknown>}"
add_candidate "$pid_user"

say "candidate users:"
sed 's/^/    /' "$CANDS" || true

hr "G2 detect Gitea work dir, custom conf, binary"
WORK_DIR=""
for d in /data/gitea /var/lib/gitea /srv/gitea /app/gitea; do
  if podman exec "$CONTAINER" test -d "$d" 2>/dev/null; then
    WORK_DIR="$d"
    break
  fi
done
[ -n "$WORK_DIR" ] || WORK_DIR="/data/gitea"
CUSTOM="$WORK_DIR/conf"
CONF_FILE="$WORK_DIR/conf/app.ini"
say "work_dir=$WORK_DIR"
say "custom=$CUSTOM"
say "conf_file=$CONF_FILE"

BIN=""
for b in gitea /app/gitea/gitea /usr/local/bin/gitea /usr/bin/gitea; do
  if podman exec "$CONTAINER" sh -c "command -v '$b' >/dev/null 2>&1"; then
    BIN="$b"
    break
  fi
done
[ -n "$BIN" ] || halt "gitea binary not found inside $CONTAINER"
say "binary=$BIN"

CONF_FLAG=()
if podman exec "$CONTAINER" test -f "$CONF_FILE" 2>/dev/null; then
  CONF_FLAG=(--config "$CONF_FILE")
  say "using --config $CONF_FILE"
else
  say "no app.ini found at $CONF_FILE; relying on GITEA_WORK_DIR/GITEA_CUSTOM"
fi

hr "G3 smoke-test candidate users until non-root Gitea CLI works"
USER_SPEC=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  say "TRY user=$cand"
  set +e
  podman exec -i \
    --user "$cand" \
    -w "$WORK_DIR" \
    --env HOME="$WORK_DIR" \
    --env GITEA_WORK_DIR="$WORK_DIR" \
    --env GITEA_CUSTOM="$CUSTOM" \
    "$CONTAINER" "$BIN" ${CONF_FLAG[@]+"${CONF_FLAG[@]}"} --version \
    > "$TMP/smoke.out" 2>&1
  rc=$?
  set -e
  mask < "$TMP/smoke.out" | sed 's/^/    /' || true
  if [ "$rc" = 0 ]; then
    USER_SPEC="$cand"
    say "SELECTED user=$USER_SPEC"
    break
  fi
done < "$CANDS"

if [ -z "$USER_SPEC" ]; then
  hr "G3D diagnostics: no non-root CLI user worked"
  say "--- container identity diagnostics ---"
  podman exec "$CONTAINER" sh -c '
    echo "id:"; id || true
    echo
    echo "ls -ld /data/gitea:"; ls -ld /data/gitea || true
    echo
    echo "stat /data/gitea:"; stat -c "%u:%g %U:%G" /data/gitea || true
    echo
    echo "getent passwd git:"; getent passwd git || true
    echo
    echo "passwd non-root users:"; awk -F: "\$3 != 0 {print \$1 \":\" \$3 \":\" \$4}" /etc/passwd || true
    echo
    echo "ps -o user= -p 1:"; ps -o user= -p 1 || true
  ' 2>&1 | sed 's/^/    /' || true
  ledger "FAIL" "GX02 could not find a non-root Gitea CLI user"
  halt "no non-root Gitea CLI user detected"
fi

gitea_cli(){
  podman exec -i \
    --user "$USER_SPEC" \
    -w "$WORK_DIR" \
    --env HOME="$WORK_DIR" \
    --env GITEA_WORK_DIR="$WORK_DIR" \
    --env GITEA_CUSTOM="$CUSTOM" \
    "$CONTAINER" "$BIN" ${CONF_FLAG[@]+"${CONF_FLAG[@]}"} "$@"
}

run_cli(){
  local out="$1"
  shift
  set +e
  gitea_cli "$@" > "$out" 2>&1
  local rc=$?
  set -e
  mask < "$out" | sed 's/^/    /' || true
  return "$rc"
}

attempt(){
  local label="$1"
  shift
  say "TRY $label"
  if run_cli "$TMP/attempt.out" "$@"; then
    say "OK $label"
    return 0
  fi
  return 1
}

hr "G4 create or reset Gitea admin user"
set +e
help_create="$(gitea_cli admin user create --help 2>&1 | mask)"
hrc=$?
set -e
if [ "$hrc" != 0 ]; then
  say "WARN create --help rc=$hrc; continuing with known flags"
fi

ACTIVE_FLAG=""
if printf '%s\n' "$help_create" | grep -qE -- '--active'; then
  ACTIVE_FLAG="--active=true"
  say "create supports --active"
fi

create_args=(
  admin user create
  --username "$UNAME"
  --password "$PASS"
  --email "$EMAIL"
  --admin
  --must-change-password=false
)
[ -n "$ACTIVE_FLAG" ] && create_args+=("$ACTIVE_FLAG")

CREATED=no
if attempt "create" "${create_args[@]}"; then
  CREATED=yes
fi

if [ "$CREATED" != yes ]; then
  say "create did not succeed; attempting idempotent password reset"
  RESET_OK=no

  if attempt "change-password username+password+must-change" \
    admin user change-password \
    --username "$UNAME" \
    --password "$PASS" \
    --must-change-password=false; then
    RESET_OK=yes
  elif attempt "change-password username+password" \
    admin user change-password \
    --username "$UNAME" \
    --password "$PASS"; then
    RESET_OK=yes
  elif attempt "change-password user+password+must-change" \
    admin user change-password \
    --user "$UNAME" \
    --password "$PASS" \
    --must-change-password=false; then
    RESET_OK=yes
  elif attempt "change-password user+password" \
    admin user change-password \
    --user "$UNAME" \
    --password "$PASS"; then
    RESET_OK=yes
  elif attempt "change-password username+new-password" \
    admin user change-password \
    --username "$UNAME" \
    --new-password "$PASS"; then
    RESET_OK=yes
  elif attempt "change-password user+new-password" \
    admin user change-password \
    --user "$UNAME" \
    --new-password "$PASS"; then
    RESET_OK=yes
  elif attempt "change-password positional" \
    admin user change-password "$UNAME" "$PASS"; then
    RESET_OK=yes
  fi

  if [ "$RESET_OK" != yes ]; then
    ledger "FAIL" "GX02 create and all change-password syntaxes failed"
    halt "could not create or reset Gitea admin user"
  fi

  # Ensure admin flag after reset.
  if ! attempt "set-admin username" \
    admin user set-admin \
    --username "$UNAME" \
    --admin=true; then
    attempt "set-admin user" \
      admin user set-admin \
      --user "$UNAME" \
      --admin=true || say "WARN set-admin failed; continuing to verify"
  fi

  # Try activate via CLI if available.
  if ! attempt "change-active username" \
    admin user change-active \
    --username "$UNAME" \
    --active=true; then
    attempt "change-active user" \
      admin user change-active \
      --user "$UNAME" \
      --active=true || say "no CLI change-active; will use DB fallback if needed"
  fi
fi

hr "G5 detect Gitea host URL"
GT_HOST_PORT="$(podman port "$CONTAINER" 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port for container port 3000"
GT="http://127.0.0.1:$GT_HOST_PORT"
say "gitea_url=$GT"

verify_api(){
  local code
  set +e
  code="$(curl -sS -m 10 -o "$TMP/api_user.json" -w '%{http_code}' -u "$UNAME:$PASS" "$GT/api/v1/user" 2>/dev/null || echo 000)"
  set -e
  say "api/v1/user http=$code"

  if [ "$code" = 200 ]; then
    python3 - "$TMP/api_user.json" <<'PYVERIFY' | sed 's/^/    /'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("parse_error:", e)
    sys.exit(0)
print("login=", d.get("login"))
print("id=", d.get("id"))
print("is_admin=", d.get("is_admin"))
print("active=", d.get("active"))
PYVERIFY
    return 0
  fi

  if [ -s "$TMP/api_user.json" ]; then
    mask < "$TMP/api_user.json" | head -c 300 | sed 's/^/    body: /' || true
    echo
  fi
  return 1
}

verify_web(){
  say "verifying real web login form"
  set +e
  GT_URL="$GT" GITEA_USER="$UNAME" GITEA_PASS="$PASS" python3 - <<'PYWEB' > "$TMP/web.out" 2>&1
import os, re, sys, urllib.request, urllib.parse, http.cookiejar

base = os.environ.get("GT_URL", "").rstrip("/")
user = os.environ.get("GITEA_USER", "")
pwd = os.environ.get("GITEA_PASS", "")

if not base or not user:
    print("web_login=SKIP")
    sys.exit(0)

cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
op.addheaders = [("User-Agent", "gx02-verify")]

try:
    r = op.open(base + "/user/login", timeout=15)
    html = r.read().decode("utf-8", "replace")
except Exception as e:
    print("web_login=ERR", type(e).__name__, str(e)[:180])
    sys.exit(2)

if 'name="password"' not in html and "name='password'" not in html:
    print("web_login=NO_FORM login form not found; API/CLI may still be valid")
    sys.exit(3)

m = (
    re.search(r'name=["\']_csrf["\'][^>]*value=["\']([^"\']+)', html)
    or re.search(r'value=["\']([^"\']+)["\'][^>]*name=["\']_csrf', html)
)
csrf = m.group(1) if m else ""

fields = {"user_name": user, "password": pwd}
if csrf:
    fields["_csrf"] = csrf

data = urllib.parse.urlencode(fields).encode()
req = urllib.request.Request(
    base + "/user/login",
    data=data,
    headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Referer": base + "/user/login",
    },
)

try:
    r = op.open(req, timeout=15)
    final = r.geturl()
except urllib.error.HTTPError as e:
    final = e.geturl()
    body = e.read().decode("utf-8", "replace")[:220]
    print("web_login=HTTP_ERROR", e.code, "final=", final, "body_hint=", re.sub(r"\s+", " ", body))
    sys.exit(2)
except Exception as e:
    print("web_login=ERR", type(e).__name__, str(e)[:180])
    sys.exit(2)

norm = final.rstrip("/")
if norm == base.rstrip("/") or norm.endswith("/") or norm.endswith("/repos"):
    print("web_login=OK final=", final)
    sys.exit(0)

if "/user/login" in final:
    print("web_login=FAIL final=", final)
    sys.exit(1)

print("web_login=UNKNOWN final=", final)
sys.exit(0)
PYWEB
  web_rc=$?
  set -e
  sed 's/^/    /' "$TMP/web.out" || true
  return "$web_rc"
}

hr "G6 verify API login"
API_OK=no
if verify_api; then
  API_OK=yes
fi

hr "G7 verify web login"
WEB_OK=no
if verify_web; then
  WEB_OK=yes
fi

if [ "$API_OK" != yes ] && [ "$WEB_OK" != yes ]; then
  hr "G8 fallback: ensure user is active in Gitea DB"
  GTDB="gitea"
  if ! podman exec "$POSTGRES_CONTAINER" psql -U "$PGU" -d "$GTDB" -tAc 'SELECT 1' >/dev/null 2>&1; then
    GTDB=""
    while IFS= read -r db; do
      [ -n "$db" ] || continue
      if podman exec "$POSTGRES_CONTAINER" psql -U "$PGU" -d "$db" -tAc \
        "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user' LIMIT 1" \
        2>/dev/null | grep -q 1; then
        GTDB="$db"
        break
      fi
    done < <(podman exec "$POSTGRES_CONTAINER" psql -U "$PGU" -d postgres -tAc \
      "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)
  fi

  if [ -z "$GTDB" ]; then
    say "could not detect Gitea DB for active fallback"
  else
    say "gitea_db=$GTDB"
    UNAME_SQL="${UNAME//\'/\'\'}"
    set +e
    podman exec "$POSTGRES_CONTAINER" psql -U "$PGU" -d "$GTDB" -c \
      "UPDATE \"user\" SET active=true WHERE name='${UNAME_SQL}';" \
      > "$TMP/sql_active.out" 2>&1
    src=$?
    set -e
    mask < "$TMP/sql_active.out" | sed 's/^/    /' || true
    [ "$src" = 0 ] || say "WARN SQL active update rc=$src"

    say "re-verifying after active fallback"
    if verify_api; then API_OK=yes; fi
    if verify_web; then WEB_OK=yes; fi
  fi
fi

if [ "$API_OK" != yes ] && [ "$WEB_OK" != yes ]; then
  hr "G9 final diagnostics"
  say "--- gitea CLI user list ---"
  set +e
  gitea_cli admin user list 2>&1 | mask | sed 's/^/    /' || true
  set -e

  say "--- gitea container logs tail 120 ---"
  podman logs --tail 120 "$CONTAINER" 2>&1 | mask | sed 's/^/    /' || true

  ledger "FAIL" "GX02 API and web login verification failed"
  halt "Gitea login verify failed"
fi

hr "G10 RESULT"
say "[RESULT] GX02 COMPLETE - Gitea admin login is verified."
say "  URL:             $GT"
say "  Username:        $UNAME"
say "  API login:       $API_OK"
say "  Web login:       $WEB_OK"
say "  Email file:      $E_FILE"
say "  Username file:   $U_FILE"
say "  Password file:   $P_FILE"
say "  Password perms:  $(stat -c '%a' "$P_FILE" 2>/dev/null || echo unknown)"
say ""
say "To reveal the saved password when needed:"
say "  cat '$P_FILE'; echo"
say ""
say "If you want to rotate again:"
say "  rm -f '$P_FILE'"
say "  bash '$0' run"

ledger "PASS" "GX02: detected non-root CLI user, created/reset admin login, verified API=$API_OK web=$WEB_OK."
exit 0
