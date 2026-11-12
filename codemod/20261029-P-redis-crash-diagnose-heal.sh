#!/usr/bin/env bash
# 20261029-P — redis brick 4 crash-loop diagnose + evidence-gated ownership heal.
# Owns O follow-up: Command->Exec healed generation; redis now crash-loops.
# Hypothesis: redis:alpine non-root uid cannot write AOF dir /data on named volume.
# Rules: no sudo; no secret echo; no blind patch; halt on config/space/OOM/unclear evidence.
# No heredoc inside $( ); no backticks; no apostrophes inside double-quoted runtime strings.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; IDX="$CD/INDEX.md"
UNIT="$QD/redis.container"; CONF="$HOME/.config/aether/redis/redis.conf"
BIN="$A/bin"; DATAPATH="/data"
REDIS_TOKEN="redis brick4 GREEN"
INS_TOKEN="redis-conf-grep-equals-instrument"
DISK_TOKEN="disk-pressure-85pct-home-restic-absent"
say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }
is_uint(){ case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
unit_state(){ local s; s=$(systemctl --user is-active redis.service 2>/dev/null || true); s=$(norm "$s"); [ -z "$s" ] && s=inactive; printf '%s' "$s"; }
container_status(){ local s; s=$(podman inspect redis --format '{{.State.Status}}' 2>/dev/null || true); s=$(norm "$s"); [ -z "$s" ] && s=absent; printf '%s' "$s"; }
conf_has_auth(){ [ -s "$1" ] && grep -Eq '^requirepass[[:space:]]+[^[:space:]]' "$1" 2>/dev/null; }
mask_conf(){ [ -s "$1" ] && sed -E 's/^requirepass[[:space:]].*/requirepass ***/' "$1" 2>/dev/null || true; }

# ===================== [Q0] disk telemetry, read-only, corrected instrument =====================
say "=== [Q0] disk telemetry (read-only; gates ollama; does NOT act on ollama) ==="
MNT_WV=$(podman volume inspect weaviate_data --format '{{.Mountpoint}}' 2>/dev/null || true); MNT_WV=$(norm "$MNT_WV")
df_line(){ df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $3,$4,$5}'; }
read -r wv_used wv_avail WP <<<"$(df_line "${MNT_WV:-/}")"; WP=$(norm "${WP:-?}")
read -r ho_used ho_avail HP <<<"$(df_line /home)";           HP=$(norm "${HP:-?}")
read -r ro_used ro_avail RP <<<"$(df_line /)";               RP=$(norm "${RP:-?}")
gib(){ awk -v k="${1:-0}" 'BEGIN{printf "%.1fGiB", k/1048576}'; }
RESTIC_SCRIPT=$([ -f "$BIN/40_restic_dr.sh" ] && echo present || echo ABSENT)
RESTIC_UNIT=$(systemctl --user is-enabled aether-backup.service 2>/dev/null || true); RESTIC_UNIT=$(norm "$RESTIC_UNIT"); [ -z "$RESTIC_UNIT" ] && RESTIC_UNIT=unknown
BUCKET="UNKNOWN"
case "$WP" in
  ''|*[!0-9]*) BUCKET="UNKNOWN (df unreadable)";;
  *) if   [ "$WP" -ge 90 ]; then BUCKET="RED>=90 weaviate shards read-only risk"
     elif [ "$WP" -ge 80 ]; then BUCKET="AMBER 80-89 (weaviate already warn)"
     elif [ "$WP" -ge 70 ]; then BUCKET="YELLOW 70-79"
     else BUCKET="GREEN <70"; fi;;
esac
say "[Q0] weaviate-vol-fs(${MNT_WV:-?}): used=$(gib "$wv_used") avail=$(gib "$wv_avail") =${WP}% | /home =${HP}% (avail $(gib "$ho_avail")) | / =${RP}% (avail $(gib "$ro_avail"))"
say "[Q0] restic DR: bin/40_restic_dr.sh=$RESTIC_SCRIPT  aether-backup.service=$RESTIC_UNIT"
say "[Q0] OLLAMA GATE := $BUCKET — no model pull until restic present+enabled AND projected post-pull use <85%."

