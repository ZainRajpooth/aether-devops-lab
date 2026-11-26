#!/usr/bin/env bash
# EX-PIXORB-8 verifier. Read-only.
set -uo pipefail
FEH="$HOME/DevOps/pixorb/frontend"; TR="$HOME/DevOps/aether/infra/traefik/dynamic/pixorb.yml"
[ -f "$FEH/build/web/main.dart.js" ] && echo "  web build: PASS" || { echo "[HALT] build"; exit 1; }
grep -q 'pixorb-web-router' "$TR" && echo "  shop route in file: PASS" || { echo "[HALT] route file"; exit 1; }
podman ps --format '{{.Names}}' | grep -qx pixorb-web && echo "  nginx container: PASS" || { echo "[HALT] nginx"; exit 1; }
curl -s --max-time 4 -H 'Host: shop.pixorb.localhost' http://127.0.0.1:8888/ | grep -qi '<html' && echo "  shop index: PASS" || { echo "[HALT] index"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: shop.pixorb.localhost' http://127.0.0.1:8888/main.dart.js)" = 200 ] && echo "  main.dart.js: PASS" || { echo "[HALT] dart.js"; exit 1; }
curl -s --max-time 4 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health | grep -q '"db":true' && echo "  api mesh: PASS" || { echo "[HALT] mesh"; exit 1; }
echo "[RESULT] EX-PIXORB-8 VERIFY PASS"
