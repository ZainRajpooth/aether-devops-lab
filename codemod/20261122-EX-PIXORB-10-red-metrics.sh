#!/usr/bin/env bash
# EX-PIXORB-10 verifier. Read-only.
set -uo pipefail
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; VPY="$HOME/.venvs/pixorb/bin/python"
grep -q 'MetricsMiddleware' "$P/backend/api/main.py" && echo "  wiring: PASS" || { echo "[HALT] wiring"; exit 1; }
( cd "$P" && "$VPY" -m ruff check backend >/dev/null 2>&1 ) && echo "  ruff: PASS" || { echo "[HALT] ruff"; exit 1; }
( cd "$P" && "$VPY" -m pytest backend/tests -q >/dev/null 2>&1 ) && echo "  pytest: PASS" || { echo "[HALT] pytest"; exit 1; }
curl -s --max-time 3 http://127.0.0.1:8100/__metrics_probe__ >/dev/null
M=$(curl -s --max-time 5 http://127.0.0.1:8100/metrics)
echo "$M" | grep -q '^http_requests_total' && echo "  RED counters: PASS" || { echo "[HALT] counters"; exit 1; }
echo "$M" | grep -q 'http_request_duration_seconds_bucket' && echo "  histogram: PASS" || { echo "[HALT] histogram"; exit 1; }
H=$(curl -s --max-time 3 -H "Host: api.pixorb.localhost" http://127.0.0.1:8888/health)
case "$H" in *'"db":true'*) echo "  mesh health: PASS";; *) echo "[HALT] mesh"; exit 1;; esac
echo "[RESULT] EX-PIXORB-10 VERIFY PASS"
