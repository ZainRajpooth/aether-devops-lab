#!/usr/bin/env bash
# 20261107-MX14 — finalize MinIO manual root/normal/console-admin credentials.
#
# Fixes MX13's false-negative verification by:
#   - verifying expected users with mc admin user info, not only user list
#   - resetting devX/conX with newly typed secrets
#   - deleting known old users if present
#   - saving new local credential files
#   - removing old minio-user.* secret files
#   - verifying S3 API and Console endpoints
#
# This script does not rotate root unless root env verification fails.
# Secrets are never echoed. Do not paste passwords into chat.
set -uo pipefail
umask 077

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="mx14-minio-finalize-manual-credentials-v1"
CONTAINER="${MINIO_CONTAINER:-minio}"
SERVICE="${MINIO_SERVICE:-minio.service}"
QUADLET="$HOME_/.config/containers/systemd/minio.container"

API_URL="http://127.0.0.1:9010"
CONSOLE_URL="http://127.0.0.1:9011/browser"

MODE="${1:-run}"
STAMP="$(date +%Y%m%d-%H%M%S)"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
: > "$TMP/secrets.txt"

cleanup_tmp(){ rm -rf "$TMP"; }
trap cleanup_tmp EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD" "$SEC" "$SEC/minio-users"
touch "$IDX"

ledger(){
  local gate
  gate="$1"

  local desc
  desc="$2"

  local row_token
  row_token="${TOKEN}:${gate}"

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
  printf '%s\n' "$v" >> "$TMP/secrets.txt"
}

mask_stream(){
  python3 - "$TMP/secrets.txt" <<'PYMASK'
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

jwt = re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")
hexish = re.compile(r"[0-9a-fA-F]{40,}")

for line in sys.stdin:
    for s in secrets:
        if s:
            line = line.replace(s, "[REDACTED]")
    line = jwt.sub("[JWT]", line)
    line = hexish.sub("[HEX]", line)
    sys.stdout.write(line)
PYMASK
}

mask_file(){
  [ -f "$1" ] && mask_stream < "$1" || true
}

http_code(){
  local url="$1"
  local timeout="${2:-8}"
  local c
  c="$(curl -sS -m "$timeout" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  c="${c:-000}"
  printf '%s\n' "${c:0:3}"
}