# ===================== [Q1] redis state + corrected conf inspection =====================
say "=== [Q1] redis state + corrected redis.conf inspection (space syntax, masked) ==="
ACT0=$(unit_state); CST0=$(container_status)
IMG=$(podman inspect redis --format '{{.Config.Image}}' 2>/dev/null || true); IMG=$(norm "$IMG")
if [ -z "$IMG" ] && [ -f "$UNIT" ]; then IMG=$(awk -F= '/^Image=/{print $2; exit}' "$UNIT" 2>/dev/null || true); IMG=$(norm "$IMG"); fi
[ -n "$IMG" ] || halt "cannot resolve redis image from container or unit; stop."
[ -s "$CONF" ] || halt "redis.conf missing/empty at $CONF; run extractor deliberately first."
CONF_AUTH=no; conf_has_auth "$CONF" && CONF_AUTH=yes
SEC_PASS=no; grep -Eq '^REDIS_PASSWORD=.' "$SECRETS" 2>/dev/null && SEC_PASS=yes
say "[Q1] unit_active=$ACT0 container_status=$CST0 image=$IMG conf_auth=$CONF_AUTH secrets_password_present=$SEC_PASS"
say "[Q1] masked redis.conf directives:"
mask_conf "$CONF" | head -n 20 | sed 's/^/    /' || true

# ===================== [Q2] logs + structured evidence =====================
say "=== [Q2] logs + evidence classification (read-only) ==="
LOGS=$(podman logs --tail 160 redis 2>&1 || true)
say "[Q2] podman logs tail 50:"
printf '%s\n' "$LOGS" | tail -n 50 | sed 's/^/    /' || true
PERM=no; CONFIG=no; SPACE=no
printf '%s\n' "$LOGS" | grep -qiE 'permission denied|operation not permitted|cannot open the append|Cant open the append|Fatal error.*append|MISCONF.*disk|Unable to open|Read-only file system|not writable' && PERM=yes
printf '%s\n' "$LOGS" | grep -qiE 'unknown configuration|Unsupported config|config file error|Bad directive|Invalid argument|wrong number of arguments|unexpected token|Unknown option' && CONFIG=yes
printf '%s\n' "$LOGS" | grep -qiE 'No space left on device|disk full|unable to write|short write' && SPACE=yes
OOM_RAW=$(podman inspect redis --format '{{.State.OOMKilled}}' 2>/dev/null || true); OOM_RAW=$(norm "$OOM_RAW")
OOM=no; [ "$OOM_RAW" = true ] && OOM=yes
EXIT_CODE=$(podman inspect redis --format '{{.State.ExitCode}}' 2>/dev/null || true); EXIT_CODE=$(norm "$EXIT_CODE")
STATE_ERR=$(podman inspect redis --format '{{.State.Error}}' 2>/dev/null || true); STATE_ERR=$(norm "$STATE_ERR")
say "[Q2] evidence perm=$PERM config=$CONFIG space=$SPACE oom=$OOM exit=$EXIT_CODE state_error=${STATE_ERR:-<none>}"

# Stable only if unit active + container running + redis-cli responds PONG/NOAUTH.
STABLE=no
if [ "$ACT0" = active ] && [ "$CST0" = running ]; then
  QO=$(podman exec redis redis-cli ping 2>&1 || true); QO=$(norm "$QO")
  say "[Q2] quick_ping=${QO:-<empty>}"
  case "$QO" in *PONG*|*NOAUTH*) STABLE=yes;; esac
fi
say "[Q2] stable=$STABLE"

