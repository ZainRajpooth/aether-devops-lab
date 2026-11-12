#!/bin/bash
# Runs ONCE on first init (empty data dir), as $POSTGRES_USER over local trust socket.
# Idempotent; reads n8n creds from the container env (EnvironmentFile=secrets.env) -> nothing echoed to host.
set -euo pipefail
DB="$DB_POSTGRESDB_DATABASE"; U="$DB_POSTGRESDB_USER"; P="$DB_POSTGRESDB_PASSWORD"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tc \
  "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1 \
  || psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE DATABASE \"$DB\""
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tc \
  "SELECT 1 FROM pg_roles WHERE rolname='$U'" | grep -q 1 \
  || psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE USER \"$U\" WITH PASSWORD '$P'"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB\" TO \"$U\""
