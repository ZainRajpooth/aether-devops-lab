#!/usr/bin/env bash
# 20261029-Q — redis brick 4 READ-ONLY crash read-out (+ protective stop of the restart storm).
# Breaks the heal-on-hypothesis cycle: O and P both guessed ownership before reading the crash line.
# This turn MEASURES only: logs, image contract (User/Entrypoint/Cmd + generated ExecStart), /data owner+writable.
# Then classifies the cause and PRINTS the precise next-turn heal as text. It does NOT chown, re-init, or delete.
# Hard bash rule (5th compact-bash defect owned): every if/then/fi is MULTI-LINE; bash -n mandatory before run.
# No sudo. No secret echo. No heredoc inside $( ). No backticks. exit 0 on every branch.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; IDX="$CD/INDEX.md"
UNIT="$QD/redis.container"; CONF="$HOME/.config/aether/redis/redis.conf"
DATAPATH="/data"
SYNTAX_TOKEN="bash-one-line-if-missing-semicolon"   # MUST be in the correction-row payload (H5 rule)
DIAG_TOKEN="redis-crash-evidence"                   # MUST be in the diagnostic-row payload
LOGF="/tmp/aether-redis-readout.$$.log"
say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }

# ===================== [Z0] protective stop (halt restart storm; reversible) =====================
say "=== [Z0] protective stop of the crash-loop (reversible; no data touch) ==="
systemctl --user stop redis.service 2>/dev/null || true
sleep 1
ACT=$(systemctl --user is-active redis.service 2>/dev/null || true); ACT=$(norm "$ACT"); [ -z "$ACT" ] && ACT=inactive
CST=$(podman inspect redis --format '{{.State.Status}}' 2>/dev/null || true); CST=$(norm "$CST"); [ -z "$CST" ] && CST=absent
say "[Z0] unit_active=$ACT container=$CST (stopped to freeze the last crash state; restart is next turn, from evidence)"

# ===================== [Z1] the actual crash line (read-only) =====================
say "=== [Z1] crash read-out (podman logs + journalctl; the cause lives here, not in my hypothesis) ==="
{
  echo "----- podman logs --tail 200 redis -----"
  podman logs --tail 200 redis 2>&1 || true
  echo "----- journalctl --user -u redis.service --tail 120 -----"
  journalctl --user -u redis.service --no-pager --tail 120 2>&1 || true
} > "$LOGF"
say "[Z1] last 40 log lines:"
tail -n 40 "$LOGF" | sed 's/^/    /' || true

# ===================== [Z2] image contract + generated ExecStart (the entrypoint-override crux) =====================
say "=== [Z2] image contract & how Exec= was translated (read-only) ==="
UC=$(podman inspect redis --format 'User={{.Config.User}}|EP={{.Config.Entrypoint}}|CMD={{.Config.Cmd}}' 2>/dev/null || true); UC=$(norm "$UC")
EXS=$(systemctl --user cat redis.service 2>/dev/null | grep -E '^Exec(Start|StartPre)=' | head -n 4 || true)
say "[Z2] $UC"
say "[Z2] generated unit Exec lines:"
printf '%s\n' "$EXS" | sed 's/^/    /' || true
say "[Z2] authored source unit (no secrets — conf is mounted, not inlined):"
[ -f "$UNIT" ] && sed 's/^/    /' "$UNIT" || say "    (source unit missing at $UNIT)"

# ===================== [Z3] /data ownership + writability (one-shot, no persistent state) =====================
say "=== [Z3] /data owner + writability (one-shot probes; read-only) ==="
IMG=$(podman inspect redis --format '{{.Config.Image}}' 2>/dev/null || true); IMG=$(norm "$IMG")
[ -z "$IMG" ] && [ -f "$UNIT" ] && IMG=$(awk -F= '/^Image=/{print $2; exit}' "$UNIT" 2>/dev/null || true); IMG=$(norm "$IMG")
OWNER=$(podman run --rm --network none --volume redis_data:/data --user root "$IMG" stat -c '%u %g %A' /data 2>/dev/null || true); OWNER=$(norm "$OWNER")
DEFUSER=$(podman run --rm --network none "$IMG" sh -c 'printf "%s %s" "$(id -u)" "$(id -g)"' 2>/dev/null || true); DEFUSER=$(norm "$DEFUSER")
WRIT=$(podman run --rm --network none --volume redis_data:/data "$IMG" sh -c 'test -w /data && echo yes || echo no' 2>/dev/null || true); WRIT=$(norm "$WRIT")
say "[Z3] image=$IMG"
say "[Z3] /data owner(mode)=$OWNER  default-user-id=$DEFUSER  default-user-writable=$WRIT"

