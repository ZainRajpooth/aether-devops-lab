#!/usr/bin/env bash
set -uo pipefail
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; T="$A/infra/traefik"; Q="$HOME/.config/containers/systemd"
[ -f "$T/dynamic/pixorb.yml" ] && echo "  route file: PASS" || { echo "[HALT] route file"; exit 1; }
[ -f "$Q/pixorb-api.container" ] && systemctl --user is-active --quiet pixorb-api.service && echo "  quadlet active: PASS" || { echo "[HALT] quadlet"; exit 1; }
R=$(curl -s --max-time 3 -H "Host: api.pixorb.localhost" http://127.0.0.1:8888/health 2>/dev/null)
echo "$R" | grep -q '"db":true' && echo "  live gate: PASS" || { echo "[HALT] live gate"; exit 1; }
echo "[RESULT] EX-PIXORB-7c VERIFY PASS"
