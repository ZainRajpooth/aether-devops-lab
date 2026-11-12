# Backup Runbook (Lane 2)
- Repo: s3:http://127.0.0.1:9010/aether-backups (restic, encrypted; password file secrets/restic-repo.pass)
- Creds: secrets/restic.env (0600) -> devX (readwrite) on MinIO
- Scope: ~/DevOps/aether (excl data/minio, caches, venvs, node_modules) + pg_dumpall staging (newest 3)
- Schedule: aether-backup.timer daily 03:30 (Persistent=true); logs backups/logs/
- Retention: 7 daily / 4 weekly / 3 monthly, prune each run
- Restore: set -a; . secrets/restic.env; set +a; restic snapshots; restic restore <id> --target /tmp/restore
- Restore gate: sha256 canary secrets/restic-repo.pass + pg dump header check (EX51 X7)
- Verify: systemctl --user list-timers aether-backup.timer; restic snapshots; restic check --read-data-subset=1%

## Append-only + weekly prune (EX52c)
- aether-backup.sh: backup only (no forget/prune in the backup transaction)
- aether-backup-prune.timer: Sun 04:00 -> forget --keep-last 14 --prune; logs backups/logs/prune-*.log
- Gate: new snapshot short_id must appear AND count must increase by exactly 1
- Manual prune: systemctl --user start aether-backup-prune.service
