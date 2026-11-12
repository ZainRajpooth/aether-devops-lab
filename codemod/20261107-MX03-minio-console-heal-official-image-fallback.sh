#!/usr/bin/env bash
# 20261107-MX03 — MinIO Console heal.
#
# Confirmed by MX02:
#   - 9010 S3 API is alive.
#   - 9011 host mapping exists.
#   - container internal 9001 Console listener is absent.
#
# This script:
#   1) captures full masked diagnostics
#   2) backs up minio.container and secrets.env
#   3) forces MINIO_CONSOLE_ADDRESS=:9001
#   4) restarts and verifies
#   5) if still failing, canary-tests official MinIO image in an ephemeral container
#   6) if canary passes, switches minio.container to official image with rollback on failure
#   7) verifies internal 9001 + host 9011/browser
#
# No data deletion. No public exposure. Secrets masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

QUADLET="$HOME_/.config/containers/systemd/minio.container"
SECRETS_ENV="/home/dev/.config/aether/secrets.env"

TOKEN="mx03-minio-console-heal-official-image-fallback-v1"
CONTAINER="${MINIO_CONTAINER:-minio}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"

OFFICIAL_IMAGE="quay.io/minio/minio:latest"
BITNAMI_IMAGE="docker.io/bitnamilegacy/minio:latest"

API_HOST_PORT=9010
CONSOLE_HOST_PORT=9011
WP_API="http://127.0.0.1:${API_HOST_PORT}"
WP_CONSOLE="http://127.0.0.1:${CONSOLE_HOST_PORT}"

MODE="${1:-run}"
STAMP="$(date +%Y%m%d-%H%M%S)"
QUADLET_BAK="${QUADLET}.pre-mx03.${STAMP}.bak"
SECRETS_BAK="${SECRETS_ENV}.pre-mx03.${STAMP}.bak"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
CANARY_ID=""

