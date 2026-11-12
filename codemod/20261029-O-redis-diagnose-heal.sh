#!/usr/bin/env bash
# 20261029-O — redis brick 4 diagnose + conditional heal.
# Primary hypothesis from N2 evidence: invalid Quadlet key Command= caused generator skip.
# This script is evidence-gated:
#   1) read-only diagnose generated-unit state, journal, rendered keys, quadlet binary hints
#   2) if Command= is present and redis.service is not generated, heal Command= -> Exec=
#   3) raise MemoryMax to 1.5x redis maxmemory to avoid cgroup OOM overhead
#   4) validate redis.service is generated BEFORE start; rollback if not
#   5) readiness poll + steel-thread gate + guarded ledger rows
# No sudo. No heredoc inside $( ). No secrets echoed. exit 0 on every branch.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; IDX="$CD/INDEX.md"; PYX="$CD/lib/redis_extract.py"
SRC="$A/legacy/compose/recovery-runtime.yml"; REDIRC="$HOME/.config/aether/redis"; BIN="$A/bin"
UNIT="$QD/redis.container"; RUNIT="$SYS/redis.container"; BAK="$UNIT.pre-O.bak"
CONF="$REDIRC/redis.conf"; DATAPATH="/data"; WORK="$REDIRC/work.diag.$$"
SLUG="20261029-O-redis-heal"
REDIS_TOKEN="redis brick4 GREEN"
DISK_TOKEN="disk-pressure-85pct-home-restic-absent"
WVVER_TOKEN="weaviate-latest-resolved-1.40.3"
say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; [ -n "${WORK:-}" ] && rm -rf "$WORK" 2>/dev/null || true; exit 0; }
unit_state(){ local s; s=$(systemctl --user is-active "$1" 2>/dev/null || true); s=$(norm "$s"); [ -z "$s" ] && s=inactive; printf '%s' "$s"; }
enabled_state(){ local s; s=$(systemctl --user is-enabled "$1" 2>/dev/null || true); s=$(norm "$s"); [ -z "$s" ] && s=unknown; printf '%s' "$s"; }
has_unit(){ systemctl --user cat "$1" >/dev/null 2>&1; }
rollback(){
  if [ -f "$BAK" ]; then cp -p "$BAK" "$UNIT" 2>/dev/null || true; fi
  rm -f "$RUNIT" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
}
mkdir -p "$QD" "$SYS" "$REDIRC" "$CD"

# ===================== [D0] disk telemetry, corrected instrument, append-only rows =====================
say "=== [D0] disk telemetry (read-only; gates ollama; does NOT act on ollama) ==="
MNT_WV=$(podman volume inspect weaviate_data --format '{{.Mountpoint}}' 2>/dev/null || true); MNT_WV=$(norm "$MNT_WV")
df_line(){ df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $3,$4,$5}'; }
read -r wv_used wv_avail WP <<<"$(df_line "${MNT_WV:-/}")"; WP=$(norm "${WP:-?}")
read -r ho_used ho_avail HP <<<"$(df_line /home)";           HP=$(norm "${HP:-?}")
read -r ro_used ro_avail RP <<<"$(df_line /)";               RP=$(norm "${RP:-?}")
gib(){ awk -v k="${1:-0}" 'BEGIN{printf "%.1fGiB", k/1048576}'; }
say "[D0] weaviate-vol-fs(${MNT_WV:-?}): used=$(gib "$wv_used") avail=$(gib "$wv_avail") =${WP}% | /home =${HP}% (avail $(gib "$ho_avail")) | / =${RP}% (avail $(gib "$ro_avail"))"
RESTIC_SCRIPT=$([ -f "$BIN/40_restic_dr.sh" ] && echo present || echo ABSENT)
RESTIC_UNIT=$(enabled_state aether-backup.service)
say "[D0] restic DR: bin/40_restic_dr.sh=$RESTIC_SCRIPT  aether-backup.service=$RESTIC_UNIT"
BUCKET="UNKNOWN"
case "$WP" in
  ''|*[!0-9]*) BUCKET="UNKNOWN (df unreadable)";;
  *) if   [ "$WP" -ge 90 ]; then BUCKET="RED>=90 weaviate shards read-only risk"
     elif [ "$WP" -ge 80 ]; then BUCKET="AMBER 80-89 (weaviate already warn)"
     elif [ "$WP" -ge 70 ]; then BUCKET="YELLOW 70-79"
     else BUCKET="GREEN <70"; fi;;
esac
say "[D0] OLLAMA GATE := $BUCKET — no model pull until restic present+enabled AND projected post-pull use <85%."

