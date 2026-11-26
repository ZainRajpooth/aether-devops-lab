#!/usr/bin/env bash
# EX-PIXORB-5b verifier: test DB, conftest+dispose fixture, no datetime.utcnow, full suite green.
set -uo pipefail
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; B="$P/backend"; VPY="$HOME/.venvs/pixorb/bin/python"
SU_USER=$(grep -m1 '^POSTGRES_USER=' "$A/secrets/postgres.env" | cut -d= -f2- | tr -d '\r')
SU_PASS=$(grep -m1 '^POSTGRES_PASSWORD=' "$A/secrets/postgres.env" | cut -d= -f2- | tr -d '\r')
SU_DB=$(grep -m1 '^POSTGRES_DB=' "$A/secrets/postgres.env" | cut -d= -f2- | tr -d '\r')
podman exec -e PGPASSWORD="$SU_PASS" postgres psql -U "$SU_USER" -h 127.0.0.1 -d "$SU_DB" -tAc "SELECT 1 FROM pg_database WHERE datname='pixorb_test'" | grep -q '^1$' && echo "  test DB: PASS" || { echo "[HALT] test DB"; exit 1; }
grep -q '_dispose_app_engine' "$B/tests/conftest.py" && echo "  dispose fixture: PASS" || { echo "[HALT] fixture"; exit 1; }
grep -q 'datetime.utcnow' "$B/core/models.py" && { echo "[HALT] utcnow"; exit 1; } || echo "  utcnow healed: PASS"
( cd "$P" && "$VPY" -m pytest backend/tests -q >/dev/null 2>&1 ) && echo "  full suite: PASS" || { echo "[HALT] suite"; exit 1; }
echo "[RESULT] EX-PIXORB-5b VERIFY PASS"
