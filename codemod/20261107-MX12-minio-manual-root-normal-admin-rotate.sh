#!/usr/bin/env bash
# 20261107-MX12 — manual MinIO root + normal + console-admin credential rotation.
#
# Behavior:
#   - prompts you to type NEW root access key/secret key
#   - prompts you to type NEW normal application access key/secret key
#   - prompts you to type NEW console admin access key/secret key
#   - updates MINIO_ROOT_USER/MINIO_ROOT_PASSWORD in MinIO EnvironmentFile(s)
#   - restarts MinIO and verifies S3 API health
#   - creates/updates only the two new IAM users:
#       normal:       policy=readwrite
#       console admin: policy=consoleAdmin
#   - deletes all other MinIO IAM users
#   - removes previous local MinIO user secret files
#   - saves new credentials into chmod-600 files
#   - optionally purges backup files containing old root secret after success
#
# Secrets are never echoed. Do not paste passwords into chat.
set -uo pipefail
umask 077

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="mx12-minio-manual-root-normal-admin-rotate-v1"
CONTAINER="${MINIO_CONTAINER:-minio}"
SERVICE="${MINIO_SERVICE:-minio.service}"
QUADLET="$HOME_/.config/containers/systemd/minio.container"

API_URL="http://127.0.0.1:9010"
CONSOLE_URL="http://127.0.0.1:9011/browser"

MODE="${1:-run}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Set false if you do NOT want unrelated minio-user.* secret files pruned.
PRUNE_OTHER_MINIO_USER_FILES="${PRUNE_OTHER_MINIO_USER_FILES:-true}"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
: > "$TMP/secrets.txt"
BAKS=()
ORIGS=()

cleanup_tmp(){ rm -rf "$TMP"; }
trap cleanup_tmp EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD" "$SEC" "$SEC/minio-users"
touch "$IDX"

ledger(){
  local gate="$1" desc="$2" row_token="${TOKEN}:${gate}"
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
secrets=[]
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            v=line.rstrip("\n")
            if v:
                secrets.append(v)
except Exception:
    pass

jwt=re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")
hexish=re.compile(r"[0-9a-fA-F]{40,}")

for line in sys.stdin:
    for s in secrets:
        line=line.replace(s, "[REDACTED]")
    line=jwt.sub("[JWT]", line)
    line=hexish.sub("[HEX]", line)
    sys.stdout.write(line)
PYMASK
}

mask_file(){
  [ -f "$1" ] && mask_stream < "$1" || true
}

http_code(){
  local c
  c="$(curl -sS -m "${2:-8}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true)"
  c="${c:-000}"
  printf '%s\n' "${c:0:3}"
}

read_access_key(){
  local prompt="$1" v
  while true; do
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r v < /dev/tty
    printf '\n' > /dev/tty
    if [[ "$v" =~ ^[A-Za-z0-9._-]{3,128}$ ]]; then
      printf '%s' "$v"
      return 0
    fi
    say "[INVALID] Access key must be 3-128 chars and use only A-Z a-z 0-9 . _ -"
  done
}

read_secret_key(){
  local prompt="$1" v
  while true; do
    printf '%s' "$prompt" > /dev/tty
    IFS= read -rs v < /dev/tty
    printf '\n' > /dev/tty
    if [[ "$v" =~ ^[^[:space:]]{8,128}$ ]]; then
      printf '%s' "$v"
      return 0
    fi
    say "[INVALID] Secret key/password must be 8-128 chars and contain no whitespace"
  done
}

read_repeat_secret(){
  local prompt="$1" expected="$2" v
  while true; do
    printf '%s' "$prompt" > /dev/tty
    IFS= read -rs v < /dev/tty
    printf '\n' > /dev/tty
    if [ "$v" = "$expected" ]; then
      return 0
    fi
    say "[MISMATCH] Secret keys do not match; repeat both"
    return 1
  done
}

slug(){
  python3 - "$1" <<'PY'
import re, sys
s=sys.argv[1]
s=re.sub(r"[^A-Za-z0-9._-]", "-", s).strip("-")
print(s or "user")
PY
}

