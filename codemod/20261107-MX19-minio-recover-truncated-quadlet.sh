#!/usr/bin/env bash
# 20261107-MX19 — recover MinIO after MX18 truncated the quadlet mid-write.
# Restores best backup, re-applies Entrypoint/Exec override ATOMICALLY,
# ensures root creds + canonical Console URLs in referenced env file(s),
# clean restarts, verifies. Data volume untouched. Secrets masked.
set -uo pipefail
umask 077

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
Q="$HOME_/.config/containers/systemd/minio.container"
CONTAINER=minio
SERVICE=minio.service
API="http://127.0.0.1:9010"
CON="http://127.0.0.1:9011"
TOKEN="mx19-minio-recover-truncated-quadlet-v1"
STAMP="$(date +%Y%m%d-%H%M%S)"
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

# --- credential files (from MX14) ---
RU="$SEC/minio-root.user"; RP="$SEC/minio-root.pass"
[ -s "$RU" ] && [ -s "$RP" ] || halt "missing root cred files; cannot proceed safely"
ROOT_AK="$(tr -d '\n\r' < "$RU")"; ROOT_SK="$(tr -d '\n\r' < "$RP")"
printf '%s\n' "$ROOT_SK" >> "$TMP/sec.txt"

hr "R0 pick best backup"
BEST=""
while IFS= read -r b; do
  [ -n "$b" ] || continue
  if grep -q '^\[Container\]' "$b" 2>/dev/null && grep -q '^Image=' "$b" 2>/dev/null; then
    BEST="$b"; break
  fi
done < <(ls -1t "$Q".pre-mx*.bak 2>/dev/null)

[ -n "$BEST" ] || halt "no valid quadlet backup found (looked for $Q.pre-mx*.bak)"
say "best backup: $BEST"

hr "R1 restore + atomic re-patch"
cp -p "$BEST" "$Q.restored.$$"
python3 - "$Q.restored.$$" <<'PY'
import sys,re
p=sys.argv[1]
t=open(p,encoding="utf-8",errors="replace").read()
t=re.sub(r'(?m)^Entrypoint=.*$','',t)
t=re.sub(r'(?m)^Exec=.*$','',t)
t=t.replace("[Container]","[Container]\nEntrypoint=/opt/bitnami/minio/bin/minio\nExec=server --address :9000 --console-address :9001 /data",1)
t=re.sub(r'\n{3,}','\n\n',t)
open(p,"w",encoding="utf-8").write(t)
PY
mv -f "$Q.restored.$$" "$Q"   # atomic replace
chmod 644 "$Q"
say "quadlet restored + patched atomically"
grep -E '^(Image|Network|EnvironmentFile|Volume|PublishPort|Entrypoint|Exec)=' "$Q" | mask | sed 's/^/    /'

hr "R2 ensure root creds + canonical URLs in referenced env file(s)"
upsert(){
  local path="$1"; shift
  [ -f "$path" ] || return 0
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

mapfile -t ENVS < <(awk -F= '/^[[:space:]]*EnvironmentFile[[:space:]]*=/{gsub(/^[^=]+=/,"");gsub(/[[:space:]]/,"");print}' "$Q")
[ "${#ENVS[@]}" -gt 0 ] || ENVS=("$HOME_/.config/aether/secrets.env" "$SEC/aether.env")
for e in "${ENVS[@]}"; do
  [ -f "$e" ] || continue
  upsert "$e" \
    "MINIO_ROOT_USER=$ROOT_AK" "MINIO_ROOT_PASSWORD=$ROOT_SK" \
    "MINIO_ADDRESS=:9000" "MINIO_CONSOLE_ADDRESS=:9001" \
    "MINIO_SERVER_URL=http://127.0.0.1:9010" \
    "MINIO_BROWSER_REDIRECT_URL=http://127.0.0.1:9011"
done

hr "R3 clean restart"
systemctl --user stop "$SERVICE" 2>/dev/null || true
podman rm -f "$CONTAINER" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user reset-failed "$SERVICE" 2>/dev/null || true
systemctl --user start "$SERVICE" || { podman logs --tail 30 "$CONTAINER" 2>&1 | mask | sed 's/^/    /'; halt "start failed"; }

ok=no
for i in $(seq 1 30); do
  st="$(podman inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
  [ "$st" = running ] && { ok=yes; say "running after ${i} checks"; break; }
  sleep 2
done
[ "$ok" = yes ] || { systemctl --user status "$SERVICE" --no-pager -l 2>&1 | sed 's/^/    /'; halt "container not running"; }

hr "R4 verify"
i9=no
podman exec "$CONTAINER" sh -c 'awk "NR>1 && \$4==\"0A\" && \$2 ~ /:2329$/" /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -q .' 2>/dev/null && i9=yes
api="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$API/minio/health/live" 2>/dev/null || echo 000)"
con="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$CON/browser" 2>/dev/null || echo 000)"
say "internal_9001=$i9  api_9010=$api  console_9011=$con"

if [ "$i9" = yes ] && [ "$api" = 200 ] && [ "$con" != 000 ]; then
  hr "R5 RESULT"
  say "[RESULT] MX19 COMPLETE - MinIO recovered; Console live."
  say "  Open: $CON/browser"
  say "  Login: conX / $(printf '%s' "cat $SEC/minio-users/minio-console-admin.pass")"
  ledger "PASS" "MX19 recovered truncated quadlet from $BEST; internal9001=$i9 api=$api console=$con"
  exit 0
fi

say "[FAIL] not fully healthy. Diagnostics:"
podman logs --tail 60 "$CONTAINER" 2>&1 | mask | sed 's/^/    /'
systemctl --user status "$SERVICE" --no-pager -l 2>&1 | sed 's/^/    /'
ledger "FAIL" "MX19 recovery incomplete: i9=$i9 api=$api con=$con"
halt "see diagnostics above"
