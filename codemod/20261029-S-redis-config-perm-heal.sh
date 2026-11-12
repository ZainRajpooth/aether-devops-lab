#!/usr/bin/env bash
# 20261029-S — redis brick 4 evidence-based heal from R.
# Root cause: official redis entrypoint must chown/chmod mounted redis.conf before dropping to redis user.
# Previous :ro mount made the 0600 config unreadable after privilege drop:
#   Fatal error, can't open config file '/etc/redis/redis.conf': Permission denied
# Heal: rw config mount + atomic extractor rewrite; file remains 0600 outside repo.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no sudo; no secret echo; no heredoc inside $( ).
set -uo pipefail
DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; IDX="$CD/INDEX.md"
SRC="$A/legacy/compose/recovery-runtime.yml"
PYX="$CD/lib/redis_extract.py"; PYX_BAK="$PYX.pre-S.bak"
REDIRC="$HOME/.config/aether/redis"; CONF="$REDIRC/redis.conf"
UNIT="$QD/redis.container"; UNIT_BAK="$UNIT.pre-S.bak"
BIN="$A/bin"; DATAPATH="/data"
WORK="$REDIRC/work.S.$$"; SUM="$WORK/summary.txt"
PPYX="/tmp/redis_extract.proposed.$$.py"
PUNIT="/tmp/redis.container.proposed.$$.txt"
SLUG="20261029-S-redis-heal"
GREEN_TOKEN="redis brick4 GREEN"
DEFECT_TOKEN="redis-config-ro-entrypoint-defect"
DISK_TOKEN="disk-pressure-85pct-home-restic-absent"

say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }
is_uint(){ case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
unit_state(){
  local s
  s=$(systemctl --user is-active redis.service 2>/dev/null || true)
  s=$(norm "$s")
  if [ -z "$s" ]; then
    s=inactive
  fi
  printf '%s' "$s"
}
container_status(){
  local s
  s=$(podman inspect redis --format '{{.State.Status}}' 2>/dev/null || true)
  s=$(norm "$s")
  if [ -z "$s" ]; then
    s=absent
  fi
  printf '%s' "$s"
}
conf_has_auth(){
  if [ -s "$1" ]; then
    grep -Eq '^requirepass[[:space:]]' "$1" 2>/dev/null
    return $?
  fi
  return 1
}
sumval(){
  local key="$1"
  if [ -s "$SUM" ]; then
    grep "^${key}=" "$SUM" 2>/dev/null | head -n1 | cut -d= -f2- || true
  fi
}
cleanup_all(){
  rm -rf "$WORK" 2>/dev/null || true
  rm -f "$PPYX" "$PUNIT" 2>/dev/null || true
}
trap cleanup_all EXIT

# ===================== [S0] protective stop + disk gate =====================
say "=== [S0] protective stop + disk gate ==="
if [ "$DRY" = 0 ]; then
  systemctl --user stop redis.service 2>/dev/null || true
  systemctl --user reset-failed redis.service 2>/dev/null || true
  sleep 1
else
  say "[S0] dry-run: no stop/reset"
fi

ACT0=$(unit_state)
CST0=$(container_status)
say "[S0] unit_active=$ACT0 container=$CST0"

MNT_WV=$(podman volume inspect weaviate_data --format '{{.Mountpoint}}' 2>/dev/null || true)
MNT_WV=$(norm "$MNT_WV")
df_line(){ df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $3,$4,$5}'; }
read -r wv_used wv_avail WP <<<"$(df_line "${MNT_WV:-/}")"
WP=$(norm "${WP:-?}")
read -r ho_used ho_avail HP <<<"$(df_line /home)"
HP=$(norm "${HP:-?}")
read -r ro_used ro_avail RP <<<"$(df_line /)"
RP=$(norm "${RP:-?}")
gib(){ awk -v k="${1:-0}" 'BEGIN{printf "%.1fGiB", k/1048576}'; }
RESTIC_SCRIPT=$([ -f "$BIN/40_restic_dr.sh" ] && echo present || echo ABSENT)
RESTIC_UNIT=$(systemctl --user is-enabled aether-backup.service 2>/dev/null || true)
RESTIC_UNIT=$(norm "$RESTIC_UNIT")
if [ -z "$RESTIC_UNIT" ]; then
  RESTIC_UNIT=unknown
fi

BUCKET="UNKNOWN"
case "$WP" in
  ''|*[!0-9]*)
    BUCKET="UNKNOWN (df unreadable)"
    ;;
  *)
    if [ "$WP" -ge 90 ]; then
      BUCKET="RED>=90 weaviate shards read-only risk"
    elif [ "$WP" -ge 80 ]; then
      BUCKET="AMBER 80-89 (weaviate already warn)"
    elif [ "$WP" -ge 70 ]; then
      BUCKET="YELLOW 70-79"
    else
      BUCKET="GREEN <70"
    fi
    ;;
