#!/usr/bin/env bash
# 20261107-MX10 — create MinIO developer/user account non-interactively.
#
# Assumes MinIO root credentials are already correct in container env:
#   MINIO_ROOT_USER
#   MINIO_ROOT_PASSWORD
#
# Creates a normal IAM user, default:
#   developer
#
# Password is generated locally and stored in:
#   ~/DevOps/aether/secrets/minio-user.developer.pass
#
# No password is typed into the terminal.
# No password is passed in command-line arguments.
# Secrets are masked in output.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
BAK="$SEC/backups"
IDX="$CD/INDEX.md"

CONTAINER="${MINIO_CONTAINER:-minio}"
DEV_USER="${MINIO_DEV_USER:-developer}"
POLICY="${MINIO_DEV_POLICY:-readwrite}"

TOKEN="mx10-minio-create-developer-user-noninteractive-v1"
STAMP="$(date +%Y%m%d-%H%M%S)"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

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

mask_stream(){
  python3 - <<'PY'
import sys, re

jwt_re = re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")
kv_re = re.compile(
    r"([A-Za-z0-9_]*(?:PASSWORD|SECRET|ACCESS_KEY|SECRET_KEY|TOKEN|PRIVATE|CREDENTIAL|ENCRYPTION|MASTER|API|CLIENT)[A-Za-z0-9_]*)=([^\s\"']+)"
)

def kv_repl(m):
    key = m.group(1)
    val = m.group(2)
    return f"{key}=[REDACTED len={len(val)}]"

for line in sys.stdin:
    line = kv_re.sub(kv_repl, line)
    line = jwt_re.sub("[JWT]", line)
    sys.stdout.write(line)
PY
}

mask_file(){
  mask_stream < "$1" 2>/dev/null || true
}

hr "D0 preflight"
for c in python3 podman awk sed grep systemctl; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done

podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"

SAFE_DEV_USER="$(printf '%s' "$DEV_USER" | tr -c 'A-Za-z0-9._-' '-')"
[ -n "$SAFE_DEV_USER" ] || halt "invalid developer access key"

USER_FILE="$SEC/minio-user.${SAFE_DEV_USER}.user"
PASS_FILE="$SEC/minio-user.${SAFE_DEV_USER}.pass"
PASS_BAK="$BAK/minio-user.${SAFE_DEV_USER}.pass.pre-mx10.${STAMP}"

say "container=$CONTAINER"
say "developer access key=$DEV_USER"
say "policy=$POLICY"
say "password file=$PASS_FILE"

hr "D1 confirm root credentials work inside container"
podman exec "$CONTAINER" sh -c '
  set -u
  if [ -z "${MINIO_ROOT_USER:-}" ] || [ -z "${MINIO_ROOT_PASSWORD:-}" ]; then
    echo "ERROR: MINIO_ROOT_USER or MINIO_ROOT_PASSWORD missing inside container"
    exit 2
  fi

  mc alias rm local >/dev/null 2>&1 || true
  mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc admin info local
' 2>&1 | mask_stream | sed 's/^/    /'

ROOT_RC=${PIPESTATUS[0]}
[ "$ROOT_RC" = 0 ] || {
  ledger "FAIL" "MX10 root credentials failed inside container"
  halt "root credentials failed; do not proceed"
}

hr "D2 list current MinIO IAM users"
podman exec "$CONTAINER" sh -c '
  mc admin user list local 2>/dev/null || true
' 2>&1 | mask_stream | sed 's/^/    /' || true

hr "D3 refuse developer access key equal to root access key"
podman exec "$CONTAINER" sh -c '
  set -u
  if [ "'"${DEV_USER}"'" = "${MINIO_ROOT_USER:-}" ]; then
    echo "ERROR: developer access key equals MINIO_ROOT_USER. Choose a different access key."
    exit 3
  fi
  echo "OK: developer access key is distinct from root access key"
' 2>&1 | mask_stream | sed 's/^/    /'

DISTINCT_RC=${PIPESTATUS[0]}
[ "$DISTINCT_RC" = 0 ] || {
  ledger "FAIL" "MX10 developer access key equals root access key"
  halt "developer access key must not equal root access key"
}

hr "D4 generate/store developer password"
umask 077