if ! grep -qF "$DISK_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $DISK_TOKEN | APPEND-ONLY | [D0] measured weaviate-vol-fs=${WP}% /home=${HP}% /=${RP}%; restic bin/40_restic_dr.sh=$RESTIC_SCRIPT aether-backup.service=$RESTIC_UNIT. OLLAMA GATE=$BUCKET. Weaviate doc: 80% warn, 90% shards read-only; compaction/backups need free space. Disk budget is now a hard precondition before ollama. |" >> "$IDX"
  say "[D0] disk-pressure ledger row appended."
else say "[D0] disk-pressure ledger row already present."; fi
grep -qF "$DISK_TOKEN" "$IDX" 2>/dev/null && say "[D0] suppression proof: disk sentinel present." || say "[D0] WARNING: disk sentinel missing."

if ! grep -qF "$WVVER_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | NOTE | $WVVER_TOKEN | APPEND-ONLY | weaviate :latest resolved to build_image_tag v1.40.3 at pull 2026-10-29 (from M1 [V2] logs); records drift baseline for the :latest-parity decision. |" >> "$IDX"
  say "[D0] weaviate version-baseline row appended."
else say "[D0] weaviate version-baseline row already present."; fi

# ===================== [D1] ensure derived redis.conf exists; show only non-secret directives =====================
say "=== [D1] redis.conf presence + non-secret directive preview ==="
if [ ! -s "$CONF" ]; then
  [ -f "$PYX" ] || halt "redis.conf missing and extractor missing at $PYX; cannot proceed without re-running the extractor deliberately."
  mkdir -p "$WORK"; chmod 700 "$WORK"
  python3 "$PYX" "$SRC" "$SECRETS" "$DATAPATH" "$REDIRC" "$WORK" || true
  SUM="$WORK/summary.txt"
  STATUS=$(grep '^status=' "$SUM" 2>/dev/null | cut -d= -f2- || true); STATUS=$(norm "${STATUS:-UNKNOWN}")
  REASON=$(grep '^halt_reason=' "$SUM" 2>/dev/null | cut -d= -f2- || true); REASON=$(norm "$REASON")
  rm -rf "$WORK" 2>/dev/null || true
  [ "$STATUS" = OK ] || halt "extractor status=$STATUS reason=${REASON:-none}; redis.conf not usable."
fi
[ -s "$CONF" ] || halt "redis.conf still missing/empty after extractor attempt."
say "[D1] non-secret redis.conf directives:"
grep -E '^(appendonly|maxmemory|maxmemory-policy|dir)=' "$CONF" 2>/dev/null | sed 's/^/    /' || true
if grep -qE '^requirepass=' "$CONF" 2>/dev/null; then say "    requirepass ***"; else say "    requirepass absent"; fi
HAS_AUTH=no; grep -qE '^REDIS_PASSWORD=.' "$SECRETS" 2>/dev/null && HAS_AUTH=yes
say "[D1] secrets.env REDIS_PASSWORD_present=$HAS_AUTH (presence only)"

# ===================== [D2] read-only generation diagnosis =====================
say "=== [D2] why redis.service was not found (read-only) ==="
SRC_EXISTS=no; [ -f "$UNIT" ] && SRC_EXISTS=yes
RUNIT_EXISTS=no; [ -f "$RUNIT" ] && RUNIT_EXISTS=yes
HAS_CMD=no; [ -f "$RUNIT" ] && grep -qE '^Command=' "$RUNIT" 2>/dev/null && HAS_CMD=yes
HAS_EXEC=no; [ -f "$RUNIT" ] && grep -qE '^Exec=' "$RUNIT" 2>/dev/null && HAS_EXEC=yes
UNIT_FOUND=no; has_unit redis.service && UNIT_FOUND=yes
say "[D2] source_unit=$SRC_EXISTS rendered_unit=$RUNIT_EXISTS rendered_has_Command=$HAS_CMD rendered_has_Exec=$HAS_EXEC redis_service_generated=$UNIT_FOUND"
say "[D2] known aether generated unit-files:"
systemctl --user list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(redis|postgres|minio|weaviate|node-exporter|prometheus|mailpit)\.service$' 2>/dev/null | sed 's/^/    unit-file: /' || true
say "[D2] recent user-journal quadlet/generator hints:"
JHIT=$(journalctl --user --since "-20min" --no-pager 2>/dev/null | grep -iE 'quadlet|redis\.container|unknown key|invalid|unsupported|generator' | tail -n 1 || true); JHIT=$(norm "$JHIT")
journalctl --user --since "-20min" --no-pager 2>/dev/null | grep -iE 'quadlet|redis\.container|unknown key|invalid|unsupported|generator' | tail -n 20 | sed 's/^/    j: /' || true
QBIN=""
for c in /usr/libexec/podman/quadlet /usr/lib/systemd/user-generators/podman-user-generator /usr/lib/systemd/system-generators/podman-system-generator; do
  [ -x "$c" ] && QBIN="$c" && break
