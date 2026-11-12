#!/usr/bin/env bash
# 20261112-EX51 — Lane 2: restic->MinIO encrypted backups, restore gate, daily user timer.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"
DOCS="$A/docs"; BK="$A/backups"; STG="$BK/staging/pg"; LOGS="$BK/logs"
TOKEN="ex51-lane2-restic-minio-backup-restore-timer-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"; BUCKET="aether-backups"
REPO="s3:http://127.0.0.1:9010/$BUCKET"
RP="$SEC/restic-repo.pass"; RE="$SEC/restic.env"
SCRIPT="$A/infra/scripts/aether-backup.sh"
SU="$H/.config/systemd/user/aether-backup.service"; TU="$H/.config/systemd/user/aether-backup.timer"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS" "$STG" "$LOGS" "$A/infra/scripts"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
bak(){ [ -f "$1" ] && { cp -p "$1" "$1.pre-ex51.$STAMP.bak"; chmod 600 "$1.pre-ex51.$STAMP.bak"; }; }
DU="$(tr -d '\n\r' < "$SEC/minio-users/minio-normal.user")"
DP="$(tr -d '\n\r' < "$SEC/minio-users/minio-normal.pass")"

hr "X0 probe"
command -v restic >/dev/null 2>&1 && say "restic: $(restic version 2>/dev/null | head -1)" || say "restic: MISSING"
podman ps --format '{{.Names}}' | grep -qx minio && say "minio: up" || halt "minio not running"
[ -s "$RP" ] && say "repo password file: present" || say "repo password file: absent"
[ -f "$RE" ] && say "restic.env: present" || say "restic.env: absent"
systemctl --user is-enabled aether-backup.timer >/dev/null 2>&1 && say "timer: enabled" || say "timer: not enabled"
du -sh "$A" 2>/dev/null | sed 's/^/  source size: /' || true
if [ "$MODE" = check ]; then
  say "plan: install restic if missing -> bucket -> creds(0600) -> init-if-absent -> pg_dumpall ->"
  say "      backup -> restore gate -> retention -> service+timer -> run-once gate -> docs+ledger"
  say "[RESULT] EX51 CHECK - nothing written."; exit 0
fi

hr "X1 restic binary"
if ! command -v restic >/dev/null 2>&1; then
  sudo -v || halt "sudo needed for apt install restic"
  sudo apt-get update -qq && sudo apt-get install -y -qq restic || halt "restic install failed"
fi
say "restic: $(restic version | head -1)"

hr "X2 bucket (devX, idempotent)"
podman exec -i minio sh -c '
  IFS= read -r ak; IFS= read -r sk
  mc alias set bk http://127.0.0.1:9000 "$ak" "$sk" >/dev/null
  mc mb --ignore-existing bk/'"$BUCKET"' >/dev/null && echo "  bucket ok: '"$BUCKET"'"
' < <(printf '%s\n%s\n' "$DU" "$DP") || halt "bucket create failed"

hr "X3 credentials (0600)"
bak "$RP"; bak "$RE"
if [ ! -s "$RP" ]; then python3 -c 'import secrets;print(secrets.token_hex(32))' > "$RP"; chmod 600 "$RP"; say "generated repo password"; else say "reusing repo password"; fi
cat > "$RE" <<ENV
RESTIC_REPOSITORY=$REPO
RESTIC_PASSWORD_FILE=$RP
AWS_ACCESS_KEY_ID=$DU
AWS_SECRET_ACCESS_KEY=$DP
ENV
chmod 600 "$RE"; say "restic.env written (0600)"

hr "X4 init repo if absent"
set -a; . "$RE"; set +a
if restic snapshots >/dev/null 2>&1; then say "repo already initialized (no-op)"; else
  restic init && say "repo initialized" || halt "restic init failed"
fi

hr "X5 postgres dump"
DUMP="$STG/pgdumpall-$STAMP.sql"
podman exec postgres pg_dumpall -U devops > "$DUMP" 2>"$TMP/pg.err" || { cat "$TMP/pg.err" | sed 's/^/    /'; halt "pg_dumpall failed"; }
[ -s "$DUMP" ] || halt "empty dump"
grep -q "PostgreSQL database dump" "$DUMP" || halt "dump content invalid"
ls -1t "$STG"/pgdumpall-*.sql 2>/dev/null | tail -n +4 | xargs -r rm -f
say "dump: $(basename "$DUMP") $(du -h "$DUMP" | cut -f1)"

hr "X6 backup"
restic backup "$A" \
  --exclude "$A/data/minio" \
  --exclude '**/__pycache__' --exclude '**/.venv' --exclude '**/node_modules' \
  --exclude '**/.git/objects/pack/tmp_*' \
  --tag aether --tag lane2 | tail -6 | sed 's/^/    /' || halt "restic backup failed"

hr "X7 RESTORE GATE"
SNAP="$(restic snapshots --json | python3 -c 'import json,sys;print(json.load(sys.stdin)[-1]["short_id"])')"
say "restoring snapshot $SNAP to temp"
restic restore "$SNAP" --target "$TMP/restore" --quiet || halt "restore failed"
CAN="$A/secrets/restic-repo.pass"
python3 - "$CAN" "$TMP/restore$CAN" "$DUMP" "$TMP/restore$DUMP" <<'PY'
import hashlib,sys,os
def h(p): return hashlib.sha256(open(p,'rb').read()).hexdigest()
src,rst,dump,rdump=sys.argv[1:5]
assert os.path.isfile(rst), "canary missing in restore"
assert h(src)==h(rst), "canary sha mismatch"
assert os.path.isfile(rdump), "pg dump missing in restore"
assert b"PostgreSQL database dump" in open(rdump,'rb').read(), "pg dump content invalid"
print("  RESTORE GATE PASS: canary sha match + pg dump verified")
PY
[ $? -eq 0 ] || halt "restore gate failed"
rm -rf "$TMP/restore"

