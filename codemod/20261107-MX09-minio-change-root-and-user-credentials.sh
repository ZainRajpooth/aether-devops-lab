#!/usr/bin/env bash
# 20261107-MX09 — change MinIO root credentials and normal user credentials.
#
# Scope:
#   - Root access key/secret key are stored in:
#       ~/DevOps/aether/secrets/aether.env
#     as:
#       MINIO_ROOT_USER
#       MINIO_ROOT_PASSWORD
#
#   - MinIO normal users are access-key based.
#     Renaming a user means creating a new access key and optionally deleting the old one.
#
# Safety:
#   - Backs up canonical env before root change.
#   - Restarts only MinIO.
#   - Verifies new root credentials with mc.
#   - Rolls back root env if verification fails.
#   - Masks secrets in output.
#   - Saves new normal-user credentials under ~/DevOps/aether/secrets with mode 600.
#
# No public exposure. No image pull. No data deletion.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
BAK="$SEC/backups"
IDX="$CD/INDEX.md"

CANON_ENV="$SEC/aether.env"
MINIO_ENV="$SEC/minio.env"
CONTAINER="minio"

API_URL="http://127.0.0.1:9000"
CONSOLE_URL="http://127.0.0.1:9011/browser"

TOKEN="mx09-minio-change-root-and-user-credentials-v1"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT_ENV_BAK="$BAK/aether.env.pre-mx09.$STAMP.bak"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
SECRETS_LIST="$TMP/secrets.txt"
: > "$SECRETS_LIST"

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

add_secret(){
  local v="${1:-}"
  [ -n "$v" ] || return 0
  printf '%s\n' "$v" >> "$SECRETS_LIST"
}

mask_stream(){
  python3 - "$SECRETS_LIST" <<'PY'
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
  mask_stream < "$1" 2>/dev/null || true
}

probe(){
  local c
  c="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true)"
  printf '%s\n' "${c:-000}"
}

get_env(){
  local key="$1"
  sed -n "s/^${key}=//p" "$CANON_ENV" 2>/dev/null |
    head -n1 |
    tr -d '\r' |
    sed -e 's/^"//' -e 's/"$//'
}

upsert_env_file(){
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
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

fd, tmp = tempfile.mkstemp(prefix=".mx09-env-", dir=os.path.dirname(path) or ".")
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
PY
}

validate_access_key(){
  local k="${1:-}"
  [ "${#k}" -ge 3 ] && [ "${#k}" -le 128 ] || return 1
  printf '%s' "$k" | grep -Eq '^[A-Za-z0-9._-]+$' || return 1
  return 0
}

validate_secret_key(){
  local k="${1:-}"
  [ "${#k}" -ge 8 ] && [ "${#k}" -le 128 ] || return 1
  return 0
}

wait_running(){
  local i st
  for i in $(seq 1 30); do
    st="$(podman inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
    if [ "$st" = running ]; then
      say "minio container running after ${i} checks"
      return 0
    fi
    sleep 2
  done
  return 1
}

restart_minio(){
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed minio.service >/dev/null 2>&1 || true
  systemctl --user restart minio.service >/dev/null 2>&1 || return 1
  wait_running
}

mc_exec(){
  local out="$TMP/mc.out"
  : > "$out"

  set +e
  podman exec -i \
    -e MC_CONFIG_DIR=/tmp/mx09-mc-config \
    "$CONTAINER" mc "$@" > "$out" 2>&1
  local rc=$?
  set -e

  mask_file "$out" | sed 's/^/    /' || true
  return "$rc"
}

sync_root_user_file(){
  local new_user="$1"
  say "syncing Bitnami .root_user file, if present"
  podman exec -i "$CONTAINER" sh -s -- "$new_user" <<'SH' 2>&1 | sed 's/^/    /' || true
new_user="$1"
for d in /data /bitnami/minio/data; do
  f="$d/.root_user"
  if [ -f "$f" ]; then
    if printf '%s\n' "$new_user" > "$f" 2>/dev/null; then
      echo "updated $f"
    else
      echo "WARN could not update $f"
    fi
  fi
done
SH
}

verify_root_credentials(){
  local user="$1"
  local pass="$2"

  add_secret "$pass"

  mc_exec alias set verify "$API_URL" "$user" "$pass" || return 1
  mc_exec admin info verify || return 1
  return 0
}

