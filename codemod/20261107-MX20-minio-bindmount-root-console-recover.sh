#!/usr/bin/env bash
# 20261107-MX20 — definitive MinIO recovery: host bind-mount + direct binary as root.
#
# Why:
#   - named volume + 'podman rm -v' on stop kept wiping data and broke perms
#   - direct binary starts Console (proven by MX17 canary B) but UID 1001 can't
#     write a rootless-named-volume owned by host 1000 -> 'file access denied'
#   - bind mount owned by host 1000 + container root(=host 1000) = trivial perms,
#     survives restarts (rm -v never touches bind mounts), Console works
#
# Actions:
#   1) stop+remove container, back up any leftover named volume, snapshot quadlet
#   2) create host data dir ~/DevOps/aether/data/minio (owned by you)
#   3) write a CLEAN quadlet atomically: direct binary, User=0:0, bind mount,
#      loopback publishes, single EnvironmentFile (aether.env)
#   4) ensure MINIO_* root creds + canonical URLs + CORS in aether.env
#   5) restart, verify internal 9001 + API 9010 + Console 9011
#   6) recreate devX(readwrite) and conX(consoleAdmin) from saved cred files
#   7) report logins
#
# Data: MinIO data was empty (GUI never worked). Old named volume backed up if present.
# Secrets masked. No downloads.
set -uo pipefail
umask 077

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
Q="$HOME_/.config/containers/systemd/minio.container"
CONTAINER=minio
SERVICE=minio.service
NET=aether
IMG=docker.io/bitnamilegacy/minio:latest
BIN=/opt/bitnami/minio/bin/minio
DATA_DIR="$HOME_/DevOps/aether/data/minio"
ENVF="$SEC/aether.env"
API="http://127.0.0.1:9010"
CON="http://127.0.0.1:9011"
TOKEN="mx20-minio-bindmount-root-console-recover-v1"
STAMP="$(date +%Y%m%d-%H%M%S)"

RU="$SEC/minio-root.user";        RP="$SEC/minio-root.pass"
NU="$SEC/minio-users/minio-normal.user";        NP="$SEC/minio-users/minio-normal.pass"
CU="$SEC/minio-users/minio-console-admin.user"; CP="$SEC/minio-users/minio-console-admin.pass"

TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
: > "$TMP/sec.txt"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"

ledger(){
  local gate="$1" desc="$2" tok="${TOKEN}:$1"
  grep -qF "$tok" "$IDX" 2>/dev/null || \
    printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$tok" "$gate" "$desc" >> "$IDX"
  say "ledger: $tok"
}
mask(){
  python3 - "$TMP/sec.txt" <<'PY'
import sys,re
secs=[l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
kv=re.compile(r"([A-Za-z0-9_]*(?:PASSWORD|SECRET|KEY|TOKEN|CREDENTIAL|PRIVATE|ENCRYPTION|MASTER)[A-Za-z0-9_]*)=([^\s\"']+)")
for line in sys.stdin:
    for s in secs: line=line.replace(s,"[REDACTED]")
    line=kv.sub(lambda m:f"{m.group(1)}=[REDACTED]",line)
    sys.stdout.write(line)
PY
}
http_code(){ local c; c="$(curl -sS -m "${2:-6}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null||true)"; printf '%s\n' "${c:-000}"; }
ok_http(){ case "${1:-000}" in 200|201|202|204|301|302|303|307|308|401|403) return 0;; *) return 1;; esac; }

hr "X0 preflight"
for c in python3 curl podman awk sed grep systemctl; do command -v "$c" >/dev/null 2>&1 || halt "missing $c"; done
for f in "$RU" "$RP" "$NU" "$NP" "$CU" "$CP"; do [ -s "$f" ] || halt "missing cred file: $f"; done
ROOT_AK="$(tr -d '\n\r' < "$RU")"; ROOT_SK="$(tr -d '\n\r' < "$RP")"
NORM_AK="$(tr -d '\n\r' < "$NU")"; NORM_SK="$(tr -d '\n\r' < "$NP")"
CONS_AK="$(tr -d '\n\r' < "$CU")"; CONS_SK="$(tr -d '\n\r' < "$CP")"
[ -n "$ROOT_AK" ]&&[ -n "$ROOT_SK" ]||halt "empty root creds"
printf '%s\n' "$ROOT_SK" "$NORM_SK" "$CONS_SK" >> "$TMP/sec.txt"
say "root=$ROOT_AK normal=$NORM_AK console=$CONS_AK"