hr "X8 retention + snapshots gate"
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune 2>&1 | tail -3 | sed 's/^/    /' || true
N="$(restic snapshots --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
[ "$N" -ge 1 ] || halt "no snapshots"
say "snapshots: $N"

hr "X9 backup script + service + timer"
bak "$SCRIPT"; bak "$SU"; bak "$TU"
cat > "$SCRIPT" <<'BS'
#!/usr/bin/env bash
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; STG="$A/backups/staging/pg"; LOGS="$A/backups/logs"
mkdir -p "$STG" "$LOGS"
LOG="$LOGS/backup-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOG" 2>&1
set -a; . "$SEC/restic.env"; set +a
echo "[backup] start $(date -Is)"
DUMP="$STG/pgdumpall-$(date +%Y%m%d-%H%M%S).sql"
podman exec postgres pg_dumpall -U devops > "$DUMP" || { echo "[backup] FAIL pg_dumpall"; exit 1; }
ls -1t "$STG"/pgdumpall-*.sql | tail -n +4 | xargs -r rm -f
restic backup "$A" --exclude "$A/data/minio" --exclude '**/__pycache__' --exclude '**/.venv' --exclude '**/node_modules' --tag aether --tag scheduled || { echo "[backup] FAIL restic"; exit 1; }
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune || true
echo "[backup] OK $(date -Is) snapshots=$(restic snapshots --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
BS
chmod 700 "$SCRIPT"
cat > "$SU" <<UNIT
[Unit]
Description=Aether restic backup to MinIO (Lane 2)
After=network-online.target minio.service postgres.service
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
ExecStart=/bin/bash $SCRIPT
UNIT
cat > "$TU" <<UNIT
[Unit]
Description=Daily Aether restic backup

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now aether-backup.timer || halt "timer enable failed"
say "timer: $(systemctl --user is-enabled aether-backup.timer) / $(systemctl --user is-active aether-backup.timer)"
systemctl --user start aether-backup.service || halt "service run failed"
sleep 2
tail -2 "$LOGS"/backup-*.log 2>/dev/null | tail -2 | sed 's/^/    /' || true
grep -q "\[backup\] OK" "$(ls -1t "$LOGS"/backup-*.log | head -1)" || halt "scheduled-path backup did not report OK"
say "service-path backup OK"

hr "X10 docs + debt + ledger"
cat > "$DOCS/backup-runbook.md" <<'MD'
# Backup Runbook (Lane 2)
- Repo: s3:http://127.0.0.1:9010/aether-backups (restic, encrypted; password file secrets/restic-repo.pass)
- Creds: secrets/restic.env (0600) -> devX (readwrite) on MinIO
- Scope: ~/DevOps/aether (excl data/minio, caches, venvs, node_modules) + pg_dumpall staging (newest 3)
- Schedule: aether-backup.timer daily 03:30 (Persistent=true); logs backups/logs/
- Retention: 7 daily / 4 weekly / 3 monthly, prune each run
- Restore: set -a; . secrets/restic.env; set +a; restic snapshots; restic restore <id> --target /tmp/restore
- Restore gate: sha256 canary secrets/restic-repo.pass + pg dump header check (EX51 X7)
- Verify: systemctl --user list-timers aether-backup.timer; restic snapshots; restic check --read-data-subset=1%
MD
cat > "$DOCS/adr-0008-restic-minio-backups.md" <<'MD'
# ADR-0008: restic -> local MinIO for encrypted, deduped, restore-gated backups
Status: accepted (2026-11-12)
Context: single-disk lab; forge/CI/secrets irreplaceable; zero-budget constraint.
Decision: restic (content-defined dedup + AES) to MinIO bucket aether-backups over loopback S3;
systemd user timer; pg_dumpall staged inside scope; restore gate mandatory in codemod.
Consequences: backup shares host disk (not offsite) -> offsite copy is future debt;
MinIO store excluded to avoid recursion; devX least-privilege creds.
MD
python3 - "$DOCS/debt-register.md" <<'PY'
import sys,os
p=sys.argv[1]
add="| 6 | postgres passwords exposed (loopback-only) | low | EX52 AFTER restore point exists (deferred from EX51 to avoid destabilizing healed stack) |\n| 7 | backups on same host disk (no offsite) | medium | future: restic copy to offsite S3/B2 free tier |\n"
if os.path.exists(p):
    t=open(p).read()
    if "| 6 |" not in t: open(p,"a").write(add)
else:
    open(p,"w").write("# Debt register\n"+add)
PY
say "docs: backup-runbook.md, adr-0008, debt-register updated"
hr "X11 RESULT"
say "[RESULT] EX51 COMPLETE - LANE 2 CLOSED: encrypted backups + restore gate + daily timer."
ledger "PASS" "EX51: restic->MinIO init+backup+restore-gate+retention+timer; snapshots=$N; service-path OK"
exit 0
