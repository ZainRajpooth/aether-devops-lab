#!/usr/bin/env bash
# 20261107-MX04 — Smart MinIO fix.
#
# Root causes identified:
# 1) Bitnami MinIO expects data at /bitnami/minio/data, but quadlet mounted minio_data:/data.
#    This meant MinIO was writing to ephemeral container storage, not the volume!
# 2) Console 9001 was not starting because Bitnami's TLS detection sees an empty /certs dir 
#    and silently disables the console.
#
# Fix:
# - Correct volume mount to /bitnami/minio/data
# - Force MINIO_BROWSER=on and MINIO_SCHEME=http to bypass cert issues
# - Restart and verify. No internet pulls required.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
QUADLET="$HOME_/.config/containers/systemd/minio.container"
SECRETS_ENV="/home/dev/.config/aether/secrets.env"

TOKEN="mx04-minio-smart-fix-volume-and-console-v1"
STAMP="$(date +%Y%m%d-%H%M%S)"
QUADLET_BAK="${QUADLET}.pre-mx04.${STAMP}.bak"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD"

hr "X0 preflight"
[ -f "$QUADLET" ] || halt "missing quadlet: $QUADLET"

hr "X1 backup"
cp -p "$QUADLET" "$QUADLET_BAK"
chmod 600 "$QUADLET_BAK"
say "quadlet backup: $QUADLET_BAK"

hr "X2 patch quadlet"
python3 - "$QUADLET" <<'PY'
import sys, tempfile, os

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
in_container = False
volume_fixed = False
env_browser_added = False
env_scheme_added = False

for line in lines:
    s = line.strip()
    
    if s == "[Container]":
        in_container = True
        out.append(line)
        continue
        
    if in_container and s.startswith("[") and s != "[Container]":
        in_container = False
        
    if in_container:
        if s.startswith("Volume="):
            if "/data" in s and "/bitnami/minio/data" not in s:
                out.append("Volume=minio_data:/bitnami/minio/data\n")
                volume_fixed = True
                continue
        if s.startswith("Environment=MINIO_BROWSER="):
            env_browser_added = True
        if s.startswith("Environment=MINIO_SCHEME="):
            env_scheme_added = True
            
    out.append(line)

new_out = []
for line in out:
    new_out.append(line)
    if line.startswith("Volume=minio_data:/bitnami/minio/data"):
        if not env_browser_added:
            new_out.append("Environment=MINIO_BROWSER=on\n")
            env_browser_added = True
        if not env_scheme_added:
            new_out.append("Environment=MINIO_SCHEME=http\n")
            env_scheme_added = True

if not volume_fixed:
    for i, line in enumerate(new_out):
        if line.strip() == "[Container]":
            new_out.insert(i+1, "Volume=minio_data:/bitnami/minio/data\n")
            new_out.insert(i+2, "Environment=MINIO_BROWSER=on\n")
            new_out.insert(i+3, "Environment=MINIO_SCHEME=http\n")
            break

fd, tmp = tempfile.mkstemp(prefix=".mx04-", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.writelines(new_out)
os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
PY

say "--- patched quadlet ---"
cat "$QUADLET" | sed 's/^/    /'

hr "X3 restart minio"
systemctl --user daemon-reload
systemctl --user reset-failed minio.service || true
systemctl --user restart minio.service

say "waiting for container to be running..."
for i in $(seq 1 15); do
  st="$(podman inspect minio --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
  if [ "$st" = running ]; then
    say "minio running after ${i}s"
    break
  fi
  sleep 2
done

hr "X4 verify"
say "waiting 5s for MinIO to initialize..."
sleep 5

say "--- internal listeners ---"
podman exec minio sh -c '
  echo "tcp4 listeners:"
  awk "NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[2]}" /proc/net/tcp 2>/dev/null | sort -u | tr "\n" " "
  echo
  echo "tcp6 listeners:"
  awk "NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[2]}" /proc/net/tcp6 2>/dev/null | sort -u | tr "\n" " "
  echo
' | sed 's/^/    /'

say ""
say "--- host probes ---"
say "API health 9010: $(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9010/minio/health/live)"
say "Console 9011:    $(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9011/)"
say "Console browser: $(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9011/browser)"

say ""
say "--- minio logs (last 30) ---"
podman logs --tail 30 minio 2>&1 | sed 's/^/    /'

hr "X5 RESULT"
say "[RESULT] MX04 COMPLETE."
say "  Fixed volume mount: minio_data -> /bitnami/minio/data"
say "  Forced MINIO_BROWSER=on and MINIO_SCHEME=http"
say "  Backup: $QUADLET_BAK"
say ""
say "If Console 9011 is now 200/302/401, open:"
say "  http://127.0.0.1:9011/browser"
say ""
say "Credentials are in:"
say "  $SECRETS_ENV"
say "  MINIO_ROOT_USER and MINIO_ROOT_PASSWORD"

exit 0
