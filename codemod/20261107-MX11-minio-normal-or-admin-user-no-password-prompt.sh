#!/usr/bin/env bash
# 20261107-MX11 — create/save MinIO normal or admin user without password prompting.
#
# Why:
#   Earlier scripts asked for passwords interactively and your terminal closed.
#   This script generates passwords automatically and stores them in 600 files.
#
# Modes:
#   bash MX11.sh normal
#   bash MX11.sh admin
#   bash MX11.sh both
#   bash MX11.sh ask
#
# Defaults:
#   normal access key: developer
#   admin  access key: consoleadmin
#
# Override with env:
#   MINIO_NORMAL_USER=mydev
#   MINIO_ADMIN_USER=myadmin
#
# Policies:
#   normal = readwrite
#   admin  = consoleAdmin
#
# Secrets:
#   Passwords are never printed.
#   Passwords are stored under ~/DevOps/aether/secrets with mode 600.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
BAK="$SEC/backups"
IDX="$CD/INDEX.md"

CANON_ENV="$SEC/aether.env"
CONTAINER="${MINIO_CONTAINER:-minio}"

NORMAL_USER="${MINIO_NORMAL_USER:-developer}"
ADMIN_USER="${MINIO_ADMIN_USER:-consoleadmin}"
NORMAL_POLICY="readwrite"
ADMIN_POLICY="consoleAdmin"

CONSOLE_URL="http://127.0.0.1:9011/browser"
API_INTERNAL_URL="http://127.0.0.1:9000"

TOKEN="mx11-minio-normal-or-admin-user-no-password-prompt-v1"
STAMP="$(date +%Y%m%d-%H%M%S)"
ROLE_INPUT="${1:-ask}"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
SECRETS_FILE="$TMP/secrets.txt"
: > "$SECRETS_FILE"

cleanup(){
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$CD" "$SEC" "$BAK"
chmod 700 "$SEC" "$BAK"
touch "$IDX"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

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

add_secret(){
  local v="${1:-}"
  [ -n "$v" ] || return 0
  printf '%s\n' "$v" >> "$SECRETS_FILE"
}

mask_stream(){
  python3 - "$SECRETS_FILE" <<'PY'
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
kv_re = re.compile(
    r"([A-Za-z0-9_]*(?:PASSWORD|SECRET|ACCESS_KEY|SECRET_KEY|TOKEN|PRIVATE|CREDENTIAL|ENCRYPTION|MASTER|API|CLIENT)[A-Za-z0-9_]*)=([^\s\"']+)"
)

def kv_repl(m):
    key = m.group(1)
    val = m.group(2)
    return f"{key}=[REDACTED len={len(val)}]"

for line in sys.stdin:
    for s in secrets:
        if s:
            line = line.replace(s, "[REDACTED]")
    line = kv_re.sub(kv_repl, line)
    line = jwt_re.sub("[JWT]", line)
    sys.stdout.write(line)
PY
}

mask_file(){
  [ -f "$1" ] || return 0
  mask_stream < "$1" 2>/dev/null || true
}

safe_access(){
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

choose_role(){
  ROLE="$ROLE_INPUT"

  case "$ROLE" in
    normal|admin|both)
      return 0
      ;;
  esac

  # Preferred: GUI menu on Kubuntu if kdialog exists.
  if command -v kdialog >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
    ROLE="$(
      kdialog \
        --title 'MinIO user role' \
        --menu 'Choose MinIO user role to create/save:' \
        normal 'Normal developer (readwrite)' \
        admin  'Console admin (consoleAdmin)' \
        both   'Create both normal and admin users' \
        2>/dev/null || true
    )"
  fi

  # Fallback: one simple terminal choice. No password is requested.
  if [ -z "${ROLE:-}" ]; then
    if [ -t 0 ] && [ -e /dev/tty ]; then
      printf 'Choose MinIO user role [normal/admin/both] (default normal): '
      IFS= read -r ROLE </dev/tty || ROLE=normal
    else
      ROLE=normal
    fi
  fi

  [ -n "${ROLE:-}" ] || ROLE=normal

  ROLE="$(printf '%s' "$ROLE" | tr '[:upper:]' '[:lower:]')"

  case "$ROLE" in
    normal|n|dev|developer)
      ROLE=normal
      ;;
    admin|a|console|consoleadmin)
      ROLE=admin
      ;;
    both|all|b)
      ROLE=both
      ;;
    *)
      ROLE=normal
      ;;
  esac
}

