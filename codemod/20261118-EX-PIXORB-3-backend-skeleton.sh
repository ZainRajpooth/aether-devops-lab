#!/usr/bin/env bash
# EX-PIXORB-3 verifier: files, secret-free ini, live-DB pytest, async alembic. Read-only.
set -uo pipefail
P="$HOME/DevOps/pixorb"; B="$P/backend"; VPY="$HOME/.venvs/pixorb/bin/python"
[ -f "$B/api/main.py" ] && [ -f "$B/core/database.py" ] && [ -f "$B/alembic/env.py" ] && echo "  files: PASS" || { echo "[HALT] files"; exit 1; }
grep -q 'asyncpg://' "$B/alembic.ini" && { echo "[HALT] secret in ini"; exit 1; } || echo "  secret-free ini: PASS"
( cd "$P" && "$VPY" -m pytest backend/tests -q >/dev/null 2>&1 ) && echo "  pytest: PASS" || { echo "[HALT] pytest"; exit 1; }
( cd "$P" && "$VPY" -m alembic -c backend/alembic.ini current >/dev/null 2>&1 ) && echo "  alembic: PASS" || { echo "[HALT] alembic"; exit 1; }
echo "[RESULT] EX-PIXORB-3 VERIFY PASS"
