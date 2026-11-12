#!/usr/bin/env bash
# 20261107-MX17 — MinIO Console canary/prove/patch.
#
# Purpose:
#   Determine whether the currently-installed Bitnami MinIO image can start embedded Console.
#
# Strategy:
#   1) backup quadlet/env
#   2) inspect Bitnami scripts and current state
#   3) canary A: current image, default entrypoint, minimal env
#   4) canary B: current image, direct minio binary, explicit server/console args
#   5) if canary A passes: enforce canonical env and restart
#   6) if canary B passes but A fails: patch quadlet to direct entrypoint/command and restart
#   7) if both fail: stop; image lacks functional embedded Console
#
# No downloads by default.
# Secrets masked. Rollback on failed live restart.
set -uo pipefail
umask 077

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="mx17-minio-console-canary-prove-or-patch-v1"
CONTAINER="${MINIO_CONTAINER:-minio}"
SERVICE="${MINIO_SERVICE:-minio.service}"
QUADLET="$HOME_/.config/containers/systemd/minio.container"

API_HOST_PORT=9010
CONSOLE_HOST_PORT=9011
API_URL="http://127.0.0.1:${API_HOST_PORT}"
CONSOLE_URL="http://127.0.0.1:${CONSOLE_HOST_PORT}"

ROOT_USER_FILE="$SEC/minio-root.user"
ROOT_PASS_FILE="$SEC/minio-root.pass"
NORMAL_USER_FILE="$SEC/minio-users/minio-normal.user"
NORMAL_PASS_FILE="$SEC/minio-users/minio-normal.pass"
CONSOLE_USER_FILE="$SEC/minio-users/minio-console-admin.user"
CONSOLE_PASS_FILE="$SEC/minio-users/minio-console-admin.pass"

MODE="${1:-run}"
STAMP="$(date +%Y%m%d-%H%M%S)"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
: > "$TMP/secrets.txt"

BAKS=()
ORIGS=()
ENV_FILES=()
CANARIES=()

