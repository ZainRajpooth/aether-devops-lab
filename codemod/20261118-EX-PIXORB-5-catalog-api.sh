#!/usr/bin/env bash
# EX-PIXORB-5 verifier: schemas, routers, live CRUD tests. Read-only.
set -uo pipefail
P="$HOME/DevOps/pixorb"; B="$P/backend"; VPY="$HOME/.venvs/pixorb/bin/python"
[ -f "$B/core/schemas.py" ] && [ -f "$B/api/routers/products.py" ] && echo "  files: PASS" || { echo "[HALT] files"; exit 1; }
( cd "$P" && "$VPY" -m pytest backend/tests/test_catalog.py -q >/dev/null 2>&1 ) && echo "  pytest: PASS" || { echo "[HALT] pytest"; exit 1; }
echo "[RESULT] EX-PIXORB-5 VERIFY PASS"
