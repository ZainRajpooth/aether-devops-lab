#!/usr/bin/env bash
# 20261107-GX01 — Gitea admin login repair.
#
# Root cause: `podman exec gitea gitea admin ...` ran as root; Gitea refuses root.
# This script detects Gitea's non-root container user, creates/resets a human admin,
# stores credentials in chmod-600 files, activates the user if needed, and verifies login.
#
# No Woodpecker changes. No Brick 12 work. Secrets masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="gx01-gitea-admin-login-fix-v1"
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

hr "G0 plan/check"
for c in python3 curl podman awk sed grep tr; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"

if [ "$MODE" = check ]; then
  say "container=$CONTAINER postgres_container=$POSTGRES_CONTAINER pg_user=$PGU"
  say "will detect non-root Gitea CLI user"
  say "will create/reset admin user from:"
  say "  $SEC/gitea-admin.user"
  say "  $SEC/gitea-admin.pass"
  say "  $SEC/gitea-admin.email"
  say "will verify http://127.0.0.1:<gitea-port>/api/v1/user"
  say "[RESULT] GX01 CHECK - nothing written."
  exit 0
fi

mkdir -p "$CD" "$SEC"
chmod 700 "$SEC"
touch "$IDX"

U_FILE="$SEC/gitea-admin.user"
P_FILE="$SEC/gitea-admin.pass"
E_FILE="$SEC/gitea-admin.email"

# Defaults for a human admin. Change files later if desired.
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

# Password source priority:
#   1) existing $P_FILE
#   2) GITEA_ADMIN_PASS env
#   3) interactive prompt
if [ ! -s "$P_FILE" ]; then
  if [ -n "${GITEA_ADMIN_PASS:-}" ]; then
    printf '%s' "$GITEA_ADMIN_PASS" > "$P_FILE"
    chmod 600 "$P_FILE"
    say "created password file from GITEA_ADMIN_PASS"
  elif [ -t 0 ] && [ -e /dev/tty ]; then
    printf 'Set NEW Gitea admin password (old typed password is considered exposed): ' > /dev/tty
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
fi

UNAME="$(tr -d '\n\r' < "$U_FILE")"
EMAIL="$(tr -d '\n\r' < "$E_FILE")"
PASS="$(tr -d '\n\r' < "$P_FILE")"

[ -n "$UNAME" ] || halt "empty username file: $U_FILE"
[ -n "$EMAIL" ] || halt "empty email file: $E_FILE"
[ -n "$PASS" ] || halt "empty password file: $P_FILE"

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

hr "G1 detect non-root Gitea container user"
USER_SPEC=""

cfg="$(podman inspect "$CONTAINER" --format '{{.Config.User}}' 2>/dev/null || true)"
case "$cfg" in
  ''|0|root) ;;
  *) USER_SPEC="$cfg" ;;
esac
[ -n "$USER_SPEC" ] && say "using Config.User=$USER_SPEC"

if [ -z "$USER_SPEC" ]; then
  uid="$(podman exec "$CONTAINER" id -u git 2>/dev/null || true)"
  case "$uid" in
    ''|0) ;;
    *) USER_SPEC="$uid"; say "using git uid=$uid" ;;
  esac
fi

if [ -z "$USER_SPEC" ]; then
  for d in /data/gitea /var/lib/gitea /srv/gitea /app/gitea; do
    uid="$(podman exec "$CONTAINER" stat -c '%u' "$d" 2>/dev/null || true)"
    case "$uid" in
      ''|0) ;;
      *) USER_SPEC="$uid"; say "using owner uid=$uid of $d"; break ;;
    esac
  done
fi

if [ -z "$USER_SPEC" ]; then
  uid="$(podman exec "$CONTAINER" ps -o uid= -p 1 2>/dev/null | tr -d ' \r' || true)"
  case "$uid" in
    ''|0) ;;
    *) USER_SPEC="$uid"; say "using PID1 uid=$uid" ;;
  esac
fi

[ -n "$USER_SPEC" ] || halt "could not detect non-root user for $CONTAINER"

hr "G2 detect Gitea work dir and binary"
WORK_DIR=""
for d in /data/gitea /var/lib/gitea /srv/gitea /app/gitea; do
  if podman exec --user "$USER_SPEC" "$CONTAINER" test -d "$d" 2>/dev/null; then
    WORK_DIR="$d"
    break
  fi
done
[ -n "$WORK_DIR" ] || WORK_DIR="/data/gitea"
CUSTOM="$WORK_DIR/conf"
say "work_dir=$WORK_DIR custom=$CUSTOM"

BIN=""
for b in gitea /app/gitea/gitea /usr/local/bin/gitea /usr/bin/gitea; do
  if podman exec --user "$USER_SPEC" -w "$WORK_DIR" \
       --env GITEA_WORK_DIR="$WORK_DIR" \
       --env GITEA_CUSTOM="$CUSTOM" \
       "$CONTAINER" sh -c "command -v '$b' >/dev/null 2>&1"; then
    BIN="$b"
    break
  fi
