#!/usr/bin/env bash
# 20261029-I-minio-brick2.sh — replayable, poll-corrected (J1). Gate = S3 API 200; console INFO.
set -uo pipefail
A="$HOME/DevOps/aether"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
hc(){ curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true; }
podman volume exists minio_data 2>/dev/null || podman volume create minio_data >/dev/null
install -D -m 644 "$QD/minio.container" "$SYS/minio.container"
systemctl --user daemon-reload; systemctl --user enable minio.service 2>/dev/null||true; systemctl --user start minio.service
API=""; CON=""
for i in $(seq 1 30); do API=$(hc http://127.0.0.1:9010/minio/health/live); [ "$API" = 200 ] && break; sleep 2; done
CON=$(hc http://127.0.0.1:9011/)
[ "$API" = 200 ] && echo "  [GATE PASS] minio api=200 console=$CON" || { echo "  [GATE FAIL] api=$API console=$CON"; exit 1; }