rollback_root_env(){
  if [ -f "$ROOT_ENV_BAK" ]; then
    say "rolling back canonical env from: $ROOT_ENV_BAK"
    cp -p "$ROOT_ENV_BAK" "$CANON_ENV"
    chmod 600 "$CANON_ENV"
    sync_root_user_file "${OLD_ROOT_USER:-}"
    restart_minio || say "WARN rollback restart failed; inspect minio.service"
  else
    say "WARN no root env backup found: $ROOT_ENV_BAK"
  fi
}

attach_policy(){
  local policy="$1"
  local user="$2"

  if mc_exec admin policy attach local "$policy" --user "$user"; then
    return 0
  fi

  say "policy attach failed; trying legacy policy set"
  if mc_exec admin policy set local "$policy" "$user"; then
    return 0
  fi

  return 1
}

upsert_minio_user(){
  local user="$1"
  local pass="$2"

  add_secret "$pass"

  if mc_exec admin user add local "$user" "$pass"; then
    return 0
  fi

  say "user add did not succeed directly; checking whether user exists"
  if mc_exec admin user info local "$user"; then
    say "user exists; resetting via remove + add"
    mc_exec admin user rm local "$user" || return 1
    mc_exec admin user add local "$user" "$pass" || return 1
    return 0
  fi

  return 1
}

save_user_credentials(){
  local user="$1"
  local pass="$2"
  local safe

  safe="$(printf '%s' "$user" | tr -c 'A-Za-z0-9._-' '-')"
  [ -n "$safe" ] || halt "unsafe user name for file storage"

  local uf="$SEC/minio-user.${safe}.user"
  local pf="$SEC/minio-user.${safe}.pass"

  printf '%s\n' "$user" > "$uf"
  chmod 600 "$uf"

  printf '%s' "$pass" > "$pf"
  chmod 600 "$pf"

  say "saved user access key file: $uf"
  say "saved user secret key file: $pf"
}

hr "X0 preflight"
for c in python3 curl podman awk sed grep systemctl journalctl xclip; do
  if ! command -v "$c" >/dev/null 2>&1; then
    if [ "$c" = xclip ]; then
      say "WARN optional command missing: xclip"
    else
      halt "missing command: $c"
    fi
  fi
done

podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$CANON_ENV" ] || halt "missing canonical env: $CANON_ENV"
[ -f "$MINIO_ENV" ] || say "WARN missing MinIO-specific env: $MINIO_ENV"

ROOT_USER="$(get_env MINIO_ROOT_USER)"
ROOT_PASS="$(get_env MINIO_ROOT_PASSWORD)"
add_secret "$ROOT_PASS"

[ -n "$ROOT_USER" ] || halt "MINIO_ROOT_USER not found in $CANON_ENV"
[ -n "$ROOT_PASS" ] || halt "MINIO_ROOT_PASSWORD not found in $CANON_ENV"

say "canonical env: $CANON_ENV"
say "MinIO env:     $MINIO_ENV"
say "current root access key: $ROOT_USER"
say "current root secret key: present"
say "Console: $CONSOLE_URL"

hr "X1 current MinIO health"
API_HEALTH="$(probe "$API_URL/minio/health/live")"
CONSOLE_HEALTH="$(probe "$CONSOLE_URL")"
say "API health inside-container URL $API_URL = $API_HEALTH"
say "Console host URL $CONSOLE_URL = $CONSOLE_HEALTH"

if [ "$API_HEALTH" != 200 ]; then
  say "WARN API health from host-side container URL is not 200; continuing because mc uses container-local URL"
fi

hr "X2 change MinIO root credentials?"
printf 'Change MinIO root access key and/or secret key? [y/N]: ' > /dev/tty
read -r CHANGE_ROOT < /dev/tty