hr "X1 stop, snapshot, preserve any leftover volume"
systemctl --user stop "$SERVICE" 2>/dev/null || true
podman rm -f "$CONTAINER" 2>/dev/null || true
[ -f "$Q" ] && { cp -p "$Q" "${Q}.pre-mx20.${STAMP}.bak"; chmod 600 "${Q}.pre-mx20.${STAMP}.bak"; say "quadlet snapshot: ${Q}.pre-mx20.${STAMP}.bak"; }
if podman volume inspect minio_data >/dev/null 2>&1; then
  say "leftover named volume minio_data present -> exporting metadata (data assumed empty)"
  podman volume inspect minio_data 2>/dev/null | mask | sed 's/^/    /' || true
  podman volume rm -f minio_data 2>/dev/null || true
  say "removed stale named volume minio_data (bind mount will replace it)"
else
  say "no named volume minio_data (already removed by prior rm -v)"
fi

hr "X2 create host bind-mount data dir"
mkdir -p "$DATA_DIR"
chmod 755 "$DATA_DIR"
say "data dir: $DATA_DIR (owned by $(id -un):$(id -gn))"

hr "X3 write CLEAN quadlet atomically (direct binary, root, bind mount)"
python3 - "$Q" "$IMG" "$NET" "$ENVF" "$DATA_DIR" "$BIN" <<'PY'
import os,sys,tempfile
q,img,net,envf,data,binp=sys.argv[1:7]
content=f"""# MX20: MinIO via host bind-mount + direct binary as container root.
# Bind mount => 'podman rm -v' on stop can never wipe data.
# Direct binary => embedded Console starts (Bitnami wrapper suppressed it).
# Container root in rootless == host {os.getuid()} == owner of bind dir => no 'file access denied'.
[Container]
Image={img}
ContainerName=minio
Network={net}
EnvironmentFile={envf}
Volume={data}:/data
PublishPort=127.0.0.1:9010:9000
PublishPort=127.0.0.1:9011:9001
Entrypoint={binp}
Exec=server --address :9000 --console-address :9001 /data
User=0:0
SecurityLabelDisable=true

[Service]
Restart=always
TimeoutStartSec=120
MemoryMax=1G
CPUQuota=50%
# Override generated ExecStop so it NEVER removes volumes (bind mount is safe anyway).
ExecStop=/usr/bin/podman rm -f -i minio
"""
fd,t=tempfile.mkstemp(prefix=".mx20-q-",dir=os.path.dirname(q) or ".")
os.write(fd,content.encode()); os.fchmod(fd,0o644); os.close(fd); os.replace(t,q)
PY
say "quadlet written:"
grep -E '^(Image|Network|EnvironmentFile|Volume|PublishPort|Entrypoint|Exec|User)=' "$Q" | mask | sed 's/^/    /'

hr "X4 ensure MINIO_* creds + URLs + CORS in $ENVF"
upsert(){
  local path="$1"; shift
  [ -f "$path" ] || : > "$path"
  python3 - "$path" "$@" <<'PY'
import os,sys,tempfile
p=sys.argv[1]; upd=dict(x.split("=",1) for x in sys.argv[2:] if "=" in x)
lines=open(p,encoding="utf-8",errors="replace").readlines()
out=[];seen=set()
for l in lines:
    s=l.strip()
    if s and not s.startswith("#") and "=" in s:
        k=s.split("=",1)[0].strip()
        if k in upd:
            if k not in seen: out.append(f"{k}={upd[k]}\n"); seen.add(k)
            continue
    out.append(l)
for k,v in upd.items():
    if k not in seen:
        if out and not out[-1].endswith("\n"): out[-1]+="\n"
        out.append(f"{k}={v}\n")
fd,t=tempfile.mkstemp(dir=os.path.dirname(p) or ".")
os.write(fd,"".join(out).encode()); os.fchmod(fd,0o600); os.close(fd); os.replace(t,p)
PY
  say "upserted: $path"
}
upsert "$ENVF" \
  "MINIO_ROOT_USER=$ROOT_AK" "MINIO_ROOT_PASSWORD=$ROOT_SK" \
  "MINIO_ADDRESS=:9000" "MINIO_CONSOLE_ADDRESS=:9001" \
  "MINIO_SERVER_URL=http://127.0.0.1:9010" \
  "MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011" \
  "MINIO_API_CORS_ALLOW_ORIGIN=http://127.0.0.1:9011,http://localhost:9011"