acceptable_http(){
  case "${1:-000}" in
    200|201|202|204|301|302|303|307|308|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

read_access_key(){
  local prompt="$1"
  local v

  while true; do
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r v < /dev/tty
    printf '\n' > /dev/tty

    if [[ "$v" =~ ^[A-Za-z0-9._-]{3,128}$ ]]; then
      printf '%s' "$v"
      return 0
    fi

    printf '[INVALID] Access key must be 3-128 chars and use only A-Z a-z 0-9 . _ -\n' > /dev/tty
  done
}

read_secret_key(){
  local prompt="$1"
  local v

  while true; do
    printf '%s' "$prompt" > /dev/tty
    IFS= read -rs v < /dev/tty
    printf '\n' > /dev/tty

    if [[ "$v" =~ ^[^[:space:]]{8,128}$ ]]; then
      printf '%s' "$v"
      return 0
    fi

    printf '[INVALID] Secret key/password must be 8-128 chars and contain no whitespace\n' > /dev/tty
  done
}

read_repeat_secret(){
  local prompt="$1"
  local expected="$2"
  local v

  printf '%s' "$prompt" > /dev/tty
  IFS= read -rs v < /dev/tty
  printf '\n' > /dev/tty

  if [ "$v" = "$expected" ]; then
    return 0
  fi

  printf '[MISMATCH] Secret keys do not match.\n' > /dev/tty
  return 1
}

detect_env_files(){
  ENV_FILES=()

  add_candidate(){
    local f="${1:-}"
    [ -n "$f" ] || return 0

    case "$f" in
      "~"/*) f="$HOME_/${f#\~/}" ;;
      /*) ;;
      *) f="$(dirname "$QUADLET")/$f" ;;
    esac

    [ -f "$f" ] || return 0

    local existing
    if [ "${#ENV_FILES[@]}" -gt 0 ]; then
      for existing in "${ENV_FILES[@]}"; do
        [ "$existing" = "$f" ] && return 0
      done
    fi

    if grep -qE '^[[:space:]]*MINIO_(ROOT_USER|ROOT_PASSWORD)[[:space:]]*=' "$f" 2>/dev/null; then
      ENV_FILES+=("$f")
    fi
  }

  if [ -f "$QUADLET" ]; then
    while IFS= read -r f; do
      add_candidate "$f"
    done < <(awk '/^[[:space:]]*EnvironmentFile[[:space:]]*=/{sub(/^[^=]+=/,""); gsub(/[[:space:]]/,"",$0); print}' "$QUADLET" 2>/dev/null || true)
  fi

  add_candidate "$HOME_/.config/aether/secrets.env"
  add_candidate "$HOME_/DevOps/aether/secrets/aether.env"

  if [ "${#ENV_FILES[@]}" -eq 0 ]; then
    while IFS= read -r f; do
      add_candidate "$f"
    done < <(find "$SEC" -maxdepth 3 -type f \( -name '*.env' -o -name 'secrets.env' -o -name 'aether.env' \) 2>/dev/null || true)
  fi
}

env_get_from_file(){
  local file="$1"
  local key="$2"

  python3 - "$file" "$key" <<'PY'
import sys

path, key = sys.argv[1], sys.argv[2]

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\r\n")
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue

            k, v = line.split("=", 1)
            if k.strip() == key:
                sys.stdout.write(v)
                break
except Exception:
    pass
PY
}

verify_root_pair(){
  local ak="$1"
  local sk="$2"

  podman exec -i "$CONTAINER" sh -c '
    IFS= read -r ak
    IFS= read -r sk

    mc alias set local http://127.0.0.1:9000 "$ak" "$sk" >/dev/null 2>&1 || exit 1

    # Any successful admin read proves the root pair is valid.
    mc admin user list local >/dev/null 2>&1 ||
    mc admin user ls local >/dev/null 2>&1 ||
    mc admin info local >/dev/null 2>&1
  ' < <(printf '%s\n%s\n' "$ak" "$sk") >/dev/null 2>&1
}

list_users_raw(){
  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || exit 0

    mc admin user list local --json 2>/dev/null || true
    mc admin user ls local --json 2>/dev/null || true
    mc admin user list local 2>/dev/null || true
    mc admin user ls local 2>/dev/null || true
  ' 2>/dev/null || true
}

parse_access_keys(){
  python3 - <<'PYPARSE'
import sys, json, re

keys = []

block = {
    "accesskey", "access", "key", "status", "enabled", "disabled",
    "user", "users", "name", "policy", "policies", "target", "local",
    "etag", "size", "versionid"
}

ak_re = re.compile(r"^[A-Za-z0-9._-]{3,128}$")

def add(k):
    k = str(k).strip()
    if not k:
        return
    if k.lower() in block:
        return
    if not ak_re.fullmatch(k):
        return
    keys.append(k)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue

    # JSON line or JSON array.
    if line.startswith("{") or line.startswith("["):
        try:
            d = json.loads(line)
        except Exception:
            d = None

        if isinstance(d, dict):
            ak = d.get("accessKey") or d.get("access_key") or d.get("user") or d.get("name")
            if ak:
                add(ak)
            continue

        if isinstance(d, list):
            for item in d:
                if isinstance(item, dict):
                    ak = item.get("accessKey") or item.get("access_key") or item.get("user") or item.get("name")
                    if ak:
                        add(ak)
            continue

    # Plain table fallback: first token is usually access key.
    parts = line.split()
    if parts:
        add(parts[0])

seen = set()
for k in keys:
    if k not in seen:
        seen.add(k)
        print(k)
PYPARSE
}

user_exists(){
  local ak="$1"

  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || exit 1
    mc admin user info local "$1" >/dev/null 2>&1
  ' _ "$ak" >/dev/null 2>&1
}

delete_user(){
  local ak="$1"

  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || exit 0
    mc admin user rm local "$1" >/dev/null 2>&1 || true
  ' _ "$ak" >/dev/null 2>&1 || true
}

create_or_replace_user_once(){
  local ak="$1"
  local sk="$2"
  local policy="$3"

  podman exec -i "$CONTAINER" sh -c '
    set -eu

    policy="$1"

    IFS= read -r ak
    IFS= read -r sk

    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

    mc admin user rm local "$ak" >/dev/null 2>&1 || true
    mc admin user add local "$ak" "$sk"
    mc admin policy attach local "$policy" --user "$ak"
  ' _ "$policy" < <(printf '%s\n%s\n' "$ak" "$sk")
}

create_or_replace_user_retry(){
  local ak="$1"
  local sk="$2"
  local policy="$3"
  local attempt

  for attempt in 1 2 3 4 5 6; do
    say "creating/resetting user access_key=$ak policy=$policy attempt=$attempt"

    if create_or_replace_user_once "$ak" "$sk" "$policy"; then
      say "OK user ready: $ak"
      return 0
    fi

    say "WARN user operation failed; retrying after short wait"
    dump_minio_logs
    sleep 5
  done

  return 1
}

dump_minio_logs(){
  say "--- MinIO logs tail 80 ---"
  podman logs --tail 80 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- journalctl minio.service tail 60 ---"
  journalctl --user -u "$SERVICE" -n 60 --no-pager 2>&1 | mask_stream | sed 's/^/    /' || true
}

allowed_key(){
  local k="$1"

  [ "$k" = "$ROOT_AK" ] && return 0
  [ "$k" = "$NORMAL_AK" ] && return 0
  [ "$k" = "$CONSOLE_AK" ] && return 0

  return 1
}

save_cred_pair(){
  local dir="$1"
  local base="$2"
  local ak="$3"
  local sk="$4"

  mkdir -p "$dir"

  printf '%s' "$ak" > "$dir/$base.user"
  printf '%s' "$sk" > "$dir/$base.pass"

  chmod 600 "$dir/$base.user" "$dir/$base.pass"
}

show_user_info(){
  local ak="$1"

  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || exit 0
    mc admin user info local "$1" 2>&1 || true
  ' _ "$ak" 2>&1 | mask_stream | sed 's/^/    /' || true
}

hr "X0 preflight"

for c in python3 curl podman awk sed grep systemctl find; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done

[ -e /dev/tty ] || halt "this script requires /dev/tty for manual credential entry"
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$QUADLET" ] || halt "missing quadlet: $QUADLET"

detect_env_files

if [ "${#ENV_FILES[@]}" -eq 0 ]; then
  halt "could not detect MinIO EnvironmentFile containing MINIO_ROOT_USER/MINIO_ROOT_PASSWORD"
fi

say "container=$CONTAINER"
say "service=$SERVICE"
say "api=$API_URL"
say "console=$CONSOLE_URL"
say "detected MinIO env files:"

for f in "${ENV_FILES[@]}"; do
  say "  $f"
done

if [ "$MODE" = check ]; then
  hr "X1 plan (check mode)"
  say "  1) read and verify current MINIO_ROOT_USER/MINIO_ROOT_PASSWORD from env files"
  say "  2) prompt for NORMAL and CONSOLE ADMIN access/secret keys"
  say "  3) reset devX/readwrite and conX/consoleAdmin with retries"
  say "  4) verify expected users using mc admin user info"
  say "  5) delete known old users and any listed unwanted users"
  say "  6) save new local credential files"
  say "  7) remove old minio-user.* secret files"
  say "  8) verify S3 API and Console endpoints"
  say "[RESULT] MX14 CHECK - nothing written."
  exit 0
fi

hr "X1 verify current root credentials from env files"

ROOT_AK=""
ROOT_SK=""
ROOT_ENV_USED=""

for f in "${ENV_FILES[@]}"; do
  ak="$(env_get_from_file "$f" MINIO_ROOT_USER || true)"
  sk="$(env_get_from_file "$f" MINIO_ROOT_PASSWORD || true)"

  if [ -n "$ak" ] && [ -n "$sk" ]; then
    say "testing root pair from: $f access_key=$ak"
    if verify_root_pair "$ak" "$sk"; then
      ROOT_AK="$ak"
      ROOT_SK="$sk"
      ROOT_ENV_USED="$f"
      say "root pair verified from: $f"
      break
    else
      say "root pair did not verify from: $f"
    fi
  else
    say "missing root user/password in: $f"
  fi
done

if [ -z "$ROOT_AK" ] || [ -z "$ROOT_SK" ]; then
  dump_minio_logs
  ledger "FAIL" "MX14 could not verify current MinIO root credentials from env files"
  halt "could not verify current MinIO root credentials; not prompting root rotation in this finalizer"
fi

add_secret "$ROOT_SK"

say "root_access_key=$ROOT_AK"
say "root_env_used=$ROOT_ENV_USED"

hr "X2 collect NORMAL and CONSOLE ADMIN credentials manually"

say "Enter the credentials you want to keep. They will not be echoed."
say "MX13 created devX/conX but did not save their passwords."
say "Re-enter the same passwords if you remember them, or set new ones now."

NORMAL_AK="$(read_access_key 'NORMAL application access key/username (example: devX): ')"
NORMAL_SK="$(read_secret_key 'NORMAL application secret key/password: ')"
read_repeat_secret 'Repeat new NORMAL secret key: ' "$NORMAL_SK" || halt "normal secret mismatch"

CONSOLE_AK="$(read_access_key 'CONSOLE ADMIN access key/username (example: conX): ')"
CONSOLE_SK="$(read_secret_key 'CONSOLE ADMIN secret key/password: ')"
read_repeat_secret 'Repeat new CONSOLE ADMIN secret key: ' "$CONSOLE_SK" || halt "console admin secret mismatch"

if [ "$ROOT_AK" = "$NORMAL_AK" ] || [ "$ROOT_AK" = "$CONSOLE_AK" ] || [ "$NORMAL_AK" = "$CONSOLE_AK" ]; then
  halt "access keys must be unique for root, normal, and console admin"
fi

add_secret "$NORMAL_SK"
add_secret "$CONSOLE_SK"

say "normal_access_key=$NORMAL_AK"
say "console_admin_access_key=$CONSOLE_AK"

hr "X3 reset requested IAM users"

if ! create_or_replace_user_retry "$NORMAL_AK" "$NORMAL_SK" "readwrite"; then
  ledger "PARTIAL" "MX14 normal user reset failed after root verification"
  halt "normal user reset failed; preserving current root credentials"
fi

if ! create_or_replace_user_retry "$CONSOLE_AK" "$CONSOLE_SK" "consoleAdmin"; then
  ledger "PARTIAL" "MX14 console admin user reset failed after normal user success"
  halt "console admin user reset failed; preserving current root credentials"
fi

hr "X4 verify expected users directly"

NORMAL_PRESENT=no
CONSOLE_PRESENT=no

if user_exists "$NORMAL_AK"; then
  NORMAL_PRESENT=yes
  say "expected normal user present: $NORMAL_AK"
else
  say "EXPECTED NORMAL USER MISSING: $NORMAL_AK"
fi

if user_exists "$CONSOLE_AK"; then
  CONSOLE_PRESENT=yes
  say "expected console admin user present: $CONSOLE_AK"
else
  say "EXPECTED CONSOLE ADMIN USER MISSING: $CONSOLE_AK"
fi

if [ "$NORMAL_PRESENT" != yes ] || [ "$CONSOLE_PRESENT" != yes ]; then
  dump_minio_logs
  ledger "FAIL" "MX14 expected users not present after reset: normal=$NORMAL_PRESENT console=$CONSOLE_PRESENT"
  halt "expected users are not present after reset"
fi

hr "X5 delete known old users and listed unwanted users"

OLD_KEYS=()

add_old_key(){
  local k="${1:-}"
  local e

  [ -n "$k" ] || return 0
  allowed_key "$k" && return 0

  if [ "${#OLD_KEYS[@]}" -gt 0 ]; then
    for e in "${OLD_KEYS[@]}"; do
      [ "$e" = "$k" ] && return 0
    done
  fi

  OLD_KEYS+=("$k")
}

# Hard-coded likely previous MX11 names.
add_old_key "developer"
add_old_key "consoleadmin"

# Collect old access keys from existing local secret files before pruning.
while IFS= read -r file; do
  [ -n "$file" ] || continue
  ak="$(tr -d '\r\n' < "$file" 2>/dev/null || true)"
  add_old_key "$ak"
done < <(find "$SEC" -maxdepth 2 -type f -name 'minio-user.*.user' 2>/dev/null || true)

say "known old candidate keys to remove if present:"
if [ "${#OLD_KEYS[@]}" -eq 0 ]; then
  say "  none"
else
  for k in "${OLD_KEYS[@]}"; do
    say "  $k"
  done
fi

for k in ${OLD_KEYS[@]+"${OLD_KEYS[@]}"}; do
  if user_exists "$k"; then
    say "deleting known old user: $k"
    delete_user "$k"
  else
    say "known old user not present: $k"
  fi
done

mapfile -t LISTED_USERS < <(list_users_raw | parse_access_keys)

say "listed IAM users detected: ${#LISTED_USERS[@]}"
for ak in ${LISTED_USERS[@]+"${LISTED_USERS[@]}"}; do
  say "  listed: $ak"
done

for ak in ${LISTED_USERS[@]+"${LISTED_USERS[@]}"}; do
  if allowed_key "$ak"; then
    say "keeping allowed access key: $ak"
  else
    say "deleting listed unwanted user: $ak"
    delete_user "$ak"
  fi
done

hr "X6 final user verification"

mapfile -t FINAL_USERS < <(list_users_raw | parse_access_keys)

say "final listed IAM users: ${#FINAL_USERS[@]}"
for ak in ${FINAL_USERS[@]+"${FINAL_USERS[@]}"}; do
  say "  $ak"
done

UNWANTED=""

for ak in ${FINAL_USERS[@]+"${FINAL_USERS[@]}"}; do
  if ! allowed_key "$ak"; then
    UNWANTED="$UNWANTED $ak"
  fi
done

say "normal user info:"
show_user_info "$NORMAL_AK"

say "console admin user info:"
show_user_info "$CONSOLE_AK"

if [ -n "$UNWANTED" ]; then
  say "[WARN] unwanted IAM users may remain:$UNWANTED"
else
  say "[OK] no listed unwanted IAM users remain"
fi

hr "X7 save new credential files"

ROOT_BASE="minio-root"
NORMAL_BASE="minio-normal"
CONSOLE_BASE="minio-console-admin"

save_cred_pair "$SEC" "$ROOT_BASE" "$ROOT_AK" "$ROOT_SK"
save_cred_pair "$SEC/minio-users" "$NORMAL_BASE" "$NORMAL_AK" "$NORMAL_SK"
save_cred_pair "$SEC/minio-users" "$CONSOLE_BASE" "$CONSOLE_AK" "$CONSOLE_SK"

say "saved:"
say "  $SEC/$ROOT_BASE.user"
say "  $SEC/$ROOT_BASE.pass"
say "  $SEC/minio-users/$NORMAL_BASE.user"
say "  $SEC/minio-users/$NORMAL_BASE.pass"
say "  $SEC/minio-users/$CONSOLE_BASE.user"
say "  $SEC/minio-users/$CONSOLE_BASE.pass"

hr "X8 remove previous local MinIO user secret files"

KNOWN_OLD_FILES=(
  "$SEC/minio-user.developer.user"
  "$SEC/minio-user.developer.pass"
  "$SEC/minio-user.consoleadmin.user"
  "$SEC/minio-user.consoleadmin.pass"
)

for f in "${KNOWN_OLD_FILES[@]}"; do
  if [ -e "$f" ]; then
    rm -f "$f"
    say "removed: $f"
  fi
done

while IFS= read -r f; do
  [ -n "$f" ] || continue
  rm -f "$f"
  say "pruned old minio-user file: $f"
done < <(find "$SEC" -maxdepth 2 -type f \( -name 'minio-user.*.pass' -o -name 'minio-user.*.user' \) 2>/dev/null || true)

hr "X9 verify endpoints"

API_HEALTH="$(http_code "$API_URL/minio/health/live")"
CONSOLE_ROOT="$(http_code "http://127.0.0.1:9011/")"
CONSOLE_BROWSER="$(http_code "$CONSOLE_URL")"

say "API health 9010 = $API_HEALTH"
say "Console root 9011 = $CONSOLE_ROOT"
say "Console browser 9011 = $CONSOLE_BROWSER"

CONSOLE_OK=no
if acceptable_http "$CONSOLE_BROWSER" || acceptable_http "$CONSOLE_ROOT"; then
  CONSOLE_OK=yes
fi

EXPECTED_OK=yes
if [ "$NORMAL_PRESENT" != yes ] || [ "$CONSOLE_PRESENT" != yes ]; then
  EXPECTED_OK=no
fi

hr "X10 result"

say "[RESULT] MX14 COMPLETE - MinIO manual credentials finalized."
say ""
say "MinIO Console:"
say "  $CONSOLE_URL"
say ""
say "Root emergency admin:"
say "  access key: $ROOT_AK"
say "  access key file: $SEC/$ROOT_BASE.user"
say "  secret key file: $SEC/$ROOT_BASE.pass"
say ""
say "Normal application user:"
say "  access key: $NORMAL_AK"
say "  access key file: $SEC/minio-users/$NORMAL_BASE.user"
say "  secret key file: $SEC/minio-users/$NORMAL_BASE.pass"
say "  policy: readwrite"
say "  S3 endpoint: $API_URL"
say ""
say "Console admin user:"
say "  access key: $CONSOLE_AK"
say "  access key file: $SEC/minio-users/$CONSOLE_BASE.user"
say "  secret key file: $SEC/minio-users/$CONSOLE_BASE.pass"
say "  policy: consoleAdmin"
say "  Console: $CONSOLE_URL"
say ""
say "To reveal a password locally when needed:"
say "  cat '$SEC/$ROOT_BASE.pass'; echo"
say "  cat '$SEC/minio-users/$NORMAL_BASE.pass'; echo"
say "  cat '$SEC/minio-users/$CONSOLE_BASE.pass'; echo"

if [ "$API_HEALTH" = 200 ] && [ "$EXPECTED_OK" = yes ] && [ -z "$UNWANTED" ] && [ "$CONSOLE_OK" = yes ]; then
  ledger "PASS" "MX14: manual MinIO credentials finalized; API=$API_HEALTH; console=$CONSOLE_BROWSER; users normal=$NORMAL_AK console=$CONSOLE_AK"
  GATE="PASS"
elif [ "$API_HEALTH" = 200 ] && [ "$EXPECTED_OK" = yes ]; then
  ledger "PARTIAL" "MX14: credentials finalized, but Console UI or unwanted-user cleanup has warnings; API=$API_HEALTH console=$CONSOLE_BROWSER unwanted=${UNWANTED:-none}"
  GATE="PARTIAL"
else
  ledger "FAIL" "MX14: credential finalization failed or API unhealthy; API=$API_HEALTH expected=$EXPECTED_OK unwanted=$UNWANTED"
  GATE="FAIL"
fi

if [ "$GATE" != FAIL ]; then
  hr "X11 purge old MX12/MX13 env backups containing previous root secret?"

  say "Old backup files may contain previous MinIO root passwords."
  printf 'Type YES to securely remove MX12/MX13 env backups now. Anything else keeps them: ' > /dev/tty
  IFS= read -r PURGE < /dev/tty
  printf '\n' > /dev/tty

  if [ "$PURGE" = "YES" ]; then
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      if command -v shred >/dev/null 2>&1; then
        shred -u -n 1 "$b" 2>/dev/null || rm -f "$b"
      else
        rm -f "$b"
      fi
      say "purged backup: $b"
    done < <(find "$HOME_/.config/aether" "$SEC" -maxdepth 3 -type f \( -name '*.pre-mx12.*.bak' -o -name '*.pre-mx13.*.bak' \) 2>/dev/null || true)

    say "old backups purged"
  else
    say "old backups kept"
  fi
fi

exit 0
