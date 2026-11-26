#!/usr/bin/env bash
# EX-PIXORB-4 verifier: models exist, no circular import, tables exist in DB. Read-only.
set -uo pipefail
P="$HOME/DevOps/pixorb"; B="$P/backend"; VPY="$HOME/.venvs/pixorb/bin/python"
[ -f "$B/core/models.py" ] && [ -f "$B/core/database.py" ] && echo "  files: PASS" || { echo "[HALT] files"; exit 1; }
grep -q 'from backend.core import models' "$B/alembic/env.py" && echo "  env.py imports models: PASS" || { echo "[HALT] env.py"; exit 1; }
TABLES=$(podman exec -e PGPASSWORD="$(grep '^DB_PASSWORD=' "$P/infra/.env.local" | cut -d= -f2)" postgres psql -U pixorb_user -h 127.0.0.1 -d pixorb -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename IN ('products', 'variants', 'inventory') ORDER BY tablename;")
echo "$TABLES" | grep -q "inventory" && echo "$TABLES" | grep -q "products" && echo "$TABLES" | grep -q "variants" && echo "  DB tables: PASS" || { echo "[HALT] DB tables"; exit 1; }
echo "[RESULT] EX-PIXORB-4 VERIFY PASS"