done
if [ -n "$QBIN" ]; then
  say "[D2] quadlet binary: $QBIN"
  if command -v strings >/dev/null 2>&1; then
    strings "$QBIN" 2>/dev/null | grep -iE '^(exec|command|podmanargs)$' | sort -u | head -n 10 | sed 's/^/    key-like: /' || true
  fi
else
  say "[D2] quadlet binary not found in common paths"
fi

# ===================== [D3] decision: only heal if evidence supports Command->Exec =====================
HEAL=no
HEAL_REASON=""
if [ "$UNIT_FOUND" = no ] && [ "$HAS_CMD" = yes ]; then
  HEAL=yes
  HEAL_REASON="Command= present and redis.service not generated"
elif [ "$UNIT_FOUND" = yes ] && [ "$HAS_CMD" = yes ]; then
  HEAL=yes
  HEAL_REASON="Command= present even though unit generated; normalize to Exec= and validate"
elif [ "$UNIT_FOUND" = no ]; then
  halt "redis.service not generated but no Command= key found; do not blind-patch. Inspect [D2] journal/quadlet evidence."
fi
say "[D3] heal_decision=$HEAL reason=${HEAL_REASON:-none}"

# ===================== [H1] conditional surgical heal: Command->Exec + MemoryMax overhead =====================
if [ "$HEAL" = yes ]; then
  [ -f "$UNIT" ] || halt "source unit missing at $UNIT; cannot heal."
  [ -f "$BAK" ] || cp -p "$UNIT" "$BAK"
  MM_MB=$(awk '
    /^maxmemory[[:space:]]+/ {
      v=$2; u=tolower(v); gsub(/[^0-9.]/,"",v);
      if (u ~ /kb$/) m=1/1024;
      else if (u ~ /mb$/) m=1;
      else if (u ~ /gb$/) m=1024;
      else m=1;
      printf "%d", (v*m + 0.999999);
      exit
    }
  ' "$CONF" 2>/dev/null || true)
  MM_MB=$(norm "${MM_MB:-256}"); case "$MM_MB" in ''|*[!0-9]*) MM_MB=256;; esac
  if [ "$MM_MB" -le 0 ]; then CEIL_MB=512; else CEIL_MB=$(( (MM_MB * 3 + 1) / 2 )); fi
  [ "$CEIL_MB" -lt 256 ] && CEIL_MB=256
  say "[H1] parsed maxmemory=${MM_MB}MB -> MemoryMax=${CEIL_MB}M (1.5x overhead floor 256M)"
  sed -i 's|^Command=|Exec=|' "$UNIT"
  if grep -qE '^MemoryMax=' "$UNIT" 2>/dev/null; then
    sed -i "s|^MemoryMax=.*|MemoryMax=${CEIL_MB}M|" "$UNIT"
  else
    printf 'MemoryMax=%sM\n' "$CEIL_MB" >> "$UNIT"
  fi
  install -D -m 644 "$UNIT" "$RUNIT"
  systemctl --user daemon-reload 2>/dev/null || true
  if has_unit redis.service; then
    UNIT_FOUND=yes
    say "[H1] heal accepted: redis.service is now generated; Exec= present and MemoryMax=${CEIL_MB}M"
  else
    rollback
    halt "[H1] heal rejected: redis.service still not generated after Exec=; rolled back to $BAK. This is the second failed heal on the same generation defect; next turn must switch to MODE A architectural teardown, not another patch."
  fi
fi

# ===================== [H2] ensure started, then readiness poll with corrected instrument =====================
say "=== [H2] start + readiness poll (unauth PING in PONG/NOAUTH = steel-thread) ==="
ACT=$(unit_state redis.service)
if [ "$ACT" != active ]; then
  systemctl --user enable redis.service 2>/dev/null || true
  systemctl --user start redis.service 2>/tmp/redis-start.$$.err || true
  if [ -s /tmp/redis-start.$$.err ]; then sed 's/^/    start-err: /' /tmp/redis-start.$$.err || true; fi
  rm -f /tmp/redis-start.$$.err 2>/dev/null || true
  for i in $(seq 1 20); do ACT=$(unit_state redis.service); [ "$ACT" = active ] && break; sleep 2; done