esac

say "[S0] weaviate-vol-fs(${MNT_WV:-?}): used=$(gib "$wv_used") avail=$(gib "$wv_avail") =${WP}% | /home =${HP}% (avail $(gib "$ho_avail")) | / =${RP}% (avail $(gib "$ro_avail"))"
say "[S0] restic DR: bin/40_restic_dr.sh=$RESTIC_SCRIPT  aether-backup.service=$RESTIC_UNIT"
say "[S0] OLLAMA GATE := $BUCKET — no model pull until restic present+enabled AND projected post-pull use <85%."

if [ "$DRY" = 0 ]; then
  if ! grep -qF "$DISK_TOKEN" "$IDX" 2>/dev/null; then
    echo "| $(date +%F) | CORRECTION | $DISK_TOKEN | APPEND-ONLY | [S0] measured weaviate-vol-fs=${WP}% /home=${HP}% /=${RP}%; restic bin/40_restic_dr.sh=$RESTIC_SCRIPT aether-backup.service=$RESTIC_UNIT. OLLAMA GATE=$BUCKET. Weaviate doc: 80% warn, 90% shards read-only; compaction/backups need free space. |" >> "$IDX"
    say "[S0] disk-pressure ledger row appended."
  else
    say "[S0] disk-pressure ledger row already present."
  fi
else
  say "[S0] dry-run: would append disk row if absent"
fi

# ===================== [S1] proposed extractor: atomic conf replacement =====================
say "=== [S1] extractor: atomic conf replacement ==="
mkdir -p "$CD/lib"

cat > "$PPYX" <<'PYEOF'
import sys,os,re,tempfile

src,sec,datapath,redirc,work=sys.argv[1:6]
os.makedirs(redirc,exist_ok=True)
os.chmod(redirc,0o700)
os.makedirs(work,exist_ok=True)
os.chmod(work,0o700)

TL=re.compile(r'^"?([A-Za-z_]+)"?:\s*$')
SVC=re.compile(r'^  "?([A-Za-z0-9_.-]+)"?:\s*$')
SUB=re.compile(r'^    "?([A-Za-z_]+)"?:\s*$')
IT=re.compile(r'^\s+- "?([^"]*)"?\s*$')
ENVKV=re.compile(r'^      "([^"]+)": "(.*)"$')

def tlk(l):
    m=TL.match(l)
    if m:
        return m.group(1)
    return None

def unesc(s):
    o=[]
    i=0
    while i<len(s):
        c=s[i]
        if c=='\\' and i+1<len(s):
            n=s[i+1]
            if n=='n':
                o.append('\n'); i+=2; continue
            if n=='r':
                o.append('\r'); i+=2; continue
            if n=='t':
                o.append('\t'); i+=2; continue
            if n=='"':
                o.append('"'); i+=2; continue
            if n=='\\':
                o.append('\\'); i+=2; continue
            o.append(c); i+=1; continue
        o.append(c); i+=1
    return ''.join(o)

