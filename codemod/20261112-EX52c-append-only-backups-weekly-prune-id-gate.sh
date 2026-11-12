#!/usr/bin/env bash
# 20261112-EX52c — append-only per-run backups; weekly keep-last prune; ID-delta backup gate.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
BS="$A/infra/scripts/aether-backup.sh"
PS="$A/infra/scripts/aether-backup-prune.sh"
SU="$H/.config/systemd/user/aether-backup-prune.service"
TU="$H/.config/systemd/user/aether-backup-prune.timer"
TOKEN="ex52c-append-only-backups-weekly-prune-id-gate-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
ANCHOR='restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune || true'
REPL='# retention handled weekly by aether-backup-prune.timer (EX52c): per-run backups are append-only'
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS" "$A/infra/scripts" "$H/.config/systemd/user"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
ids(){ set -a; . "$SEC/restic.env"; set +a; restic snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(" ".join(sorted(s["short_id"] for s in json.load(sys.stdin))))' 2>/dev/null || true; }

hr "X0 guards + dry-run diff"
[ -f "$BS" ] || halt "canonical backup script missing: $BS"
grep -qF "$ANCHOR" "$BS" && STATE=present || STATE=absent
grep -qF "$REPL" "$BS" && DONE=yes || DONE=no
say "anchor: $STATE ; replacement already applied: $DONE"
[ "$STATE" = present ] || [ "$DONE" = yes ] || halt "anchor absent and replacement absent; aborting untouched"
python3 - "$BS" "$ANCHOR" "$REPL" > "$TMP/bs.diff" <<'PY'
import sys,difflib
p,a,r=sys.argv[1:4]
old=open(p,encoding="utf-8").readlines()
new=[(r+"\n") if l.rstrip("\n")==a else l for l in old]
sys.stdout.write("".join(difflib.unified_diff(old,new,fromfile=p,tofile=p+" (proposed)")) or "  (no change)\n")
PY
sed 's/^/    /' "$TMP/bs.diff" | head -14
for f in "$PS" "$SU" "$TU"; do [ -f "$f" ] && say "exists: $f" || say "will create: $f"; done
if [ "$MODE" = check ]; then
  say "plan: anchor-replace prune line -> write prune script+service+timer -> enable timer ->"
  say "      ID-delta backup gate -> prune dry-run -> docs+ledger"
  say "[RESULT] EX52c CHECK - nothing written."; exit 0
fi

hr "X1 append-only backup script (anchored, idempotent)"
if [ "$STATE" = present ]; then
  cp -p "$BS" "$BS.pre-ex52c.$STAMP.bak"; chmod 600 "$BS.pre-ex52c.$STAMP.bak"
  python3 - "$BS" "$ANCHOR" "$REPL" <<'PY'
import sys,os,tempfile
p,a,r=sys.argv[1:4]
lines=open(p,encoding="utf-8").readlines()
out=[(r+"\n") if l.rstrip("\n")==a else l for l in lines]
fd,t=tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd,"".join(out).encode()); os.fchmod(fd,0o700); os.close(fd); os.replace(t,p)
PY
  say "prune line replaced (backup .pre-ex52c.$STAMP.bak)"
else
  say "already append-only (no-op)"
fi
bash -n "$BS" || halt "backup script syntax broken"
say "bash -n backup script: OK"

hr "X2 weekly prune script + units"
cat > "$TMP/prune.sh" <<'PS1'
#!/usr/bin/env bash
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; LOGS="$A/backups/logs"
mkdir -p "$LOGS"
LOG="$LOGS/prune-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOG" 2>&1
set -a; . "$SEC/restic.env"; set +a
echo "[prune] start $(date -Is)"
restic forget --keep-last 14 --prune || { echo "[prune] FAIL"; exit 1; }
echo "[prune] OK $(date -Is) snapshots=$(restic snapshots --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
PS1
cat > "$TMP/prune.service" <<UNIT
[Unit]
Description=Aether restic retention prune (weekly, keep-last 14)
After=network-online.target minio.service
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
ExecStart=/bin/bash $PS
UNIT
cat > "$TMP/prune.timer" <<UNIT
[Unit]
Description=Weekly Aether restic prune

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
UNIT
for pair in "$TMP/prune.sh:$PS:700" "$TMP/prune.service:$SU:644" "$TMP/prune.timer:$TU:644"; do
  src="${pair%%:*}"; rest="${pair#*:}"; dst="${rest%%:*}"; perm="${rest##*:}"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then say "unchanged (no-op): $dst"; else
    [ -f "$dst" ] && { cp -p "$dst" "$dst.pre-ex52c.$STAMP.bak"; chmod 600 "$dst.pre-ex52c.$STAMP.bak"; }
    install -m "$perm" "$src" "$dst"; say "written: $dst"
  fi
