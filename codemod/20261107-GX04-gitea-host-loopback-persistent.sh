#!/usr/bin/env bash
# 20261107-GX04 — persistent local browser reachability for Woodpecker -> Gitea OAuth.
#
# Makes host resolve:
#   gitea -> 127.0.0.2
#
# Runs user systemd service:
#   127.0.0.2:3000 -> 127.0.0.1:<gitea-host-port>
#
# This lets normal browsers follow Woodpecker's internal OAuth redirect:
#   http://gitea:3000/login/oauth/authorize?...
#
# No Gitea quadlet change. No Woodpecker config change. Loopback-only.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
NET="$HOME_/DevOps/aether/apps/net"
UNIT_DIR="$HOME_/.config/systemd/user"
UNIT_NAME="aether-gitea-loop-3000.service"
UNIT="$UNIT_DIR/$UNIT_NAME"
FWD="$NET/gitea-loop-3000.py"

TOKEN="gx04-gitea-host-loopback-persistent-v1"
IDX="$CD/INDEX.md"

mkdir -p "$CD" "$NET" "$UNIT_DIR"
touch "$IDX"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

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

hr "P0 preflight"
for c in python3 curl podman awk sed grep systemctl sudo; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect gitea >/dev/null 2>&1 || halt "container missing: gitea"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port for container port 3000"
say "Gitea container:3000 -> host 127.0.0.1:$GT_HOST_PORT"

hr "P1 check 127.0.0.2:3000 availability"
C2="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.2:3000/ 2>/dev/null || true)"
say "http://127.0.0.2:3000/ = ${C2:-000}"

SERVICE_ACTIVE=no
if systemctl --user is-active --quiet "$UNIT_NAME"; then
  SERVICE_ACTIVE=yes
  say "existing $UNIT_NAME is active"
fi

if [ "${C2:-000}" != 000 ] && [ "$SERVICE_ACTIVE" != yes ]; then
  say "127.0.0.2:3000 is occupied by something other than our service."
  say "Diagnostics:"
  ss -ltnp 2>/dev/null | grep -E '127\.0\.0\.2:3000|:3000' | sed 's/^/    /' || true
  halt "refusing to overwrite unknown listener on 127.0.0.2:3000"
fi

hr "P2 ensure /etc/hosts maps gitea -> 127.0.0.2"
if grep -qE '^[[:space:]]*127\.0\.0\.2[[:space:]]+gitea([[:space:]]|#|$)' /etc/hosts; then
  say "/etc/hosts already has: 127.0.0.2 gitea"
else
  if grep -qE '^[^#]*[[:space:]]gitea([[:space:]]|#|$)' /etc/hosts; then
    say "Existing /etc/hosts entry for gitea found, but not 127.0.0.2:"
    grep -nE '^[^#]*[[:space:]]gitea([[:space:]]|#|$)' /etc/hosts | sed 's/^/    /' || true
    halt "manual review required; refusing to create conflicting gitea hosts entries"
  fi

  say "Adding hosts entry: 127.0.0.2 gitea"
  echo '127.0.0.2 gitea' | sudo tee -a /etc/hosts >/dev/null
fi

hr "P3 write loopback forwarder script"
cat > "$FWD" <<'PYEOF'
#!/usr/bin/env python3
import socket, threading, sys, select, os

if len(sys.argv) != 5:
    sys.stderr.write("usage: gitea-loop-3000.py LISTEN_HOST LISTEN_PORT UPSTREAM_HOST UPSTREAM_PORT\n")
    sys.exit(2)

LH = sys.argv[1]
LP = int(sys.argv[2])
UH = sys.argv[3]
UP = int(sys.argv[4])

def pipe(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 30)
            if not r:
                break
            for s in r:
                d = s.recv(65536)
                if not d:
                    for x in (a, b):
                        try:
                            x.close()
                        except Exception:
                            pass
                    return
                (b if s is a else a).sendall(d)
    except Exception:
        for x in (a, b):
            try:
                x.close()
            except Exception:
                pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((LH, LP))
srv.listen(128)

sys.stderr.write("aether-gitea-loop: %s:%d -> %s:%d pid=%d\n" % (LH, LP, UH, UP, os.getpid()))
sys.stderr.flush()

while True:
    c, addr = srv.accept()
    u = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        u.connect((UH, UP))
    except Exception as e:
        sys.stderr.write("aether-gitea-loop: upstream connect failed from %s: %s\n" % (addr, e))
        sys.stderr.flush()
        try:
            c.close()
        except Exception:
            pass
        continue
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    threading.Thread(target=pipe, args=(u, c), daemon=True).start()
PYEOF

chmod 755 "$FWD"
say "wrote $FWD"

hr "P4 install user systemd service"
cat > "$UNIT" <<UNIT
[Unit]
Description=Aether Gitea host loopback forwarder (gitea:3000 -> 127.0.0.1:$GT_HOST_PORT)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $FWD 127.0.0.2 3000 127.0.0.1 $GT_HOST_PORT
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT

say "wrote $UNIT"

systemctl --user daemon-reload
systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || true
systemctl --user restart "$UNIT_NAME"

sleep 1

hr "P5 verify"
say "systemctl status:"
systemctl --user --no-pager --full status "$UNIT_NAME" 2>&1 | sed 's/^/    /' || true

say ""
say "getent hosts gitea:"
getent hosts gitea | sed 's/^/    /' || say "    gitea does not resolve"

C3="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' http://gitea:3000/ 2>/dev/null || true)"
say ""
say "http://gitea:3000/ = ${C3:-000}"

if [ "${C3:-000}" = 000 ]; then
  say "--- recent service logs ---"
  journalctl --user -u "$UNIT_NAME" -n 40 --no-pager 2>&1 | sed 's/^/    /' || true
  ledger "FAIL" "GX04 installed but http://gitea:3000/ unreachable"
  halt "gitea:3000 not reachable from host"
fi

hr "P6 RESULT"
say "[RESULT] GX04 COMPLETE - host can now reach Woodpecker's internal Gitea OAuth URL."
say "  hosts entry:    127.0.0.2 gitea"
say "  forwarder:      127.0.0.2:3000 -> 127.0.0.1:$GT_HOST_PORT"
say "  service:        systemctl --user status $UNIT_NAME"
say ""
say "Now open:"
say "  http://127.0.0.1:8000/login"
say "Click Gitea, then login as:"
say "  username: adminX"
say "  password: cat '$HOME_/DevOps/aether/secrets/gitea-admin.pass'"

ledger "PASS" "GX04: persistent local gitea:3000 host reachability installed; http://gitea:3000/ returned $C3."
exit 0
