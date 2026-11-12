#!/usr/bin/env bash
# 20261107-MX08 — final MinIO secrets relocation + Console URL/port fix.
#
# Fixes MX07 false rollback:
#   - host HTTP probes are authoritative
#   - internal listener check is diagnostic only
#
# Goals:
#   - canonical secrets remain under:
#       ~/DevOps/aether/secrets
#   - old path remains compatible symlink:
#       /home/dev/.config/aether/secrets.env -> ~/DevOps/aether/secrets/aether.env
#   - MinIO-specific env:
#       ~/DevOps/aether/secrets/minio.env
#   - MinIO quadlet uses canonical env files
#   - Console redirect URL pinned to:
#       http://127.0.0.1:9011
#   - S3 server URL pinned to:
#       http://127.0.0.1:9010
#
# No image pull. No public exposure. Secrets masked. Codemod-recorded.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
BAK="$SEC/backups"
IDX="$CD/INDEX.md"

OLD_ENV="$HOME_/.config/aether/secrets.env"
CANON_ENV="$SEC/aether.env"
MINIO_ENV="$SEC/minio.env"

QUADLET="$HOME_/.config/containers/systemd/minio.container"
CONTAINER="minio"

TOKEN="mx08-minio-canonical-secrets-console-url-final-v1"
MODE="${1:-run}"
STAMP="$(date +%Y%m%d-%H%M%S)"

QUADLET_BAK="$BAK/minio.container.pre-mx08.$STAMP.bak"

API_URL="http://127.0.0.1:9010"
CONSOLE_URL="http://127.0.0.1:9011"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD" "$SEC" "$BAK"
chmod 700 "$SEC" "$BAK"
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

mask_file(){
  python3 - "$1" <<'PY'
import re, sys

path = sys.argv[1]

sens = re.compile(
    r"(PASSWORD|SECRET|ACCESS_KEY|SECRET_KEY|TOKEN|PRIVATE|CREDENTIAL|ENCRYPTION|MASTER|API|CLIENT)",
    re.I
)
kv = re.compile(r"^\s*([A-Za-z0-9_]+)=(.*)$")
jwt_re = re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
except Exception as e:
    print("mask_file_read_error=", e)
    sys.exit(0)

for raw in lines:
    line = raw.rstrip("\n")
    m = kv.match(line)
    if m and sens.search(m.group(1)):
        key, val = m.group(1), m.group(2)
        line = f"{key}=[REDACTED len={len(val)}]"
    line = jwt_re.sub("[JWT]", line)
    print(line)
PY
}

mask_text_file(){
  mask_file "$1"
}

probe(){
  local c
  c="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true)"
  printf '%s\n' "${c:-000}"
}