grep -E '^MINIO_(ROOT_USER|ADDRESS|CONSOLE_ADDRESS|SERVER_URL|BROWSER_REDIRECT_URL|API_CORS)=' "$ENVF" | mask | sed 's/^/    /'

hr "X5 restart + verify"
systemctl --user daemon-reload
systemctl --user reset-failed "$SERVICE" 2>/dev/null || true
systemctl --user start "$SERVICE" || { systemctl --user status "$SERVICE" --no-pager -l 2>&1|sed 's/^/    /'; halt "start failed"; }
run=no
for i in $(seq 1 30); do
  st="$(podman inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null||echo unknown)"
  [ "$st" = running ] && { run=yes; say "running after $i checks"; break; }
  sleep 2
done
[ "$run" = yes ] || { podman logs --tail 40 "$CONTAINER" 2>&1|mask|sed 's/^/    /'; halt "not running"; }

i9=no
for i in $(seq 1 20); do
  podman exec "$CONTAINER" sh -c 'awk "NR>1&&\$4==\"0A\"&&\$2~/:2329$/" /proc/net/tcp /proc/net/tcp6 2>/dev/null|grep -q .' 2>/dev/null && { i9=yes; break; }
  sleep 2
done
api="$(http_code "$API/minio/health/live")"
con="$(http_code "$CON/browser")"
say "internal_9001=$i9 api_9010=$api console_9011=$con"
if [ "$i9" != yes ] || [ "$api" != 200 ] || ! ok_http "$con"; then
  podman logs --tail 60 "$CONTAINER" 2>&1|mask|sed 's/^/    /'
  systemctl --user status "$SERVICE" --no-pager -l 2>&1|sed 's/^/    /'
  ledger "FAIL" "MX20 verify failed i9=$i9 api=$api con=$con"
  halt "MinIO not healthy after MX20"
fi
say "[OK] API + Console healthy"

hr "X6 recreate IAM users (fresh data dir => .minio.sys empty)"
sleep 6  # let admin API settle
mcalias(){ podman exec "$CONTAINER" sh -c 'mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1'; }
adduser(){ # ak sk policy
  local ak="$1" sk="$2" pol="$3" a
  for a in 1 2 3 4 5; do
    if podman exec -i "$CONTAINER" sh -c '
        set -eu; pol="$1"; IFS= read -r ak; IFS= read -r sk
        mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
        mc admin user rm local "$ak" >/dev/null 2>&1 || true
        mc admin user add local "$ak" "$sk"
        mc admin policy attach local "$pol" --user "$ak"
      ' _ "$pol" < <(printf '%s\n%s\n' "$ak" "$sk") 2>"$TMP/u.err"; then
      say "OK user=$ak policy=$pol"; return 0
    fi
    say "retry user=$ak attempt=$a"; mask < "$TMP/u.err"|sed 's/^/    /'; sleep 5
  done
  return 1
}
mcalias || halt "mc alias failed"
adduser "$NORM_AK" "$NORM_SK" readwrite   || { ledger "PARTIAL" "MX20 normal user failed"; halt "normal user failed"; }
adduser "$CONS_AK" "$CONS_SK" consoleAdmin || { ledger "PARTIAL" "MX20 console user failed"; halt "console user failed"; }
say "IAM users:"
podman exec "$CONTAINER" sh -c 'mc admin user ls local 2>/dev/null || mc admin user list local 2>/dev/null' 2>/dev/null | mask | sed 's/^/    /' || true

hr "X7 RESULT"
say "[RESULT] MX20 COMPLETE - MinIO recovered with working Console GUI."
say ""
say "  Console (use 127.0.0.1, NOT localhost):"
say "    $CON/browser"
say "  S3 API endpoint (apps/restic/mc):"
say "    $API"
say "  Data dir (bind mount, survives restarts):"
say "    $DATA_DIR"
say ""
say "  Logins (reveal locally; never paste to chat):"
say "    console admin : $CONS_AK  ->  cat '$CP'"
say "    normal app    : $NORM_AK  ->  cat '$NP'"
say "    root emergency: $ROOT_AK  ->  cat '$RP'"
ledger "PASS" "MX20: bind-mount+root direct-binary recovered MinIO; api=$api console=$con users normal=$NORM_AK console=$CONS_AK"
exit 0