upsert_env_file(){
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PYUPSERT'
import os, sys, tempfile

path=sys.argv[1]
updates={}
for pair in sys.argv[2:]:
    if "=" not in pair:
        continue
    k,v=pair.split("=",1)
    updates[k]=v

if not os.path.exists(path):
    open(path,"a",encoding="utf-8").close()

with open(path,"r",encoding="utf-8",errors="replace") as f:
    lines=f.readlines()

out=[]
seen=set()
for line in lines:
    stripped=line.strip()
    if stripped and not stripped.startswith("#") and "=" in stripped:
        k=stripped.split("=",1)[0].strip()
        if k in updates:
            if k not in seen:
                out.append(f"{k}={updates[k]}\n")
                seen.add(k)
            continue
    out.append(line)

for k,v in updates.items():
    if k not in seen:
        if out and not out[-1].endswith("\n"):
            out[-1]+="\n"
        out.append(f"{k}={v}\n")

fd,tmp=tempfile.mkstemp(prefix=".mx12-env-", dir=os.path.dirname(path) or ".")
try:
    with os.fdopen(fd,"w",encoding="utf-8") as f:
        f.writelines(out)
    st=os.stat(path)
    os.chmod(tmp, st.st_mode & 0o777)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp):
        try: os.unlink(tmp)
        except Exception: pass
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
    for existing in "${ENV_FILES[@]:-}"; do
      [ "$existing" = "$f" ] && return 0
    done

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

  # Last resort: any MinIO root env file under secrets, but do not mass-edit unknown files.
  if [ "${#ENV_FILES[@]}" -eq 0 ]; then
    while IFS= read -r f; do
      add_candidate "$f"
    done < <(find "$SEC" -maxdepth 3 -type f \( -name '*.env' -o -name 'secrets.env' -o -name 'aether.env' \) 2>/dev/null || true)
  fi
}

backup_and_note(){
  local f="$1"
  local b="${f}.pre-mx12.${STAMP}.bak"
  cp -p "$f" "$b" || halt "backup failed: $f"
  chmod 600 "$b" || true
  BAKS+=("$b")
  ORIGS+=("$f")
  say "backup: $b"
}

rollback_env(){
  say "rolling back MinIO env files"
  local i
  for i in "${!BAKS[@]}"; do
    [ -f "${BAKS[$i]}" ] && cp -p "${BAKS[$i]}" "${ORIGS[$i]}" || true
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user restart "$SERVICE" >/dev/null 2>&1 || true
}