get_root_user(){
  local u=""
  u="$(podman exec "$CONTAINER" printenv MINIO_ROOT_USER 2>/dev/null | tr -d '\r\n' || true)"
  if [ -z "$u" ] && [ -f "$CANON_ENV" ]; then
    u="$(
      sed -n 's/^MINIO_ROOT_USER=//p' "$CANON_ENV" 2>/dev/null |
        head -n1 |
        tr -d '\r' |
        sed -e 's/^"//' -e 's/"$//'
    )"
  fi
  printf '%s\n' "$u"
}

verify_root(){
  local out="$TMP/root-verify.out"
  podman exec -i \
    -e MC_CONFIG_DIR=/tmp/mx11-mc \
    "$CONTAINER" sh -c "
      set -u
      mc alias rm rootmx11 >/dev/null 2>&1 || true
      mc alias set rootmx11 ${API_INTERNAL_URL} \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null
      mc admin info rootmx11
    " > "$out" 2>&1

  local rc=$?
  mask_file "$out" | sed 's/^/    /'
  return "$rc"
}

save_credentials(){
  local access="$1"
  local pass="$2"
  local label="$3"

  local safe
  safe="$(safe_access "$access")"

  local uf="$SEC/minio-user.${safe}.user"
  local pf="$SEC/minio-user.${safe}.pass"
  local pbak="$BAK/minio-user.${safe}.pass.pre-mx11.${STAMP}.bak"

  mkdir -p "$SEC" "$BAK"
  chmod 700 "$SEC" "$BAK"

  if [ -f "$pf" ]; then
    cp -p "$pf" "$pbak" 2>/dev/null || true
    chmod 600 "$pbak" 2>/dev/null || true
    say "backed up existing password file: $pbak"
  fi

  umask 077

  printf '%s\n' "$access" > "$uf"
  chmod 600 "$uf"

  printf '%s' "$pass" > "$pf"
  chmod 600 "$pf"

  say "saved $label credentials:"
  say "  access key file: $uf"
  say "  secret key file: $pf"
}

create_one(){
  local access="$1"
  local policy="$2"
  local label="$3"

  if [ -z "$access" ]; then
    say "SKIP $label: empty access key"
    return 1
  fi

  if [ "$access" = "${ROOT_USER:-}" ]; then
    say "SKIP $label: access key '$access' equals MinIO root access key"
    return 2
  fi

  local pass
  pass="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24), end="")')" || {
    say "FAIL $label: could not generate password"
    return 1
  }

  add_secret "$pass"

  say "creating/updating $label user:"
  say "  access key: $access"
  say "  policy:     $policy"

  local out="$TMP/create-${label}.out"

  podman exec -i \
    -e MC_CONFIG_DIR=/tmp/mx11-mc \
    -e ACCESS_KEY="$access" \
    -e NEW_PASS="$pass" \
    -e POLICY="$policy" \
    "$CONTAINER" sh -c '
      set -u

      mc alias rm rootmx11 >/dev/null 2>&1 || true
      mc alias set rootmx11 http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

      if mc admin user info rootmx11 "$ACCESS_KEY" >/dev/null 2>&1; then
        echo "existing user found; resetting password"
        mc admin user rm rootmx11 "$ACCESS_KEY" >/dev/null
      fi

      mc admin user add rootmx11 "$ACCESS_KEY" "$NEW_PASS"

      if ! mc admin policy attach rootmx11 "$POLICY" --user "$ACCESS_KEY"; then
        mc admin policy set rootmx11 "$POLICY" "$ACCESS_KEY"
      fi

      mc admin user info rootmx11 "$ACCESS_KEY"
    ' > "$out" 2>&1

  local rc=$?
  mask_file "$out" | sed 's/^/    /'

  if [ "$rc" != 0 ]; then
    say "FAIL $label: create/attach/verify failed rc=$rc"
    return "$rc"
  fi

  local vout="$TMP/verify-${label}.out"

  podman exec -i \
    -e MC_CONFIG_DIR=/tmp/mx11-mc \
    -e ACCESS_KEY="$access" \
    -e NEW_PASS="$pass" \
    "$CONTAINER" sh -c '
      set -u
      mc alias rm userverify >/dev/null 2>&1 || true
      mc alias set userverify http://127.0.0.1:9000 "$ACCESS_KEY" "$NEW_PASS" >/dev/null
      mc ls userverify 2>/dev/null || true
    ' > "$vout" 2>&1

  local vrc=$?
  mask_file "$vout" | sed 's/^/    /'

  if [ "$vrc" != 0 ]; then
    say "FAIL $label: user login verification failed rc=$vrc"
    return "$vrc"
  fi

  save_credentials "$access" "$pass" "$label"
  say "OK $label user created/updated: $access"
  return 0
}

