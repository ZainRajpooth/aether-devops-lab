#!/usr/bin/env bash
# 20261107-MX13 — safe manual MinIO root + normal + console-admin credential rotation.
#
# Fixes MX12:
#   - uses http://127.0.0.1:9000 inside the MinIO container, avoiding ::1 refusal
#   - retries IAM user creation
#   - does not rollback after users have been created
#   - fixes ledger local-variable bug
#   - removes previous local MinIO user secret files
#   - saves new credential files only after success
#
# Behavior:
#   1) prompts for NEW root access key/secret key
#   2) prompts for NEW normal application access key/secret key
#   3) prompts for NEW console admin access key/secret key
#   4) backs up MinIO EnvironmentFile(s)
#   5) updates MINIO_ROOT_USER/MINIO_ROOT_PASSWORD
#   6) restarts MinIO and waits for API + internal mc readiness
#   7) creates/resets only requested IAM users:
#        normal:        policy=readwrite
#        console admin: policy=consoleAdmin
#   8) deletes all other IAM users
#   9) removes old local minio-user.* secret files
#  10) saves new credential files under chmod-600 paths
#
# Secrets are never echoed. Do not paste passwords into chat.
set -uo pipefail
umask 077

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="mx13-minio-manual-credential-rotation-safe-retry-v1"
CONTAINER="${MINIO_CONTAINER:-minio}"
SERVICE="${MINIO_SERVICE:-minio.service}"
QUADLET="$HOME_/.config/containers/systemd/minio.container"

API_URL="http://127.0.0.1:9010"
CONSOLE_URL="http://127.0.0.1:9011/browser"

MODE="${1:-run}"
STAMP="$(date +%Y%m%d-%H%M%S)"

PRUNE_OTHER_MINIO_USER_FILES="${PRUNE_OTHER_MINIO_USER_FILES:-true}"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
: > "$TMP/secrets.txt"

BAKS=()
ORIGS=()

cleanup_tmp(){
  rm -rf "$TMP"
}
trap cleanup_tmp EXIT

say(){
  printf '  %s\n' "$*"
}

hr(){
  printf '\n===== %s =====\n' "$*"
}

halt(){
  say "[HALT] $*"
  exit 1
}

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