argv=[]
n8n_pass=None
n8n_key=None
cur=None
sub=None

for raw in open(src,encoding='utf-8'):
    l=raw.rstrip('\n')
    k=tlk(l)
    if k=='services':
        cur=None
        sub=None
        continue
    sm=SVC.match(l)
    if sm:
        cur=sm.group(1)
        sub=None
        continue
    sb=SUB.match(l)
    if sb:
        sub=sb.group(1)
        continue
    if cur=='redis' and sub=='command':
        it=IT.match(l)
        if it:
            argv.append(it.group(1))
    if cur=='n8n' and sub=='environment':
        m=ENVKV.match(l)
        if m and 'redis' in m.group(1).lower() and ('pass' in m.group(1).lower() or 'pwd' in m.group(1).lower()):
            if n8n_key is None:
                n8n_key=m.group(1)
            n8n_pass=unesc(m.group(2))

P_argv=None
i=0
conf_flags=[]
while i<len(argv):
    w=argv[i]
    if w=='redis-server':
        i+=1
        continue
    if w.startswith('--'):
        name=w[2:]
        vals=[]
        i+=1
        while i<len(argv) and not argv[i].startswith('--') and argv[i]!='redis-server':
            vals.append(argv[i])
            i+=1
        if name=='requirepass':
            P_argv=(vals[0] if vals else '')
        else:
            conf_flags.append((name,vals))
    else:
        conf_flags.append(('<positional '+w,[]))
        i+=1

has_auth=(P_argv is not None) or (n8n_pass is not None)
mismatch=(P_argv is not None and n8n_pass is not None and P_argv!=n8n_pass)

if P_argv not in (None,''):
    P=P_argv
    source='argv'
elif n8n_pass not in (None,''):
    P=n8n_pass
    source='n8n-env'
else:
    P=''
    source='none'

ALLOW = {
    "masterauth",
    "bind",
    "port",
    "protected-mode",
    "timeout",
    "tcp-keepalive",
    "databases",
    "save",
    "appendonly",
    "appendfsync",
    "no-appendfsync-on-rewrite",
    "auto-aof-rewrite-percentage",
    "auto-aof-rewrite-min-size",
    "maxmemory",
    "maxmemory-policy",
    "hz",
    "loglevel",
    "logfile",
    "syslog-enabled",
    "syslog-ident",
    "syslog-facility",
    "dir",
    "client-output-buffer-limit",
    "slowlog-log-slower-than",
    "slowlog-max-len",
    "latency-monitor-history-limit",
    "activedefrag",
    "active-defrag-threshold-lower",
    "active-defrag-threshold-upper",
    "active-defrag-ignore-bytes",
    "active-defrag-cycle-min",
    "active-defrag-cycle-max",
    "active-defrag-max-scan-fields",
    "lua-time-limit",
    "replica-serve-stale-data",
    "replica-read-only",
    "replicas-ignore-maxmemory",
    "repl-diskless-load",
    "repl-diskless-sync",
    "repl-diskless-sync-delay",
    "repl-backlog-size",
    "repl-backlog-ttl",
    "repl-ping-replica-period",
    "min-replicas-to-write",
    "min-replicas-max-lag",
    "notify-keyspace-events",
    "io-threads",
    "io-threads-do-reads",
    "enable-debug-command",
    "enable-module-command",
    "enable-protected-configs",
    "proto-max-bulk-len",
    "maxmemory-samples",
    "jemalloc-bg-thread",
}
DENY={"version","help","v","sentinel","check-single-config","test"}
unknown=sorted(set(n for n,_ in conf_flags if (n in DENY) or n.startswith('<positional') or n not in ALLOW))

status='OK'
halt_reason=''
if mismatch:
    status='HALT'
    halt_reason='argv requirepass differs from n8n redis-password env (capture internally inconsistent); not auto-picking'