cleanup(){
  if [ -n "${CANARY_ID:-}" ]; then
    podman rm -f "$CANARY_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD"
touch "$IDX"

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

host_probe(){
  local url="$1"
  local c
  c="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  c="${c:-000}"
  printf '%s\n' "${c:0:3}"
}

acceptable_console_code(){
  case "${1:-000}" in
    200|201|202|204|301|302|303|307|308|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

write_listener_script(){
  cat > "$TMP/listener.sh" <<'SH'
#!/bin/sh
hex="$1"
awk -v hex="$hex" '
NR>1 && $4=="0A" && $2 ~ (":" hex "$") {
  found=1
}
END {
  exit !found
}
' /proc/net/tcp /proc/net/tcp6 2>/dev/null
SH
}

internal_listener_now(){
  local cname="$1" hex="$2"
  write_listener_script
  podman exec -i "$cname" sh -s -- "$hex" < "$TMP/listener.sh" >/dev/null 2>&1
}

wait_internal_listener(){
  local cname="$1" hex="$2" attempts="${3:-30}"
  write_listener_script
  local i
  for i in $(seq 1 "$attempts"); do
    if podman exec -i "$cname" sh -s -- "$hex" < "$TMP/listener.sh" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

collect_secret_values(){
  : > "$TMP/secret_values.txt"

  podman inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    python3 - >> "$TMP/secret_values.txt" <<'PY'
import re, sys
sens = re.compile(r"(PASSWORD|SECRET|KEY|TOKEN|AUTH|CREDENTIAL|PRIVATE|ENCRYPTION|MASTER|API|CLIENT)", re.I)
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line or "=" not in line:
        continue
    k, v = line.split("=", 1)
    if sens.search(k) and v:
        print(v)
PY

  if [ -f "$SECRETS_ENV" ]; then
    python3 - "$SECRETS_ENV" >> "$TMP/secret_values.txt" <<'PY'
import re, sys
path = sys.argv[1]
sens = re.compile(r"(PASSWORD|SECRET|KEY|TOKEN|AUTH|CREDENTIAL|PRIVATE|ENCRYPTION|MASTER|API|CLIENT)", re.I)
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
  fi
}

mask_stream(){
  python3 - "$TMP/secret_values.txt" <<'PY'
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
    r"([A-Za-z0-9_]*(?:PASSWORD|SECRET|KEY|TOKEN|AUTH|CREDENTIAL|PRIVATE|ENCRYPTION|MASTER|API|CLIENT)[A-Za-z0-9_]*)=([^\s\"']+)"
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

mask_str(){
  printf '%s\n' "$1" | mask_stream
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

fd, tmp = tempfile.mkstemp(prefix=".mx03-env-", dir=os.path.dirname(path) or ".")
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

patch_quadlet(){
  local image="$1"
  local user="$2"
  shift 2
  python3 - "$QUADLET" "$image" "$user" "$@" <<'PY'
import os, sys, tempfile

path = sys.argv[1]
image = sys.argv[2]
user = sys.argv[3]
env_updates = {}
for pair in sys.argv[4:]:
    if "=" not in pair:
        continue
    k, v = pair.split("=", 1)
    env_updates[k] = v

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
    # No [Container] section; append one.
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append("\n[Container]\n")
    start = len(lines) - 1
    end = len(lines)
    body = []
else:
    body = lines[start + 1:end]

new_body = []
seen_image = False
seen_user = False

for line in body:
    s = line.strip()
    if s.startswith("Image="):
        if image:
            new_body.append(f"Image={image}\n")
            seen_image = True
        else:
            new_body.append(line)
        continue
    if s.startswith("User="):
        if user:
            new_body.append(f"User={user}\n")
            seen_user = True
        else:
            new_body.append(line)
        continue
    if s.startswith("Environment="):
        val = s[len("Environment="):]
        k = val.split("=", 1)[0] if "=" in val else val
        if k in env_updates:
            continue
    new_body.append(line)

if image and not seen_image:
    new_body.append(f"Image={image}\n")
if user and not seen_user:
    new_body.append(f"User={user}\n")
for k, v in env_updates.items():
    new_body.append(f"Environment={k}={v}\n")

out = lines[:start + 1] + new_body + lines[end:]

fd, tmp = tempfile.mkstemp(prefix=".mx03-quadlet-", dir=os.path.dirname(path) or ".")
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

restart_minio(){
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed minio.service >/dev/null 2>&1 || true
  systemctl --user restart minio.service
  local i st
  for i in $(seq 1 60); do
    st="$(podman inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
    if [ "$st" = running ]; then
      say "minio container running after ${i} checks"
      return 0
    fi
    sleep 2
  done
  return 1
}

verify_minio_console(){
  local label="$1"
  local api_health console_root console_browser internal9001

  api_health="$(host_probe "${WP_API}/minio/health/live")"
  console_root="$(host_probe "${WP_CONSOLE}/")"
  console_browser="$(host_probe "${WP_CONSOLE}/browser")"

  if internal_listener_now "$CONTAINER" 2329; then
    internal9001=yes
  else
    internal9001=no
  fi

  say "VERIFY[$label] api_health_9010=$api_health"
  say "VERIFY[$label] internal_9001=$internal9001"
  say "VERIFY[$label] console_root_9011=$console_root"
  say "VERIFY[$label] console_browser_9011=$console_browser"

  if [ "$api_health" != 200 ]; then
    say "VERIFY[$label] FAIL: MinIO API health is not 200"
    return 1
  fi

  if [ "$internal9001" != yes ]; then
    say "VERIFY[$label] FAIL: container internal Console listener 9001 absent"
    return 1
  fi

  if ! acceptable_console_code "$console_root" && ! acceptable_console_code "$console_browser"; then
    say "VERIFY[$label] FAIL: host Console port 9011 not reachable"
    return 1
  fi

  say "VERIFY[$label] PASS"
  return 0
}

dump_minio_diagnostics(){
  hr "DIAG minio"
  say "--- container state ---"
  podman inspect "$CONTAINER" \
    --format 'name={{.Name}}
image={{.Config.Image}}
status={{.State.Status}}
exitCode={{.State.ExitCode}}
startedAt={{.State.StartedAt}}
finishedAt={{.State.FinishedAt}}
error={{.State.Error}}
restartpolicy={{.HostConfig.RestartPolicy.Name}}
networkmode={{.HostConfig.NetworkMode}}' 2>/dev/null | sed 's/^/    /' || true

  say "--- ports ---"
  podman port "$CONTAINER" 2>/dev/null | sed 's/^/    /' || true

  say "--- process cmdlines containing minio ---"
  podman exec "$CONTAINER" sh -c '
    for p in /proc/[0-9]*; do
      if grep -qi minio "$p/comm" 2>/dev/null; then
        printf "%s " "$(basename "$p")"
        tr "\0" " " < "$p/cmdline" 2>/dev/null
        printf "\n"
      fi
    done
  ' 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- data path inspection ---"
  podman exec "$CONTAINER" sh -c '
    echo "id:"; id 2>/dev/null || true
    echo
    echo "ls -ld /data /bitnami/minio/data:"
    ls -ld /data /bitnami/minio/data 2>/dev/null || true
    echo
    echo "readlink -f /bitnami/minio/data:"
    readlink -f /bitnami/minio/data 2>/dev/null || true
    echo
    echo "find /data maxdepth 2:"
    find /data -maxdepth 2 -printf "%y %u:%g %s %p\n" 2>/dev/null | head -80 || true
  ' 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- internal listeners ---"
  podman exec "$CONTAINER" sh -c '
    echo "tcp4 hex listeners:"
    awk "NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[2]}" /proc/net/tcp 2>/dev/null | sort -u | tr "\n" " "
    echo
    echo "tcp6 hex listeners:"
    awk "NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[2]}" /proc/net/tcp6 2>/dev/null | sort -u | tr "\n" " "
    echo
  ' 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- last 220 logs masked ---"
  podman logs --tail 220 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- journalctl last 120 masked ---"
  journalctl --user -u minio.service -n 120 --no-pager 2>&1 | mask_stream | sed 's/^/    /' || true
}

restore_backups(){
  say "restoring MX03 backups"
  [ -f "$QUADLET_BAK" ] && cp -p "$QUADLET_BAK" "$QUADLET" || true
  [ -f "$SECRETS_BAK" ] && cp -p "$SECRETS_BAK" "$SECRETS_ENV" || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user restart minio.service >/dev/null 2>&1 || true
}

hr "X0 preflight"
for c in python3 curl podman awk sed grep systemctl journalctl find; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$QUADLET" ] || halt "missing quadlet: $QUADLET"
[ -f "$SECRETS_ENV" ] || halt "missing env file: $SECRETS_ENV"

collect_secret_values

if [ "$MODE" = check ]; then
  hr "X1 plan (check mode)"
  say "current image: $(podman inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || echo unknown)"
  say "quadlet: $QUADLET"
  say "env file: $SECRETS_ENV"
  say "will backup quadlet/env"
  say "will upsert MINIO_CONSOLE_ADDRESS=:9001"
  say "will restart and verify internal 9001 + host 9011"
  say "if still failing, will canary $OFFICIAL_IMAGE"
  say "if canary passes, will patch quadlet image with rollback on failure"
  say "[RESULT] MX03 CHECK - nothing written."
  exit 0
fi

hr "X1 backups"
cp -p "$QUADLET" "$QUADLET_BAK"
chmod 600 "$QUADLET_BAK"
say "quadlet backup: $QUADLET_BAK"

cp -p "$SECRETS_ENV" "$SECRETS_BAK"
chmod 600 "$SECRETS_BAK"
say "env backup: $SECRETS_BAK"

hr "X2 pre-repair diagnostics"
dump_minio_diagnostics

hr "X3 stage A: force MINIO_CONSOLE_ADDRESS in shared env file"
upsert_env_file "$SECRETS_ENV" "MINIO_CONSOLE_ADDRESS=:9001"
say "upserted MINIO_CONSOLE_ADDRESS=:9001 into $SECRETS_ENV"

if ! restart_minio; then
  dump_minio_diagnostics
  restore_backups
  ledger "FAIL" "MX03 stage A restart failed"
  halt "minio.service did not become running after stage A"
fi

sleep 5

if verify_minio_console "stage-A"; then
  hr "X9 RESULT"
  say "[RESULT] MX03 COMPLETE - MinIO Console healed by explicit MINIO_CONSOLE_ADDRESS."
  say "  API:     $WP_API"
  say "  Console: $WP_CONSOLE/browser"
  say "  root user file/env: MINIO_ROOT_USER in $SECRETS_ENV"
  say "  root password: stored in $SECRETS_ENV; do not paste into chat"
  ledger "PASS" "MX03 stage A PASS: MINIO_CONSOLE_ADDRESS=:9001 restored internal 9001 and host 9011."
  exit 0
fi

say "stage A did not restore Console; proceeding to image canary"

hr "X4 stage B: canary official MinIO image in ephemeral container"
say "pulling $OFFICIAL_IMAGE"
podman pull "$OFFICIAL_IMAGE" 2>&1 | mask_stream | tail -20 | sed 's/^/    /' || halt "pull failed"

CANARY_NAME="mx03-minio-canary-${STAMP}"
podman rm -f "$CANARY_NAME" >/dev/null 2>&1 || true

say "starting canary with empty tmpfs data and no published ports"
CANARY_ID="$(
  podman run --rm -d \
    --name "$CANARY_NAME" \
    --network none \
    --tmpfs /data:rw,size=64m \
    -e MINIO_ROOT_USER=canary \
    -e MINIO_ROOT_PASSWORD=canarypassword123 \
    -e MINIO_CONSOLE_ADDRESS=:9001 \
    "$OFFICIAL_IMAGE" 2>"$TMP/canary.err" || true
)"

if [ -z "$CANARY_ID" ]; then
  mask_file "$TMP/canary.err" | sed 's/^/    /' || true
  ledger "FAIL" "MX03 official canary failed to start"
  restore_backups
  halt "official MinIO canary failed to start"
fi

say "canary id=${CANARY_ID:0:12}"

if ! wait_internal_listener "$CANARY_NAME" 2329 30; then
  say "official canary did NOT listen on internal 9001"
  say "--- canary logs ---"
  podman logs --tail 120 "$CANARY_NAME" 2>&1 | mask_stream | sed 's/^/    /' || true
  podman rm -f "$CANARY_NAME" >/dev/null 2>&1 || true
  CANARY_ID=""
  ledger "FAIL" "MX03 official canary did not bind 9001; embedded Console likely unavailable in official latest too. Next step: standalone MinIO Console sidecar."
  restore_backups
  halt "official MinIO canary did not bind Console port 9001"
fi

say "official canary DOES listen on internal 9001"
podman rm -f "$CANARY_NAME" >/dev/null 2>&1 || true
CANARY_ID=""

hr "X5 stage C: patch quadlet to official MinIO image"
CUR_UID="$(podman exec "$CONTAINER" id -u 2>/dev/null || echo 1001)"
case "$CUR_UID" in
  ''|0) USER_SPEC="" ;;
  *) USER_SPEC="${CUR_UID}:0" ;;
esac
say "detected current uid=$CUR_UID; user_spec=${USER_SPEC:-<default>}"

patch_quadlet "$OFFICIAL_IMAGE" "$USER_SPEC" "MINIO_CONSOLE_ADDRESS=:9001"
say "patched quadlet:"
say "  Image=$OFFICIAL_IMAGE"
[ -n "$USER_SPEC" ] && say "  User=$USER_SPEC"
say "  Environment=MINIO_CONSOLE_ADDRESS=:9001"

say "--- patched quadlet masked ---"
mask_file "$QUADLET" | sed 's/^/    /' || true

if ! restart_minio; then
  dump_minio_diagnostics
  restore_backups
  ledger "FAIL" "MX03 stage C restart failed after image switch"
  halt "minio.service did not become running after image switch"
fi

sleep 8

if verify_minio_console "stage-C-official-image"; then
  hr "X9 RESULT"
  say "[RESULT] MX03 COMPLETE - MinIO Console healed by switching to official MinIO image."
  say "  API:     $WP_API"
  say "  Console: $WP_CONSOLE/browser"
  say "  image:   $OFFICIAL_IMAGE"
  say "  volume:  minio_data:/data preserved"
  say "  backups:"
  say "    $QUADLET_BAK"
  say "    $SECRETS_BAK"
  ledger "PASS" "MX03 stage C PASS: official MinIO image restored internal 9001 and host 9011 Console."
  exit 0
fi

say "stage C verification failed; rolling back"
dump_minio_diagnostics
restore_backups

if verify_minio_console "rollback"; then
  ledger "PARTIAL" "MX03 image switch failed, rollback restored previous MinIO state but Console still not healthy."
else
  ledger "FAIL" "MX03 image switch failed and rollback did not restore Console."
fi

halt "MinIO Console could not be healed automatically; backups restored"
