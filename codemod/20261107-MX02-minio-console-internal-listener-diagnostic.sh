#!/usr/bin/env bash
# 20261107-MX02 — read-only MinIO Console deep diagnostic.
#
# Fixes MX01's unreliable env extraction and answers the decisive question:
#   Is MinIO listening on container port 9001 inside the container?
#
# Checks:
#   - container state / ports
#   - sanitized env vars
#   - host listeners and stale rootlessport processes
#   - internal /proc/net/tcp listeners for 9000/9001
#   - internal HTTP/HTTPS probes from inside container
#   - /certs presence
#   - MinIO binary Console/Browser flag support
#   - quadlet/container unit content
#   - journald/podman logs for Console/Error
#   - host probes for 9010/9011
#
# No mutations. Secrets masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="mx02-minio-console-internal-listener-diagnostic-v1"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD" "$SEC"
touch "$IDX"

MASK="$TMP/mask.py"
cat > "$MASK" <<'PYMASK'
import sys, re

jwt_re = re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")

# Redact KEY=VALUE where KEY looks sensitive.
# This also catches:
#   Environment=MINIO_ROOT_PASSWORD=...
#   MINIO_ROOT_PASSWORD=...
#   access_token=...
kv_re = re.compile(
    r"([A-Za-z0-9_]*(?:PASSWORD|SECRET|ACCESS_KEY|SECRET_KEY|TOKEN|PRIVATE|CREDENTIAL)[A-Za-z0-9_]*)=([^\s\"\']+)"
)

def kv_repl(m):
    key = m.group(1)
    val = m.group(2)
    return f"{key}=[REDACTED len={len(val)}]"

for line in sys.stdin:
    line = kv_re.sub(kv_repl, line)
    line = jwt_re.sub("[JWT]", line)
    sys.stdout.write(line)
PYMASK

mask_file(){
  python3 "$MASK" < "$1" 2>/dev/null || {
    say "    WARN mask_file fallback; output may be incomplete"
  }
}

mask_stream(){
  python3 "$MASK" 2>/dev/null || {
    say "    WARN mask_stream fallback; output may be incomplete"
  }
}

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
  local code
  code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  case "$code" in
    000000) code=000 ;;
  esac
  printf '%s\n' "$code"
}

hr "X0 preflight"
for c in python3 curl podman awk sed grep ss systemctl journalctl ps find; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done

CONTAINER="${MINIO_CONTAINER:-}"
if [ -n "$CONTAINER" ] && podman inspect "$CONTAINER" >/dev/null 2>&1; then
  say "using MINIO_CONTAINER=$CONTAINER"
else
  CONTAINER=""
  while IFS='|' read -r name image status; do
    [ -n "$name" ] || continue
    if printf '%s %s' "$name" "$image" | grep -qi minio; then
      CONTAINER="$name"
      break
    fi
  done < <(podman ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null || true)

  [ -n "$CONTAINER" ] || {
    say "Existing containers:"
    podman ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    /' || true
    ledger "FAIL" "MX02 no MinIO container found"
    halt "MinIO container not found"
  }

  say "auto-detected MinIO container=$CONTAINER"
fi

hr "X1 container state"
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

say ""
say "cmd:"
podman inspect "$CONTAINER" --format '{{json .Config.Cmd}}' 2>/dev/null | mask_stream | sed 's/^/    /' || true
say "entrypoint:"
podman inspect "$CONTAINER" --format '{{json .Config.Entrypoint}}' 2>/dev/null | mask_stream | sed 's/^/    /' || true

hr "X2 published ports"
say "podman port all:"
podman port "$CONTAINER" 2>/dev/null | sed 's/^/    /' || say "    none"

say ""
for p in 9000/tcp 9001/tcp; do
  out="$(podman port "$CONTAINER" "$p" 2>/dev/null || true)"
  say "podman port $CONTAINER $p = ${out:-<empty>}"
done