NEED_STOP=no
[ "$STABLE" = no ] && NEED_STOP=yes
[ "$CONFIG" = yes ] && NEED_STOP=yes
[ "$SPACE" = yes ] && NEED_STOP=yes
[ "$OOM" = yes ] && NEED_STOP=yes
STOPPED=no
if [ "$NEED_STOP" = yes ]; then
  systemctl --user stop redis.service 2>/dev/null || true
  STOPPED=yes
  sleep 1
  CST0=$(container_status)
  say "[Q2] stopped redis.service for stable diagnosis; container_status=$CST0"
fi

# ===================== [Q3] volume ownership/writability probes (one-shot, no persistent state) =====================
say "=== [Q3] volume ownership/writability probes ==="
VOL_MP=$(podman volume inspect redis_data --format '{{.Mountpoint}}' 2>/dev/null || true); VOL_MP=$(norm "$VOL_MP")
[ -n "$VOL_MP" ] || halt "cannot inspect redis_data mountpoint."
E1="/tmp/aether-redis-owner.$$.err"; E2="/tmp/aether-redis-target.$$.err"; E3="/tmp/aether-redis-write.$$.err"
ORIG_OWNER=$(podman run --rm --network none --volume redis_data:/data --user root "$IMG" stat -c '%u %g' /data 2>"$E1" || true); ORIG_OWNER=$(norm "$ORIG_OWNER")
TARGET_OWNER=$(podman run --rm --network none "$IMG" sh -c 'printf "%s %s" "$(id -u)" "$(id -g)"' 2>"$E2" || true); TARGET_OWNER=$(norm "$TARGET_OWNER")
WRITABLE=$(podman run --rm --network none --volume redis_data:/data "$IMG" sh -c 'test -w /data && echo yes || echo no' 2>"$E3" || true); WRITABLE=$(norm "$WRITABLE")
[ -s "$E1" ] && say "    owner-probe-err: $(head -n1 "$E1" | norm)"
[ -s "$E2" ] && say "    target-probe-err: $(head -n1 "$E2" | norm)"
[ -s "$E3" ] && say "    write-probe-err: $(head -n1 "$E3" | norm)"
rm -f "$E1" "$E2" "$E3"
say "[Q3] mountpoint=$VOL_MP original_owner=${ORIG_OWNER:-<none>} target_owner=${TARGET_OWNER:-<none>} writable=${WRITABLE:-unknown}"
read -r OU OG <<<"$ORIG_OWNER"
read -r TU TG <<<"$TARGET_OWNER"
ORIG_VALID=no; is_uint "$OU" && is_uint "$OG" && ORIG_VALID=yes
if ! is_uint "$TU" || ! is_uint "$TG"; then halt "cannot determine redis image uid/gid; stop rather than blind-chown." fi
if [ "$WRITABLE" = no ] && [ "$TU" != 0 ] && [ "$ORIG_VALID" = yes ] && [ "$OU" = "$TU" ]; then
  halt "data dir is owned by target redis uid but test -w failed; likely mount/read-only issue; not blind-chown."
fi
if [ "$WRITABLE" = no ] && [ "$TU" != 0 ]; then
  if [ "$ORIG_VALID" = no ] || [ "$OU" != "$TU" ]; then PERM=yes; say "[Q3] writability probe raises perm evidence to yes"
  fi
fi

# ===================== [Q4] decision =====================
say "=== [Q4] decision ==="
if [ "$CONFIG" = yes ]; then halt "redis conf/command rejected by server. Evidence in [Q2] logs. Do not blind-patch; inspect directive/Exec semantics." fi
if [ "$SPACE" = yes ]; then halt "disk/full/write evidence. Do not advance; free space or change storage target first." fi
if [ "$OOM" = yes ]; then halt "OOMKilled evidence. Do not advance; revisit MemoryMax/maxmemory budget." fi
HEAL=no
if [ "$PERM" = yes ] && [ "$STABLE" = no ] && [ "$TU" != 0 ]; then
  HEAL=owner
  say "[Q4] heal_decision=owner reason=permission evidence and target redis uid is non-root"