CHANGE_ROOT_LC="$(printf '%s' "${CHANGE_ROOT:-N}" | tr '[:upper:]' '[:lower:]')"
if [ "$CHANGE_ROOT_LC" = y ] || [ "$CHANGE_ROOT_LC" = yes ]; then
  OLD_ROOT_USER="$ROOT_USER"
  OLD_ROOT_PASS="$ROOT_PASS"

  printf 'New root access key [%s]: ' "$ROOT_USER" > /dev/tty
  read -r NEW_ROOT_USER < /dev/tty
  NEW_ROOT_USER="${NEW_ROOT_USER:-$ROOT_USER}"

  validate_access_key "$NEW_ROOT_USER" || halt "invalid root access key"

  printf 'New root secret key: ' > /dev/tty
  read -rs NEW_ROOT_PASS < /dev/tty
  printf '\nRepeat new root secret key: ' > /dev/tty
  read -rs NEW_ROOT_PASS2 < /dev/tty
  printf '\n' > /dev/tty

  [ -n "$NEW_ROOT_PASS" ] || halt "empty root secret key"
  [ "$NEW_ROOT_PASS" = "$NEW_ROOT_PASS2" ] || halt "root secret keys do not match"
  validate_secret_key "$NEW_ROOT_PASS" || halt "root secret key must be 8-128 characters"

  add_secret "$NEW_ROOT_PASS"

  cp -p "$CANON_ENV" "$ROOT_ENV_BAK"
  chmod 600 "$ROOT_ENV_BAK"
  say "backed up canonical env: $ROOT_ENV_BAK"

  say "updating MINIO_ROOT_USER/MINIO_ROOT_PASSWORD in canonical env"
  upsert_env_file "$CANON_ENV" \
    "MINIO_ROOT_USER=$NEW_ROOT_USER" \
    "MINIO_ROOT_PASSWORD=$NEW_ROOT_PASS"
  chmod 600 "$CANON_ENV"

  sync_root_user_file "$NEW_ROOT_USER"

  say "restarting MinIO"
  if ! restart_minio; then
    say "--- minio logs tail 120 ---"
    podman logs --tail 120 "$CONTAINER" > "$TMP/logs.out" 2>&1 || true
    mask_file "$TMP/logs.out" | sed 's/^/    /' || true

    say "--- journalctl minio.service tail 120 ---"
    journalctl --user -u minio.service -n 120 --no-pager > "$TMP/journal.out" 2>&1 || true
    mask_file "$TMP/journal.out" | sed 's/^/    /' || true

    rollback_root_env
    ledger "FAIL" "MX09 root change failed: MinIO did not restart"
    halt "MinIO did not restart after root credential change; rolled back"
  fi

  say "waiting 6s for MinIO initialization"
  sleep 6

  ROOT_USER="$NEW_ROOT_USER"
  ROOT_PASS="$NEW_ROOT_PASS"

  say "verifying new root credentials"
  if ! verify_root_credentials "$ROOT_USER" "$ROOT_PASS"; then
    say "new root credentials failed verification"
    say "--- minio logs tail 120 ---"
    podman logs --tail 120 "$CONTAINER" > "$TMP/logs.out" 2>&1 || true
    mask_file "$TMP/logs.out" | sed 's/^/    /' || true

    rollback_root_env

    say "verifying rolled-back old root credentials"
    if verify_root_credentials "$OLD_ROOT_USER" "$OLD_ROOT_PASS"; then
      ledger "FAIL" "MX09 root change failed verification; rollback succeeded"
      halt "root credential change failed; old credentials restored"
    else
      ledger "FAIL" "MX09 root change failed and rollback verification failed"
      halt "root credential change failed and rollback verification failed; inspect MinIO manually"
    fi
  fi

  say "[OK] MinIO root credentials changed and verified"
  say "new root access key: $ROOT_USER"
  say "new root secret key: stored in $CANON_ENV"
else
  say "skipping root credential change"
fi

hr "X3 set mc alias with current root credentials"
ROOT_USER="$(get_env MINIO_ROOT_USER)"
ROOT_PASS="$(get_env MINIO_ROOT_PASSWORD)"
add_secret "$ROOT_PASS"

[ -n "$ROOT_USER" ] || halt "MINIO_ROOT_USER missing after root phase"
[ -n "$ROOT_PASS" ] || halt "MINIO_ROOT_PASSWORD missing after root phase"

if ! mc_exec alias set local "$API_URL" "$ROOT_USER" "$ROOT_PASS"; then
  ledger "FAIL" "MX09 could not set mc alias with current root credentials"
  halt "could not configure mc alias"
fi

hr "X4 current MinIO users"
mc_exec admin user list local || say "WARN could not list users"