elif unknown:
    status='HALT'
    halt_reason='unmapped redis flag(s): '+', '.join(unknown)

final_pass=''
if status=='OK':
    lines=open(sec,encoding='utf-8').read().split('\n') if os.path.isfile(sec) else []
    have=any(re.match(r'^REDIS_PASSWORD=',x) for x in lines)
    if has_auth and P:
        if not have:
            if lines and lines[-1]!='':
                lines.append('')
            ins=(len(lines)-1) if (lines and lines[-1]=='') else len(lines)
            lines.insert(ins,'REDIS_PASSWORD='+P)
            with open(sec,'w',encoding='utf-8') as f:
                f.write('\n'.join(lines))
            os.chmod(sec,0o600)
        for x in open(sec,encoding='utf-8'):
            m=re.match(r'^REDIS_PASSWORD=(.*)$',x.rstrip('\n'))
            if m:
                final_pass=m.group(1)
                break
        if not final_pass:
            final_pass=P
        if final_pass and re.search(r'[\s"\\#]', final_pass):
            status='HALT'
            halt_reason='requirepass contains whitespace/quote/backslash/hash; not safe for unquoted redis.conf line'
    elif has_auth and not P:
        status='HALT'
        halt_reason='has_auth but no recoverable password (argv and n8n env both empty)'

if status=='OK':
    cl=[]
    seen_dir=False
    for n,vals in conf_flags:
        if n=='dir':
            seen_dir=True
            cl.append('dir '+datapath)
            continue
        if vals:
            cl.append(n+' '+' '.join(vals))
        else:
            cl.append(n)
    if not seen_dir:
        cl.append('dir '+datapath)
    if has_auth and final_pass:
        cl.append('requirepass '+final_pass)

    conf_path=os.path.join(redirc,'redis.conf')
    fd,tmp=tempfile.mkstemp(dir=redirc, prefix='.redis.conf.', text=True)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            f.write('\n'.join(cl)+'\n')
        os.chmod(tmp,0o600)
        os.replace(tmp,conf_path)
    except Exception as e:
        if os.path.exists(tmp):
            os.unlink(tmp)
        status='HALT'
        halt_reason='atomic conf write failed: '+str(e)

av='na'
if P_argv is not None and n8n_pass is not None:
    if P_argv==n8n_pass:
        av='match'
    else:
        av='mismatch'

PASS_SHAPE='absent'
if final_pass:
    PASS_LEN=len(final_pass)
    PASS_HAS_SPACE='yes' if re.search(r'\s', final_pass) else 'no'
    PASS_QUOTED='no'
    if len(final_pass)>=2:
        if (final_pass[0]=='"' and final_pass[-1]=='"') or (final_pass[0]=="'" and final_pass[-1]=="'"):
            PASS_QUOTED='yes'
    PASS_SHAPE='len='+str(PASS_LEN)+' has_space='+PASS_HAS_SPACE+' quoted='+PASS_QUOTED

with open(os.path.join(work,'summary.txt'),'w',encoding='utf-8') as f:
    f.write('has_auth=%s\n'%('yes' if has_auth else 'no'))
    f.write('auth_source=%s\n'%source)
    f.write('argv_vs_n8n=%s\n'%av)
    f.write('n8n_redis_env_key=%s\n'%(n8n_key or ''))
    f.write('flags=%s\n'%' '.join(n for n,_ in conf_flags))
    f.write('requirepass_shape=%s\n'%PASS_SHAPE)
    f.write('status=%s\n'%status)
    if halt_reason:
        f.write('halt_reason=%s\n'%halt_reason)

open(os.path.join(work,'status'),'w',encoding='utf-8').write(status+'\n')
sys.exit(0 if status=='OK' else 2)
PYEOF

if ! python3 -m py_compile "$PPYX"; then
  halt "proposed extractor failed py_compile; no persistent change"
fi