acceptable_console_code(){
  case "${1:-000}" in
    200|201|202|204|301|302|303|307|308|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

internal_has_port(){
  local port="$1"
  local hex
  hex="$(printf '%04X' "$port")"

  podman exec "$CONTAINER" sh -c "grep -E ':${hex}[[:space:]]' /proc/net/tcp /proc/net/tcp6 >/dev/null 2>&1"
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

rollback_quadlet(){
  if [ -f "$QUADLET_BAK" ]; then
    say "rolling back quadlet from: $QUADLET_BAK"
    cp -p "$QUADLET_BAK" "$QUADLET"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user reset-failed minio.service >/dev/null 2>&1 || true
    systemctl --user restart minio.service >/dev/null 2>&1 || true
  fi
}

hr "S0 preflight"
for c in python3 curl podman awk sed grep systemctl journalctl readlink ln cp chmod mkdir printf; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$QUADLET" ] || halt "missing quadlet: $QUADLET"

if [ ! -e "$CANON_ENV" ]; then
  halt "canonical env missing: $CANON_ENV. Run MX07 stage S2 or restore from backup."
fi

if [ ! -L "$OLD_ENV" ]; then
  say "WARN old env path is not a symlink: $OLD_ENV"
  say "     MX08 will continue, but compatibility for other services may be incomplete."
else
  say "old env symlink: $OLD_ENV -> $(readlink -f "$OLD_ENV" 2>/dev/null || echo unknown)"
fi

hr "S1 current state"
say "quadlet: $QUADLET"
say "canonical env: $CANON_ENV"
say "minio env: $MINIO_ENV"
say ""
say "--- current quadlet, masked ---"
mask_file "$QUADLET" | sed 's/^/    /' || true

say ""
say "--- current probes before change ---"
PRE_API_HEALTH="$(probe "$API_URL/minio/health/live")"
PRE_CONSOLE_ROOT="$(probe "$CONSOLE_URL/")"
PRE_CONSOLE_BROWSER="$(probe "$CONSOLE_URL/browser")"
say "API health 9010      = $PRE_API_HEALTH"
say "Console root 9011    = $PRE_CONSOLE_ROOT"
say "Console browser 9011 = $PRE_CONSOLE_BROWSER"

if [ "$MODE" = check ]; then
  hr "S2 check-mode plan"
  say "1) ensure canonical env exists: $CANON_ENV"
  say "2) ensure compatibility symlink: $OLD_ENV -> $CANON_ENV"
  say "3) create/update MinIO-specific env: $MINIO_ENV"
  say "4) patch MinIO quadlet to use canonical env files"
  say "5) restart minio.service only"
  say "6) verify host probes as authoritative gate"
  say "[RESULT] MX08 CHECK - nothing written."
  exit 0
fi

hr "S3 ensure compatibility symlink"
mkdir -p "$(dirname "$OLD_ENV")"
chmod 700 "$(dirname "$OLD_ENV")" || true

if [ -f "$OLD_ENV" ] && [ ! -L "$OLD_ENV" ]; then
  OLD_BAK="$BAK/secrets.env.pre-mx08.$STAMP.bak"
  cp -p "$OLD_ENV" "$OLD_BAK"
  chmod 600 "$OLD_BAK"
  say "backed up old regular env: $OLD_BAK"
  rm -f "$OLD_ENV"
  ln -s "$CANON_ENV" "$OLD_ENV"
  say "created compatibility symlink: $OLD_ENV -> $CANON_ENV"
elif [ -L "$OLD_ENV" ]; then
  current="$(readlink -f "$OLD_ENV" 2>/dev/null || true)"
  desired="$(readlink -f "$CANON_ENV" 2>/dev/null || true)"
  if [ "$current" != "$desired" ]; then
    rm -f "$OLD_ENV"
    ln -s "$CANON_ENV" "$OLD_ENV"
    say "corrected compatibility symlink: $OLD_ENV -> $CANON_ENV"
  else
    say "compatibility symlink already correct"
  fi
else
  ln -s "$CANON_ENV" "$OLD_ENV"
  say "created compatibility symlink: $OLD_ENV -> $CANON_ENV"
fi

hr "S4 create/update MinIO-specific env"
python3 - "$MINIO_ENV" <<'PY'
import os, sys, tempfile

path = sys.argv[1]

updates = {
    "MINIO_BROWSER": "on",
    "MINIO_CONSOLE_ADDRESS": ":9001",
    "MINIO_SERVER_URL": "http://127.0.0.1:9010",
    "MINIO_BROWSER_REDIRECT_URL": "http://127.0.0.1:9011",
}

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

fd, tmp = tempfile.mkstemp(prefix=".mx08-minio-", dir=os.path.dirname(path) or ".")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(out)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        try:
            os.unlink(tmp)
        except Exception:
            pass
PY

chmod 600 "$MINIO_ENV"
say "wrote $MINIO_ENV"
say "--- minio.env, masked ---"
mask_file "$MINIO_ENV" | sed 's/^/    /' || true

hr "S5 backup and patch MinIO quadlet"
cp -p "$QUADLET" "$QUADLET_BAK"
chmod 600 "$QUADLET_BAK"
say "quadlet backup: $QUADLET_BAK"

python3 - "$QUADLET" "$CANON_ENV" "$MINIO_ENV" <<'PY'
import os, sys, tempfile

path, canon_env, minio_env = sys.argv[1:4]

drop_env_keys = {
    "MINIO_BROWSER",
    "MINIO_SCHEME",
    "MINIO_CONSOLE_ADDRESS",
    "MINIO_SERVER_URL",
    "MINIO_BROWSER_REDIRECT_URL",
}

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
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append("\n")
    lines.append("[Container]\n")
    start = len(lines) - 1
    end = len(lines)
    body = []
else:
    body = lines[start + 1:end]

keep = []

for line in body:
    s = line.strip()

    if s.startswith("EnvironmentFile="):
        continue

    if s.startswith("PublishPort="):
        continue

    if s.startswith("Environment="):
        rest = s[len("Environment="):]
        key = rest.split("=", 1)[0].strip() if "=" in rest else rest.strip()
        if key in drop_env_keys:
            continue

    keep.append(line)

while keep and keep[-1].strip() == "":
    keep.pop()

keep.append(f"EnvironmentFile={canon_env}\n")
keep.append(f"EnvironmentFile={minio_env}\n")
keep.append("PublishPort=127.0.0.1:9010:9000\n")
keep.append("PublishPort=127.0.0.1:9011:9001\n")

out = lines[:start + 1] + keep + lines[end:]

fd, tmp = tempfile.mkstemp(prefix=".mx08-quadlet-", dir=os.path.dirname(path) or ".")
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

say "--- patched quadlet, masked ---"
mask_file "$QUADLET" | sed 's/^/    /' || true

hr "S6 restart MinIO"
systemctl --user daemon-reload
systemctl --user reset-failed minio.service >/dev/null 2>&1 || true
systemctl --user restart minio.service

if ! wait_running; then
  say "--- minio logs tail 120 ---"
  podman logs --tail 120 "$CONTAINER" > "$TMP/logs.out" 2>&1 || true
  mask_text_file "$TMP/logs.out" | sed 's/^/    /' || true

  say "--- journalctl minio.service tail 120 ---"
  journalctl --user -u minio.service -n 120 --no-pager > "$TMP/journal.out" 2>&1 || true
  mask_text_file "$TMP/journal.out" | sed 's/^/    /' || true

  rollback_quadlet
  ledger "FAIL" "MX08 minio did not become running after quadlet patch"
  halt "minio did not become running"
fi

say "waiting 8s for MinIO initialization..."
sleep 8

hr "S7 verify"
say "--- podman port ---"
podman port "$CONTAINER" 2>/dev/null | sed 's/^/    /' || true

INTERNAL_9000=no
INTERNAL_9001=no
internal_has_port 9000 && INTERNAL_9000=yes
internal_has_port 9001 && INTERNAL_9001=yes

say "diagnostic internal 9000 listening = $INTERNAL_9000"
say "diagnostic internal 9001 listening = $INTERNAL_9001"

API_HEALTH="$(probe "$API_URL/minio/health/live")"
API_ROOT="$(probe "$API_URL/")"
CONSOLE_ROOT="$(probe "$CONSOLE_URL/")"
CONSOLE_BROWSER="$(probe "$CONSOLE_URL/browser")"

say ""
say "authoritative host probes:"
say "  API health 9010      = $API_HEALTH"
say "  API root 9010        = $API_ROOT (403/XML is normal)"
say "  Console root 9011    = $CONSOLE_ROOT"
say "  Console browser 9011 = $CONSOLE_BROWSER"

say ""
say "--- MinIO env inside container, masked ---"
podman exec "$CONTAINER" printenv > "$TMP/printenv.out" 2>/dev/null || true
python3 - "$TMP/printenv.out" <<'PY' | sed 's/^/    /'
import re, sys

path = sys.argv[1]
sens = re.compile(
    r"(PASSWORD|SECRET|ACCESS_KEY|SECRET_KEY|TOKEN|PRIVATE|CREDENTIAL|ENCRYPTION|MASTER|API|CLIENT)",
    re.I
)

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
except Exception as e:
    print("printenv_read_error=", e)
    sys.exit(0)

for raw in lines:
    line = raw.rstrip("\n")
    if not line.startswith("MINIO_") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    if sens.search(k):
        v = f"[REDACTED len={len(v)}]"
    print(f"{k}={v}")
PY

say ""
say "--- console HTML port hints, if any ---"
curl -sS -m 8 "$CONSOLE_URL/browser" > "$TMP/console.html" 2>/dev/null || true
grep -Eo '(localhost|127\.0\.0\.1):90[0-9]{2}' "$TMP/console.html" 2>/dev/null |
  sort -u |
  sed 's/^/    /' || say "    none"

HOST_OK=no
if [ "$API_HEALTH" = 200 ] && { acceptable_console_code "$CONSOLE_ROOT" || acceptable_console_code "$CONSOLE_BROWSER"; }; then
  HOST_OK=yes
fi

if [ "$HOST_OK" != yes ]; then
  say ""
  say "--- minio logs tail 160 ---"
  podman logs --tail 160 "$CONTAINER" > "$TMP/logs.out" 2>&1 || true
  mask_text_file "$TMP/logs.out" | sed 's/^/    /' || true

  say "--- journalctl minio.service tail 160 ---"
  journalctl --user -u minio.service -n 160 --no-pager > "$TMP/journal.out" 2>&1 || true
  mask_text_file "$TMP/journal.out" | sed 's/^/    /' || true

  rollback_quadlet
  ledger "FAIL" "MX08 host probes failed: api=$API_HEALTH console=$CONSOLE_ROOT/$CONSOLE_BROWSER"
  halt "MinIO host probes failed; quadlet rolled back"
fi

hr "S8 RESULT"
say "[RESULT] MX08 COMPLETE"
say ""
say "Canonical secrets:"
say "  $CANON_ENV"
say ""
say "Compatibility symlink:"
say "  $OLD_ENV -> $CANON_ENV"
say ""
say "MinIO-specific env:"
say "  $MINIO_ENV"
say ""
say "MinIO endpoints:"
say "  S3 API:     $API_URL"
say "  Console UI: $CONSOLE_URL/browser"
say ""
say "Host probe status:"
say "  API health 9010      = $API_HEALTH"
say "  Console root 9011    = $CONSOLE_ROOT"
say "  Console browser 9011 = $CONSOLE_BROWSER"
say ""
say "Diagnostic internal listener status:"
say "  container 9000 = $INTERNAL_9000"
say "  container 9001 = $INTERNAL_9001"
say ""
say "Important:"
say "  9001 is the container-internal Console port."
say "  The host must use 9011."
say "  If Podman Desktop still shows localhost:9001, refresh/restart its UI cache."
say "  Authoritative command:"
say "    podman port minio"
say ""
say "MinIO user created earlier:"
say "  Access Key: adminX"
say "  Password file: $SEC/minio-user.adminX.pass"
say "  Policy: readwrite"
say ""
say "To copy password:"
say "  xclip -selection clipboard < '$SEC/minio-user.adminX.pass'"

ledger "PASS" "MX08: canonical secrets retained, MinIO quadlet patched to canonical env files, Console URL pinned to 127.0.0.1:9011, host probes passed."
exit 0