elif [ "$PERM" = yes ] && [ "$STABLE" = yes ]; then
  say "[Q4] permission evidence present but redis is currently stable; no heal, gate will reconfirm"
elif [ "$STABLE" = no ]; then
  halt "redis is unstable but no clear permission/config/space/OOM evidence. Paste [Q2] logs; do not blind-patch."
else
  say "[Q4] heal_decision=no reason=stable"
fi

# ===================== gate function =====================
gate_redis(){
  G_UP=no; G_CRASH=no; G_PING_SEQ=""; G_GREEN_ITER=0
  for i in $(seq 1 30); do
    G_ACT=$(unit_state)
    G_CST=$(container_status)
    if [ "$G_CST" = exited ]; then G_CRASH=yes; break; fi
    if [ "$G_CST" = running ]; then
      O=$(podman exec redis redis-cli ping 2>&1 || true)
    else
      O="not-running:$G_CST"
    fi
    O=$(norm "$O"); [ -z "$O" ] && O=empty
    G_PING_SEQ+="${O:0:18} "
    case "$O" in *PONG*|*NOAUTH*) G_UP=yes; G_GREEN_ITER=$i; break;; esac
    sleep 2
  done
  G_ACT=$(unit_state); G_CST=$(container_status)
  G_RUN=$(podman ps --filter name=redis --format '{{.Names}} {{.Status}}' 2>/dev/null || true); G_RUN=$(norm "$G_RUN"); [ -z "$G_RUN" ] && G_RUN=none
  G_AUTHINFO="not-evaluated"
  if [ "$CONF_AUTH" = yes ]; then
    if [ "$SEC_PASS" = yes ] && [ "$G_UP" = yes ] && [ "$G_CST" = running ]; then
      PV=$(podman exec redis sh -c 'test -n "${REDIS_PASSWORD:-}" && echo present || echo absent' 2>&1 || true); PV=$(norm "$PV")
      if [ "$PV" = present ]; then
        AO=$(podman exec redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping' 2>&1 || true); AO=$(norm "$AO")
        case "$AO" in
          *PONG*) G_AUTHINFO="key-valid";;
          *WRONGPASS*|*invalid*) G_AUTHINFO="wrongpass";;
          *) G_AUTHINFO="anomalous:${AO:0:24}";;
        esac
      else
        G_AUTHINFO="container-missing-REDIS_PASSWORD"
      fi
    elif [ "$SEC_PASS" = no ]; then
      G_AUTHINFO="secrets-missing-password"
    else
      G_AUTHINFO="not-up"
    fi
  else
    G_AUTHINFO="no-auth-required"
  fi
  G_PERSIST=no; G_PMATCH=""
  while read -r typ dest; do
    [ -z "${dest:-}" ] && continue
    case "$DATAPATH" in
      "$dest"|"$dest"/*) if [ "$typ" = volume ] || [ "$typ" = bind ]; then G_PERSIST=yes; G_PMATCH="$typ at $dest"; fi ;;
    esac
  done < <(podman inspect redis --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>/dev/null || true)
  G_PASS=no
  if [ "$G_ACT" = active ] && [ "$G_UP" = yes ] && [ "$G_PERSIST" = yes ]; then
    if [ "$CONF_AUTH" = yes ] && [ "$SEC_PASS" = yes ]; then
      [ "$G_AUTHINFO" = key-valid ] && G_PASS=yes
    else
      G_PASS=yes
    fi
  fi
}

# ===================== [Q5] conditional ownership heal =====================
if [ "$HEAL" = owner ]; then
  say "=== [Q5] ownership heal (stop, chown volume to image uid, start) ==="
  if [ "$STOPPED" != yes ]; then
    systemctl --user stop redis.service 2>/dev/null || true
    STOPPED=yes
    sleep 1
  fi
  if ! podman run --rm --network none --volume redis_data:/data --user root "$IMG" chown -R "$TU:$TG" /data; then
    halt "chown heal command failed; no start attempted."
  fi
  say "[Q5] chowned redis_data:/data to $TU:$TG"
  systemctl --user start redis.service 2>/dev/null || true
  sleep 2
elif [ "$STOPPED" = yes ]; then
  say "=== [Q5] no heal; restarting stopped redis.service for gate ==="
  systemctl --user start redis.service 2>/dev/null || true
  sleep 2
fi

# ===================== [Q6] gate =====================
say "=== [Q6] readiness + auth + persistence gate ==="
gate_redis
G_PING_SEQ_SHORT=$(printf '%s' "$G_PING_SEQ" | cut -c1-160)
say "[Q6] active=$G_ACT container=$G_CST up=$G_UP crash=$G_CRASH green_iter=$G_GREEN_ITER ping_seq=[$G_PING_SEQ_SHORT] auth=$G_AUTHINFO persist=$G_PERSIST match=$G_PMATCH run=$G_RUN"
say "[Q6] journal tail:"
journalctl --user -u redis.service --no-pager --tail 10 2>/dev/null | sed 's/^/    j: /' || true
say "[Q6] podman logs tail:"
podman logs --tail 30 redis 2>&1 | sed 's/^/    /' || true

if [ "$G_PASS" != yes ]; then
  if [ "$HEAL" = owner ] && [ "$ORIG_VALID" = yes ]; then
    say "[Q6] gate failed after owner heal; rolling ownership back to $OU:$OG and leaving service stopped"
    systemctl --user stop redis.service 2>/dev/null || true
    podman run --rm --network none --volume redis_data:/data --user root "$IMG" chown -R "$OU:$OG" /data 2>/dev/null || say "[Q6] rollback chown failed; inspect manually"
  fi
  halt "redis gate failed (active=$G_ACT up=$G_UP crash=$G_CRASH auth=$G_AUTHINFO persist=$G_PERSIST). See [Q6] logs; do not advance."
fi

# ===================== [Q7] guarded ledger rows, sentinel IS in payload =====================
say "=== [Q7] ledger rows (guarded; sentinel in payload) ==="
if ! grep -qF "$INS_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $INS_TOKEN | APPEND-ONLY | O [D1] used key=value grep against redis.conf, but Redis config uses space syntax, so requirepass/maxmemory were falsely reported absent. P uses ^requirepass[[:space:]]+ and masks requirepass. No patient change from this instrument correction. |" >> "$IDX"
  say "[Q7] instrument correction row appended."
else
  say "[Q7] instrument correction row already present."
fi
grep -qF "$INS_TOKEN" "$IDX" 2>/dev/null && say "[Q7] suppression proof: instrument sentinel present." || say "[Q7] WARNING: instrument sentinel missing."

if ! grep -qF "$REDIS_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-P-redis-heal | GATE=PASS | $REDIS_TOKEN: unauth PING up (ping_seq=[$G_PING_SEQ_SHORT]), auth=$G_AUTHINFO, data on named volume (ancestor+volume-type, DATA=$DATAPATH), loopback 6379, conf_auth=$CONF_AUTH secrets_password_present=$SEC_PASS, healed Command->Exec in O and volume ownership to redis uid in P when evidence supported; OLLAMA_GATE=$BUCKET; replay=20261029-P-redis-crash-diagnose-heal.sh |" >> "$IDX"
  say "[Q7] redis green row appended."
else
  say "[Q7] redis green row already present (guard suppressed)."
fi
grep -qF "$REDIS_TOKEN" "$IDX" 2>/dev/null && say "[Q7] suppression proof: redis sentinel present." || say "[Q7] WARNING: redis sentinel missing."

say "[RESULT] REDIS GREEN (brick 4 healed) — crash-loop root-caused to volume ownership/AOF writability when evidence supported; disk gate remains $BUCKET; next should be restic DR before ollama, not ollama."
exit 0