if [ "$DRY" = 1 ]; then
  say "[S1] dry-run: proposed extractor py_compile OK"
  if [ -f "$PYX" ]; then
    diff -u "$PYX" "$PPYX" | sed 's/^/    /' || true
  else
    say "[S1] dry-run: no current extractor; proposed would be installed"
  fi
else
  mkdir -p "$REDIRC"
  chmod 700 "$REDIRC"
  if [ -f "$PYX" ]; then
    if [ ! -f "$PYX_BAK" ]; then
      cp -p "$PYX" "$PYX_BAK"
      say "[S1] extractor backup -> $PYX_BAK"
    fi
  fi
  cp -p "$PPYX" "$PYX"
  if ! python3 -m py_compile "$PYX"; then
    if [ -f "$PYX_BAK" ]; then
      cp -p "$PYX_BAK" "$PYX"
    fi
    halt "installed extractor failed py_compile; restored backup if present"
  fi
  say "[S1] installed $PYX; py_compile OK"
fi

# ===================== [S2] derive conf (real only) =====================
say "=== [S2] derive redis.conf ==="
if [ "$DRY" = 1 ]; then
  say "[S2] dry-run: would run installed extractor to derive $CONF atomically"
  if [ -s "$CONF" ]; then
    sed -E 's/^requirepass[[:space:]].*/requirepass ***/' "$CONF" | head -n 20 | sed 's/^/    /' || true
  else
    say "    current conf absent"
  fi
  CONF_AUTH=no
  if conf_has_auth "$CONF"; then
    CONF_AUTH=yes
  fi
  AUTHSRC="dry-run"
  PASS_SHAPE_NORM="dry-run"
else
  mkdir -p "$WORK"
  chmod 700 "$WORK"
  python3 "$PYX" "$SRC" "$SECRETS" "$DATAPATH" "$REDIRC" "$WORK"
  XRC=$?
  STATUS=$(sumval status)
  STATUS=$(norm "$STATUS")
  if [ -z "$STATUS" ]; then
    STATUS=MISSING
  fi
  if [ "$STATUS" != OK ]; then
    REASON=$(sumval halt_reason)
    REASON=$(norm "$REASON")
    halt "extractor status=$STATUS rc=$XRC reason=${REASON:-none}. No unit change."
  fi
  CONF_AUTH=no
  if conf_has_auth "$CONF"; then
    CONF_AUTH=yes
  fi
  PASS_SHAPE=$(sumval requirepass_shape)
  PASS_SHAPE_NORM=$(norm "$PASS_SHAPE")
  AUTHSRC=$(sumval auth_source)
  AUTHSRC=$(norm "$AUTHSRC")
  say "[S2] conf derived; conf_auth=$CONF_AUTH requirepass_shape=$PASS_SHAPE_NORM auth_source=$AUTHSRC"
fi

# ===================== [S3] proposed unit with rw config mount =====================
say "=== [S3] redis.unit: rw config mount ==="
IMG=""
if [ -f "$UNIT" ]; then
  IMG=$(awk -F= '/^Image=/{print $2; exit}' "$UNIT" 2>/dev/null || true)
  IMG=$(norm "$IMG")
fi
if [ -z "$IMG" ]; then
  IMG="docker.io/library/redis:alpine"
fi

if [ "$DRY" = 0 ]; then
  if ! podman image exists "$IMG"; then
    PULLERR="/tmp/redis-pull.$$.err"
    if ! podman pull "$IMG" >"$PULLERR" 2>&1; then
      LAST=$(tail -n1 "$PULLERR" 2>/dev/null || true)
      rm -f "$PULLERR"
      halt "image not present and pull failed: $(norm "$LAST")"
    fi
    rm -f "$PULLERR"
  fi
else
  if podman image exists "$IMG"; then
    say "[S3] dry-run: image present $IMG"
  else
    say "[S3] dry-run: image would be pulled $IMG"
  fi
