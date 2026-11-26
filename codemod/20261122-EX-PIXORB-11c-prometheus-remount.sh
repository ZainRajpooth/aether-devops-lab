#!/usr/bin/env bash
# EX-PIXORB-11c verifier. Read-only.
set -uo pipefail
podman exec prometheus sh -c 'grep -q "job_name: pixorb" /etc/prometheus/prometheus.yml' 2>/dev/null \
  && echo "  container config current: PASS" || { echo "[HALT] stale config"; exit 1; }
python3 - <<'PY' || { echo "[HALT] scrape"; exit 1; }
import json, sys, urllib.request
with urllib.request.urlopen("http://127.0.0.1:9090/api/v1/targets", timeout=5) as r:
    ts = json.load(r).get("data", {}).get("activeTargets", [])
px = [t for t in ts if t.get("labels", {}).get("job") == "pixorb"]
ok = bool(px) and px[0].get("health") == "up"
print("  scrape up: PASS" if ok else "  scrape up: FAIL")
sys.exit(0 if ok else 1)
PY
curl -s http://127.0.0.1:9100/metrics | grep -q 'podman_container_cpu_percent' && echo "  podman cpu metric: PASS" || { echo "[HALT] cpu metric"; exit 1; }
curl -s http://127.0.0.1:9100/metrics | grep -q 'podman_container_memory_bytes' && echo "  podman memory metric: PASS" || { echo "[HALT] memory metric"; exit 1; }
curl -s --max-time 3 -H "Host: api.pixorb.localhost" http://127.0.0.1:8888/metrics | grep -q '^http_requests_total' && echo "  loopback metrics: PASS" || { echo "[HALT] loopback"; exit 1; }
curl -s --max-time 3 -H "Host: api.pixorb.localhost" http://127.0.0.1:8888/health | grep -q '"db":true' && echo "  api mesh: PASS" || { echo "[HALT] mesh"; exit 1; }
systemctl --user is-active --quiet pixorb-worker.service && echo "  worker active: PASS" || { echo "[HALT] worker"; exit 1; }
echo "[RESULT] EX-PIXORB-11c VERIFY PASS"
