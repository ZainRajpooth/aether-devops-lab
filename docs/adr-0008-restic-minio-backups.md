# ADR-0008: restic -> local MinIO for encrypted, deduped, restore-gated backups
Status: accepted (2026-11-12)
Context: single-disk lab; forge/CI/secrets irreplaceable; zero-budget constraint.
Decision: restic (content-defined dedup + AES) to MinIO bucket aether-backups over loopback S3;
systemd user timer; pg_dumpall staged inside scope; restore gate mandatory in codemod.
Consequences: backup shares host disk (not offsite) -> offsite copy is future debt;
MinIO store excluded to avoid recursion; devX least-privilege creds.

## EX52c amendment (2026-11-12)
Measured: restic keeps oldest+newest per bucket; per-run `forget --keep-daily/weekly/monthly --prune`
collapsed intra-day history to a constant 2 snapshots, making count-based gates false-negative.
Decision: per-run backups are APPEND-ONLY; retention moves to weekly aether-backup-prune.timer
(Sun 04:00, `forget --keep-last 14 --prune`). Backup gates use snapshot-ID delta + count+1.
Consequence: intra-day restore points survive up to 14 snapshots (~<=200 MiB bound).
