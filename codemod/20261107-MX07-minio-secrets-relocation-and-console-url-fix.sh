#!/usr/bin/env bash
# 20261107-MX07 — relocate MinIO/Aether secrets canonically and fix MinIO Console URL/port behavior.
#
# Goals:
#   - canonical secrets move from:
#       /home/dev/.config/aether/secrets.env
#     to:
#       /home/dev/DevOps/aether/secrets/aether.env
#
#   - keep old path as compatibility symlink so other services do not break immediately.
#
#   - create MinIO-specific env:
#       /home/dev/DevOps/aether/secrets/minio.env
#
#   - pin MinIO Console/S3 URLs to host loopback published ports:
#       MINIO_SERVER_URL=http://127.0.0.1:9010
#       MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011
#
#   - patch MinIO quadlet to use canonical env files.
#   - restart only MinIO.
#   - verify internal 9000/9001 listeners and host 9010/9011 probes.
#
# No public exposure. Secrets masked. Codemod-recorded.
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

TOKEN="mx07-minio-secrets-relocation-and-console-url-fix-v1"
MODE="${1:-run}"
STAMP="$(date +%Y%m%d-%H%M%S)"

QUADLET_BAK="$BAK/minio.container.pre-mx07.$STAMP.bak"
OLD_ENV_BAK="$BAK/secrets.env.pre-mx07.$STAMP.bak"

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

mask_stream(){
  python3 - <<'PY'
import sys, re

sens = re.compile(
    r"(PASSWORD|SECRET|ACCESS_KEY|SECRET_KEY|TOKEN|PRIVATE|CREDENTIAL|ENCRYPTION|MASTER|API|CLIENT)",
    re.I
)
kv = re.compile(r"^\s*([A-Za-z0-9_]+)=(.*)$")
jwt_re = re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")

for raw in sys.stdin:
    line = raw.rstrip("\n")
    m = kv.match(line)
    if m and sens.search(m.group(1)):
        key, val = m.group(1), m.group(2)
        line = f"{key}=[REDACTED len={len(val)}]"
    line = jwt_re.sub("[JWT]", line)
    sys.stdout.write(line + "\n")
PY
}

probe(){
  curl -sS -m 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000
}

