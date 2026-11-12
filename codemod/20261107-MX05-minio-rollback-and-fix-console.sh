#!/usr/bin/env bash
# 20261107-MX05 — MinIO crash recovery.
#
# MX04 broke the container by changing the volume mount to /bitnami/minio/data,
# which likely had permission issues with the existing minio_data volume.
# The container crashed and was auto-removed (--rm).
#
# Fix:
# 1. Read journalctl to see the crash reason.
# 2. Rollback to the MX04 backup (which had the working /data mount).
# 3. Inject ONLY MINIO_BROWSER=on and MINIO_SCHEME=http.
# 4. Restart and verify.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
QUADLET="$HOME_/.config/containers/systemd/minio.container"
SECRETS_ENV="/home/dev/.config/aether/secrets.env"

TOKEN="mx05-minio-rollback-and-fix-console-v1"

# Find the most recent MX04 backup
QUADLET_BAK="$(ls -t "$HOME/.config/containers/systemd/minio.container.pre-mx04."*.bak 2>/dev/null | head -1)"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD"

hr "X1 crash diagnostics (journalctl)"
say "--- last 40 lines of minio.service journal ---"
journalctl --user -u minio.service -n 40 --no-pager 2>&1 | sed 's/^/    /' || true

if [ -z "$QUADLET_BAK" ]; then
  halt "Could not find MX04 backup quadlet in $HOME/.config/containers/systemd/"
fi
say "found backup: $QUADLET_BAK"

hr "X2 rollback and patch quadlet"
cp -p "$QUADLET_BAK" "$QUADLET"
say "restored working quadlet (volume=minio_data:/data)"

say "injecting MINIO_BROWSER=on and MINIO_SCHEME=http"
python3 - "$QUADLET" <<'PY'
import sys, tempfile, os

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
in_container = False
env_browser_added = False
env_scheme_added = True

for line in lines:
    s = line.strip()
    
    if s == "[Container]":
        in_container = True
    elif in_container and s.startswith("[") and s != "[Container]":
        in_container = False
        
    if in_container and s.startswith("Environment=MINIO_BROWSER="):
        env_browser_added = True
    if in_container and s.startswith("Environment=MINIO_SCHEME="):
        env_scheme_added = True
        
    out.append(line)

if not env_browser_added or not env_scheme_added:
    new_out = []
    for line in out:
        new_out.append(line)
        if line.strip().startswith("Volume=") and not env_browser_added:
            new_out.append("Environment=MINIO_BROWSER=on\n")
            env_browser_added = True
            if not env_scheme_added:
                new_out.append("Environment=MINIO_SCHEME=http\n")
                env_scheme_added = True
    out = new_out

fd, tmp = tempfile.mkstemp(prefix=".mx05-", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.writelines(out)
os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
PY

say "--- final quadlet ---"
cat "$QUADLET" | sed 's/^/    /'

hr "X3 restart minio"
systemctl --user daemon-reload
systemctl --user reset-failed minio.service || true
systemctl --user restart minio.service

say "waiting for container to be running..."
for i in $(seq 1 20); do
  st="$(podman inspect minio --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
  if [ "$st" = running ]; then
    say "minio running after ${i}s"
    break
  fi
  if [ "$st" = exited ] || [ "$st" = unknown ]; then
    say "container not running (status=$st). checking logs..."
    podman logs minio 2>&1 | tail -20 | sed 's/^/    /' || journalctl --user -u minio.service -n 20 --no-pager | sed 's/^/    /'
    halt "minio container failed to stay running"
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
API_CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9010/minio/health/live)"
CONSOLE_CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9011/)"
BROWSER_CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9011/browser)"

say "API health 9010: $API_CODE"
say "Console 9011:    $CONSOLE_CODE"
say "Console browser: $BROWSER_CODE"

if [ "$API_CODE" != 200 ]; then
  say "API health failed. Logs:"
  podman logs --tail 20 minio 2>&1 | sed 's/^/    /' || true
  halt "MinIO API health check failed"
fi

if [ "$CONSOLE_CODE" = 000 ] && [ "$BROWSER_CODE" = 000 ]; then
  say "Console still not responding. Logs:"
  podman logs --tail 20 minio 2>&1 | sed 's/^/    /' || true
  halt "MinIO Console still not responding"
fi

hr "X5 RESULT"
say "[RESULT] MX05 COMPLETE."
say "  API:     http://127.0.0.1:9010"
say "  Console: http://127.0.0.1:9011/browser"
say ""
say "Credentials are in:"
say "  $SECRETS_ENV"
say "  MINIO_ROOT_USER and MINIO_ROOT_PASSWORD"

exit 0
