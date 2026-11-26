#!/usr/bin/env bash
set -uo pipefail
P="$HOME/DevOps/pixorb"
grep -q '^HealthCmd=\[' "$P/infra/quadlets/pixorb-api.container" && echo "  JSON array HealthCmd: PASS" || { echo "[HALT] HealthCmd format"; exit 1; }
[ "$(podman inspect pixorb-api --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && echo "  container healthy: PASS" || { echo "[HALT] health"; exit 1; }
curl -s --max-time 5 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health | grep -q '"db":true' && echo "  edge health: PASS" || { echo "[HALT] edge"; exit 1; }
echo "[RESULT] REPAIR-21 VERIFY PASS"
