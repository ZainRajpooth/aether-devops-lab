#!/usr/bin/env bash
# 20261029-AB-llama-embed.sh — replayable brick 5: ensure unit installed+active, gate /health + /v1/embeddings.
set -uo pipefail
A="$HOME/DevOps/aether"
SYSU="$HOME/.config/systemd/user"
SRCU="$A/infra/systemd/llama-embed.service"
install -D -m 644 "$SRCU" "$SYSU/llama-embed.service"
systemctl --user daemon-reload
systemctl --user enable llama-embed.service >/dev/null 2>&1 || true
systemctl --user start llama-embed.service
for i in $(seq 1 30); do
  C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:8081/health 2>/dev/null || true)
  if [ "$C" = 200 ]; then
    break
  fi
  sleep 2
done
D=$(curl -s --max-time 30 -X POST http://127.0.0.1:8081/v1/embeddings -H 'Content-Type: application/json' -d '{"model":"nomic-embed-text","input":"replay"}' 2>/dev/null | python3 -c 'import sys,json
try:
    print(len(json.load(sys.stdin).get("data",[{}])[0].get("embedding",[])))
except Exception:
    print(0)' 2>/dev/null || echo 0)
if [ "$C" = 200 ] && [ "${D:-0}" -gt 0 ]; then
  echo "  [GATE PASS] llama-embed health=200 dims=$D"
else
  echo "  [GATE FAIL] health=${C:-000} dims=${D:-0}"
  exit 1
fi
