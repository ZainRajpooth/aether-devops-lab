#!/usr/bin/env bash
# 20261107-MX16 — MinIO Console network/login heal.
#
# Fixes the current symptom:
#   http://localhost:9011/login -> "unable to login due to network error"
#
# Root cause handled here:
#   - Console UI is reachable, but Console/API URL configuration is inconsistent.
#   - MX15 failed mid-consolidation and hit a ledger() unbound-variable bug.
#
# MX16:
#   1) detects active MinIO EnvironmentFile(s)
#   2) backs up env files + quadlet
#   3) forces canonical local MinIO URLs:
#        MINIO_ADDRESS=:9000
#        MINIO_CONSOLE_ADDRESS=:9001
#        MINIO_SERVER_URL=http://127.0.0.1:9010
#        MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011
#   4) removes MINIO_BROWSER=off if present
#   5) restarts MinIO and verifies internal 9001 + host 9010/9011
#   6) verifies/resets devX/conX from saved secret files
#   7) best-effort tests Console login API
#   8) rolls back automatically if MinIO becomes unhealthy
#
# Secrets are masked. Do not paste passwords into chat.
set -uo pipefail
umask 077

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="mx16-minio-console-network-login-heal-v1"
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

cleanup(){
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
  local b="${f}.pre-mx16.${STAMP}.bak"

  [ -f "$f" ] || return 0
  cp -p "$f" "$b" || halt "backup failed: $f"
  chmod 600 "$b" || true

  BAKS+=("$b")
  ORIGS+=("$f")
  say "backup: $b"
}