acceptable_console_code(){
  case "${1:-000}" in
    200|201|202|204|301|302|303|307|308|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

internal_listener(){
  local hex="$1"
  podman exec -i "$CONTAINER" sh -s -- "$hex" <<'SH' >/dev/null 2>&1
hex="$1"
awk -v hex="$hex" '
NR>1 && $4=="0A" && $2 ~ (":" hex "$") {
  found=1
}
END {
  exit !found
}
' /proc/net/tcp /proc/net/tcp6
SH
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
    systemctl --user restart minio.service >/dev/null 2>&1 || true
  fi
}

hr "S0 preflight"
for c in python3 curl podman awk sed grep systemctl journalctl readlink ln cp chmod mkdir; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$QUADLET" ] || halt "missing quadlet: $QUADLET"

if [ ! -e "$OLD_ENV" ] && [ ! -e "$CANON_ENV" ]; then
  halt "neither old env nor canonical env exists: $OLD_ENV / $CANON_ENV"
fi

hr "S1 discover references to old secrets path"
say "files referencing $OLD_ENV:"
grep -RIl "$OLD_ENV" \
  "$HOME_/.config/containers/systemd" \
  "$HOME_/.config/systemd/user" \
  "/etc/containers/systemd" \
  2>/dev/null |
  sed 's/^/    /' || say "    none"

if [ "$MODE" = check ]; then
  hr "S2 check-mode plan"
  say "1) copy/retain canonical env at: $CANON_ENV"
  say "2) replace old env path with symlink: $OLD_ENV -> $CANON_ENV"
  say "3) create MinIO-specific env: $MINIO_ENV"
  say "4) set:"
  say "     MINIO_SERVER_URL=$API_URL"
  say "     MINIO_BROWSER_REDIRECT_URL=$CONSOLE_URL"
  say "     MINIO_CONSOLE_ADDRESS=:9001"
  say "     MINIO_BROWSER=on"
  say "5) patch MinIO quadlet EnvironmentFile entries"
  say "6) restart minio.service only"
  say "7) verify internal 9000/9001 and host 9010/9011"
  say "[RESULT] MX07 CHECK - nothing written."
  exit 0
fi

hr "S2 canonical secret relocation"
mkdir -p "$(dirname "$OLD_ENV")"
chmod 700 "$(dirname "$OLD_ENV")" || true

if [ ! -e "$CANON_ENV" ]; then
  [ -f "$OLD_ENV" ] || halt "canonical env missing and old env is not a regular file: $OLD_ENV"
  cp -p "$OLD_ENV" "$CANON_ENV"
  chmod 600 "$CANON_ENV"
  say "created canonical env: $CANON_ENV"
else
  say "canonical env already exists: $CANON_ENV"
fi

if ! grep -q '^MINIO_ROOT_USER=' "$CANON_ENV" 2>/dev/null; then
  halt "canonical env missing MINIO_ROOT_USER: $CANON_ENV"
fi
if ! grep -q '^MINIO_ROOT_PASSWORD=' "$CANON_ENV" 2>/dev/null; then
  halt "canonical env missing MINIO_ROOT_PASSWORD: $CANON_ENV"
fi

if [ -f "$OLD_ENV" ] && [ ! -L "$OLD_ENV" ]; then
  cp -p "$OLD_ENV" "$OLD_ENV_BAK"
  chmod 600 "$OLD_ENV_BAK"
  say "backed up old regular env file: $OLD_ENV_BAK"
  rm -f "$OLD_ENV"
  ln -s "$CANON_ENV" "$OLD_ENV"
  say "replaced old env path with compatibility symlink: $OLD_ENV -> $CANON_ENV"
elif [ -L "$OLD_ENV" ]; then
  current_target="$(readlink -f "$OLD_ENV" 2>/dev/null || true)"
  desired_target="$(readlink -f "$CANON_ENV" 2>/dev/null || true)"
  if [ "$current_target" != "$desired_target" ]; then
    rm -f "$OLD_ENV"
    ln -s "$CANON_ENV" "$OLD_ENV"
    say "corrected compatibility symlink: $OLD_ENV -> $CANON_ENV"
  else
    say "compatibility symlink already correct: $OLD_ENV -> $CANON_ENV"
  fi
else
  ln -s "$CANON_ENV" "$OLD_ENV"
  say "created compatibility symlink: $OLD_ENV -> $CANON_ENV"
fi

hr "S3 remove MinIO UI/env duplicates from canonical shared env"
python3 - "$CANON_ENV" \
  MINIO_BROWSER \
  MINIO_SCHEME \
  MINIO_CONSOLE_ADDRESS \
  MINIO_SERVER_URL \
  MINIO_BROWSER_REDIRECT_URL <<'PY'
import os, sys, tempfile

path = sys.argv[1]
keys = set(sys.argv[2:])

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

out = []
removed = 0
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in stripped:
        k = stripped.split("=", 1)[0].strip()
        if k in keys:
            removed += 1
            continue
    out.append(line)

fd, tmp = tempfile.mkstemp(prefix=".mx07-canon-", dir=os.path.dirname(path) or ".")
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

print(f"removed_duplicate_keys={removed}")
PY
chmod 600 "$CANON_ENV"

hr "S4 create/update MinIO-specific env"
python3 - "$MINIO_ENV" <<'PY'
import os, sys, tempfile

path = sys.argv[1]
updates = {
    "MINIO_BROWSER": "on",
    "MINIO_SCHEME": "http",
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

fd, tmp = tempfile.mkstemp(prefix=".mx07-minio-", dir=os.path.dirname(path) or ".")
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
say "--- minio.env, secrets masked ---"
mask_stream < "$MINIO_ENV" | sed 's/^/    /' || true

hr "S5 backup and patch MinIO quadlet"
cp -p "$QUADLET" "$QUADLET_BAK"
chmod 600 "$QUADLET_BAK"
say "quadlet backup: $QUADLET_BAK"

python3 - "$QUADLET" "$CANON_ENV" "$MINIO_ENV" <<'PY'
import os, sys, tempfile

path, canon_env, minio_env = sys.argv[1:4]

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

new_body = []
for line in body:
    s = line.strip()
    if s.startswith("EnvironmentFile="):
        continue
    if s.startswith("PublishPort="):
        continue
    new_body.append(line)

# Remove trailing blank lines from old body, then append desired settings.
while new_body and new_body[-1].strip() == "":
    new_body.pop()

new_body.append(f"EnvironmentFile={canon_env}\n")
new_body.append(f"EnvironmentFile={minio_env}\n")
new_body.append("PublishPort=127.0.0.1:9010:9000\n")
new_body.append("PublishPort=127.0.0.1:9011:9001\n")

out = lines[:start + 1] + new_body + lines[end:]

fd, tmp = tempfile.mkstemp(prefix=".mx07-quadlet-", dir=os.path.dirname(path) or ".")
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

say "--- patched quadlet ---"
sed -n '1,220p' "$QUADLET" | mask_stream | sed 's/^/    /' || true

hr "S6 restart MinIO"
systemctl --user daemon-reload
systemctl --user reset-failed minio.service >/dev/null 2>&1 || true
systemctl --user restart minio.service

if ! wait_running; then
  say "--- minio logs tail 80 ---"
  podman logs --tail 80 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true
  say "--- journalctl minio.service tail 80 ---"
  journalctl --user -u minio.service -n 80 --no-pager 2>&1 | mask_stream | sed 's/^/    /' || true
  rollback_quadlet
  ledger "FAIL" "MX07 minio did not become running after quadlet patch"
  halt "minio did not become running"
fi

say "waiting 6s for MinIO initialization..."
sleep 6

hr "S7 verify listeners and probes"
say "--- podman port ---"
podman port "$CONTAINER" 2>/dev/null | sed 's/^/    /' || true

INTERNAL_9000=no
INTERNAL_9001=no
internal_listener 2328 && INTERNAL_9000=yes
internal_listener 2329 && INTERNAL_9001=yes

say "internal 9000 listening = $INTERNAL_9000"
say "internal 9001 listening = $INTERNAL_9001"

API_HEALTH="$(probe "$API_URL/minio/health/live")"
API_ROOT="$(probe "$API_URL/")"
CONSOLE_ROOT="$(probe "$CONSOLE_URL/")"
CONSOLE_BROWSER="$(probe "$CONSOLE_URL/browser")"

say "API health 9010       = $API_HEALTH"
say "API root 9010         = $API_ROOT (403/XML is normal)"
say "Console root 9011     = $CONSOLE_ROOT"
say "Console browser 9011  = $CONSOLE_BROWSER"

say ""
say "--- MinIO relevant env inside container, secrets masked ---"
podman exec "$CONTAINER" printenv 2>/dev/null |
python3 - <<'PY' |
sed 's/^/    /'
import sys, re
sens = re.compile(
    r"(PASSWORD|SECRET|ACCESS_KEY|SECRET_KEY|TOKEN|PRIVATE|CREDENTIAL|ENCRYPTION|MASTER|API|CLIENT)",
    re.I
)
for raw in sys.stdin:
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
curl -sS -m 8 "$CONSOLE_URL/browser" 2>/dev/null |
  grep -Eo '(localhost|127\.0\.0\.1):90[0-9]{2}' |
  sort -u |
  sed 's/^/    /' || say "    none"

PASS=yes
[ "$INTERNAL_9000" = yes ] || PASS=no
[ "$INTERNAL_9001" = yes ] || PASS=no
[ "$API_HEALTH" = 200 ] || PASS=no
acceptable_console_code "$CONSOLE_ROOT" || acceptable_console_code "$CONSOLE_BROWSER" || PASS=no

if [ "$PASS" != yes ]; then
  say ""
  say "--- minio logs tail 120 ---"
  podman logs --tail 120 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true
  say "--- journalctl minio.service tail 120 ---"
  journalctl --user -u minio.service -n 120 --no-pager 2>&1 | mask_stream | sed 's/^/    /' || true
  rollback_quadlet
  ledger "FAIL" "MX07 verification failed: internal9000=$INTERNAL_9000 internal9001=$INTERNAL_9001 api=$API_HEALTH console=$CONSOLE_ROOT/$CONSOLE_BROWSER"
  halt "MinIO verification failed; quadlet rolled back"
fi

hr "S8 RESULT"
say "[RESULT] MX07 COMPLETE"
say "  canonical secrets env: $CANON_ENV"
say "  compatibility symlink: $OLD_ENV -> $CANON_ENV"
say "  MinIO-specific env:    $MINIO_ENV"
say "  S3 API:                $API_URL"
say "  MinIO Console:         $CONSOLE_URL/browser"
say ""
say "  MinIO user created earlier:"
say "    username/access key: adminX"
say "    password file:       $SEC/minio-user.adminX.pass"
say "    policy:              readwrite"
say ""
say "  To copy MinIO user password to clipboard:"
say "    xclip -selection clipboard < '$SEC/minio-user.adminX.pass'"
say ""
say "  If you need full MinIO Console admin rights, recreate/attach consoleAdmin policy."
say "  readwrite is a normal storage user, not necessarily Console admin."

ledger "PASS" "MX07: relocated canonical secrets to ~/DevOps/aether/secrets, added minio.env, pinned Console URLs to 9010/9011, restarted MinIO, verified internal 9001 and host 9011."
exit 0
