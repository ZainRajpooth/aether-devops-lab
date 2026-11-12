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