upsert_env_file(){
  local path="$1"
  shift

  python3 - "$path" "$@" <<'PYUPSERT'
import os, sys, tempfile

path = sys.argv[1]
updates = {}

for pair in sys.argv[2:]:
    if "=" not in pair:
        continue
    k, v = pair.split("=", 1)
    updates[k] = v

if not os.path.exists(path):
    open(path, "a", encoding="utf-8").close()

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

out = []
seen = set()

for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in stripped:
        k = stripped.split("=", 1)[0].strip()
        if k in updates:
            if k not in seen:
                out.append(f"{k}={updates[k]}\n")
                seen.add(k)
            continue
    out.append(line)

for k, v in updates.items():
    if k not in seen:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append(f"{k}={v}\n")

fd, tmp = tempfile.mkstemp(prefix=".mx13-env-", dir=os.path.dirname(path) or ".")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(out)
    st = os.stat(path)
    os.chmod(tmp, st.st_mode & 0o777)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        try:
            os.unlink(tmp)
        except Exception:
            pass
PYUPSERT
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

backup_and_note(){
  local f="$1"
  local b="${f}.pre-mx13.${STAMP}.bak"

  cp -p "$f" "$b" || halt "backup failed: $f"
  chmod 600 "$b" || true

  BAKS+=("$b")
  ORIGS+=("$f")

  say "backup: $b"
}

rollback_env_only(){
  say "rolling back MinIO env files only"

  local i
  if [ "${#BAKS[@]}" -gt 0 ]; then
    for i in "${!BAKS[@]}"; do
      if [ -f "${BAKS[$i]}" ]; then
        cp -p "${BAKS[$i]}" "${ORIGS[$i]}" || say "WARN rollback copy failed: ${BAKS[$i]} -> ${ORIGS[$i]}"
      fi
    done
  fi

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user restart "$SERVICE" >/dev/null 2>&1 || true
}

wait_minio_api(){
  local attempts="${1:-90}"
  local i c

  for i in $(seq 1 "$attempts"); do
    c="$(http_code "$API_URL/minio/health/live" 3)"
    if [ "$c" = 200 ]; then
      say "MinIO API ready: $API_URL/minio/health/live = 200"
      return 0
    fi
    sleep 2
  done

  return 1
}

mc_ready_internal(){
  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 &&
    mc admin user ls local --json >/dev/null 2>&1
  ' >/dev/null 2>&1
}

dump_minio_logs(){
  say "--- MinIO logs tail 100 ---"
  podman logs --tail 100 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- journalctl minio.service tail 80 ---"
  journalctl --user -u "$SERVICE" -n 80 --no-pager 2>&1 | mask_stream | sed 's/^/    /' || true
}

wait_mc_ready(){
  local attempts="${1:-30}"
  local i

  for i in $(seq 1 "$attempts"); do
    if mc_ready_internal; then
      say "internal mc ready using http://127.0.0.1:9000"
      return 0
    fi
    say "waiting for internal mc readiness... attempt=$i"
    sleep 3
  done

  dump_minio_logs
  return 1
}

list_users_raw(){
  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
    mc admin user ls local --json 2>/dev/null || mc admin user ls local 2>/dev/null || true
  ' 2>/dev/null || true
}

parse_access_keys(){
  python3 - <<'PYPARSE'
import sys, json, re

keys = []

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue

    try:
        d = json.loads(line)
        if isinstance(d, dict):
            ak = d.get("accessKey") or d.get("access_key") or d.get("user") or d.get("name")
            if ak:
                keys.append(str(ak))
            continue
    except Exception:
        pass

    parts = line.split()
    if parts:
        cand = parts[0]
        if cand.lower() not in ("access", "key", "user", "name", "users") and re.fullmatch(r"[A-Za-z0-9._-]{3,128}", cand):
            keys.append(cand)

seen = set()
for k in keys:
    if k not in seen:
        seen.add(k)
        print(k)
PYPARSE
}

remove_user(){
  local ak="$1"

  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
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
    say "creating/replacing user access_key=$ak policy=$policy attempt=$attempt"

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
  say "  1) prompt for NEW root access key/secret key"
  say "  2) prompt for NEW normal access key/secret key"
  say "  3) prompt for NEW console admin access key/secret key"
  say "  4) backup env files"
  say "  5) update MINIO_ROOT_*"
  say "  6) restart MinIO and wait for API + internal mc readiness"
  say "  7) create/reset normal + consoleAdmin users with retries"
  say "  8) delete all other IAM users"
  say "  9) remove previous local minio-user.* secret files"
  say " 10) save new credential files"
  say "[RESULT] MX13 CHECK - nothing written."
  exit 0
fi

hr "X1 collect new credentials manually"

say "Enter credentials now. They will not be echoed."
say "Access keys are usernames/IDs; secret keys are passwords."
say "Use strong values. Do not paste them into chat."

ROOT_AK="$(read_access_key 'New MinIO ROOT access key/username: ')"
ROOT_SK="$(read_secret_key 'New MinIO ROOT secret key/password: ')"
read_repeat_secret 'Repeat new ROOT secret key: ' "$ROOT_SK" || halt "root secret mismatch"

NORMAL_AK="$(read_access_key 'New NORMAL application access key/username: ')"
NORMAL_SK="$(read_secret_key 'New NORMAL application secret key/password: ')"
read_repeat_secret 'Repeat new NORMAL secret key: ' "$NORMAL_SK" || halt "normal secret mismatch"

CONSOLE_AK="$(read_access_key 'New CONSOLE ADMIN access key/username: ')"
CONSOLE_SK="$(read_secret_key 'New CONSOLE ADMIN secret key/password: ')"
read_repeat_secret 'Repeat new CONSOLE ADMIN secret key: ' "$CONSOLE_SK" || halt "console admin secret mismatch"

if [ "$ROOT_AK" = "$NORMAL_AK" ] || [ "$ROOT_AK" = "$CONSOLE_AK" ] || [ "$NORMAL_AK" = "$CONSOLE_AK" ]; then
  halt "access keys must be unique for root, normal, and console admin"
fi

add_secret "$ROOT_SK"
add_secret "$NORMAL_SK"
add_secret "$CONSOLE_SK"

say "credential entry complete"
say "root_access_key=$ROOT_AK"
say "normal_access_key=$NORMAL_AK"
say "console_admin_access_key=$CONSOLE_AK"

hr "X2 backup MinIO env files"

for f in "${ENV_FILES[@]}"; do
  backup_and_note "$f"
done

hr "X3 update MINIO_ROOT_USER/MINIO_ROOT_PASSWORD"

for f in "${ENV_FILES[@]}"; do
  upsert_env_file "$f" "MINIO_ROOT_USER=$ROOT_AK" "MINIO_ROOT_PASSWORD=$ROOT_SK"
  say "updated root credentials in: $f"
done

hr "X4 restart MinIO and verify readiness"

systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user reset-failed "$SERVICE" >/dev/null 2>&1 || true

if ! systemctl --user restart "$SERVICE"; then
  say "MinIO service restart failed; rolling back env files because no IAM users were changed yet"
  rollback_env_only
  ledger "FAIL" "MX13 systemctl restart $SERVICE failed before user creation"
  halt "MinIO service restart failed; env rolled back"
fi

if ! wait_minio_api 90; then
  say "MinIO API did not become healthy; rolling back env files because no IAM users were changed yet"
  dump_minio_logs
  rollback_env_only
  ledger "FAIL" "MX13 MinIO API not healthy after root rotation before user creation"
  halt "MinIO API not healthy; env rolled back"
fi

if ! wait_mc_ready 40; then
  say "internal mc did not become ready; rolling back env files because no IAM users were changed yet"
  rollback_env_only
  ledger "FAIL" "MX13 internal mc not ready after root rotation before user creation"
  halt "internal mc not ready; env rolled back"
fi

hr "X5 create/reset requested IAM users"

if ! create_or_replace_user_retry "$NORMAL_AK" "$NORMAL_SK" "readwrite"; then
  say "[PARTIAL] normal user creation failed."
  say "New root credentials remain applied. Backups are kept. Do not rollback automatically because state may be mixed."
  ledger "PARTIAL" "MX13 normal user creation failed after root rotation; manual retry required"
  halt "normal user creation failed; preserving new root env for retry"
fi

if ! create_or_replace_user_retry "$CONSOLE_AK" "$CONSOLE_SK" "consoleAdmin"; then
  say "[PARTIAL] console admin user creation failed."
  say "Normal user may already exist. New root credentials remain applied. Backups are kept."
  ledger "PARTIAL" "MX13 console admin user creation failed after root rotation; manual retry required"
  halt "console admin user creation failed; preserving new root env for retry"
fi

hr "X6 delete all other MinIO IAM users"

mapfile -t EXISTING_USERS < <(list_users_raw | parse_access_keys)

say "existing IAM users detected: ${#EXISTING_USERS[@]}"

for ak in "${EXISTING_USERS[@]}"; do
  if allowed_key "$ak"; then
    say "keeping allowed access key: $ak"
  else
    say "deleting non-requested IAM user: $ak"
    remove_user "$ak"
  fi
done

mapfile -t FINAL_USERS < <(list_users_raw | parse_access_keys)

say "final IAM users:"
for ak in "${FINAL_USERS[@]}"; do
  say "  $ak"
done

NORMAL_PRESENT=no
CONSOLE_PRESENT=no
UNWANTED=""

for ak in "${FINAL_USERS[@]}"; do
  if [ "$ak" = "$NORMAL_AK" ]; then
    NORMAL_PRESENT=yes
  fi

  if [ "$ak" = "$CONSOLE_AK" ]; then
    CONSOLE_PRESENT=yes
  fi

  if ! allowed_key "$ak"; then
    UNWANTED="$UNWANTED $ak"
  fi
done

if [ "$NORMAL_PRESENT" != yes ] || [ "$CONSOLE_PRESENT" != yes ]; then
  ledger "PARTIAL" "MX13 requested users not all present: normal=$NORMAL_PRESENT console=$CONSOLE_PRESENT"
  halt "requested users are not all present"
fi

if [ -n "$UNWANTED" ]; then
  say "[WARN] unwanted IAM users remain:$UNWANTED"
  ledger "PARTIAL" "MX13 requested users exist, but unwanted IAM users remain:$UNWANTED"
else
  say "[OK] only requested IAM users remain"
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

if [ "$PRUNE_OTHER_MINIO_USER_FILES" = true ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$f"
    say "pruned old minio-user file: $f"
  done < <(find "$SEC" -maxdepth 2 -type f \( -name 'minio-user.*.pass' -o -name 'minio-user.*.user' \) 2>/dev/null || true)
fi

hr "X9 verify endpoints and users"

API_HEALTH="$(http_code "$API_URL/minio/health/live")"
CONSOLE_ROOT="$(http_code "http://127.0.0.1:9011/")"
CONSOLE_BROWSER="$(http_code "$CONSOLE_URL")"

say "API health 9010 = $API_HEALTH"
say "Console root 9011 = $CONSOLE_ROOT"
say "Console browser 9011 = $CONSOLE_BROWSER"

say "--- normal user info ---"
podman exec "$CONTAINER" sh -c '
  mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
  mc admin user info local "$1" 2>&1 || true
' _ "$NORMAL_AK" | mask_stream | sed 's/^/    /' || true

say "--- console admin user info ---"
podman exec "$CONTAINER" sh -c '
  mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
  mc admin user info local "$1" 2>&1 || true
' _ "$CONSOLE_AK" | mask_stream | sed 's/^/    /' || true

hr "X10 result"

say "[RESULT] MX13 COMPLETE - MinIO credentials manually rotated."
say ""
say "MinIO Console:"
say "  $CONSOLE_URL"
say ""
say "Root emergency admin:"
say "  access key file: $SEC/$ROOT_BASE.user"
say "  secret key file: $SEC/$ROOT_BASE.pass"
say ""
say "Normal application user:"
say "  access key file: $SEC/minio-users/$NORMAL_BASE.user"
say "  secret key file: $SEC/minio-users/$NORMAL_BASE.pass"
say "  policy: readwrite"
say "  S3 endpoint: $API_URL"
say ""
say "Console admin user:"
say "  access key file: $SEC/minio-users/$CONSOLE_BASE.user"
say "  secret key file: $SEC/minio-users/$CONSOLE_BASE.pass"
say "  policy: consoleAdmin"
say "  Console: $CONSOLE_URL"
say ""
say "To reveal a password locally when needed:"
say "  cat '$SEC/$ROOT_BASE.pass'; echo"
say "  cat '$SEC/minio-users/$NORMAL_BASE.pass'; echo"
say "  cat '$SEC/minio-users/$CONSOLE_BASE.pass'; echo"

if [ "$API_HEALTH" = 200 ] && [ -z "$UNWANTED" ]; then
  ledger "PASS" "MX13: manual root/normal/console-admin rotation complete; API=$API_HEALTH; final_users=${#FINAL_USERS[@]}"
else
  ledger "PARTIAL" "MX13: rotation completed with warnings; API=$API_HEALTH; unwanted=$UNWANTED"
fi

hr "X11 purge MX13 backups containing previous root secret?"

say "Backup files may contain the OLD root password."
printf 'Type YES to securely remove MX13 backups now. Anything else keeps them for rollback: ' > /dev/tty
IFS= read -r PURGE < /dev/tty
printf '\n' > /dev/tty

if [ "$PURGE" = "YES" ]; then
  for b in "${BAKS[@]}"; do
    if [ -f "$b" ]; then
      if command -v shred >/dev/null 2>&1; then
        shred -u -n 1 "$b" 2>/dev/null || rm -f "$b"
      else
        rm -f "$b"
      fi
      say "purged backup: $b"
    fi
  done
  say "MX13 backups purged; rollback no longer available"
else
  say "MX13 backups kept:"
  for b in "${BAKS[@]}"; do
    say "  $b"
  done
fi

exit 0