hr "X5 change MinIO normal user credentials?"
printf 'Change/create MinIO normal user? [y/N]: ' > /dev/tty
read -r CHANGE_USER < /dev/tty

CHANGE_USER_LC="$(printf '%s' "${CHANGE_USER:-N}" | tr '[:upper:]' '[:lower:]')"
if [ "$CHANGE_USER_LC" = y ] || [ "$CHANGE_USER_LC" = yes ]; then
  printf 'Existing user/access key to change [adminX]: ' > /dev/tty
  read -r OLD_USER < /dev/tty
  OLD_USER="${OLD_USER:-adminX}"

  validate_access_key "$OLD_USER" || halt "invalid existing user/access key"

  printf 'New user/access key [%s]: ' "$OLD_USER" > /dev/tty
  read -r NEW_USER < /dev/tty
  NEW_USER="${NEW_USER:-$OLD_USER}"

  validate_access_key "$NEW_USER" || halt "invalid new user/access key"

  if [ "$NEW_USER" = "$ROOT_USER" ]; then
    halt "refusing to use root access key as normal user access key"
  fi

  printf 'New secret key/password for %s: ' "$NEW_USER" > /dev/tty
  read -rs NEW_PASS < /dev/tty
  printf '\nRepeat new secret key/password: ' > /dev/tty
  read -rs NEW_PASS2 < /dev/tty
  printf '\n' > /dev/tty

  [ -n "$NEW_PASS" ] || halt "empty user secret key"
  [ "$NEW_PASS" = "$NEW_PASS2" ] || halt "user secret keys do not match"
  validate_secret_key "$NEW_PASS" || halt "user secret key must be 8-128 characters"

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

  say "old user/access key: $OLD_USER"
  say "new user/access key: $NEW_USER"
  say "policy: $POLICY"

  if [ "$NEW_USER" = "$OLD_USER" ]; then
    say "same access key selected; resetting password/user secret key"

    if ! mc_exec admin user info local "$OLD_USER"; then
      ledger "FAIL" "MX09 same-user reset failed: user does not exist: $OLD_USER"
      halt "existing user does not exist: $OLD_USER"
    fi

    printf 'Confirm reset password for %s? This may briefly invalidate sessions. [y/N]: ' "$OLD_USER" > /dev/tty
    read -r CONFIRM_RESET < /dev/tty
    CONFIRM_RESET_LC="$(printf '%s' "${CONFIRM_RESET:-N}" | tr '[:upper:]' '[:lower:]')"
    [ "$CONFIRM_RESET_LC" = y ] || [ "$CONFIRM_RESET_LC" = yes ] || halt "reset cancelled"

    if ! upsert_minio_user "$NEW_USER" "$NEW_PASS"; then
      ledger "FAIL" "MX09 same-user password reset failed: $NEW_USER"
      halt "could not reset MinIO user password"
    fi

    if ! attach_policy "$POLICY" "$NEW_USER"; then
      say "WARN user password reset succeeded, but policy attach failed"
    fi

    if ! mc_exec admin user info local "$NEW_USER"; then
      ledger "PARTIAL" "MX09 same-user reset succeeded but verification failed: $NEW_USER"
      halt "user verification failed after reset"
    fi

    save_user_credentials "$NEW_USER" "$NEW_PASS"
    say "[OK] MinIO user password reset: $NEW_USER"
  else
    say "different access key selected; creating new user"

    if mc_exec admin user info local "$NEW_USER"; then
      ledger "FAIL" "MX09 new user already exists: $NEW_USER"
      halt "new user/access key already exists: $NEW_USER"
    fi

    if ! mc_exec admin user info local "$OLD_USER"; then
      say "WARN old user does not exist or could not be read: $OLD_USER"
    fi

    if ! upsert_minio_user "$NEW_USER" "$NEW_PASS"; then
      ledger "FAIL" "MX09 new user creation failed: $NEW_USER"
      halt "could not create new MinIO user"
    fi

    if ! attach_policy "$POLICY" "$NEW_USER"; then
      say "WARN new user created, but policy attach failed"
    fi

    if ! mc_exec admin user info local "$NEW_USER"; then
      ledger "PARTIAL" "MX09 new user created but verification failed: $NEW_USER"
      halt "new user verification failed"
    fi

    save_user_credentials "$NEW_USER" "$NEW_PASS"
    say "[OK] New MinIO user created: $NEW_USER"

    printf 'Delete old user/access key %s? [y/N]: ' "$OLD_USER" > /dev/tty
    read -r DELETE_OLD < /dev/tty
    DELETE_OLD_LC="$(printf '%s' "${DELETE_OLD:-N}" | tr '[:upper:]' '[:lower:]')"

    if [ "$DELETE_OLD_LC" = y ] || [ "$DELETE_OLD_LC" = yes ]; then
      if [ "$OLD_USER" = "$ROOT_USER" ]; then
        say "REFUSING to delete old user because it equals current root access key"
      elif [ "$OLD_USER" = "$NEW_USER" ]; then
        say "old and new user are same; no deletion needed"
      else
        if mc_exec admin user rm local "$OLD_USER"; then
          say "[OK] deleted old user/access key: $OLD_USER"

          old_safe="$(printf '%s' "$OLD_USER" | tr -c 'A-Za-z0-9._-' '-')"
          old_uf="$SEC/minio-user.${old_safe}.user"
          old_pf="$SEC/minio-user.${old_safe}.pass"

          if [ -f "$old_uf" ] || [ -f "$old_pf" ]; then
            mkdir -p "$BAK/retired-minio-users.$STAMP"
            [ -f "$old_uf" ] && mv "$old_uf" "$BAK/retired-minio-users.$STAMP/" || true
            [ -f "$old_pf" ] && mv "$old_pf" "$BAK/retired-minio-users.$STAMP/" || true
            say "moved old local credential files to: $BAK/retired-minio-users.$STAMP"
          fi
        else
          say "WARN could not delete old user: $OLD_USER"
        fi
      fi
    else
      say "keeping old user/access key: $OLD_USER"
    fi
  fi