cleanup(){
  local c
  for c in ${CANARIES[@]+"${CANARIES[@]}"}; do
    podman rm -f "$c" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

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

backup_file(){
  local f="$1"
  local b="${f}.pre-mx17.${STAMP}.bak"

  [ -f "$f" ] || return 0
  cp -p "$f" "$b" || halt "backup failed: $f"
  chmod 600 "$b" || true

  BAKS+=("$b")
  ORIGS+=("$f")
  say "backup: $b"
}

rollback_files(){
  say "rolling back MX17 backups"

  local i
  if [ "${#BAKS[@]}" -gt 0 ]; then
    for i in "${!BAKS[@]}"; do
      if [ -f "${BAKS[$i]}" ]; then
        cp -p "${BAKS[$i]}" "${ORIGS[$i]}" || say "WARN rollback copy failed: ${BAKS[$i]} -> ${ORIGS[$i]}"
      fi
    done
  fi

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE" >/dev/null 2>&1 || true
  systemctl --user restart "$SERVICE" >/dev/null 2>&1 || true
}

detect_env_files(){
  ENV_FILES=()

  _add(){
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

    if grep -qE '^[[:space:]]*MINIO_' "$f" 2>/dev/null \
      || [ "$f" = "$HOME_/.config/aether/secrets.env" ] \
      || [ "$f" = "$SEC/aether.env" ] \
      || [ "$f" = "$SEC/minio.env" ]; then
      ENV_FILES+=("$f")
    fi
  }

  if [ -f "$QUADLET" ]; then
    while IFS= read -r f; do
      _add "$f"
    done < <(awk '/^[[:space:]]*EnvironmentFile[[:space:]]*=/{sub(/^[^=]+=/,""); gsub(/[[:space:]]/,"",$0); print}' "$QUADLET" 2>/dev/null || true)
  fi

  _add "$HOME_/.config/aether/secrets.env"
  _add "$SEC/aether.env"
  _add "$SEC/minio.env"
}

collect_secrets_from_files(){
  local f
  for f in "$ROOT_PASS_FILE" "$NORMAL_PASS_FILE" "$CONSOLE_PASS_FILE"; do
    [ -s "$f" ] || continue
    add_secret "$(tr -d '\n\r' < "$f")"
  done

  for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do
    [ -f "$f" ] || continue
    python3 - "$f" >> "$TMP/secrets.txt" <<'PY'
import re, sys
path = sys.argv[1]
sens = re.compile(r"(PASSWORD|SECRET|KEY|TOKEN|AUTH|CREDENTIAL|PRIVATE|ENCRYPTION|MASTER)", re.I)
try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if sens.search(k) and v:
                print(v)
except Exception:
    pass
PY
  done
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

fd, tmp = tempfile.mkstemp(prefix=".mx17-env-", dir=os.path.dirname(path) or ".")
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

delete_env_key(){
  local path="$1"
  local key="$2"

  python3 - "$path" "$key" <<'PYDELETE'
import os, sys, tempfile

path, key = sys.argv[1], sys.argv[2]

if not os.path.exists(path):
    sys.exit(0)

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

out = []
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in stripped:
        k = stripped.split("=", 1)[0].strip()
        if k == key:
            continue
    out.append(line)

fd, tmp = tempfile.mkstemp(prefix=".mx17-del-", dir=os.path.dirname(path) or ".")
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
PYDELETE
}

patch_quadlet_direct(){
  local bin_path="$1"

  python3 - "$QUADLET" "$bin_path" <<'PYQUADLET'
import os, sys, tempfile

path, bin_path = sys.argv[1], sys.argv[2]

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

start = None
end = len(lines)

for i, line in enumerate(lines):
    s = line.strip()
    if s == "[Container]":
        start = i
    elif start is not None and i > start and s.startswith("[") and s.endswith("]"):
        end = i
        break

if start is None:
    raise SystemExit("no [Container] section found")

body = lines[start + 1:end]
new_body = []

seen_entrypoint = False
seen_exec = False

for line in body:
    s = line.strip()
    if s.startswith("Entrypoint="):
        if not seen_entrypoint:
            new_body.append(f"Entrypoint={bin_path}\n")
            seen_entrypoint = True
        continue
    if s.startswith("Exec="):
        if not seen_exec:
            new_body.append("Exec=server --address :9000 --console-address :9001 /data\n")
            seen_exec = True
        continue
    new_body.append(line)

if not seen_entrypoint:
    new_body.insert(0, f"Entrypoint={bin_path}\n")
if not seen_exec:
    new_body.insert(1, "Exec=server --address :9000 --console-address :9001 /data\n")

out = lines[:start + 1] + new_body + lines[end:]

fd, tmp = tempfile.mkstemp(prefix=".mx17-quadlet-", dir=os.path.dirname(path) or ".")
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
PYQUADLET
}

cat > "$TMP/listener.sh" <<'SH'
#!/bin/sh
awk -v hex="$1" '
NR>1 && $4=="0A" && $2 ~ (":" hex "$") {
  found=1
}
END {
  exit !found
}
' /proc/net/tcp /proc/net/tcp6 2>/dev/null
SH

internal_listener(){
  local cname="$1"
  local hex="$2"
  podman exec -i "$cname" sh -s -- "$hex" < "$TMP/listener.sh" >/dev/null 2>&1
}

wait_internal_listener(){
  local cname="$1"
  local hex="$2"
  local attempts="${3:-30}"
  local i

  for i in $(seq 1 "$attempts"); do
    if internal_listener "$cname" "$hex"; then
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_container_running(){
  local cname="$1"
  local attempts="${2:-30}"
  local i st

  for i in $(seq 1 "$attempts"); do
    st="$(podman inspect "$cname" --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
    if [ "$st" = running ]; then
      return 0
    fi
    sleep 2
  done

  return 1
}

dump_live_logs(){
  say "--- MinIO logs tail 120 ---"
  podman logs --tail 120 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- journalctl minio.service tail 100 ---"
  journalctl --user -u "$SERVICE" -n 100 --no-pager 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- podman port minio ---"
  podman port "$CONTAINER" 2>/dev/null | sed 's/^/    /' || true

  say "--- ss listeners ---"
  ss -ltnp 2>/dev/null | awk 'NR==1 || /:(9000|9001|9010|9011)([[:space:]]|$)/' | sed 's/^/    /' || true
}

dump_canary_logs(){
  local name="$1"
  local label="$2"

  say "--- canary $label logs tail 120 ---"
  podman logs --tail 120 "$name" 2>&1 | mask_stream | sed 's/^/    /' || true
}

canary_console_check(){
  local name="$1"
  local label="$2"
  local attempts="${3:-25}"

  if ! wait_container_running "$name" 20; then
    say "CANARY[$label] container did not reach running state"
    dump_canary_logs "$name" "$label"
    return 1
  fi

  if wait_internal_listener "$name" 2329 "$attempts"; then
    say "CANARY[$label] internal Console listener 9001 = yes"
    dump_canary_logs "$name" "$label"
    return 0
  fi

  say "CANARY[$label] internal Console listener 9001 = no"
  dump_canary_logs "$name" "$label"
  return 1
}

mc_root_ok(){
  local ak="$1"
  local sk="$2"

  podman exec -i "$CONTAINER" sh -c '
    set -eu
    IFS= read -r ak
    IFS= read -r sk

    mc alias set local http://127.0.0.1:9000 "$ak" "$sk" >/dev/null
    mc admin info local >/dev/null 2>&1 || mc admin user ls local >/dev/null 2>&1
  ' < <(printf '%s\n%s\n' "$ak" "$sk") >/dev/null 2>&1
}

user_exists(){
  local ak="$1"

  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || exit 1
    mc admin user info local "$1" >/dev/null 2>&1
  ' _ "$ak" >/dev/null 2>&1
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

  for attempt in 1 2 3 4 5; do
    say "creating/resetting user access_key=$ak policy=$policy attempt=$attempt"

    if create_or_replace_user_once "$ak" "$sk" "$policy"; then
      say "OK user ready: $ak"
      return 0
    fi

    say "WARN user operation failed; retrying"
    dump_live_logs
    sleep 5
  done

  return 1
}

show_user_info(){
  local ak="$1"

  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || exit 0
    mc admin user info local "$1" 2>&1 || true
  ' _ "$ak" 2>&1 | mask_stream | sed 's/^/    /' || true
}

verify_live_minio(){
  local label="$1"
  local api i9 root br

  api="$(http_code "$API_URL/minio/health/live")"

  if internal_listener "$CONTAINER" 2329; then
    i9=yes
  else
    i9=no
  fi

  root="$(http_code "$CONSOLE_URL/")"
  br="$(http_code "$CONSOLE_URL/browser")"

  say "VERIFY[$label] api9010=$api internal9001=$i9 console9011_root=$root console9011_browser=$br"

  if [ "$api" != 200 ]; then
    return 1
  fi

  if [ "$i9" != yes ]; then
    return 1
  fi

  if ! acceptable_http "$root" && ! acceptable_http "$br"; then
    return 1
  fi

  return 0
}

hr "X0 preflight"

for c in python3 curl podman awk sed grep systemctl find ss; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done

podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$QUADLET" ] || halt "missing quadlet: $QUADLET"

for f in "$ROOT_USER_FILE" "$ROOT_PASS_FILE" "$NORMAL_USER_FILE" "$NORMAL_PASS_FILE" "$CONSOLE_USER_FILE" "$CONSOLE_PASS_FILE"; do
  [ -s "$f" ] || halt "missing credential file: $f"
done

ROOT_AK="$(tr -d '\n\r' < "$ROOT_USER_FILE")"
ROOT_SK="$(tr -d '\n\r' < "$ROOT_PASS_FILE")"
NORMAL_AK="$(tr -d '\n\r' < "$NORMAL_USER_FILE")"
NORMAL_SK="$(tr -d '\n\r' < "$NORMAL_PASS_FILE")"
CONSOLE_AK="$(tr -d '\n\r' < "$CONSOLE_USER_FILE")"
CONSOLE_SK="$(tr -d '\n\r' < "$CONSOLE_PASS_FILE")"

[ -n "$ROOT_AK" ] && [ -n "$ROOT_SK" ] || halt "empty root credential files"
[ -n "$NORMAL_AK" ] && [ -n "$NORMAL_SK" ] || halt "empty normal credential files"
[ -n "$CONSOLE_AK" ] && [ -n "$CONSOLE_SK" ] || halt "empty console admin credential files"

detect_env_files
[ "${#ENV_FILES[@]}" -gt 0 ] || halt "could not detect MinIO env files"

collect_secrets_from_files

CURRENT_IMAGE="$(podman inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || echo unknown)"
MINIO_BIN="$(podman exec "$CONTAINER" sh -c 'command -v minio 2>/dev/null || echo /opt/bitnami/minio/bin/minio' 2>/dev/null || echo /opt/bitnami/minio/bin/minio)"

say "container=$CONTAINER"
say "service=$SERVICE"
say "image=$CURRENT_IMAGE"
say "minio_bin=$MINIO_BIN"
say "api=$API_URL"
say "console=$CONSOLE_URL"
say "root_access_key=$ROOT_AK"
say "normal_access_key=$NORMAL_AK"
say "console_admin_access_key=$CONSOLE_AK"
say "detected MinIO env files:"
for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do
  say "  $f"
done

if [ "$MODE" = check ]; then
  hr "X1 plan (check mode)"
  say "  1) backup quadlet/env"
  say "  2) inspect Bitnami scripts and current listener state"
  say "  3) canary A: current image default entrypoint, minimal env"
  say "  4) canary B: current image direct binary, explicit console args"
  say "  5) if A passes: enforce canonical env and restart"
  say "  6) if B passes but A fails: patch quadlet direct entrypoint/command and restart"
  say "  7) if both fail: declare embedded Console unavailable in this image"
  say ""
  say "Canonical env enforced:"
  say "  MINIO_ADDRESS=:9000"
  say "  MINIO_CONSOLE_ADDRESS=:9001"
  say "  MINIO_SERVER_URL=http://127.0.0.1:9010"
  say "  MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011"
  say "  MINIO_API_CORS_ALLOW_ORIGIN=http://127.0.0.1:9011,http://localhost:9011"
  say "[RESULT] MX17 CHECK - nothing written."
  exit 0
fi

hr "X1 backups"
backup_file "$QUADLET"
for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do
  backup_file "$f"
done

hr "X2 current state snapshot"
say "--- container command/entrypoint ---"
podman inspect "$CONTAINER" --format 'entrypoint={{json .Config.Entrypoint}}
cmd={{json .Config.Cmd}}' 2>/dev/null | mask_stream | sed 's/^/    /' || true

say "--- relevant env in container, masked ---"
podman inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
  grep -E '^MINIO_|^GF_|^WOODPECKER_|^GITEA_' |
  mask_stream |
  sed 's/^/    /' || true

say "--- internal listeners before canary ---"
podman exec "$CONTAINER" sh -c '
  echo "tcp4 hex listeners:"
  awk "NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[2]}" /proc/net/tcp 2>/dev/null | sort -u | tr "\n" " "
  echo
  echo "tcp6 hex listeners:"
  awk "NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[2]}" /proc/net/tcp6 2>/dev/null | sort -u | tr "\n" " "
  echo
' 2>&1 | mask_stream | sed 's/^/    /' || true

say "--- Bitnami run.sh, masked ---"
podman exec "$CONTAINER" sh -c 'sed -n "1,220p" /opt/bitnami/scripts/minio/run.sh 2>/dev/null || true' 2>&1 |
  mask_stream |
  sed 's/^/    /' || true

say "--- Bitnami entrypoint.sh, masked ---"
podman exec "$CONTAINER" sh -c 'sed -n "1,160p" /opt/bitnami/scripts/minio/entrypoint.sh 2>/dev/null || true' 2>&1 |
  mask_stream |
  sed 's/^/    /' || true

say "--- /certs metadata ---"
podman exec "$CONTAINER" sh -c 'ls -la /certs 2>/dev/null || true; find /certs -maxdepth 2 -printf "%y %u:%g %s %p\n" 2>/dev/null || true' 2>&1 |
  mask_stream |
  sed 's/^/    /' || true

say "--- /data and /bitnami/minio/data metadata ---"
podman exec "$CONTAINER" sh -c 'ls -ld /data /bitnami/minio/data 2>/dev/null || true; id 2>/dev/null || true' 2>&1 |
  mask_stream |
  sed 's/^/    /' || true

hr "X3 canary A: current image, default entrypoint, minimal env"

CAN_A="mx17-canA-$STAMP"
CANARIES+=("$CAN_A")

podman rm -f "$CAN_A" >/dev/null 2>&1 || true

podman run -d --rm \
  --name "$CAN_A" \
  --network none \
  --tmpfs /data:rw,size=64m \
  --tmpfs /bitnami/minio/data:rw,size=64m \
  -e "MINIO_ROOT_USER=$ROOT_AK" \
  -e "MINIO_ROOT_PASSWORD=$ROOT_SK" \
  -e "MINIO_ADDRESS=:9000" \
  -e "MINIO_CONSOLE_ADDRESS=:9001" \
  -e "MINIO_SERVER_URL=http://127.0.0.1:9010" \
  -e "MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011" \
  "$CURRENT_IMAGE" >/dev/null 2>"$TMP/canA.err" || {
    say "canary A failed to start"
    mask_file "$TMP/canA.err" | sed 's/^/    /' || true
  }

CAN_A_OK=no
if podman inspect "$CAN_A" >/dev/null 2>&1; then
  if canary_console_check "$CAN_A" "A-default-entrypoint" 25; then
    CAN_A_OK=yes
  fi
else
  say "canary A not inspectable"
fi

podman rm -f "$CAN_A" >/dev/null 2>&1 || true

say "CANARY_A_DEFAULT_ENTRYPOINT_CONSOLE=$CAN_A_OK"

hr "X4 canary B: current image, direct minio binary, explicit args"

CAN_B="mx17-canB-$STAMP"
CANARIES+=("$CAN_B")

podman rm -f "$CAN_B" >/dev/null 2>&1 || true

podman run -d --rm \
  --name "$CAN_B" \
  --network none \
  --tmpfs /data:rw,size=64m \
  -e "MINIO_ROOT_USER=$ROOT_AK" \
  -e "MINIO_ROOT_PASSWORD=$ROOT_SK" \
  --entrypoint "$MINIO_BIN" \
  "$CURRENT_IMAGE" \
  server --address :9000 --console-address :9001 /data \
  >/dev/null 2>"$TMP/canB.err" || {
    say "canary B failed to start"
    mask_file "$TMP/canB.err" | sed 's/^/    /' || true
  }

CAN_B_OK=no
if podman inspect "$CAN_B" >/dev/null 2>&1; then
  if canary_console_check "$CAN_B" "B-direct-binary" 25; then
    CAN_B_OK=yes
  fi
else
  say "canary B not inspectable"
fi

podman rm -f "$CAN_B" >/dev/null 2>&1 || true

say "CANARY_B_DIRECT_BINARY_CONSOLE=$CAN_B_OK"

hr "X5 decision"

if [ "$CAN_A_OK" != yes ] && [ "$CAN_B_OK" != yes ]; then
  say "[CONFIRMED] This local Bitnami MinIO image cannot start embedded Console."
  say "            Canary A failed and direct-binary canary B failed."
  say "            Therefore no env/quadlet tweak will fix the GUI on this image."
  say ""
  say "Your S3 API and credentials remain valid:"
  say "  S3 endpoint: $API_URL"
  say "  root:        $ROOT_AK"
  say "  normal:      $NORMAL_AK"
  say "  console adm: $CONSOLE_AK"
  say ""
  say "Immediate CLI-only verification:"
  say "  podman exec -it $CONTAINER sh"
  say "  mc alias set local http://127.0.0.1:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\""
  say "  mc admin user ls local"
  say ""
  say "To get a working GUI, next step is MX18: canary/switch to an official MinIO image from docker.io."
  say "MX17 does not download anything."
  ledger "IMAGE-CONSOLE-UNAVAILABLE" "MX17: local Bitnami image cannot start Console; canary A=$CAN_A_OK canary B=$CAN_B_OK; S3 API remains healthy."
  exit 0
fi

hr "X6 enforce canonical MinIO env"

for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do
  upsert_env_file "$f" \
    "MINIO_ROOT_USER=$ROOT_AK" \
    "MINIO_ROOT_PASSWORD=$ROOT_SK" \
    "MINIO_ADDRESS=:9000" \
    "MINIO_CONSOLE_ADDRESS=:9001" \
    "MINIO_SERVER_URL=http://127.0.0.1:9010" \
    "MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011" \
    "MINIO_API_CORS_ALLOW_ORIGIN=http://127.0.0.1:9011,http://localhost:9011"

  delete_env_key "$f" "MINIO_BROWSER"

  say "updated env file: $f"
  grep -E '^(MINIO_ADDRESS|MINIO_CONSOLE_ADDRESS|MINIO_SERVER_URL|MINIO_BROWSER_REDIRECT_URL|MINIO_API_CORS_ALLOW_ORIGIN|MINIO_ROOT_USER)=' "$f" 2>/dev/null |
    mask_stream |
    sed 's/^/    /' || true
done

if [ "$CAN_A_OK" != yes ] && [ "$CAN_B_OK" = yes ]; then
  hr "X7 patch quadlet to direct MinIO binary because default entrypoint failed"
  patch_quadlet_direct "$MINIO_BIN"
  say "patched quadlet:"
  grep -E '^(Entrypoint|Exec|Image|EnvironmentFile|Volume|PublishPort)=' "$QUADLET" 2>/dev/null |
    mask_stream |
    sed 's/^/    /' || true
else
  say "default-entrypoint canary passed; not changing Entrypoint/Exec"
fi

hr "X8 restart MinIO and verify"

systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user reset-failed "$SERVICE" >/dev/null 2>&1 || true

if ! systemctl --user restart "$SERVICE"; then
  dump_live_logs
  rollback_files
  ledger "FAIL" "MX17 systemctl restart failed"
  halt "MinIO service restart failed; rolled back"
fi

if ! wait_container_running "$CONTAINER" 60; then
  dump_live_logs
  rollback_files
  ledger "FAIL" "MX17 container did not become running"
  halt "MinIO container did not become running; rolled back"
fi

if ! wait_internal_listener "$CONTAINER" 2329 45; then
  say "internal Console listener 9001 absent after patch"
  dump_live_logs
  rollback_files
  ledger "FAIL" "MX17 internal Console listener 9001 absent after patch"
  halt "MinIO Console internal listener 9001 absent after patch; rolled back"
fi

API_READY=no
for i in $(seq 1 60); do
  c="$(http_code "$API_URL/minio/health/live" 3)"
  if [ "$c" = 200 ]; then
    API_READY=yes
    say "MinIO API ready: $API_URL/minio/health/live = 200"
    break
  fi
  sleep 2
done

if [ "$API_READY" != yes ]; then
  dump_live_logs
  rollback_files
  ledger "FAIL" "MX17 MinIO API not healthy after patch"
  halt "MinIO API not healthy after patch; rolled back"
fi

CONSOLE_READY=no
for i in $(seq 1 45); do
  c="$(http_code "$CONSOLE_URL/browser" 3)"
  if acceptable_http "$c"; then
    CONSOLE_READY=yes
    say "MinIO Console ready: $CONSOLE_URL/browser = $c"
    break
  fi
  sleep 2
done

if [ "$CONSOLE_READY" != yes ]; then
  dump_live_logs
  rollback_files
  ledger "FAIL" "MX17 MinIO Console host port 9011 not reachable after patch"
  halt "MinIO Console 9011 not reachable after patch; rolled back"
fi

say "[OK] MinIO API and Console are healthy after MX17 patch"

hr "X9 verify root and users"

if ! mc_root_ok "$ROOT_AK" "$ROOT_SK"; then
  dump_live_logs
  ledger "FAIL" "MX17 root credentials did not verify inside MinIO after patch"
  halt "root credentials did not verify after patch"
fi
say "root credentials verified using http://127.0.0.1:9000 inside container"

NORMAL_PRESENT=no
CONSOLE_PRESENT=no

user_exists "$NORMAL_AK" && NORMAL_PRESENT=yes
user_exists "$CONSOLE_AK" && CONSOLE_PRESENT=yes

say "normal user present=$NORMAL_PRESENT"
say "console admin user present=$CONSOLE_PRESENT"

if [ "$NORMAL_PRESENT" != yes ]; then
  if ! create_or_replace_user_retry "$NORMAL_AK" "$NORMAL_SK" "readwrite"; then
    dump_live_logs
    ledger "PARTIAL" "MX17 normal user creation failed after Console heal"
    halt "normal user creation failed"
  fi
fi

if [ "$CONSOLE_PRESENT" != yes ]; then
  if ! create_or_replace_user_retry "$CONSOLE_AK" "$CONSOLE_SK" "consoleAdmin"; then
    dump_live_logs
    ledger "PARTIAL" "MX17 console admin user creation failed after Console heal"
    halt "console admin user creation failed"
  fi
fi

if ! user_exists "$NORMAL_AK"; then
  dump_live_logs
  ledger "FAIL" "MX17 normal user not present after reset"
  halt "normal user not present after reset"
fi

if ! user_exists "$CONSOLE_AK"; then
  dump_live_logs
  ledger "FAIL" "MX17 console admin user not present after reset"
  halt "console admin user not present after reset"
fi

hr "X10 user info"
say "normal user info:"
show_user_info "$NORMAL_AK"

say "console admin user info:"
show_user_info "$CONSOLE_AK"

hr "X11 final probes"
API_HEALTH="$(http_code "$API_URL/minio/health/live")"
CONSOLE_BROWSER_127="$(http_code "$CONSOLE_URL/browser")"
CONSOLE_LOGIN_127="$(http_code "$CONSOLE_URL/login")"
CONSOLE_BROWSER_LOCALHOST="$(http_code "http://localhost:9011/browser")"
CONSOLE_LOGIN_LOCALHOST="$(http_code "http://localhost:9011/login")"

say "API health 127:9010 = $API_HEALTH"
say "Console browser 127:9011 = $CONSOLE_BROWSER_127"
say "Console login 127:9011 = $CONSOLE_LOGIN_127"
say "Console browser localhost:9011 = $CONSOLE_BROWSER_LOCALHOST"
say "Console login localhost:9011 = $CONSOLE_LOGIN_LOCALHOST"

hr "X12 result"

say "[RESULT] MX17 COMPLETE - MinIO Console heal finished."
say ""
say "Use this URL exactly:"
say "  $CONSOLE_URL/browser"
say ""
say "Do not mix localhost and 127.0.0.1. Canonical enforced values:"
say "  MINIO_SERVER_URL=http://127.0.0.1:9010"
say "  MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011"
say "  MINIO_API_CORS_ALLOW_ORIGIN=http://127.0.0.1:9011,http://localhost:9011"
say ""
say "Root emergency admin:"
say "  access key: $ROOT_AK"
say "  secret file: $ROOT_PASS_FILE"
say ""
say "Normal application user:"
say "  access key: $NORMAL_AK"
say "  secret file: $NORMAL_PASS_FILE"
say "  policy: readwrite"
say "  S3 endpoint: $API_URL"
say ""
say "Console admin user:"
say "  access key: $CONSOLE_AK"
say "  secret file: $CONSOLE_PASS_FILE"
say "  policy: consoleAdmin"
say "  Console: $CONSOLE_URL/browser"
say ""
say "Canary results:"
say "  default-entrypoint Console = $CAN_A_OK"
say "  direct-binary Console      = $CAN_B_OK"

GATE="PARTIAL"
if [ "$API_HEALTH" = 200 ] && acceptable_http "$CONSOLE_BROWSER_127"; then
  GATE="PASS"
fi

ledger "$GATE" "MX17: api=$API_HEALTH console127=$CONSOLE_BROWSER_127 canaryA=$CAN_A_OK canaryB=$CAN_B_OK users normal=$NORMAL_AK console=$CONSOLE_AK"

if [ "$GATE" != PASS ]; then
  say ""
  say "[NOTE] MinIO API/Console checks did not fully pass. Paste X8-X12."
fi

exit 0
