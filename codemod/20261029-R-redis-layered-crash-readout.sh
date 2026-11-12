#!/usr/bin/env bash
# 20261029-R — redis brick 4 layered crash read-out.
# Fixes Q's instrument gaps: --rm erased logs; journalctl --tail invalid; ownership hypothesis unproven.
# Method: stop service, read journal correctly, then run three ephemeral diagnostics without --rm:
#   1) cfgtest: same conf/env/command but dir /tmp, appendonly no -> tests config parsing only.
#   2) apptest: same conf/env/command with redis_data mounted -> tests redis + /data persistence only.
#   3) quadtest: apptest plus Quadlet-like --cgroups=split --sdnotify=conmon --network aether publish -> tests systemd/Quadlet options.
# Removes all diagnostic containers. Does NOT start redis.service, chown, re-init, or delete data.
# Hard bash rule: multi-line if/then/fi only; bash -n mandatory before run. No sudo. No secret echo. exit 0 everywhere.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; IDX="$CD/INDEX.md"
UNIT="$QD/redis.container"; CONF="$HOME/.config/aether/redis/redis.conf"
DATAPATH="/data"
R_TOKEN="redis-crash-readout-R"
LOGJ="/tmp/aether-redis-journal.$$.log"
LOGCFG="/tmp/aether-redis-cfg.$$.log"
LOGAPP="/tmp/aether-redis-app.$$.log"
LOGQ="/tmp/aether-redis-quad.$$.log"
CFG_NAME="redis-cfgtest-$$"
APP_NAME="redis-apptest-$$"
Q_NAME="redis-quadtest-$$"
say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
cleanup_all(){
  podman stop -t 3 "$CFG_NAME" >/dev/null 2>&1 || true
  podman stop -t 3 "$APP_NAME" >/dev/null 2>&1 || true
  podman stop -t 3 "$Q_NAME" >/dev/null 2>&1 || true
  podman rm -f "$CFG_NAME" >/dev/null 2>&1 || true
  podman rm -f "$APP_NAME" >/dev/null 2>&1 || true
  podman rm -f "$Q_NAME" >/dev/null 2>&1 || true
  rm -f "$LOGJ" "$LOGCFG" "$LOGAPP" "$LOGQ" 2>/dev/null || true
}
trap cleanup_all EXIT
wait_state(){
  local name="$1" limit="$2" i st
  st=absent
  for i in $(seq 1 "$limit"); do
    st=$(podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)
    st=$(norm "$st")
    if [ -z "$st" ]; then
      st=absent
    fi
    if [ "$st" = running ]; then
      printf '%s' "running"
      return 0
    fi
    if [ "$st" = exited ]; then
      printf '%s' "exited"
      return 0
    fi
    if [ "$st" = created ]; then
      printf '%s' "created"
      return 0
    fi
    sleep 1
  done
  printf '%s' "$st"
}
collect_state_logs(){
  local name="$1" logfile="$2"
  {
    echo "----- inspect $name -----"
    podman inspect "$name" --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}} started={{.State.StartedAt}}' 2>&1 || true
    echo "----- logs $name -----"
    podman logs "$name" 2>&1 || true
  } >>"$logfile"
}
ping_if_running(){
  local name="$1" state="$2" label="$3"
  if [ "$state" = running ]; then
    local p ap
    p=$(podman exec "$name" redis-cli ping 2>&1 || true)
    say "[$label] ping=$(norm "$p")"
    if [ "$CONF_AUTH" = yes ]; then
      ap=$(podman exec "$name" sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping' 2>&1 || true)
      say "[$label] auth_ping=$(norm "$ap")"
    fi
  fi
}

# ===================== [R0] freeze service, read journal with correct flags =====================
say "=== [R0] protective stop + corrected journal read-out ==="
systemctl --user stop redis.service 2>/dev/null || true
sleep 1
ACT=$(systemctl --user is-active redis.service 2>/dev/null || true); ACT=$(norm "$ACT"); [ -z "$ACT" ] && ACT=inactive
CST=$(podman inspect redis --format '{{.State.Status}}' 2>/dev/null || true); CST=$(norm "$CST"); [ -z "$CST" ] && CST=absent
NRS=$(systemctl --user show redis.service -p NRestarts --value 2>/dev/null || true); NRS=$(norm "$NRS"); [ -z "$NRS" ] && NRS=?
say "[R0] unit_active=$ACT container=$CST n_restarts=$NRS"
{
  echo "----- journalctl --user -u redis.service -n 160 -----"
  journalctl --user -u redis.service -n 160 --no-pager 2>&1 || true
  echo "----- journalctl --user -n 220 grep redis/quadlet/podman -----"
  journalctl --user -n 220 --no-pager 2>&1 | grep -iE 'redis|quadlet|podman-user-generator|unsupported key' || true
} >"$LOGJ"
JOURNAL_PRESENT=no
if [ -s "$LOGJ" ]; then
  JOURNAL_PRESENT=yes
fi
say "[R0] journal captured=$JOURNAL_PRESENT"

# ===================== [R1] resolve image + image contract + masked auth shape =====================
say "=== [R1] image contract and requirepass shape (masked) ==="
IMG=""
if [ -f "$UNIT" ]; then
  IMG=$(awk -F= '/^Image=/{print $2; exit}' "$UNIT" 2>/dev/null || true)
  IMG=$(norm "$IMG")
fi
if [ -z "$IMG" ]; then
  IMG=$(podman ps -a --filter name=redis --format '{{.Image}}' 2>/dev/null | head -n1 || true)
  IMG=$(norm "$IMG")
fi
if [ -z "$IMG" ]; then
  say "[R1] HALT cannot resolve redis image from unit or container."
  exit 0
fi
if ! podman image exists "$IMG"; then
  say "[R1] HALT image not present: $IMG"
  exit 0
fi
ICONTRACT=$(podman image inspect "$IMG" --format 'User={{.Config.User}}|EP={{.Config.Entrypoint}}|CMD={{.Config.Cmd}}|WD={{.Config.WorkingDir}}' 2>&1 || true)
say "[R1] image=$IMG"
say "[R1] image_contract=$(norm "$ICONTRACT")"
CONF_AUTH=no
if grep -Eq '^requirepass[[:space:]]' "$CONF" 2>/dev/null; then
  CONF_AUTH=yes
fi
PASS_SHAPE="absent"
PASS_HAS_SPACE=unknown
PASS_QUOTED=unknown
PASS_LINE=$(grep -E '^requirepass[[:space:]]' "$CONF" 2>/dev/null | head -n1 || true)
if [ -n "$PASS_LINE" ]; then
  PASS_VAL=${PASS_LINE#requirepass}
  PASS_VAL=${PASS_VAL#"${PASS_VAL%%[![:space:]]*}"}
  PASS_LEN=${#PASS_VAL}
  PASS_TOKENS=$(printf '%s\n' "$PASS_LINE" | awk '{print NF}')
  PASS_HAS_SPACE=no
  case "$PASS_VAL" in
    *[[:space:]]*)
      PASS_HAS_SPACE=yes
      ;;
  esac
  PASS_QUOTED=no
  PASS_FIRST=${PASS_VAL:0:1}
  PASS_LAST=${PASS_VAL: -1}
  if [ "$PASS_FIRST" = '"' ] && [ "$PASS_LAST" = '"' ]; then
    PASS_QUOTED=yes
  fi
  if [ "$PASS_FIRST" = "'" ] && [ "$PASS_LAST" = "'" ]; then
    PASS_QUOTED=yes
  fi
  PASS_SHAPE="len=$PASS_LEN tokens=$PASS_TOKENS has_space=$PASS_HAS_SPACE quoted=$PASS_QUOTED"
fi
say "[R1] conf_auth=$CONF_AUTH requirepass_shape=$PASS_SHAPE (value not printed)"

# ===================== [R2] cfgtest: config parsing only, no redis_data writes =====================
say "=== [R2] cfgtest: same conf/env/command but dir /tmp and appendonly no (no redis_data write) ==="
: >"$LOGCFG"
{
  echo "----- cfg launch -----"
} >>"$LOGCFG"
if podman run -d --replace --name "$CFG_NAME" \
  --network none \
  -v "$CONF:/etc/redis/redis.conf:ro" \
  --env-file "$SECRETS" \
  "$IMG" redis-server /etc/redis/redis.conf --dir /tmp --appendonly no >>"$LOGCFG" 2>&1; then
  say "[R2] cfgtest launched"
else
  say "[R2] cfgtest launch command returned non-zero"
fi
CFG_STATE=$(wait_state "$CFG_NAME" 12)
collect_state_logs "$CFG_NAME" "$LOGCFG"
say "[R2] cfg_state=$CFG_STATE"
ping_if_running "$CFG_NAME" "$CFG_STATE" "R2"
say "[R2] cfg log tail:"
tail -n 35 "$LOGCFG" | sed 's/^/    /' || true
podman stop -t 5 "$CFG_NAME" >/dev/null 2>&1 || true
podman rm -f "$CFG_NAME" >/dev/null 2>&1 || true

# ===================== [R3] apptest: redis + /data persistence only =====================
APP_STATE=skipped
if [ "$CFG_STATE" = running ]; then
  say "=== [R3] apptest: same conf/env/command with redis_data mounted (tests /data/AOF path) ==="
  : >"$LOGAPP"
  {
    echo "----- app launch -----"
  } >>"$LOGAPP"
  if podman run -d --replace --name "$APP_NAME" \
    --network none \
    -v redis_data:/data \
    -v "$CONF:/etc/redis/redis.conf:ro" \
    --env-file "$SECRETS" \
    "$IMG" redis-server /etc/redis/redis.conf >>"$LOGAPP" 2>&1; then
    say "[R3] apptest launched"
  else
    say "[R3] apptest launch command returned non-zero"
  fi
  APP_STATE=$(wait_state "$APP_NAME" 15)
  collect_state_logs "$APP_NAME" "$LOGAPP"
  say "[R3] app_state=$APP_STATE"
  ping_if_running "$APP_NAME" "$APP_STATE" "R3"
  say "[R3] app log tail:"
  tail -n 35 "$LOGAPP" | sed 's/^/    /' || true
  podman stop -t 5 "$APP_NAME" >/dev/null 2>&1 || true
  podman rm -f "$APP_NAME" >/dev/null 2>&1 || true
else
  say "[R3] apptest skipped because cfgtest did not reach running"
fi

# ===================== [R4] quadtest: add Quadlet-like systemd/cgroup/sdnotify options =====================
Q_STATE=skipped
if [ "$APP_STATE" = running ]; then
  say "=== [R4] quadtest: apptest plus --cgroups=split --sdnotify=conmon --network aether publish ==="
  : >"$LOGQ"
  {
    echo "----- quad launch -----"
  } >>"$LOGQ"
  if podman run -d --replace --name "$Q_NAME" \
    --network aether \
    --cgroups=split \
    --sdnotify=conmon \
    -v redis_data:/data \
    -v "$CONF:/etc/redis/redis.conf:ro" \
    --env-file "$SECRETS" \
    --publish 127.0.0.1:6399:6379 \
    "$IMG" redis-server /etc/redis/redis.conf >>"$LOGQ" 2>&1; then
    say "[R4] quadtest launched"
  else
    say "[R4] quadtest launch command returned non-zero"
  fi
  Q_STATE=$(wait_state "$Q_NAME" 15)
  collect_state_logs "$Q_NAME" "$LOGQ"
  say "[R4] quad_state=$Q_STATE"
  ping_if_running "$Q_NAME" "$Q_STATE" "R4"
  say "[R4] quad log tail:"
  tail -n 35 "$LOGQ" | sed 's/^/    /' || true
  podman stop -t 5 "$Q_NAME" >/dev/null 2>&1 || true
  podman rm -f "$Q_NAME" >/dev/null 2>&1 || true
else
  say "[R4] quadtest skipped because apptest did not reach running"
fi

# ===================== [R5] classify from verbatim evidence =====================
say "=== [R5] cause classification from journal + layered diagnostic logs ==="
CAUSE="UNKNOWN"
MATCHLINE=""
classify(){
  local name="$1" re="$2" file hit
  for file in "$LOGJ" "$LOGCFG" "$LOGAPP" "$LOGQ"; do
    if [ -s "$file" ]; then
      hit=$(grep -m1 -iE "$re" "$file" 2>/dev/null || true)
      hit=$(norm "$hit")
      if [ -n "$hit" ]; then
        say "    [$name] $hit"
        if [ "$CAUSE" = UNKNOWN ]; then
          CAUSE="$name"
          MATCHLINE="$hit"
        fi
        return 0
      fi
    fi
  done
}
classify exec_or_path 'no such file or directory|executable file not found|exec format error|standard_init_linux|gosu|su-exec|setpriv|redis\.conf: No such|cannot find the configuration'
classify config_reject 'Unsupported config option|unknown configuration|Bad directive|Invalid argument|wrong number of arguments|Unrecognized configuration|Fatal: Can.t configure|redis-server:.*error'
classify perm_denied 'Permission denied|Operation not permitted|not writable|Read-only file system|cannot open.*permission|Failed opening the append'
classify aof_fatal 'Fatal error loading append|Unexpected end of file.*append|Bad file format|Can.t open the append-only file|loading the append only file.*failed|append-only file'
classify oom 'oom=true|Out of memory|OOMKilled|Killed|memory allocation failed'
classify disk_full 'No space left on device|disk full|short write|unable to write'
classify bind_fail 'Address already in use|Could not create server TCP|bind.*failed'
if [ "$CAUSE" = UNKNOWN ]; then
  if [ "$CFG_STATE" != running ]; then
    CAUSE="cfgtest_not_running"
  elif [ "$APP_STATE" != running ]; then
    CAUSE="apptest_not_running"
  elif [ "$Q_STATE" != running ]; then
    CAUSE="quadlet_like_not_running"
  else
    CAUSE="all_diagnostics_ran"
  fi
fi
say "[R5] CAUSE=$CAUSE"
say "[R5] states cfg=$CFG_STATE app=$APP_STATE quad=$Q_STATE"

# ===================== [R6] next-turn heal, text only =====================
say "=== [R6] precise next-turn heal (text only; R executes no persistent heal) ==="
case "$CAUSE" in
  config_reject)
    if [ "$PASS_HAS_SPACE" = yes ] && [ "$PASS_QUOTED" = no ]; then
      say "    -> Likely unquoted requirepass containing spaces. Heal next turn: quote requirepass value in derived redis.conf (or move to supported env/config path), re-derive conf, start, re-gate. No data touch."
    else
      say "    -> A redis.conf directive is rejected. Heal next turn from the exact line above; adjust extractor allowlist/conf, restart, re-gate. No data touch."
    fi
    ;;
  exec_or_path)
    say "    -> Entrypoint/binary/config path issue. Heal next turn from [R1] image_contract and exact log line; likely adjust Exec= or use image-supported config injection. No data touch."
    ;;
  perm_denied)
    say "    -> /data permission issue. Heal next turn only after comparing [R1] Config.User/Entrypoint with [R3] app logs; prefer entrypoint-preserving fix over blind chown."
    ;;
  aof_fatal)
    say "    -> AOF/load issue. DATA question: do not delete/re-init without your explicit word (B13). Next turn can inspect/repair or, on approval, clean re-init this fresh redis brick."
    ;;
  oom)
    say "    -> Memory ceiling/maxmemory interaction. Heal next turn by raising MemoryMax relative to maxmemory 256mb or lowering maxmemory, then re-gate. No data touch."
    ;;
  disk_full)
    say "    -> Disk pressure. Do not advance to ollama. Next turn: restic DR / free space first. No data touch."
    ;;
  bind_fail)
    say "    -> Bind/port issue. Heal next turn from publish mapping; diagnostic used host 6399 to avoid collision. No data touch."
    ;;
  cfgtest_not_running)
    say "    -> Config-only test failed before reaching /data. Root cause is in [R2] cfg log tail above, not persistence."
    ;;
  apptest_not_running)
    say "    -> Config parses, but redis fails when using redis_data. Root cause is in [R3] app log tail above: /data, AOF, entrypoint chown/drop, or volume ownership."
    ;;
  quadlet_like_not_running)
    say "    -> Redis works app-only, but fails with Quadlet-like --cgroups=split/--sdnotify=conmon/network/publish. Root cause is systemd/Quadlet option translation, not redis data."
    ;;
  all_diagnostics_ran)
    say "    -> All diagnostic layers ran. Likely transient restart-storm state or systemd failed-unit state. Next-turn heal: reset-failed + start redis.service + re-gate; no data touch unless gate fails."
    ;;
  *)
    say "    -> HALT (B13/§7): cause not classified. Paste [R2]/[R3]/[R4] log tails and I disambiguate from evidence; no blind patch."
    ;;
esac

# ===================== [R7] guarded ledger row, sentinel IS in payload =====================
say "=== [R7] ledger (append-only; sentinel-in-payload; suppression proven in-run) ==="
if ! grep -qF "$R_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | DIAG | $R_TOKEN | APPEND-ONLY | redis brick4 layered crash read-out (R): CAUSE=$CAUSE match='${MATCHLINE:0:90}' cfg=$CFG_STATE app=$APP_STATE quad=$Q_STATE requirepass='$PASS_SHAPE' image_contract='${ICONTRACT:0:140}' journal_present=$JOURNAL_PRESENT. Diagnostic containers removed; redis.service left stopped; no chown/re-init/delete. |" >> "$IDX"
  say "[R7] diagnostic row appended."
else
  say "[R7] diagnostic row already present (guard suppressed)."
fi
grep -qF "$R_TOKEN" "$IDX" 2>/dev/null && say "[R7] suppression proof: R sentinel present." || say "[R7] WARNING: R sentinel missing."

say "[RESULT] REDIS LAYERED READ-OUT DONE — cause=$CAUSE; next-turn heal is named above; no persistent heal executed."
exit 0