fi

MM_MB=$(awk '
/^maxmemory[[:space:]]+/ {
  v=$2; u=tolower(v); gsub(/[^0-9.]/,"",v);
  if (u ~ /kb$/) { m=1/1024 }
  else if (u ~ /mb$/) { m=1 }
  else if (u ~ /gb$/) { m=1024 }
  else { m=1 }
  printf "%d", (v*m + 0.999999)
  exit
}
' "$CONF" 2>/dev/null || true)
MM_MB=$(norm "$MM_MB")
if ! is_uint "$MM_MB"; then
  MM_MB=256
fi
CEIL_MB=$(( (MM_MB * 3 + 1) / 2 ))
if [ "$CEIL_MB" -lt 256 ]; then
  CEIL_MB=256
fi

cat > "$PUNIT" <<UNIT
# STATEFUL brick 4 (redis). Auth via derived 0600 conf (secrets.env canonical; rotation = edit secrets.env + re-run).
# No literal secret in this unit. The config mount is rw because the official redis entrypoint must chown/chmod
# the config file before dropping from root to the redis user. A ro mount leaves the 0600 file unreadable after
# privilege drop and produces: Fatal error, can't open config file ... Permission denied. The file remains outside
# the repo and 0600; the extractor replaces it atomically so future rotations work after entrypoint chown.
# Host-publish LOOPBACK-only; n8n reaches redis over the aether net by hostname redis:6379.
# dir is forced to $DATAPATH (= the redis_data volume) so persistence is on the volume.
# Image: $IMG. auth_source=$AUTHSRC requirepass_shape=$PASS_SHAPE_NORM
[Container]
Image=$IMG
ContainerName=redis
Network=aether
EnvironmentFile=$SECRETS
Volume=redis_data:$DATAPATH
Volume=$CONF:/etc/redis/redis.conf:rw
PublishPort=127.0.0.1:6379:6379
Exec=redis-server /etc/redis/redis.conf

[Service]
Restart=always
TimeoutStartSec=60
MemoryMax=${CEIL_MB}M
CPUQuota=25%
UNIT

if [ "$DRY" = 1 ]; then
  say "[S3] dry-run: proposed unit diff vs current (no write):"
  if [ -f "$UNIT" ]; then
    diff -u "$UNIT" "$PUNIT" | sed 's/^/    /' || true
  else
    sed 's/^/    /' "$PUNIT" || true
  fi
  say "[RESULT] DRY-RUN complete; no extractor install, no conf write, no unit write, no start, no ledger."
  exit 0
fi

if [ -f "$UNIT" ]; then
  if [ ! -f "$UNIT_BAK" ]; then
    cp -p "$UNIT" "$UNIT_BAK"
    say "[S3] unit backup -> $UNIT_BAK"
  fi
fi
cp -p "$PUNIT" "$UNIT"
install -D -m 644 "$UNIT" "$SYS/redis.container"
systemctl --user daemon-reload
say "[S3] wrote $UNIT with rw config mount; MemoryMax=${CEIL_MB}M"

# ===================== [S4] start + readiness + auth + persistence gate =====================
say "=== [S4] start + readiness + auth + persistence gate ==="
systemctl --user enable redis.service 2>/dev/null || true
STARTERR="/tmp/redis-start.$$.err"
systemctl --user start redis.service 2>"$STARTERR" || true
if [ -s "$STARTERR" ]; then
  sed 's/^/    start-err: /' "$STARTERR" || true
fi
rm -f "$STARTERR"

UP=no
CRASH=no
PING_SEQ=""
GREEN_ITER=0
S0="absent"
for i in $(seq 1 30); do
  CST=$(container_status)
  if [ "$CST" = exited ]; then
    CRASH=yes
    break
  fi
  if [ "$CST" = running ]; then
    O=$(podman exec redis redis-cli ping 2>&1 || true)
    O=$(norm "$O")
    if [ -z "$O" ]; then
      O=empty
    fi
    PING_SEQ+="${O:0:18} "
    case "$O" in
      *PONG*|*NOAUTH*)
        UP=yes
        GREEN_ITER=$i
        break
        ;;
    esac
  else
    PING_SEQ+="not-running:$CST "
  fi
  S1=$(podman inspect redis --format '{{.State.StartedAt}}' 2>/dev/null || true)
  S1=$(norm "$S1")
  if [ -z "$S1" ]; then
    S1=absent
  fi
  if [ "$S0" = absent ] && [ "$S1" != absent ]; then
    S0="$S1"
  elif [ "$S0" != absent ] && [ "$S1" != absent ] && [ "$S1" != "$S0" ]; then
    CRASH=yes
    break
  fi
  sleep 2
