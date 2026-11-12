#!/usr/bin/env bash
# 20261107-MX01 — read-only MinIO 9010/9011 diagnostic.
#
# Purpose:
#   Explain why 9010 shows S3 AccessDenied XML and why 9011 Console is unreachable.
#
# This script does not mutate containers, systemd units, quadlets, DB, or secrets.
# Secrets are masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="mx01-minio-9010-9011-diagnostic-v1"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD" "$SEC"
touch "$IDX"

: > "$TMP/secrets.txt"

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

# Also mask common JWT/hex patterns.
jwt_re = re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")
hex_re = re.compile(r"[0-9a-fA-F]{40,}")

for line in sys.stdin:
    for s in secrets:
        if s:
            line = line.replace(s, "[REDACTED]")
    line = jwt_re.sub("[JWT]", line)
    # Do not globally mask all long hex in MinIO HostId? It is not secret, but safe enough.
    # Keep HostId readable by not replacing hex here. If needed, remove hex_re.
    sys.stdout.write(line)
PYMASK
}

mask_str(){
  printf '%s\n' "$1" | mask_stream
}

add_secret_value(){
  local v="${1:-}"
  [ -n "$v" ] || return 0
  printf '%s\n' "$v" >> "$TMP/secrets.txt"
}

http_probe(){
  local label="$1"
  local url="$2"
  local body="$TMP/probe.body"
  local err="$TMP/probe.err"

  : > "$body"
  : > "$err"

  local code
  code="$(curl -sS -m 8 -o "$body" -w '%{http_code}' "$url" 2>"$err" || echo 000)"

  say "PROBE $label url=$url code=$code"
  if [ -s "$err" ]; then
    say "  curl_err:"
    mask_stream < "$err" | head -c 500 | sed 's/^/    /' || true
    echo
  fi
  if [ -s "$body" ]; then
    say "  body_head:"
    mask_stream < "$body" | head -c 700 | sed 's/^/    /' || true
    echo
  fi
  printf '%s\n' "$code" > "$TMP/code.$label" 2>/dev/null || true
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

hr "M0 preflight"
for c in python3 curl podman awk sed grep ss systemctl find; do
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

  if [ -z "$CONTAINER" ]; then
    say "No Podman container found with 'minio' in name/image."
    say "Existing containers:"
    podman ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    /' || true
    ledger "FAIL" "MX01 no MinIO container found"
    halt "MinIO container not found"
  fi

  say "auto-detected MinIO container=$CONTAINER"
fi

hr "M1 container state"
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
say "command:"
podman inspect "$CONTAINER" --format '{{json .Config.Cmd}}' 2>/dev/null | mask_stream | sed 's/^/    /' || true
say "entrypoint:"
podman inspect "$CONTAINER" --format '{{json .Config.Entrypoint}}' 2>/dev/null | mask_stream | sed 's/^/    /' || true

hr "M2 published ports"
say "podman port all:"
podman port "$CONTAINER" 2>/dev/null | sed 's/^/    /' || say "    none"

say ""
for p in 9000/tcp 9001/tcp 9010/tcp 9011/tcp; do
  out="$(podman port "$CONTAINER" "$p" 2>/dev/null || true)"
  say "podman port $CONTAINER $p = ${out:-<empty>}"
done

hr "M3 environment variables, sanitized"
podman inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
python3 - <<'PYENV' | sed 's/^/    /' || true
import re, sys
sens = re.compile(r"(PASSWORD|SECRET|ACCESS_KEY|TOKEN|PRIVATE|CREDENTIAL|KEY)", re.I)
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    if "=" not in line:
        print(line)
        continue
    k, v = line.split("=", 1)
    if sens.search(k) and v:
        print(f"{k}=[REDACTED len={len(v)}]")
    else:
        print(line)
PYENV

# Collect sensitive env values for masking later output.
podman inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in *=*) ;; *) continue ;; esac
  key="${line%%=*}"
  val="${line#*=}"
  case "$key" in
    *PASSWORD*|*SECRET*|*ACCESS_KEY*|*TOKEN*|*PRIVATE*|*CREDENTIAL*)
      add_secret_value "$val"
      ;;
  esac
