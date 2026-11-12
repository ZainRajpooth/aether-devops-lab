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
# retention handled weekly by aether-backup-prune.timer (EX52c): per-run backups are append-only
echo "[backup] OK $(date -Is) snapshots=$(restic snapshots --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
