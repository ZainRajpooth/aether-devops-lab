#!/usr/bin/env bash
# 20261107-GX03 — temporary browser shim for Woodpecker -> Gitea OAuth login.
# Starts 127.0.0.2:3000 -> 127.0.0.1:<gitea-host-port>
# Launches Chromium-family browser with: --host-resolver-rules=MAP gitea 127.0.0.2
# No sudo. No persistent change. Forwarder dies when script exits.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
mkdir -p "$CD"

WP="http://127.0.0.1:8000"
LOGIN_URL="$WP/login"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
FWD_PY="$TMP/fwd.py"
PROFILE="$TMP/chromium-profile"
FWD_PID=""
BR_PID=""

cleanup(){
  [ -n "$BR_PID" ] && kill "$BR_PID" 2>/dev/null || true
  [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

hr "B0 preflight"
for c in python3 curl podman awk sed grep; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect gitea >/dev/null 2>&1 || halt "container missing: gitea"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port for container port 3000"
say "Gitea container:3000 -> host 127.0.0.1:$GT_HOST_PORT"

C2="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.2:3000/ 2>/dev/null || true)"
say "http://127.0.0.2:3000/ before forwarder = ${C2:-000}"
[ "${C2:-000}" = 000 ] || halt "127.0.0.2:3000 is already occupied"

hr "B1 start temporary forwarder 127.0.0.2:3000 -> 127.0.0.1:$GT_HOST_PORT"
cat > "$FWD_PY" <<'FWDEOF'
import socket, threading, sys, select
LH,LP,UH,UP = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
def pipe(a,b):
    try:
        while True:
            r,_,_ = select.select([a,b],[],[],30)
            if not r: break
            for s in r:
                d = s.recv(65536)
                if not d:
                    for x in (a,b):
                        try: x.close()
                        except: pass
                    return
                (b if s is a else a).sendall(d)
    except Exception:
        for x in (a,b):
            try: x.close()
            except: pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((LH, LP)); srv.listen(128)
sys.stderr.write("fwd %s:%d -> %s:%d\n" % (LH,LP,UH,UP)); sys.stderr.flush()
while True:
    c,_ = srv.accept()
    u = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try: u.connect((UH, UP))
    except Exception:
        try: c.close()
        except: pass
        continue
    threading.Thread(target=pipe, args=(c,u), daemon=True).start()
    threading.Thread(target=pipe, args=(u,c), daemon=True).start()
FWDEOF

python3 "$FWD_PY" 127.0.0.2 3000 127.0.0.1 "$GT_HOST_PORT" >"$TMP/fwd.log" 2>&1 &
FWD_PID=$!
say "forwarder pid=$FWD_PID"

UP=no
for i in $(seq 1 20); do
  B="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.2:3000/ 2>/dev/null || true)"
  if [ -n "$B" ] && [ "$B" != 000 ]; then
    UP=yes
    say "forwarder live: http://127.0.0.2:3000/ = $B"
    break
  fi
  kill -0 "$FWD_PID" 2>/dev/null || {
    say "forwarder died; log:"
    sed 's/^/    /' "$TMP/fwd.log" || true
    halt "forwarder exited immediately"
  }
  sleep 1
done
[ "$UP" = yes ] || {
  sed 's/^/    /' "$TMP/fwd.log" || true
  halt "forwarder not reachable"
}

hr "B2 choose Chromium-family browser"
BROWSER=""
for b in chromium chromium-browser google-chrome google-chrome-stable brave-browser microsoft-edge; do
  if command -v "$b" >/dev/null 2>&1; then
    BROWSER="$b"
    break
  fi
done
[ -n "$BROWSER" ] || halt "No Chromium-family browser found. Use Option 2 for Firefox/system-wide fix."
say "browser=$BROWSER"

hr "B3 launch isolated browser with gitea -> 127.0.0.2 mapping"
mkdir -p "$PROFILE"
say "temporary profile: $PROFILE"
say "opening: $LOGIN_URL"
say "In the browser: click Gitea login, then sign in as adminX."
say "Password can be revealed with: cat '$HOME_/DevOps/aether/secrets/gitea-admin.pass'"
say ""
say "Leave this terminal open while using the browser."
say "Press ENTER in this terminal when finished to stop the forwarder."

"$BROWSER" \
  --user-data-dir="$PROFILE" \
  --host-resolver-rules="MAP gitea 127.0.0.2" \
  --no-first-run \
  --no-default-browser-check \
  "$LOGIN_URL" >/dev/null 2>&1 &
BR_PID=$!

read -r _ || true

say "stopping browser shim..."
exit 0
