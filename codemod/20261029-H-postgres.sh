#!/usr/bin/env bash
# 20261029-H-postgres.sh — replayable: idempotent initdb + resolve image + render/start/gate postgres.
# Re-run on an ALREADY-initialized volume: initdb.d will NOT re-fire (by design); gate still passes if n8n db exists.
# Clean re-init (e.g. after a half-initialized crash): systemctl --user stop postgres; podman volume rm postgres_data; re-run.
set -uo pipefail
A="$HOME/DevOps/aether"; QD="$A/infra/quadlet"; PGINIT="$A/infra/configs/postgres/initdb"; SYS="$HOME/.config/containers/systemd"
podman volume exists postgres_data 2>/dev/null || podman volume create postgres_data >/dev/null
install -D -m 644 "$QD/postgres.container" "$SYS/postgres.container"
systemctl --user daemon-reload; systemctl --user enable postgres.service 2>/dev/null||true; systemctl --user start postgres.service
for i in $(seq 1 40); do systemctl --user is-active --quiet postgres.service && break; sleep 2; done
R=$(podman exec postgres sh -c 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" && echo ok||echo no' 2>/dev/null)
N=$(podman exec postgres sh -c 'PGPASSWORD="$DB_POSTGRESDB_PASSWORD" psql -U "$DB_POSTGRESDB_USER" -h 127.0.0.1 -d "$DB_POSTGRESDB_DATABASE" -tAc "SELECT 1"' 2>/dev/null)
[ "$R" = ok ] && [ -n "$N" ] && echo "  [GATE PASS] postgres" || { echo "  [GATE FAIL] ready=$R n8n=$N"; exit 1; }
