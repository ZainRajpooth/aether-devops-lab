#!/usr/bin/env bash
# EX-PIXORB-7b verifier: image, templates, worker, env hygiene. Read-only.
set -uo pipefail
P="$HOME/DevOps/pixorb"; I="$P/infra"
podman image exists localhost/pixorb:latest && echo "  image: PASS" || { echo "[HALT] image"; exit 1; }
grep -q 'Image=localhost/pixorb:latest' "$I/quadlets/pixorb-api.container" && echo "  image ref: PASS" || { echo "[HALT] image ref"; exit 1; }
grep -q 'Environment=DB_HOST=postgres' "$I/quadlets/pixorb-api.container" && ! grep -q '.env.local' "$I/quadlets/pixorb-api.container" && echo "  env hygiene: PASS" || { echo "[HALT] env"; exit 1; }
[ -f "$P/backend/worker.py" ] && echo "  worker: PASS" || { echo "[HALT] worker"; exit 1; }
[ "$(stat -c %a "$I/.env.container")" = 600 ] && echo "  secret perms: PASS" || { echo "[HALT] perms"; exit 1; }
echo "[RESULT] EX-PIXORB-7b VERIFY PASS"
