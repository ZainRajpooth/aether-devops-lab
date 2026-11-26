#!/usr/bin/env bash
# EX-PIXORB-7 verifier: Containerfile, quadlet templates, Traefik labels. Read-only.
set -uo pipefail
P="$HOME/DevOps/pixorb"; INFRA="$P/infra"
[ -f "$INFRA/Containerfile" ] && echo "  Containerfile: PASS" || { echo "[HALT] Containerfile"; exit 1; }
[ -f "$INFRA/quadlets/pixorb-api.container" ] && [ -f "$INFRA/quadlets/pixorb-worker.container" ] && echo "  quadlets: PASS" || { echo "[HALT] quadlets"; exit 1; }
grep -q 'traefik.http.routers.pixorb-api.rule' "$INFRA/quadlets/pixorb-api.container" && echo "  Traefik labels: PASS" || { echo "[HALT] labels"; exit 1; }
echo "[RESULT] EX-PIXORB-7 VERIFY PASS"