done

hr "M4 local listeners"
say "ss listeners for 9000/9001/9010/9011:"
ss -ltnp 2>/dev/null | awk 'NR==1 || /:(9000|9001|9010|9011)([[:space:]]|$)/' | sed 's/^/    /' || true

hr "M5 HTTP probes"
http_probe API_HEALTH_9010 "http://127.0.0.1:9010/minio/health/live"
http_probe API_ROOT_9010  "http://127.0.0.1:9010/"
http_probe CONSOLE_9011   "http://127.0.0.1:9011/"
http_probe CONSOLE_BROWSER_9011 "http://127.0.0.1:9011/browser"

# Also probe common alternative ports if they exist.
for alt in 9000 9001; do
  http_probe "ALT_${alt}_ROOT" "http://127.0.0.1:${alt}/" || true
done

hr "M6 MinIO container logs, filtered"
say "--- last 180 log lines, filtered ---"
podman logs --tail 180 "$CONTAINER" 2>&1 |
  mask_stream |
  grep -iE 'API|Console|Browser|Error|Fatal|listen|address|9000|9001|9010|9011|AccessDenied|root|credential|MINIO_' |
  tail -120 |
  sed 's/^/    /' || true

say ""
say "--- last 80 raw log lines, masked ---"
podman logs --tail 80 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true

hr "M7 systemd user units"
say "matching user units:"
systemctl --user --no-pager --full list-units --type=service --all 2>/dev/null |
  grep -i minio |
  sed 's/^/    /' || say "    none"

say ""
say "matching user unit files:"
systemctl --user --no-pager --full list-unit-files --type=service 2>/dev/null |
  grep -i minio |
  sed 's/^/    /' || say "    none"

for unit in minio.service minio-console.service minio-server.service; do
  if systemctl --user cat "$unit" >/dev/null 2>&1; then
    say ""
    say "--- systemctl --user cat $unit ---"
    systemctl --user cat "$unit" 2>&1 | mask_stream | sed 's/^/    /' || true

    say "--- systemctl --user status $unit ---"
    systemctl --user --no-pager --full status "$unit" 2>&1 | sed 's/^/    /' || true

    say "--- journalctl --user -u $unit last 80 ---"
    journalctl --user -u "$unit" -n 80 --no-pager 2>&1 | mask_stream | sed 's/^/    /' || true
  fi
done

hr "M8 quadlet / container systemd files"
say "searching common quadlet dirs:"
FOUND_FILES=no
for d in \
  "$HOME/.config/containers/systemd" \
  "$HOME/.config/systemd/user" \
  "/etc/containers/systemd" \
  "/etc/containers/systemd/users/$(id -u)" \
  "/run/user/$(id -u)/containers/systemd"; do
  [ -d "$d" ] || continue
  say "dir=$d"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    FOUND_FILES=yes
    say "--- file: $file ---"
    sed -n '1,240p' "$file" 2>/dev/null | mask_stream | sed 's/^/    /' || true
  done < <(find "$d" -maxdepth 4 -type f \( -iname '*minio*' -o -iname '*s3*' -o -iname '*object*' \) 2>/dev/null || true)
done
[ "$FOUND_FILES" = yes ] || say "    no MinIO/S3 quadlet/unit files found in searched dirs"

hr "M9 secret/env files, keys only"
say "searching $SEC for MinIO/S3 env files:"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  say "--- file: $file ---"
  python3 - "$file" <<'PYFILE' | sed 's/^/    /'
import re, sys
path = sys.argv[1]
sens = re.compile(r"(PASSWORD|SECRET|ACCESS_KEY|TOKEN|PRIVATE|CREDENTIAL|KEY)", re.I)
try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                print(line)
                continue
            if "=" not in line:
                print(line)
                continue
            k, v = line.split("=", 1)
            if sens.search(k) and v:
                print(f"{k}=[REDACTED len={len(v)}]")
            else:
                print(line)
except Exception as e:
    print("read_error=", e)
PYFILE

  # Append sensitive values from file for masking later.
  python3 - "$file" <<'PYAPPEND'