done

ACT=$(unit_state)
CST=$(container_status)
RUN=$(podman ps --filter name=redis --format '{{.Names}} {{.Status}}' 2>/dev/null || true)
RUN=$(norm "$RUN")
if [ -z "$RUN" ]; then
  RUN=none
fi
PING_SEQ_SHORT=$(printf '%s' "$PING_SEQ" | cut -c1-160)

AUTHINFO="not-evaluated"
if [ "$CONF_AUTH" = yes ]; then
  if [ "$UP" = yes ] && [ "$CST" = running ]; then
    PV=$(podman exec redis sh -c 'test -n "${REDIS_PASSWORD:-}" && echo present || echo absent' 2>&1 || true)
    PV=$(norm "$PV")
    if [ "$PV" = present ]; then
      AO=$(podman exec redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping' 2>&1 || true)
      AO=$(norm "$AO")
      case "$AO" in
        *PONG*)
          AUTHINFO="key-valid"
          ;;
        *WRONGPASS*|*invalid*)
          AUTHINFO="wrongpass"
          ;;
        *)
          AUTHINFO="anomalous:${AO:0:24}"
          ;;
      esac
    else
      AUTHINFO="container-missing-REDIS_PASSWORD"
    fi
  else
    AUTHINFO="not-up"
  fi
else
  AUTHINFO="no-auth-required"
fi