# ===================== [Z4] classify the cause from the VERBATIM log line (no guessing) =====================
say "=== [Z4] cause classification (first matching line per category, printed verbatim) ==="
CAUSE="UNKNOWN"; MATCHLINE=""
classify(){ # $1=name $2=regex  -> sets CAUSE/MATCHLINE on first hit if still UNKNOWN
  local name="$1" re="$2" hit
  hit=$(grep -m1 -iE "$re" "$LOGF" 2>/dev/null || true); hit=$(norm "$hit")
  if [ -n "$hit" ]; then
    say "    [$name] $hit"
    if [ "$CAUSE" = UNKNOWN ]; then CAUSE="$name"; MATCHLINE="$hit"; fi
  fi
}
classify exec_or_path  'no such file or directory|executable file not found|exec format error|standard_init_linux|cannot find the configuration|redis\.conf: No such'
classify config_reject 'Unsupported config option|unknown configuration|Bad directive|Invalid argument|wrong number of arguments|Unrecognized configuration|Fatal: Can.t configure'
classify perm_denied   'Permission denied|Operation not permitted|not writable|Read-only file system|cannot open.*permission|Failed opening the append'
classify aof_fatal     'Fatal error loading append|Unexpected end of file.*append|Bad file format|Can.t open the append-only file|loading the append only file.*failed'
classify oom           'OOM|Out of memory|Killed|memory allocation failed'
classify disk_full     'No space left on device|disk full|short write|unable to write'
classify bind_fail     'Address already in use|Could not create server TCP|bind.*failed'
OOMK=$(podman inspect redis --format '{{.State.OOMKilled}}' 2>/dev/null || true); OOMK=$(norm "$OOMK")
EXITC=$(podman inspect redis --format '{{.State.ExitCode}}' 2>/dev/null || true); EXITC=$(norm "$EXITC")
NRS=$(systemctl --user show redis.service -p NRestarts --value 2>/dev/null || true); NRS=$(norm "$NRS")
say "[Z4] CAUSE=$CAUSE  (OOMKilled=$OOMK exit=$EXITC systemd_NRestarts=${NRS:-?})"

# ===================== [Z5] precise next-turn heal, PRINTED as text only (not executed) =====================
say "=== [Z5] heal proposal for NEXT turn (text only; Q executes no heal, chown, re-init, or delete) ==="
case "$CAUSE" in
  exec_or_path)
    say "    -> Exec= translation is wrong (binary or conf path). Fix the [Container] Exec= per the [Z2] generated ExecStart; this is architectural (MODE A) if the image entrypoint must be preserved. No data touch." ;;
  config_reject)
    say "    -> A directive in redis.conf is rejected. Read the exact line above, remove/fix that directive in the extractor allowlist (lib/redis_extract.py), re-derive conf, restart, re-gate. No data touch." ;;
  perm_denied)
    say "    -> redis user cannot write /data. DECIDE FROM [Z2]: if Config.User is non-root AND Exec= overrode the entrypoint, the real fault is the override (the image entrypoint normally prepares the data dir) — prefer removing the Exec= override / using the image-supported config path over a blind chown. Only if the entrypoint is preserved and the volume is simply root-owned: chown redis_data:/data to Config.User. Do NOT blind-chown until [Z2] is read." ;;
  aof_fatal)
    say "    -> Fresh-volume AOF likely corrupted by the restart storm. DATA question: do NOT delete without your word (B13). Options next turn: (a) inspect/repair AOF, (b) clean re-init of redis_data ONLY on your explicit approval (loses the in-memory/AOF state, which is empty anyway on a fresh brick)." ;;
  oom)
    say "    -> MemoryMax/maxmemory interaction. Adjust the cgroup ceiling relative to maxmemory 256mb, restart, re-gate. No data touch." ;;
  disk_full)
    say "    -> Blocked by disk: /home is at 85% (see prior [D0]/[Q0]). Free space or land restic DR before any further write; do NOT advance to ollama. No data touch." ;;
  bind_fail)
    say "    -> Port/socket bind failed (stale listener or wrong publish). Inspect [Z2] ExecStart publish mapping; restart cleanly. No data touch." ;;
  *)
    say "    -> HALT (B13/§7): cause not classified from the logs. Paste the [Z1] lines and I disambiguate from evidence; no blind patch." ;;
esac

# ===================== [Z6] guarded ledger rows (sentinel IS in payload + in-run suppression proof) =====================
say "=== [Z6] ledger (append-only; sentinel-in-payload; suppression proven in-run) ==="
if ! grep -qF "$SYNTAX_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $SYNTAX_TOKEN | APPEND-ONLY | P failed bash -n (line 256 unexpected EOF from if at 126): one-line 'if … then halt \"…\" fi' lacked ';' before fi — the 5th compact-bash defect (after Z3 group-counts, Q2 indent, J2 sed-delim, N heredoc-in-substitution). HARD RULE encoded: every if/then/fi is multi-line; bash -n mandatory before run (it held: zero side-effects). Deeper lesson: O and P healed redis on an ownership HYPOTHESIS before reading the crash line; Q breaks that cycle by measuring first. |" >> "$IDX"
  say "[Z6] syntax-correction row appended."
else
  say "[Z6] syntax-correction row already present (guard suppressed)."
fi
grep -qF "$SYNTAX_TOKEN" "$IDX" 2>/dev/null && say "[Z6] suppression proof: syntax sentinel present." || say "[Z6] WARNING: syntax sentinel missing."

if ! grep -qF "$DIAG_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | DIAG | $DIAG_TOKEN | APPEND-ONLY | redis brick4 read-only crash read-out (Q): CAUSE=$CAUSE match='${MATCHLINE:0:80}' OOMKilled=$OOMK exit=$EXITC NRestarts=${NRS:-?} container=$CST /data-owner='$OWNER' default-user='$DEFUSER' writable=$WRIT image=$IMG ConfigUser='${UC}'. Heal proposed as TEXT for next turn; Q executed no chown/re-init/delete. Protective stop only. |" >> "$IDX"
  say "[Z6] diagnostic-evidence row appended."
else
  say "[Z6] diagnostic-evidence row already present (guard suppressed)."
fi
grep -qF "$DIAG_TOKEN" "$IDX" 2>/dev/null && say "[Z6] suppression proof: diagnostic sentinel present." || say "[Z6] WARNING: diagnostic sentinel missing."

rm -f "$LOGF" 2>/dev/null || true
say "[RESULT] REDIS READ-OUT DONE — cause classified as $CAUSE from the verbatim log line (not a hypothesis); protective stop applied; no heal/chown/delete executed. Next turn heals from [Z5] on your word."
exit 0