import re, sys
path = sys.argv[1]
sens = re.compile(r"(PASSWORD|SECRET|ACCESS_KEY|TOKEN|PRIVATE|CREDENTIAL|KEY)", re.I)
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
PYAPPEND
done < <(find "$SEC" -maxdepth 3 -type f \( -iname '*minio*' -o -iname '*s3*' -o -iname '*object*' \) 2>/dev/null || true)

hr "M10 verdict"
API_CODE_9010="$(cat "$TMP/code.API_HEALTH_9010" 2>/dev/null || echo 000)"
API_ROOT_CODE_9010="$(cat "$TMP/code.API_ROOT_9010" 2>/dev/null || echo 000)"
CONSOLE_CODE_9011="$(cat "$TMP/code.CONSOLE_9011" 2>/dev/null || echo 000)"
CONSOLE_BROWSER_CODE_9011="$(cat "$TMP/code.CONSOLE_BROWSER_9011" 2>/dev/null || echo 000)"

PORT_9001_MAPPED=no
if [ -n "$(podman port "$CONTAINER" 9001/tcp 2>/dev/null || true)" ]; then
  PORT_9001_MAPPED=yes
fi

PORT_9000_MAPPED=no
if [ -n "$(podman port "$CONTAINER" 9000/tcp 2>/dev/null || true)" ]; then
  PORT_9000_MAPPED=yes
fi

CONSOLE_LOG_HINT=no
if podman logs --tail 250 "$CONTAINER" 2>&1 | grep -qiE 'Console:|console address|MINIO_CONSOLE_ADDRESS|--console-address'; then
  CONSOLE_LOG_HINT=yes
fi

BROWSER_OFF=no
if podman inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -qiE '^MINIO_BROWSER=off'; then
  BROWSER_OFF=yes
fi

say "container=$CONTAINER"
say "API health 9010=$API_CODE_9010"
say "API root 9010=$API_ROOT_CODE_9010 (403/XML is expected)"
say "Console root 9011=$CONSOLE_CODE_9011"
say "Console /browser 9011=$CONSOLE_BROWSER_CODE_9011"
say "container 9000 published=$PORT_9000_MAPPED"
say "container 9001 published=$PORT_9001_MAPPED"
say "log hint for Console=$CONSOLE_LOG_HINT"
say "MINIO_BROWSER=off=$BROWSER_OFF"

say ""
if [ "$API_CODE_9010" = 200 ] || [ "$API_ROOT_CODE_9010" = 403 ]; then
  say "[OK] MinIO S3 API on 9010 is alive."
  say "     AccessDenied XML in browser is normal for the S3 API port."
else
  say "[WARN] MinIO S3 API on 9010 did not respond normally."
fi

if [ "$CONSOLE_CODE_9011" = 200 ] || [ "$CONSOLE_CODE_9011" = 302 ] || [ "$CONSOLE_CODE_9011" = 401 ]; then
  say "[OK] MinIO Console on 9011 appears reachable."
else
  say "[FAIL] MinIO Console on 9011 is not reachable."
  say "       This is the actual UI problem."
fi

if [ "$PORT_9001_MAPPED" != yes ]; then
  say "[LIKELY CAUSE] Container port 9001 is not published to host."
  say "               MinIO Console usually needs: 127.0.0.1:9011 -> container 9001."
fi

if [ "$BROWSER_OFF" = yes ]; then
  say "[LIKELY CAUSE] MINIO_BROWSER=off disables the Console UI."
fi

if [ "$CONSOLE_LOG_HINT" != yes ] && [ "$PORT_9001_MAPPED" = yes ]; then
  say "[LIKELY CAUSE] Port may be published, but logs do not show Console startup."
  say "               Check MINIO_CONSOLE_ADDRESS / --console-address / MINIO_BROWSER."
fi

ledger "DIAG" "MX01 MinIO diagnostic: api9010=$API_CODE_9010/$API_ROOT_CODE_9010 console9011=$CONSOLE_CODE_9011 port9001_published=$PORT_9001_MAPPED browser_off=$BROWSER_OFF console_log_hint=$CONSOLE_LOG_HINT"
say "saved diagnostic ledger row"
exit 0