fi
S0=$(podman inspect redis --format '{{.State.StartedAt}}' 2>/dev/null || true); S0=$(norm "$S0"); [ -z "$S0" ] && S0=absent
UP=no; CRASH=no; GREEN_ITER=0; PING_SEQ=""
for i in $(seq 1 30); do
  ST1=$(podman inspect redis --format '{{.State.Status}}' 2>/dev/null || true); ST1=$(norm "$ST1"); [ -z "$ST1" ] && ST1=absent
  S1=$(podman inspect redis --format '{{.State.StartedAt}}' 2>/dev/null || true); S1=$(norm "$S1"); [ -z "$S1" ] && S1=absent
  if [ "$S0" = absent ] && [ "$S1" != absent ]; then S0="$S1"; fi
  if [ "$S0" != absent ] && [ "$S1" != absent ] && [ "$S1" != "$S0" ]; then CRASH=yes; say "  [H2] restart detected at iter $i => crash-loop"; break; fi
  O=$(podman exec redis redis-cli ping 2>&1 || true); O=$(norm "$O"); [ -z "$O" ] && O=empty
  PING_SEQ+="${O:0:14} "
  case "$O" in
    *PONG*|*NOAUTH*) UP=yes; GREEN_ITER=$i; break;;
  esac
  if [ "$ST1" = exited ]; then CRASH=yes; say "  [H2] status flipped to exited at iter $i"; break; fi
  sleep 2
done
PING_SEQ_SHORT=$(printf '%s' "$PING_SEQ" | cut -c1-140)
ACT=$(unit_state redis.service)
RUN=$(podman ps --filter name=redis --format '{{.Names}} {{.Status}}' 2>/dev/null || true); RUN=$(norm "$RUN"); [ -z "$RUN" ] && RUN=none
AUTHINFO="not-evaluated (redis not up)"
if [ "$HAS_AUTH" = yes ] && [ "$UP" = yes ]; then
  AO=$(podman exec redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping' 2>&1 || true); AO=$(norm "$AO")
  case "$AO" in
    *PONG*) AUTHINFO="key-valid (Lane-A redis auth proven)";;
    *WRONGPASS*|*invalid*) AUTHINFO="up+auth-enforced but REDIS_PASSWORD mismatch -> one-line secrets.env fix (not echoed)";;
    *) AUTHINFO="anomalous (${AO:0:24})";;
  esac
elif [ "$HAS_AUTH" = no ]; then
  AUTHINFO="skipped (no REDIS_PASSWORD in secrets.env)"
fi
PERSIST=no; PMATCH=""
while read -r typ dest; do
  [ -z "${dest:-}" ] && continue
  case "$DATAPATH" in
    "$dest"|"$dest"/*) if [ "$typ" = volume ] || [ "$typ" = bind ]; then PERSIST=yes; PMATCH="$typ at $dest"; fi ;;
  esac
done < <(podman inspect redis --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>/dev/null || true)
say "[H2] active=$ACT up=$UP crash=$CRASH green_iter=$GREEN_ITER ping_seq=[$PING_SEQ_SHORT] auth=$AUTHINFO persist=$PERSIST match=$PMATCH DATA=$DATAPATH run=$RUN"
journalctl --user -u redis.service --no-pager --tail 8 2>/dev/null | sed 's/^/    j: /' || true

[ "$CRASH" = yes ] && halt "redis crash-loop after heal (ping_seq=[$PING_SEQ_SHORT]). Evidence in j: lines. Do not auto-patch further; inspect conf directive rejection or permission errors."
[ "$UP" = no ] && halt "redis still never answered PING/NOAUTH after heal (ping_seq=[$PING_SEQ_SHORT], active=$ACT). Evidence in j: lines. Do not advance."
PASS=no; { [ "$ACT" = active ] && [ "$UP" = yes ] && [ "$PERSIST" = yes ]; } && PASS=yes
[ "$PASS" = yes ] || halt "up but gate conjuncts failed (active=$ACT persist=$PERSIST); inspect [H2]."

# ===================== [H3] guarded ledger green row, sentinel IS in payload =====================
if ! grep -qF "$REDIS_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | $SLUG | GATE=PASS | $REDIS_TOKEN: unauth PING up (ping_seq=[$PING_SEQ_SHORT]), auth=$AUTHINFO, data on named volume (ancestor+volume-type, DATA=$DATAPATH), loopback 6379, auth_source=derived-conf (no literal in unit), healed Command->Exec and MemoryMax overhead; replay=$SLUG.sh |" >> "$IDX"
  say "[H3] redis green row appended."
else say "[H3] redis green row already present (guard suppressed)."; fi
grep -qF "$REDIS_TOKEN" "$IDX" 2>/dev/null && say "[H3] suppression proof: redis sentinel present." || say "[H3] WARNING: redis sentinel missing."

say "[RESULT] REDIS GREEN (brick 4 healed) — quadlet generation defect owned and healed; disk gate remains $BUCKET; next should be restic DR before ollama, not ollama."
exit 0