list_users(){
  local out="$TMP/users.out"
  podman exec -i \
    -e MC_CONFIG_DIR=/tmp/mx11-mc \
    "$CONTAINER" sh -c "
      set -u
      mc alias rm rootmx11 >/dev/null 2>&1 || true
      mc alias set rootmx11 ${API_INTERNAL_URL} \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null
      mc admin user list rootmx11
    " > "$out" 2>&1

  local rc=$?
  mask_file "$out" | sed 's/^/    /'
  return "$rc"
}

hr "R0 preflight"
for c in python3 podman sed awk grep tr mkdir chmod cp kdialog; do
  if ! command -v "$c" >/dev/null 2>&1; then
    if [ "$c" = kdialog ]; then
      say "WARN optional command missing: kdialog; will fallback to terminal/default role"
    else
      halt "missing required command: $c"
    fi
  fi
done

podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"

choose_role
ROOT_USER="$(get_root_user)"

say "container=$CONTAINER"
say "role=$ROLE"
say "normal access key=$NORMAL_USER"
say "admin access key=$ADMIN_USER"
say "root access key=${ROOT_USER:-unknown}"
say "console=$CONSOLE_URL"

if [ -z "$ROOT_USER" ]; then
  ledger "FAIL" "MX11 could not determine MINIO_ROOT_USER"
  halt "could not determine MINIO_ROOT_USER"
fi

hr "R1 verify MinIO root credentials"
if ! verify_root; then
  ledger "FAIL" "MX11 root credentials failed verification"
  halt "MinIO root credentials failed; fix root first"
fi

hr "R2 create/save requested user(s)"
FAILURES=0

case "$ROLE" in
  normal)
    create_one "$NORMAL_USER" "$NORMAL_POLICY" "normal" || FAILURES=1
    ;;
  admin)
    create_one "$ADMIN_USER" "$ADMIN_POLICY" "admin" || FAILURES=1
    ;;
  both)
    create_one "$NORMAL_USER" "$NORMAL_POLICY" "normal" || FAILURES=1
    create_one "$ADMIN_USER" "$ADMIN_POLICY" "admin" || FAILURES=1
    ;;
esac

hr "R3 final MinIO user list"
list_users || say "WARN could not list users"

hr "R4 result"
if [ "$FAILURES" = 0 ]; then
  say "[RESULT] MX11 COMPLETE - MinIO user credentials created/saved."
  say ""
  say "Console login:"
  say "  $CONSOLE_URL"
  say ""
  say "Normal developer:"
  say "  Access Key: $NORMAL_USER"
  say "  Password:   cat '$SEC/minio-user.$(safe_access "$NORMAL_USER").pass'"
  say "  Policy:     $NORMAL_POLICY"
  say ""
  say "Console admin:"
  say "  Access Key: $ADMIN_USER"
  say "  Password:   cat '$SEC/minio-user.$(safe_access "$ADMIN_USER").pass'"
  say "  Policy:     $ADMIN_POLICY"
  say ""
  say "Root admin:"
  say "  Access Key: $ROOT_USER"
  say "  Password:   stored in $CANON_ENV as MINIO_ROOT_PASSWORD"
  say ""
  say "Do not paste passwords into chat."
  ledger "PASS" "MX11: role=$ROLE; created/saved MinIO user credentials without password prompt."
else
  say "[RESULT] MX11 PARTIAL/FAIL - one or more users failed."
  ledger "PARTIAL" "MX11: role=$ROLE completed with failures."
fi

# Pause helps prevent Konsole/terminal auto-close after script exit.
if [ -t 1 ] && [ -e /dev/tty ]; then
  printf '\nPress ENTER to exit MX11...'
  IFS= read -r _ </dev/tty || true
fi

[ "$FAILURES" = 0 ] || exit 1
exit 0