hr "X3 sanitized environment variables (fixed extraction)"
podman inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$TMP/env.raw" 2>/dev/null || true
say "--- env, secrets redacted ---"
mask_file "$TMP/env.raw" | sed 's/^/    /' || true

BROWSER_OFF=no
if grep -qiE '(^|[[:space:]])MINIO_BROWSER=off([[:space:]]|$)' "$TMP/env.raw" 2>/dev/null; then
  BROWSER_OFF=yes
fi

CONSOLE_ADDR_ENV=no
if grep -qiE 'MINIO_CONSOLE_ADDRESS=' "$TMP/env.raw" 2>/dev/null; then
  CONSOLE_ADDR_ENV=yes
fi

SERVER_URL_ENV=no
if grep -qiE 'MINIO_SERVER_URL=' "$TMP/env.raw" 2>/dev/null; then
  SERVER_URL_ENV=yes
fi

say ""
say "MINIO_BROWSER=off detected = $BROWSER_OFF"
say "MINIO_CONSOLE_ADDRESS env detected = $CONSOLE_ADDR_ENV"
say "MINIO_SERVER_URL env detected = $SERVER_URL_ENV"

hr "X4 host listeners and rootlessport process owners"
say "--- ss listeners ---"
ss -ltnp 2>/dev/null | awk 'NR==1 || /:(9000|9001|9010|9011)([[:space:]]|$)/' | sed 's/^/    /' || true

say ""
say "--- pid diagnostics for listeners ---"
PIDS="$(ss -ltnp 2>/dev/null |
  grep -E ':(9000|9001|9010|9011)([[:space:]]|$)' |
  grep -oE 'pid=[0-9]+' |
  cut -d= -f2 |
  sort -u || true)"

if [ -z "$PIDS" ]; then
  say "    no listener pids parsed"
else
  for pid in $PIDS; do
    [ -n "$pid" ] || continue
    say "PID $pid:"
    ps -o pid=,ppid=,user=,args= -p "$pid" 2>/dev/null | sed 's/^/    /' || say "    process not found"
  done
fi

hr "X5 internal container listeners /proc/net/tcp"
cat > "$TMP/internal-listeners.sh" <<'SH'
#!/bin/sh
echo "container identity:"
id 2>/dev/null || true

echo ""
echo "all listening tcp4 hex ports:"
awk 'NR>1 && $4=="0A" {split($2,a,":"); print a[2]}' /proc/net/tcp 2>/dev/null | sort -u | tr '\n' ' '
echo ""

echo "all listening tcp6 hex ports:"
awk 'NR>1 && $4=="0A" {split($2,a,":"); print a[2]}' /proc/net/tcp6 2>/dev/null | sort -u | tr '\n' ' '
echo ""

echo ""
echo "specific listeners:"
for pair in "2328 9000" "2329 9001"; do
  set -- $pair
  hex="$1"
  name="$2"

  awk -v hex="$hex" -v name="$name" '
    NR>1 && $4=="0A" && $2 ~ (":" hex "$") {
      print "LISTEN tcp4 " name " local=" $2 " rem=" $3
    }
  ' /proc/net/tcp 2>/dev/null || true

  awk -v hex="$hex" -v name="$name" '
    NR>1 && $4=="0A" && $2 ~ (":" hex "$") {
      print "LISTEN tcp6 " name " local=" $2 " rem=" $3
    }
  ' /proc/net/tcp6 2>/dev/null || true
done
SH

podman exec -i "$CONTAINER" sh -s < "$TMP/internal-listeners.sh" > "$TMP/internal-listeners.out" 2>&1 || true
mask_file "$TMP/internal-listeners.out" | sed 's/^/    /' || true

INTERNAL_9000_LISTEN=no
INTERNAL_9001_LISTEN=no

if grep -qE 'LISTEN tcp[46] 9000' "$TMP/internal-listeners.out" 2>/dev/null; then
  INTERNAL_9000_LISTEN=yes