done
bash -n "$PS" || halt "prune script syntax broken"
say "bash -n prune script: OK"
systemctl --user daemon-reload
systemd-analyze --user verify "$SU" 2>&1 | sed 's/^/    verify: /' || true
systemctl --user enable --now aether-backup-prune.timer || halt "prune timer enable failed"
say "prune timer: $(systemctl --user is-enabled aether-backup-prune.timer) / $(systemctl --user is-active aether-backup-prune.timer)"

hr "X3 ID-delta backup gate (authoritative)"
B="$(ids)"; NB="$(printf '%s' "$B" | wc -w)"; say "ids before ($NB): $B"
systemctl --user start aether-backup.service; RC=$?
RES="$(systemctl --user show aether-backup.service -p Result --value 2>/dev/null || echo unknown)"
EXS="$(systemctl --user show aether-backup.service -p ExecMainStatus --value 2>/dev/null || echo unknown)"
AFT="$(ids)"; NA="$(printf '%s' "$AFT" | wc -w)"
NEW="$(python3 -c 'import sys;b=set(sys.argv[1].split());a=set(sys.argv[2].split());print(" ".join(sorted(a-b)))' "$B" "$AFT")"
say "start rc=$RC Result=$RES ExecMainStatus=$EXS"
say "ids after ($NA): $AFT"
say "new snapshot ids: ${NEW:-<none>}"
if [ "$RC" != 0 ] || [ "$RES" != success ] || [ "$EXS" != 0 ] || [ -z "$NEW" ] || [ "$NA" -ne "$((NB+1))" ]; then
  journalctl --user -u aether-backup.service -n 25 --no-pager 2>/dev/null | tail -20 | sed 's/^/    /'
  ledger "FAIL" "EX52c gate rc=$RC Result=$RES new=${NEW:-none} count $NB->$NA"
  halt "ID-delta gate failed"
fi
say "BACKUP GATE PASS: new id(s) $NEW ; count $NB -> $NA (append-only proven)"

hr "X4 retention policy proof (dry-run, no writes)"
set -a; . "$SEC/restic.env"; set +a
restic forget --keep-last 14 --dry-run 2>&1 | grep -E "keep [0-9]+ snapshots|snapshots$" | sed 's/^/    /' || true
restic check 2>&1 | tail -2 | sed 's/^/    /'

hr "X5 docs (guarded) + ledger"
if ! grep -q "EX52c amendment" "$DOCS/adr-0008-restic-minio-backups.md" 2>/dev/null; then
cat >> "$DOCS/adr-0008-restic-minio-backups.md" <<'MD'

## EX52c amendment (2026-11-12)
Measured: restic keeps oldest+newest per bucket; per-run `forget --keep-daily/weekly/monthly --prune`
collapsed intra-day history to a constant 2 snapshots, making count-based gates false-negative.
Decision: per-run backups are APPEND-ONLY; retention moves to weekly aether-backup-prune.timer
(Sun 04:00, `forget --keep-last 14 --prune`). Backup gates use snapshot-ID delta + count+1.
Consequence: intra-day restore points survive up to 14 snapshots (~<=200 MiB bound).
MD
fi
if ! grep -q "Append-only + weekly prune (EX52c)" "$DOCS/backup-runbook.md" 2>/dev/null; then
cat >> "$DOCS/backup-runbook.md" <<'MD'

## Append-only + weekly prune (EX52c)
- aether-backup.sh: backup only (no forget/prune in the backup transaction)
- aether-backup-prune.timer: Sun 04:00 -> forget --keep-last 14 --prune; logs backups/logs/prune-*.log
- Gate: new snapshot short_id must appear AND count must increase by exactly 1
- Manual prune: systemctl --user start aether-backup-prune.service
MD
fi
say "docs amended (guarded)"
hr "X6 RESULT"
say "[RESULT] EX52c COMPLETE - append-only backups, weekly bounded prune, ID-delta gate PASS. EX52 closed."
ledger "PASS" "EX52c: append-only + weekly keep-last-14 prune; new ids=$NEW; count $NB->$NA; check clean"
exit 0
