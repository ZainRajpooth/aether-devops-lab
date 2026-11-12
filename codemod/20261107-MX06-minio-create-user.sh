#!/usr/bin/env bash
# 20261107-MX06 — create a MinIO user/account securely.
#
# MinIO Console has no public registration.
# This script uses the existing root credentials from:
#   /home/dev/.config/aether/secrets.env
#
# It creates a normal MinIO user, attaches a policy, saves credentials to:
#   ~/DevOps/aether/secrets/minio-user.<username>.user
#   ~/DevOps/aether/secrets/minio-user.<username>.pass
#
# Secrets are masked in output.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

SECRETS_ENV="/home/dev/.config/aether/secrets.env"
CONTAINER="minio"
API_URL="http://127.0.0.1:9000"
CONSOLE_URL="http://127.0.0.1:9011/browser"

TOKEN="mx06-minio-create-user-v1"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$CD" "$SEC"
chmod 700 "$SEC"
touch "$IDX"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

: > "$TMP/secrets.txt"

add_secret(){
  local v="${1:-}"
  [ -n "$v" ] || return 0
  printf '%s\n' "$v" >> "$TMP/secrets.txt"
}

mask(){
  python3 - "$TMP/secrets.txt" <<'PY'
import sys, re

secret_file = sys.argv[1]
secrets = []
try:
    with open(secret_file, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            v = line.rstrip("\n")
            if v:
                secrets.append(v)
except Exception:
    pass

jwt_re = re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")

for line in sys.stdin:
    for s in secrets:
        if s:
            line = line.replace(s, "[REDACTED]")
    line = jwt_re.sub("[JWT]", line)
    sys.stdout.write(line)
PY
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

get_env(){
  local key="$1"
  sed -n "s/^${key}=//p" "$SECRETS_ENV" 2>/dev/null |
    head -n1 |
    tr -d '\r' |
    sed -e 's/^"//' -e 's/"$//'
}

mc(){
  podman exec -i -e MC_CONFIG_DIR=/tmp/mc-config "$CONTAINER" mc "$@"
}

run_mc(){
  local out="$TMP/mc.out"
  : > "$out"
  set +e
  mc "$@" > "$out" 2>&1
  local rc=$?
  set -e
  mask < "$out" | sed 's/^/    /' || true
  return "$rc"
}

hr "M0 preflight"
for c in python3 curl podman sed awk grep mkdir chmod; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$SECRETS_ENV" ] || halt "missing secrets file: $SECRETS_ENV"

CODE="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$CONSOLE_URL" 2>/dev/null || echo 000)"
say "console probe: $CONSOLE_URL = $CODE"
[ "$CODE" = 200 ] || [ "$CODE" = 302 ] || [ "$CODE" = 401 ] || halt "MinIO Console is not reachable"

hr "M1 read root credentials"
ROOT_USER="$(get_env MINIO_ROOT_USER)"
ROOT_PASS="$(get_env MINIO_ROOT_PASSWORD)"

add_secret "$ROOT_PASS"

[ -n "$ROOT_USER" ] || halt "MINIO_ROOT_USER not found in $SECRETS_ENV"
[ -n "$ROOT_PASS" ] || halt "MINIO_ROOT_PASSWORD not found in $SECRETS_ENV"

say "root access key loaded: $ROOT_USER"
say "root secret key loaded: yes"

hr "M2 collect new user details"
printf 'New MinIO username [default: devops]: ' > /dev/tty
read -r NEW_USER < /dev/tty
NEW_USER="${NEW_USER:-devops}"

SAFE_USER="$(printf '%s' "$NEW_USER" | tr -c 'A-Za-z0-9._-' '-')"
[ -n "$SAFE_USER" ] || halt "invalid username"

printf 'New MinIO password for %s: ' "$NEW_USER" > /dev/tty
read -rs NEW_PASS < /dev/tty
printf '\nRepeat password: ' > /dev/tty
read -rs NEW_PASS2 < /dev/tty
printf '\n' > /dev/tty

[ -n "$NEW_PASS" ] || halt "empty password"
[ "$NEW_PASS" = "$NEW_PASS2" ] || halt "passwords do not match"

add_secret "$NEW_PASS"

printf 'Policy:\n' > /dev/tty
printf '  1 = readwrite     (normal developer/storage user)\n' > /dev/tty
printf '  2 = consoleAdmin  (full MinIO console/admin user)\n' > /dev/tty
printf '  3 = readonly      (read-only user)\n' > /dev/tty
printf 'Choose [1/2/3, default 1]: ' > /dev/tty
read -r POLICY_CHOICE < /dev/tty
POLICY_CHOICE="${POLICY_CHOICE:-1}"

case "$POLICY_CHOICE" in
  1) POLICY="readwrite" ;;
  2) POLICY="consoleAdmin" ;;
  3) POLICY="readonly" ;;
  *) halt "invalid policy choice" ;;
esac

say "creating user: $NEW_USER"
say "policy: $POLICY"

hr "M3 configure mc alias"
if ! run_mc alias set local "$API_URL" "$ROOT_USER" "$ROOT_PASS"; then
  ledger "FAIL" "MX06 mc alias set failed"
  halt "could not configure mc alias"
fi

hr "M4 check whether user already exists"
if run_mc admin user info local "$NEW_USER"; then
  say "user already exists: $NEW_USER"
  say "To reset password, use MinIO Console or delete/recreate intentionally."
  ledger "PARTIAL" "MX06 user already exists: $NEW_USER"
  halt "user already exists"
fi

hr "M5 create user"
if ! run_mc admin user add local "$NEW_USER" "$NEW_PASS"; then
  ledger "FAIL" "MX06 user create failed: $NEW_USER"
  halt "could not create MinIO user"
fi

hr "M6 attach policy"
if ! run_mc admin policy attach local "$POLICY" --user "$NEW_USER"; then
  say "WARN policy attach failed; trying legacy policy set"
  run_mc admin policy set local "$POLICY" "$NEW_USER" || say "WARN could not attach policy automatically"
fi

hr "M7 verify user"
if ! run_mc admin user info local "$NEW_USER"; then
  ledger "PARTIAL" "MX06 user created but verification failed: $NEW_USER"
  halt "user verification failed"
fi

hr "M8 save credentials locally"
USER_FILE="$SEC/minio-user.${SAFE_USER}.user"
PASS_FILE="$SEC/minio-user.${SAFE_USER}.pass"

printf '%s\n' "$NEW_USER" > "$USER_FILE"
chmod 600 "$USER_FILE"

printf '%s' "$NEW_PASS" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

say "saved username: $USER_FILE"
say "saved password: $PASS_FILE"

hr "M9 RESULT"
say "[RESULT] MX06 COMPLETE - MinIO user created."
say "  Console:  $CONSOLE_URL"
say "  Username: $NEW_USER"
say "  Policy:   $POLICY"
say ""
say "To copy password to clipboard:"
say "  xclip -selection clipboard < '$PASS_FILE'"
say ""
say "To reveal password locally:"
say "  cat '$PASS_FILE'; echo"

ledger "PASS" "MX06: created MinIO user '$NEW_USER' with policy '$POLICY'; credentials saved under $SEC."
exit 0