fi
if grep -qE 'LISTEN tcp[46] 9001' "$TMP/internal-listeners.out" 2>/dev/null; then
  INTERNAL_9001_LISTEN=yes
fi

say ""
say "internal 9000 listening = $INTERNAL_9000_LISTEN"
say "internal 9001 listening = $INTERNAL_9001_LISTEN"

hr "X6 internal HTTP/HTTPS probes from inside container"
cat > "$TMP/internal-probe.sh" <<'SH'
#!/bin/sh
probe() {
  url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -sS -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || printf '000'
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget -q -O /dev/null --timeout=5 "$url" 2>/dev/null; then
      printf '200'
    else
      printf '000'
    fi
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY'
import sys
import urllib.request
import urllib.error

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=5) as r:
        print(r.status, end="")
except urllib.error.HTTPError as e:
    print(e.code, end="")
except Exception:
    print("000", end="")
PY
    return
  fi

  printf 'NOSUPPORT'
}

for u in \
  "http://127.0.0.1:9000/minio/health/live" \
  "http://127.0.0.1:9000/" \
  "http://127.0.0.1:9001/" \
  "http://127.0.0.1:9001/browser"
do
  printf '%s = ' "$u"
  probe "$u"
  printf '\n'
done

if command -v curl >/dev/null 2>&1; then
  echo ""
  echo "HTTPS probes if curl exists:"
  for u in \
    "https://127.0.0.1:9000/" \
    "https://127.0.0.1:9001/" \
    "https://127.0.0.1:9001/browser"
  do
    printf '%s -k = ' "$u"
    curl -skS -m 5 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null || printf '000'
    printf '\n'
  done
fi
SH

podman exec -i "$CONTAINER" sh -s < "$TMP/internal-probe.sh" > "$TMP/internal-probe.out" 2>&1 || true
mask_file "$TMP/internal-probe.out" | sed 's/^/    /' || true

INTERNAL_9001_CODE="$(grep -E '^http://127\.0\.0\.1:9001/ = ' "$TMP/internal-probe.out" 2>/dev/null | awk '{print $NF}' | head -1 || true)"
INTERNAL_9001_BROWSER_CODE="$(grep -E '^http://127\.0\.0\.1:9001/browser = ' "$TMP/internal-probe.out" 2>/dev/null | awk '{print $NF}' | head -1 || true)"
INTERNAL_9000_HEALTH_CODE="$(grep -E '^http://127\.0\.0\.1:9000/minio/health/live = ' "$TMP/internal-probe.out" 2>/dev/null | awk '{print $NF}' | head -1 || true)"

say ""
say "internal 9000 health = ${INTERNAL_9000_HEALTH_CODE:-none}"
say "internal 9001 root   = ${INTERNAL_9001_CODE:-none}"
say "internal 9001 /browser = ${INTERNAL_9001_BROWSER_CODE:-none}"

hr "X7 /certs inspection, metadata only"
cat > "$TMP/certs.sh" <<'SH'
#!/bin/sh
if [ -d /certs ]; then
  echo "/certs exists"
  ls -la /certs 2>/dev/null | head -30 || true
  echo ""
  echo "files:"
  find /certs -maxdepth 1 -type f -printf '%f %s bytes\n' 2>/dev/null | head -30 || true
else
  echo "/certs missing"
fi
SH

podman exec -i "$CONTAINER" sh -s < "$TMP/certs.sh" > "$TMP/certs.out" 2>&1 || true
mask_file "$TMP/certs.out" | sed 's/^/    /' || true

CERTS_NONEMPTY=no
if grep -qE '\.(pem|crt|key)$|private\.key|public\.crt' "$TMP/certs.out" 2>/dev/null; then
  CERTS_NONEMPTY=yes
fi
say ""
say "certs non-empty detected = $CERTS_NONEMPTY"

