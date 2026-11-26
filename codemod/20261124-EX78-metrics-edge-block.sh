#!/usr/bin/env bash
# EX78 verifier. No file writes. Generates one counted probe so the Counter has a sample.
set -uo pipefail
TR="$HOME/DevOps/aether/infra/traefik/dynamic/pixorb.yml"
grep -q '!PathPrefix(`/metrics`)' "$TR" && echo "  rule anchor: PASS" || { echo "[HALT] rule"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/metrics)" = 404 ] && echo "  edge /metrics 404: PASS" || { echo "[HALT] edge"; exit 1; }
curl -s --max-time 5 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health | grep -q '"db":true' && echo "  edge /health: PASS" || { echo "[HALT] health"; exit 1; }
curl -s --max-time 6 http://127.0.0.1:9090/api/v1/targets | grep -q '"job":"pixorb"' && echo "  scrape target: PASS" || { echo "[HALT] scrape"; exit 1; }
curl -s -o /dev/null --max-time 4 http://127.0.0.1:8100/__metrics_probe__
curl -s --max-time 5 http://127.0.0.1:8100/metrics | grep -q '^http_requests_total{' && echo "  debug 8100 sample: PASS" || { echo "[HALT] debug"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: shop.pixorb.localhost' http://127.0.0.1:8888/)" = 200 ] && echo "  shop edge: PASS" || { echo "[HALT] shop"; exit 1; }
echo "[RESULT] EX78 VERIFY PASS"