wait_minio_api(){
  local attempts="${1:-60}" i c
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

mc_alias_local(){
  podman exec "$CONTAINER" sh -c '
    mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
  '
}

list_users_raw(){
  podman exec "$CONTAINER" sh -c '
    mc admin user ls local --json 2>/dev/null || mc admin user ls local 2>/dev/null || true
  '
}

parse_access_keys(){
  python3 - <<'PYPARSE'
import sys, json, re
keys=[]
for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    try:
        d=json.loads(line)
        if isinstance(d, dict):
            ak=d.get("accessKey") or d.get("access_key") or d.get("user") or d.get("name")
            if ak:
                keys.append(str(ak))
            continue
    except Exception:
        pass
    parts=line.split()
    if parts:
        cand=parts[0]
        if cand.lower() not in ("access", "key", "user", "name", "users") and re.fullmatch(r"[A-Za-z0-9._-]{3,128}", cand):
            keys.append(cand)

seen=set()
for k in keys:
    if k not in seen:
        seen.add(k)
        print(k)
PYPARSE
}

remove_user(){
  local ak="$1"
  podman exec "$CONTAINER" sh -c '
    mc admin user rm local "$1" >/dev/null 2>&1 || true
  ' _ "$ak"
}

create_or_replace_user(){
  local ak="$1" sk="$2" policy="$3"
  podman exec -i "$CONTAINER" sh -c '
    policy="$1"
    IFS= read -r ak
    IFS= read -r sk
    mc admin user rm local "$ak" >/dev/null 2>&1 || true
    mc admin user add local "$ak" "$sk" || exit 1
    mc admin policy attach local "$policy" --user "$ak" || exit 1
  ' _ "$policy" < <(printf '%s\n%s\n' "$ak" "$sk")
}

allowed_key(){
  local k="$1"
  [ "$k" = "$NORMAL_AK" ] && return 0
  [ "$k" = "$CONSOLE_AK" ] && return 0
  [ "$k" = "$ROOT_AK" ] && return 0
  return 1
}

save_cred_pair(){
  local dir="$1" base="$2" ak="$3" sk="$4"
  mkdir -p "$dir"
  printf '%s' "$ak" > "$dir/$base.user"
  printf '%s' "$sk" > "$dir/$base.pass"
  chmod 600 "$dir/$base.user" "$dir/$base.pass"
}

hr "X0 preflight"
for c in python3 curl podman awk sed grep systemctl find; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
[ -t 0 ] || [ -e /dev/tty ] || halt "this script requires an interactive TTY for manual credential entry"
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$QUADLET" ] || halt "missing quadlet: $QUADLET"

detect_env_files
[ "${#ENV_FILES[@]}" -gt 0 ] || halt "could not detect MinIO EnvironmentFile containing MINIO_ROOT_USER/MINIO_ROOT_PASSWORD"

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
  say "  4) backup env files, update MINIO_ROOT_*"
  say "  5) restart MinIO and verify API health"
  say "  6) create/replace normal + consoleAdmin IAM users"
  say "  7) delete all other IAM users"
  say "  8) remove previous local minio-user.* secret files"
  say "  9) save new credential files and optionally purge old backups"
  say "[RESULT] MX12 CHECK - nothing written."
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

hr "X4 restart MinIO and verify API"
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user reset-failed "$SERVICE" >/dev/null 2>&1 || true
if ! systemctl --user restart "$SERVICE"; then
  rollback_env
  ledger "FAIL" "MX12 systemctl restart $SERVICE failed"
  halt "MinIO service restart failed; env rolled back"
fi

if ! wait_minio_api 90; then
  say "--- MinIO logs tail 80 ---"
  podman logs --tail 80 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true
  rollback_env
  ledger "FAIL" "MX12 MinIO API not healthy after root rotation"
  halt "MinIO API not healthy; env rolled back"
fi

if ! mc_alias_local; then
  rollback_env
  ledger "FAIL" "MX12 mc alias set failed after root rotation"
  halt "mc alias set failed; env rolled back"
fi
say "mc alias local configured inside MinIO container"

hr "X5 create/replace requested IAM users"
if ! create_or_replace_user "$NORMAL_AK" "$NORMAL_SK" "readwrite"; then
  remove_user "$NORMAL_AK" || true
  remove_user "$CONSOLE_AK" || true
  rollback_env
  ledger "FAIL" "MX12 failed to create normal user"
  halt "failed to create normal user; env rolled back"
fi
say "normal user created/updated: policy=readwrite"

if ! create_or_replace_user "$CONSOLE_AK" "$CONSOLE_SK" "consoleAdmin"; then
  remove_user "$NORMAL_AK" || true
  remove_user "$CONSOLE_AK" || true
  rollback_env
  ledger "FAIL" "MX12 failed to create console admin user"
  halt "failed to create console admin user; env rolled back"
fi
say "console admin user created/updated: policy=consoleAdmin"

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

UNWANTED=""
for ak in "${FINAL_USERS[@]}"; do
  if ! allowed_key "$ak"; then
    UNWANTED="$UNWANTED $ak"
  fi
done

if [ -n "$UNWANTED" ]; then
  say "[WARN] unwanted IAM users remain:$UNWANTED"
  ledger "PARTIAL" "MX12 root rotated and requested users created, but unwanted IAM users remain:$UNWANTED"
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

hr "X9 verify endpoints"
API_HEALTH="$(http_code "$API_URL/minio/health/live")"
CONSOLE_ROOT="$(http_code "http://127.0.0.1:9011/")"
CONSOLE_BROWSER="$(http_code "$CONSOLE_URL")"
say "API health 9010 = $API_HEALTH"
say "Console root 9011 = $CONSOLE_ROOT"
say "Console browser 9011 = $CONSOLE_BROWSER"

hr "X10 result"
say "[RESULT] MX12 COMPLETE - MinIO credentials manually rotated."
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

ledger "PASS" "MX12: manual root/normal/console-admin rotation complete; API=$API_HEALTH; final_users=${#FINAL_USERS[@]}"

hr "X11 purge old backups containing previous root secret?"
say "Backup files may contain the OLD root password."
printf 'Type YES to securely remove backups now. Anything else keeps them for rollback: ' > /dev/tty
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
  say "backups purged; rollback no longer available"
else
  say "backups kept:"
  for b in "${BAKS[@]}"; do
    say "  $b"
  done
fi

exit 0