PERSIST=no
PMATCH=""
while read -r typ dest; do
  if [ -z "${dest:-}" ]; then
    continue
  fi
  case "$DATAPATH" in
    "$dest"|"$dest"/*)
      if [ "$typ" = volume ] || [ "$typ" = bind ]; then
        PERSIST=yes
        PMATCH="$typ at $dest"
      fi
      ;;
  esac
done < <(podman inspect redis --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>/dev/null || true)

say "[S4] active=$ACT container=$CST up=$UP crash=$CRASH green_iter=$GREEN_ITER ping_seq=[$PING_SEQ_SHORT] auth=$AUTHINFO persist=$PERSIST match=$PMATCH run=$RUN"
journalctl --user -u redis.service -n 12 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
podman logs --tail 20 redis 2>&1 | sed 's/^/    /' || true

PASS=no
if [ "$ACT" = active ] && [ "$UP" = yes ] && [ "$PERSIST" = yes ]; then
  if [ "$CONF_AUTH" = yes ]; then
    if [ "$AUTHINFO" = key-valid ]; then
      PASS=yes
    fi
  else
    PASS=yes
  fi
fi

if [ "$PASS" != yes ]; then
  say "[S4] failure logs:"
  journalctl --user -u redis.service -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 40 redis 2>&1 | sed 's/^/    /' || true
  if [ -f "$UNIT_BAK" ]; then
    cp -p "$UNIT_BAK" "$UNIT"
    install -D -m 644 "$UNIT" "$SYS/redis.container"
    systemctl --user daemon-reload
    systemctl --user stop redis.service 2>/dev/null || true
    say "[S4] rolled back unit to $UNIT_BAK; redis.service stopped"
  fi
  halt "redis heal gate failed (active=$ACT up=$UP crash=$CRASH auth=$AUTHINFO persist=$PERSIST). See logs above; no green row written."
fi

# ===================== [S5] guarded ledger rows =====================
say "=== [S5] ledger rows ==="
if ! grep -qF "$DEFECT_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $DEFECT_TOKEN | APPEND-ONLY | Redis brick4 root cause from R cfgtest: official redis entrypoint drops to redis user and must chown/chmod mounted redis.conf; ro mount caused Fatal error can't open config file Permission denied. Heal: rw config mount + atomic extractor rewrite; file remains 0600 outside repo. |" >> "$IDX"
  say "[S5] defect correction row appended."
else
  say "[S5] defect correction row already present."
fi
grep -qF "$DEFECT_TOKEN" "$IDX" 2>/dev/null && say "[S5] suppression proof: defect sentinel present." || say "[S5] WARNING: defect sentinel missing."

if ! grep -qF "$GREEN_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | $SLUG | GATE=PASS | $GREEN_TOKEN: unauth PING up (ping_seq=[$PING_SEQ_SHORT]), auth=$AUTHINFO, data on named volume (ancestor+volume-type, DATA=$DATAPATH), loopback 6379, config mount rw for entrypoint privilege-drop, conf_auth=$CONF_AUTH, MemoryMax=${CEIL_MB}M, OLLAMA_GATE=$BUCKET; replay=$SLUG.sh |" >> "$IDX"
  say "[S5] redis green row appended."
else
  say "[S5] redis green row already present (guard suppressed)."
fi
grep -qF "$GREEN_TOKEN" "$IDX" 2>/dev/null && say "[S5] suppression proof: green sentinel present." || say "[S5] WARNING: green sentinel missing."

# ===================== [S6] replay archive =====================
cat > "$CD/${SLUG}.sh" <<'REPLAY'
#!/usr/bin/env bash
# 20261029-S-redis-heal.sh — replayable redis brick 4: derive conf atomically, render unit, start, gate.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; SRC="$A/legacy/compose/recovery-runtime.yml"
PYX="$CD/lib/redis_extract.py"; REDIRC="$HOME/.config/aether/redis"
UNIT="$QD/redis.container"; DATAPATH="/data"; WORK="$REDIRC/work.replay.$$"
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
mkdir -p "$REDIRC" "$WORK"
chmod 700 "$REDIRC" "$WORK"
systemctl --user stop redis.service 2>/dev/null || true
systemctl --user reset-failed redis.service 2>/dev/null || true
python3 "$PYX" "$SRC" "$SECRETS" "$DATAPATH" "$REDIRC" "$WORK" || { echo "  [GATE FAIL] extractor"; rm -rf "$WORK"; exit 1; }
rm -rf "$WORK"
install -D -m 644 "$UNIT" "$SYS/redis.container"
systemctl --user daemon-reload
systemctl --user enable redis.service 2>/dev/null || true
systemctl --user start redis.service
UP=no
for i in $(seq 1 30); do
  CST=$(podman inspect redis --format '{{.State.Status}}' 2>/dev/null || true)
  CST=$(norm "$CST")
  if [ "$CST" = running ]; then
    O=$(podman exec redis redis-cli ping 2>&1 || true)
    O=$(norm "$O")
    case "$O" in
      *PONG*|*NOAUTH*)
        UP=yes
        break
        ;;
    esac
  fi
  sleep 2
done
if [ "$UP" = yes ]; then
  echo "  [GATE PASS] redis up"
else
  echo "  [GATE FAIL] redis not up"
  exit 1
fi
REPLAY
chmod +x "$CD/${SLUG}.sh"
say "[S6] archived -> codemod/${SLUG}.sh"

say "[RESULT] REDIS GREEN (brick 4 healed) — config-permission root cause fixed by rw mount + atomic extractor; disk gate remains $BUCKET; next should be restic DR before ollama."
exit 0