hr "X8 MinIO binary Console/Browser flag support"
cat > "$TMP/help.sh" <<'SH'
#!/bin/sh
for b in /opt/bitnami/minio/bin/minio minio; do
  if command -v "$b" >/dev/null 2>&1 || [ -x "$b" ]; then
    echo "binary=$b"
    "$b" --version 2>&1 || true
    echo ""
    echo "server help console/browser lines:"
    "$b" server --help 2>&1 | grep -iE 'console|browser' || true
    break
  fi
done
SH

podman exec -i "$CONTAINER" sh -s < "$TMP/help.sh" > "$TMP/help.out" 2>&1 || true
mask_file "$TMP/help.out" | sed 's/^/    /' || true

CONSOLE_HELP=no
if grep -qiE 'console|browser' "$TMP/help.out" 2>/dev/null; then
  CONSOLE_HELP=yes
fi
say ""
say "binary help mentions console/browser = $CONSOLE_HELP"

hr "X9 quadlet / systemd unit content"
QUADLET_CANDIDATES="
$HOME/.config/containers/systemd/minio.container
$HOME/.config/containers/systemd/minio.quadlet
/etc/containers/systemd/minio.container
/run/user/$(id -u)/containers/systemd/minio.container
"

for f in $QUADLET_CANDIDATES; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  say "--- file: $f ---"
  mask_file "$f" | sed 's/^/    /' || true
  echo
done

say "--- systemctl --user cat minio.service ---"
systemctl --user cat minio.service 2>&1 | mask_stream | sed 's/^/    /' || true

say ""
say "--- systemctl --user show minio.service ---"
systemctl --user show minio.service \
  -p Id \
  -p FragmentPath \
  -p SourcePath \
  -p ActiveState \
  -p SubState \
  -p ExecMainPID \
  -p ExecMainStartTimestamp \
  -p ControlGroup 2>&1 | mask_stream | sed 's/^/    /' || true

say ""
say "--- systemctl --user show Environment/ExecStart ---"
systemctl --user show minio.service -p Environment -p ExecStart 2>&1 | mask_stream | sed 's/^/    /' || true

hr "X10 logs: Console/Error evidence"
journalctl --user -u minio.service -n 500 --no-pager > "$TMP/journal.out" 2>&1 || true
podman logs --tail 300 "$CONTAINER" > "$TMP/podman-logs.out" 2>&1 || true

say "--- journalctl filtered ---"
mask_file "$TMP/journal.out" |
  grep -iE 'console|browser|error|fatal|listen|address|API|9000|9001|MINIO_' |
  tail -120 |
  sed 's/^/    /' || true

say ""
say "--- podman logs filtered ---"
mask_file "$TMP/podman-logs.out" |
  grep -iE 'console|browser|error|fatal|listen|address|API|9000|9001|MINIO_' |
  tail -120 |
  sed 's/^/    /' || true

LOGS_CONSOLE=no
LOGS_ERROR=no
if grep -qiE 'Console:' "$TMP/journal.out" "$TMP/podman-logs.out" 2>/dev/null; then
  LOGS_CONSOLE=yes
fi
if grep -qiE 'error|fatal' "$TMP/journal.out" "$TMP/podman-logs.out" 2>/dev/null; then
  LOGS_ERROR=yes
fi

say ""
say "logs mention Console = $LOGS_CONSOLE"
say "logs mention error/fatal = $LOGS_ERROR"

hr "X11 host HTTP probes"
API_9010_HEALTH="$(host_probe http://127.0.0.1:9010/minio/health/live)"
API_9010_ROOT="$(host_probe http://127.0.0.1:9010/)"
CONSOLE_9011_ROOT="$(host_probe http://127.0.0.1:9011/)"
CONSOLE_9011_BROWSER="$(host_probe http://127.0.0.1:9011/browser)"
ALT_9000_ROOT="$(host_probe http://127.0.0.1:9000/)"
ALT_9001_ROOT="$(host_probe http://127.0.0.1:9001/)"