if [ -s "$PASS_FILE" ]; then
  cp -p "$PASS_FILE" "$PASS_BAK" || true
  chmod 600 "$PASS_BAK" 2>/dev/null || true
  say "existing password backed up: $PASS_BAK"
fi

python3 -c 'import secrets; print(secrets.token_urlsafe(24), end="")' > "$PASS_FILE"
chmod 600 "$PASS_FILE"

printf '%s\n' "$DEV_USER" > "$USER_FILE"
chmod 600 "$USER_FILE"

say "generated developer password file: $PASS_FILE"
say "developer access key file:        $USER_FILE"

hr "D5 create/recreate developer user"
DEV_PASS="$(cat "$PASS_FILE")"
export DEV_USER DEV_PASS POLICY

podman exec -i \
  -e DEV_USER \
  -e DEV_PASS \
  -e POLICY \
  "$CONTAINER" sh -c '
    set -u

    mc alias rm local >/dev/null 2>&1 || true
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

    if mc admin user info local "$DEV_USER" >/dev/null 2>&1; then
      echo "developer user already exists; removing and recreating to apply new password"
      mc admin user rm local "$DEV_USER"
    fi

    mc admin user add local "$DEV_USER" "$DEV_PASS"

    echo "attaching policy: $POLICY"
    mc admin policy attach local "$POLICY" --user "$DEV_USER" ||
      mc admin policy set local "$POLICY" "$DEV_USER"

    echo "developer user info:"
    mc admin user info local "$DEV_USER"
  ' 2>&1 | mask_stream | sed 's/^/    /'

CREATE_RC=${PIPESTATUS[0]}
unset DEV_PASS

if [ "$CREATE_RC" != 0 ]; then
  ledger "FAIL" "MX10 developer user creation failed rc=$CREATE_RC"
  halt "developer user creation failed"
fi

hr "D6 verify developer login"
DEV_PASS="$(cat "$PASS_FILE")"
export DEV_USER DEV_PASS

podman exec -i \
  -e DEV_USER \
  -e DEV_PASS \
  "$CONTAINER" sh -c '
    set -u
    mc alias rm devtest >/dev/null 2>&1 || true
    mc alias set devtest http://127.0.0.1:9000 "$DEV_USER" "$DEV_PASS" >/dev/null

    echo "developer alias OK"
    mc admin user info local "$DEV_USER" >/dev/null
    echo "developer user info OK"

    echo "developer bucket list:"
    mc ls devtest 2>/dev/null || true
  ' 2>&1 | mask_stream | sed 's/^/    /'

VERIFY_RC=${PIPESTATUS[0]}
unset DEV_PASS

if [ "$VERIFY_RC" != 0 ]; then
  ledger "PARTIAL" "MX10 developer user created but verification failed rc=$VERIFY_RC"
  halt "developer verification failed"
fi

hr "D7 optional conflict warning: IAM user with same key as root"
podman exec "$CONTAINER" sh -c '
  set -u
  if mc admin user info local "${MINIO_ROOT_USER:-}" >/dev/null 2>&1; then
    echo "WARN: an IAM user exists with the same access key as MINIO_ROOT_USER."
    echo "      This can cause confusion in Console."
    echo "      Recommended cleanup command:"
    echo "        podman exec minio sh -c '\''mc admin user rm local \"$MINIO_ROOT_USER\"'\''"
  else
    echo "OK: no IAM user conflicts with root access key"
  fi
' 2>&1 | mask_stream | sed 's/^/    /' || true

hr "D8 RESULT"
say "[RESULT] MX10 COMPLETE - MinIO developer user created."
say ""
say "Console:"
say "  http://127.0.0.1:9011/browser"
say ""
say "Root/admin login:"
say "  Access Key: MINIO_ROOT_USER from container/env"
say "  Secret Key: MINIO_ROOT_PASSWORD from:"
say "              $SEC/aether.env"
say ""
say "Developer login:"
say "  Access Key: $DEV_USER"
say "  Secret Key: contents of:"
say "              $PASS_FILE"
say ""
say "To reveal developer password locally:"
say "  cat '$PASS_FILE'; echo"
say ""
say "Policy:"
say "  $POLICY"

ledger "PASS" "MX10: created MinIO developer user '$DEV_USER' with policy '$POLICY'; password stored at $PASS_FILE."
exit 0