done
[ -n "$BIN" ] || halt "gitea binary not found inside $CONTAINER"
say "binary=$BIN"

gitea_cli(){
  podman exec -i \
    --user "$USER_SPEC" \
    -w "$WORK_DIR" \
    --env GITEA_WORK_DIR="$WORK_DIR" \
    --env GITEA_CUSTOM="$CUSTOM" \
    "$CONTAINER" "$BIN" "$@"
}

hr "G3 smoke-test Gitea CLI as non-root"
set +e
gitea_cli --version > "$TMP/version.out" 2>&1
vrc=$?
set -e
mask < "$TMP/version.out" | sed 's/^/    /' || true
[ "$vrc" = 0 ] || halt "gitea CLI failed as user=$USER_SPEC; see masked output above"

hr "G4 create or reset Gitea admin user"
create_help="$(gitea_cli admin user create --help 2>&1 | mask || true)"
ACTIVE_FLAG=""
if printf '%s\n' "$create_help" | grep -qE -- '--active'; then
  ACTIVE_FLAG="--active=true"
  say "create supports --active"
fi

cmd=(
  admin user create
  --username "$UNAME"
  --password "$PASS"
  --email "$EMAIL"
  --admin
  --must-change-password=false
)
[ -n "$ACTIVE_FLAG" ] && cmd+=("$ACTIVE_FLAG")

set +e
gitea_cli "${cmd[@]}" > "$TMP/create.out" 2>&1
crc=$?
set -e
mask < "$TMP/create.out" | sed 's/^/    /' || true

if [ "$crc" != 0 ]; then
  say "create returned rc=$crc; attempting idempotent reset for existing user"

  set +e
  gitea_cli admin user change-password \
    --username "$UNAME" \
    --password "$PASS" \
    --must-change-password=false \
    > "$TMP/pass.out" 2>&1
  prc=$?

  gitea_cli admin user set-admin \
    --username "$UNAME" \
    --admin=true \
    > "$TMP/admin.out" 2>&1
  arc=$?
  set -e

  mask < "$TMP/pass.out" | sed 's/^/    /' || true
  mask < "$TMP/admin.out" | sed 's/^/    /' || true

  if [ "$prc" != 0 ] && [ "$arc" != 0 ]; then
    ledger "FAIL" "GX01 create/reset failed crc=$crc prc=$prc arc=$arc"
    halt "could not create or reset Gitea admin user"
  fi

  if gitea_cli admin user change-active --help >/dev/null 2>&1; then
    set +e
    gitea_cli admin user change-active \
      --username "$UNAME" \
      --active=true \
      > "$TMP/active.out" 2>&1
    acr=$?
    set -e
    mask < "$TMP/active.out" | sed 's/^/    /' || true
    [ "$acr" = 0 ] || say "WARN change-active rc=$acr"
  else
    say "no change-active CLI; will use DB fallback only if API verify fails"
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

hr "G6 verify API login"
if ! verify_api; then
  hr "G7 fallback: ensure user is active in Gitea DB"

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

  [ -n "$GTDB" ] || halt "could not detect Gitea DB for active fallback"
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

  if ! verify_api; then
    hr "G8 diagnostics"
    say "--- gitea CLI user list ---"
    gitea_cli admin user list 2>&1 | mask | sed 's/^/    /' || true

    say "--- gitea container logs tail 120 ---"
    podman logs --tail 120 "$CONTAINER" 2>&1 | mask | sed 's/^/    /' || true

    ledger "FAIL" "GX01 API login failed after create/reset and active fallback"
    halt "Gitea login verify failed"
  fi
fi

hr "G9 verify admin endpoint"
set +e
ADMIN_CODE="$(curl -sS -m 10 -o "$TMP/admin_user.json" -w '%{http_code}' -u "$UNAME:$PASS" "$GT/api/v1/admin/users/$UNAME" 2>/dev/null || echo 000)"
set -e
say "api/v1/admin/users/$UNAME http=$ADMIN_CODE"
if [ "$ADMIN_CODE" = 200 ]; then
  python3 - "$TMP/admin_user.json" <<'PYADMIN' | sed 's/^/    /'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("parse_error:", e)
    sys.exit(0)
print("login=", d.get("login"))
print("is_admin=", d.get("is_admin"))
print("active=", d.get("active"))
PYADMIN
else
  if [ -s "$TMP/admin_user.json" ]; then
    mask < "$TMP/admin_user.json" | head -c 300 | sed 's/^/    body: /' || true
    echo
  fi
  say "WARN admin endpoint not 200; normal login may still work, but admin UI/API may be limited"
fi

hr "G10 RESULT"
say "[RESULT] GX01 COMPLETE - Gitea admin login should now work."
say "  URL:             $GT"
say "  Username:        $UNAME"
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

ledger "PASS" "GX01: detected non-root Gitea CLI user, created/reset admin login, verified /api/v1/user=200."
exit 0