else
  say "skipping normal user change"
fi

hr "X6 final verification"
API_HEALTH="$(probe "http://127.0.0.1:9010/minio/health/live")"
CONSOLE_HEALTH="$(probe "$CONSOLE_URL")"

say "API health 9010      = $API_HEALTH"
say "Console browser 9011 = $CONSOLE_HEALTH"

say ""
say "current root access key: $ROOT_USER"
say "current root secret key: stored in $CANON_ENV"

if [ -n "${NEW_USER:-}" ]; then
  new_safe="$(printf '%s' "$NEW_USER" | tr -c 'A-Za-z0-9._-' '-')"
  say "latest normal user access key: $NEW_USER"
  say "normal user secret key file:   $SEC/minio-user.${new_safe}.pass"
fi

hr "X7 references to old root access key"
if [ -n "${OLD_ROOT_USER:-}" ] && [ "${OLD_ROOT_USER:-}" != "$ROOT_USER" ]; then
  say "checking configs that may still reference old root access key: $OLD_ROOT_USER"
  grep -RIl "$OLD_ROOT_USER" \
    "$SEC" \
    "$HOME_/.config/containers/systemd" \
    "$HOME_/.config/systemd/user" \
    2>/dev/null |
    sed 's/^/    /' || say "    none"
else
  say "root access key unchanged; skipping reference scan"
fi

hr "X8 RESULT"
say "[RESULT] MX09 COMPLETE"
say ""
say "MinIO endpoints:"
say "  S3 API:     http://127.0.0.1:9010"
say "  Console UI: http://127.0.0.1:9011/browser"
say ""
say "Root credentials:"
say "  file: $CANON_ENV"
say "  keys: MINIO_ROOT_USER / MINIO_ROOT_PASSWORD"
say ""
say "Normal user credentials:"
say "  files: $SEC/minio-user.<access-key>.user"
say "         $SEC/minio-user.<access-key>.pass"
say ""
say "Important:"
say "  If you changed the root access key/secret key, update any apps that use MinIO directly:"
say "    n8n"
say "    Woodpecker plugins"
say "    backup scripts"
say "    restic/S3 clients"
say "    Grafana/Weaviate/LiteLLM configs if they point to MinIO"
say ""
say "To copy a saved user password:"
say "  xclip -selection clipboard < '$SEC/minio-user.<access-key>.pass'"

ledger "PASS" "MX09: MinIO root/user credential change workflow completed; root verified; user phase completed or skipped."
exit 0