say "http://127.0.0.1:9010/minio/health/live = $API_9010_HEALTH"
say "http://127.0.0.1:9010/                  = $API_9010_ROOT (403/XML is normal)"
say "http://127.0.0.1:9011/                  = $CONSOLE_9011_ROOT"
say "http://127.0.0.1:9011/browser           = $CONSOLE_9011_BROWSER"
say "http://127.0.0.1:9000/                  = $ALT_9000_ROOT"
say "http://127.0.0.1:9001/                  = $ALT_9001_ROOT"

hr "X12 verdict"
say "container=$CONTAINER"
say "image=$(podman inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || echo unknown)"
say ""
say "host mapping:"
say "  9000/tcp -> $(podman port "$CONTAINER" 9000/tcp 2>/dev/null || echo none)"
say "  9001/tcp -> $(podman port "$CONTAINER" 9001/tcp 2>/dev/null || echo none)"
say ""
say "internal listeners:"
say "  container 9000 listening = $INTERNAL_9000_LISTEN"
say "  container 9001 listening = $INTERNAL_9001_LISTEN"
say ""
say "internal probes:"
say "  9000 health = ${INTERNAL_9000_HEALTH_CODE:-none}"
say "  9001 root   = ${INTERNAL_9001_CODE:-none}"
say "  9001 browser= ${INTERNAL_9001_BROWSER_CODE:-none}"
say ""
say "host probes:"
say "  9010 health = $API_9010_HEALTH"
say "  9010 root   = $API_9010_ROOT"
say "  9011 root   = $CONSOLE_9011_ROOT"
say "  9011 browser= $CONSOLE_9011_BROWSER"
say ""
say "config evidence:"
say "  MINIO_BROWSER=off = $BROWSER_OFF"
say "  MINIO_CONSOLE_ADDRESS env = $CONSOLE_ADDR_ENV"
say "  MINIO_SERVER_URL env = $SERVER_URL_ENV"
say "  binary help console/browser = $CONSOLE_HELP"
say "  logs mention Console = $LOGS_CONSOLE"
say "  logs mention error/fatal = $LOGS_ERROR"
say "  /certs non-empty = $CERTS_NONEMPTY"

say ""
if [ "$INTERNAL_9001_LISTEN" != yes ]; then
  say "[CONFIRMED] MinIO is NOT listening inside the container on port 9001."
  say "            Host 127.0.0.1:9011 -> container 9001 mapping exists, but upstream is absent."
  say "            This exactly explains browser connection reset on 9011."
  say ""
  if [ "$BROWSER_OFF" = yes ]; then
    say "[LIKELY FIX] Remove/adjust MINIO_BROWSER=off in the quadlet/env and restart MinIO."
  elif [ "$CONSOLE_HELP" != yes ]; then
    say "[LIKELY FIX] This MinIO build/image may not include Console support. Consider official MinIO image or Console-enabled image."
  elif [ "$LOGS_CONSOLE" != yes ]; then
    say "[LIKELY FIX] Console did not start. Inspect X10 errors, X7 certs, and X9 quadlet env/command."
  else
    say "[LIKELY FIX] Console was mentioned but not listening. Inspect X10 errors and restart MinIO cleanly after config correction."
  fi
else
  say "[INFO] MinIO IS listening inside container on 9001."
  if [ "$CONSOLE_9011_ROOT" = 000 ] || [ "$CONSOLE_9011_BROWSER" = 000 ]; then
    say "[CONFIRMED] Host rootlessport/Podman forwarding to 9011 is stale/broken."
    say "            Likely fix: restart minio.service or recreate the container cleanly."
  else
    say "[OK] Console appears reachable from host."
  fi
fi

ledger "DIAG" "MX02 internal9001=$INTERNAL_9001_LISTEN host9011=$CONSOLE_9011_ROOT browser_off=$BROWSER_OFF console_help=$CONSOLE_HELP logs_console=$LOGS_CONSOLE certs=$CERTS_NONEMPTY"
say "saved diagnostic ledger row"
exit 0
