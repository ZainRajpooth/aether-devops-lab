#!/usr/bin/env bash
# 20261112-EX52b — complete EX52 X3/X4 with authoritative backup gate (snapshot delta + unit Result).
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex52b-complete-restore-point-gate-v1"
MODE="${1:-run}"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
snaps(){ set -a; . "$SEC/restic.env"; set +a; restic snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0; }

hr "X0 probe (read-only)"
systemctl --user cat aether-backup.service 2>/dev/null | grep -E '^ExecStart=' | sed 's/^/    /' || true
SP="$(systemctl --user cat aether-backup.service 2>/dev/null | sed -n 's/^ExecStart=\/bin\/bash //p' | head -1)"
[ -n "$SP" ] && [ -f "$SP" ] && say "backup script present: $SP" || say "backup script MISSING: ${SP:-<unset>}"
say "logs dir entries: $(ls -1 "$A/backups/logs" 2>/dev/null | wc -l)"
ls -1t "$A/backups/logs" 2>/dev/null | head -3 | sed 's/^/    /' || true
journalctl --user -u aether-backup.service -n 12 --no-pager 2>/dev/null | tail -12 | sed 's/^/    /' || true
SN0="$(snaps)"; say "snapshots before: $SN0"
say "rotation marker: $([ -f "$SEC/pg-rotation.sync" ] && echo present || echo absent) (EX52 X2 already applied)"
if [ "$MODE" = check ]; then
  say "plan: start aether-backup.service -> gate on Result=success + ExecMainStatus=0 + snapshots delta -> docs+ledger"
  say "[RESULT] EX52b CHECK - nothing written."; exit 0
fi

hr "X1 authoritative backup gate"
systemctl --user start aether-backup.service; RC=$?
RES="$(systemctl --user show aether-backup.service -p Result --value 2>/dev/null || echo unknown)"
EXS="$(systemctl --user show aether-backup.service -p ExecMainStatus --value 2>/dev/null || echo unknown)"
say "start rc=$RC Result=$RES ExecMainStatus=$EXS"
SN1="$(snaps)"; say "snapshots after: $SN1"
if [ "$RC" != 0 ] || [ "$RES" != success ] || [ "$EXS" != 0 ] || [ "$SN1" -le "$SN0" ]; then
  journalctl --user -u aether-backup.service -n 40 --no-pager 2>/dev/null | tail -30 | sed 's/^/    /'
  find "$A/backups" -name 'backup-*.log' -mmin -15 2>/dev/null | head -3 | sed 's/^/    log: /' || true
  ledger "FAIL" "EX52b backup gate rc=$RC Result=$RES snaps $SN0->$SN1"
  halt "backup gate failed; evidence above"
fi
say "BACKUP GATE PASS: snapshots $SN0 -> $SN1"
find "$A/backups" -name 'backup-*.log' -mmin -15 2>/dev/null | head -1 | while IFS= read -r p; do
  say "newest log (informational): $p"; tail -1 "$p" | sed 's/^/    /'
done

hr "X2 docs + debt + ledger (idempotent)"
python3 - "$DOCS/debt-register.md" <<'PY'
import sys,os
p=sys.argv[1]; add="| 8 | woodpecker DB password (exposed in env dump) | closed | rotated EX52; marker secrets/pg-rotation.sync |\n| 9 | gitea/devops DB passwords loopback-only, not in exposed dump | accepted | rotate in future maintenance window |\n"
t=open(p).read() if os.path.exists(p) else "# Debt register\n"
if "| 8 |" not in t: open(p,"w").write(t+add)
PY
if ! grep -q "Credential rotation (EX52)" "$DOCS/backup-runbook.md" 2>/dev/null; then
cat >> "$DOCS/backup-runbook.md" <<'MD'

## Credential rotation (EX52)
- woodpecker DB role rotated; env WOODPECKER_DATABASE_PASSWORD + DATASOURCE synced; marker secrets/pg-rotation.sync
- Backup gate is authoritative: unit Result=success + restic snapshot delta (log path is informational only)
- gitea/devops DB passwords: accepted loopback-only risk (not in exposed dump)
MD
fi
say "docs updated (guarded)"
hr "X3 RESULT"
say "[RESULT] EX52b COMPLETE - EX52 closed: hygiene + rotation + verified restore point (snapshots=$SN1)."
ledger "PASS" "EX52b: authoritative backup gate PASS snapshots $SN0->$SN1; EX52 fully closed"
exit 0
