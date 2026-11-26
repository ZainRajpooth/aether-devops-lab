#!/usr/bin/env bash
# EX-PIXORB-6 verifier: push sha match, ruff+pytest local, CI status success. Read-only.
set -uo pipefail
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; VPY="$HOME/.venvs/pixorb/bin/python"
U=$(cat "$A/secrets/gitea-admin.user"); GP=$(cat "$A/secrets/gitea-admin.pass")
PORT=$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')
SHA=$(git -C "$P" rev-parse HEAD)
RSHA=$(curl -s -u "$U:$GP" "http://127.0.0.1:$PORT/api/v1/repos/$U/pixorb/branches/main" | python3 -c 'import json,sys;print(json.load(sys.stdin)["commit"]["id"])')
[ "$SHA" = "$RSHA" ] && echo "  push sha: PASS" || { echo "[HALT] push sha"; exit 1; }
( cd "$P" && "$VPY" -m ruff check backend >/dev/null 2>&1 ) && echo "  ruff: PASS" || { echo "[HALT] ruff"; exit 1; }
( cd "$P" && "$VPY" -m pytest backend/tests -q >/dev/null 2>&1 ) && echo "  pytest: PASS" || { echo "[HALT] pytest"; exit 1; }
curl -s -u "$U:$GP" "http://127.0.0.1:$PORT/api/v1/repos/$U/pixorb/statuses/$SHA" | grep -q '"success"' && echo "  CI success: PASS" || { echo "[HALT] CI"; exit 1; }
echo "[RESULT] EX-PIXORB-6 VERIFY PASS"