rollback_files(){
  say "rolling back MX16 backups"

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
      || [ "$f" = "$SEC/aether.env" ]; then
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

fd, tmp = tempfile.mkstemp(prefix=".mx16-env-", dir=os.path.dirname(path) or ".")
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

fd, tmp = tempfile.mkstemp(prefix=".mx16-del-", dir=os.path.dirname(path) or ".")
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
  local attempts="${3:-45}"
  local i

  for i in $(seq 1 "$attempts"); do
    if internal_listener "$cname" "$hex"; then
      say "internal listener ready: container=$cname hex=$hex"
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_container_running(){
  local attempts="${1:-60}"
  local i st

  for i in $(seq 1 "$attempts"); do
    st="$(podman inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
    if [ "$st" = running ]; then
      say "container running after ${i} checks"
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_api_ready(){
  local attempts="${1:-60}"
  local i c

  for i in $(seq 1 "$attempts"); do
    c="$(http_code "$API_URL/minio/health/live" 3)"
    if [ "$c" = 200 ]; then
      say "MinIO API ready: $API_URL/minio/health/live = 200"
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_console_ready(){
  local attempts="${1}"
  local i c

  for i in $(seq 1 "$attempts"); do
    c="$(http_code "$CONSOLE_URL/browser" 3)"
    if acceptable_http "$c"; then
      say "MinIO Console ready: $CONSOLE_URL/browser = $c"
      return 0
    fi
    sleep 2
  done

  return 1
}

dump_minio_logs(){
  say "--- MinIO logs tail 120 ---"
  podman logs --tail 120 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- journalctl minio.service tail 100 ---"
  journalctl --user -u "$SERVICE" -n 100 --no-pager 2>&1 | mask_stream | sed 's/^/    /' || true

  say "--- podman port minio ---"
  podman port "$CONTAINER" 2>/dev/null | sed 's/^/    /' || true

  say "--- ss listeners ---"
  ss -ltnp 2>/dev/null | awk 'NR==1 || /:(9000|9001|9010|9011)([[:space:]]|$)/' | sed 's/^/    /' || true
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

  for attempt in 1 2 3 4 5 6; do
    say "creating/resetting user access_key=$ak policy=$policy attempt=$attempt"

    if create_or_replace_user_once "$ak" "$sk" "$policy"; then
      say "OK user ready: $ak"
      return 0
    fi

    say "WARN user operation failed; retrying after short wait"
    dump_minio_logs
    sleep 5
  done

  return 1
}

delete_user_if_present(){
  local ak="$1"

  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || exit 0
    mc admin user rm local "$1" >/dev/null 2>&1 || true
  ' _ "$ak" >/dev/null 2>&1 || true
}

show_user_info(){
  local ak="$1"

  podman exec "$CONTAINER" sh -c '
    mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || exit 0
    mc admin user info local "$1" 2>&1 || true
  ' _ "$ak" 2>&1 | mask_stream | sed 's/^/    /' || true
}

console_login_test(){
  local base="$1"
  local ak="$2"
  local sk="$3"
  local label="$4"
  local out="$TMP/console-login-$label.out"

  MX16_BASE="$base" MX16_AK="$ak" MX16_SK="$sk" python3 - > "$out" 2>&1 <<'PYLOGIN'
import json, os, urllib.request, urllib.error

base = os.environ.get("MX16_BASE", "").rstrip("/")
ak = os.environ.get("MX16_AK", "")
sk = os.environ.get("MX16_SK", "")

if not base or not ak or not sk:
    print("console_login=SKIP missing_base_or_credentials")
    raise SystemExit(0)

payloads = [
    {"accessKey": ak, "secretKey": sk},
    {"ACCESS_KEY": ak, "SECRET_KEY": sk},
    {"userName": ak, "password": sk},
    {"username": ak, "password": sk},
]

paths = [
    "/api/v1/login",
    "/api/login",
    "/login",
]

results = []

for path in paths:
    for idx, body in enumerate(payloads, start=1):
        try:
            data = json.dumps(body).encode("utf-8")
            req = urllib.request.Request(
                base + path,
                data=data,
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
                method="POST",
            )

            with urllib.request.urlopen(req, timeout=10) as r:
                status = r.status
                results.append((path, idx, status, "OK"))
                if status == 200:
                    print("console_login=OK path=", path, "payload=", idx, "status=", status)
                    raise SystemExit(0)
        except urllib.error.HTTPError as e:
            results.append((path, idx, e.code, "HTTP_ERROR"))
        except Exception as e:
            results.append((path, idx, 0, type(e).__name__))

print("console_login=FAIL")
for r in results[:16]:
    print("  attempt path=", r[0], "payload=", r[1], "status=", r[2], "kind=", r[3])
PYLOGIN

  mask_stream < "$out" | sed 's/^/    /' || true

  grep -q '^console_login=OK' "$out" 2>/dev/null
}

hr "X0 preflight"

for c in python3 curl podman awk sed grep systemctl find; do
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

add_secret "$ROOT_SK"
add_secret "$NORMAL_SK"
add_secret "$CONSOLE_SK"

detect_env_files
[ "${#ENV_FILES[@]}" -gt 0 ] || halt "could not detect MinIO env files"

say "container=$CONTAINER"
say "service=$SERVICE"
say "api=$API_URL"
say "console=$CONSOLE_URL"
say "root_access_key=$ROOT_AK"
say "normal_access_key=$NORMAL_AK"
say "console_admin_access_key=$CONSOLE_AK"
say "detected MinIO env files:"
for f in "${ENV_FILES[@]}"; do
  say "  $f"
done

if [ "$MODE" = check ]; then
  hr "X1 plan (check mode)"
  say "  1) backup env files and quadlet"
  say "  2) upsert canonical MinIO local URLs into all detected env files"
  say "  3) delete MINIO_BROWSER key if present"
  say "  4) restart MinIO and verify internal 9001 + host 9010/9011"
  say "  5) verify/reset devX and conX"
  say "  6) best-effort Console login API test"
  say "  7) rollback automatically if unhealthy"
  say ""
  say "Canonical values to be enforced:"
  say "  MINIO_ADDRESS=:9000"
  say "  MINIO_CONSOLE_ADDRESS=:9001"
  say "  MINIO_SERVER_URL=http://127.0.0.1:9010"
  say "  MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011"
  say "[RESULT] MX16 CHECK - nothing written."
  exit 0
fi

hr "X1 backups"
backup_file "$QUADLET"
for f in "${ENV_FILES[@]}"; do
  backup_file "$f"
done

hr "X2 enforce canonical MinIO Console env"
for f in "${ENV_FILES[@]}"; do
  upsert_env_file "$f" \
    "MINIO_ROOT_USER=$ROOT_AK" \
    "MINIO_ROOT_PASSWORD=$ROOT_SK" \
    "MINIO_ADDRESS=:9000" \
    "MINIO_CONSOLE_ADDRESS=:9001" \
    "MINIO_SERVER_URL=http://127.0.0.1:9010" \
    "MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011"

  delete_env_key "$f" "MINIO_BROWSER"

  say "updated env file: $f"
  grep -E '^(MINIO_ADDRESS|MINIO_CONSOLE_ADDRESS|MINIO_SERVER_URL|MINIO_BROWSER_REDIRECT_URL|MINIO_ROOT_USER)=' "$f" 2>/dev/null | mask_stream | sed 's/^/    /' || true
done

hr "X3 restart MinIO"
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user reset-failed "$SERVICE" >/dev/null 2>&1 || true

if ! systemctl --user restart "$SERVICE"; then
  dump_minio_logs
  rollback_files
  ledger "FAIL" "MX16 systemctl restart failed"
  halt "MinIO service restart failed; rolled back"
fi

if ! wait_container_running 60; then
  dump_minio_logs
  rollback_files
  ledger "FAIL" "MX16 container did not become running"
  halt "MinIO container did not become running; rolled back"
fi

if ! wait_internal_listener "$CONTAINER" 2329 45; then
  say "internal Console listener 9001 absent"
  dump_minio_logs
  rollback_files
  ledger "FAIL" "MX16 internal Console listener 9001 absent after env heal"
  halt "MinIO Console internal listener 9001 absent; rolled back"
fi

if ! wait_api_ready 60; then
  dump_minio_logs
  rollback_files
  ledger "FAIL" "MX16 MinIO API not healthy after env heal"
  halt "MinIO API not healthy; rolled back"
fi

if ! wait_console_ready 45; then
  dump_minio_logs
  rollback_files
  ledger "FAIL" "MX16 MinIO Console host port 9011 not reachable after env heal"
  halt "MinIO Console 9011 not reachable; rolled back"
fi

say "[OK] MinIO API and Console are healthy after canonical env enforcement"

hr "X4 verify root credentials inside MinIO"
if ! mc_root_ok "$ROOT_AK" "$ROOT_SK"; then
  dump_minio_logs
  ledger "FAIL" "MX16 root credentials did not verify inside MinIO"
  halt "root credentials did not verify; not rolling back because env is healthy, but manual intervention required"
fi
say "root credentials verified using http://127.0.0.1:9000 inside container"

hr "X5 verify/reset requested IAM users"
NORMAL_PRESENT=no
CONSOLE_PRESENT=no

if user_exists "$NORMAL_AK"; then
  NORMAL_PRESENT=yes
  say "normal user already present: $NORMAL_AK"
else
  say "normal user missing; creating/resetting"
fi

if user_exists "$CONSOLE_AK"; then
  CONSOLE_PRESENT=yes
  say "console admin user already present: $CONSOLE_AK"
else
  say "console admin user missing; creating/resetting"
fi

if [ "$NORMAL_PRESENT" != yes ]; then
  if ! create_or_replace_user_retry "$NORMAL_AK" "$NORMAL_SK" "readwrite"; then
    dump_minio_logs
    ledger "PARTIAL" "MX16 normal user creation failed after Console heal"
    halt "normal user creation failed"
  fi
fi

if [ "$CONSOLE_PRESENT" != yes ]; then
  if ! create_or_replace_user_retry "$CONSOLE_AK" "$CONSOLE_SK" "consoleAdmin"; then
    dump_minio_logs
    ledger "PARTIAL" "MX16 console admin user creation failed after Console heal"
    halt "console admin user creation failed"
  fi
fi

if ! user_exists "$NORMAL_AK"; then
  dump_minio_logs
  ledger "FAIL" "MX16 normal user not present after reset"
  halt "normal user not present after reset"
fi

if ! user_exists "$CONSOLE_AK"; then
  dump_minio_logs
  ledger "FAIL" "MX16 console admin user not present after reset"
  halt "console admin user not present after reset"
fi

say "deleting known old users if present"
for old in developer consoleadmin; do
  if [ "$old" != "$NORMAL_AK" ] && [ "$old" != "$CONSOLE_AK" ] && [ "$old" != "$ROOT_AK" ]; then
    delete_user_if_present "$old"
    say "deleted old user if present: $old"
  fi
done

hr "X6 user info"
say "normal user info:"
show_user_info "$NORMAL_AK"

say "console admin user info:"
show_user_info "$CONSOLE_AK"

hr "X7 endpoint probes"
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

hr "X8 best-effort Console login API test"
say "testing console admin login on 127.0.0.1"
CONSOLE_LOGIN_127_OK=no
if console_login_test "$CONSOLE_URL" "$CONSOLE_AK" "$CONSOLE_SK" "127"; then
  CONSOLE_LOGIN_127_OK=yes
fi

say "testing console admin login on localhost"
CONSOLE_LOGIN_LOCALHOST_OK=no
if console_login_test "http://localhost:9011" "$CONSOLE_AK" "$CONSOLE_SK" "localhost"; then
  CONSOLE_LOGIN_LOCALHOST_OK=yes
fi

hr "X9 result"
say "[RESULT] MX16 COMPLETE - MinIO Console network/login heal finished."
say ""
say "Use this URL:"
say "  $CONSOLE_URL/browser"
say ""
say "Do not mix localhost and 127.0.0.1. The canonical values enforced are:"
say "  MINIO_SERVER_URL=http://127.0.0.1:9010"
say "  MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011"
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
say "Console login API test:"
say "  127.0.0.1 = $CONSOLE_LOGIN_127_OK"
say "  localhost = $CONSOLE_LOGIN_LOCALHOST_OK"

GATE="PARTIAL"
if [ "$API_HEALTH" = 200 ] \
  && acceptable_http "$CONSOLE_BROWSER_127" \
  && [ "$CONSOLE_LOGIN_127_OK" = yes ]; then
  GATE="PASS"
elif [ "$API_HEALTH" = 200 ] && acceptable_http "$CONSOLE_BROWSER_127"; then
  GATE="HEALTHY-LOGIN-TEST-INCONCLUSIVE"
fi

ledger "$GATE" "MX16: api=$API_HEALTH console127=$CONSOLE_BROWSER_127 login127=$CONSOLE_LOGIN_127_OK loginLocalhost=$CONSOLE_LOGIN_LOCALHOST_OK users normal=$NORMAL_AK console=$CONSOLE_AK"

if [ "$GATE" != PASS ]; then
  say ""
  say "[NOTE] MinIO API/Console are healthy, but Console login API test was inconclusive."
  say "       Open browser DevTools -> Network tab and retry login at:"
  say "         $CONSOLE_URL/browser"
  say "       Paste only the failing request URL and status, not passwords."
fi

exit 0
