#!/usr/bin/env bash
set -uo pipefail
P="$HOME/DevOps/pixorb"
grep -q 'uv pip install --python /opt/venv/bin/python -r /tmp/requirements.lock' "$P/infra/Containerfile" && echo "  Containerfile wired: PASS" || { echo "[HALT] wiring"; exit 1; }
grep -q '^COPY requirements.lock' "$P/infra/Containerfile" && echo "  lock COPY present: PASS" || { echo "[HALT] COPY"; exit 1; }
podman image exists localhost/pixorb:ex84check && echo "  candidate present: PASS" || { echo "[HALT] candidate"; exit 1; }
bash "$P/infra/scripts/lock-verify.sh" >/dev/null 2>&1 && echo "  drift gate: PASS" || { echo "[HALT] drift"; exit 1; }
podman ps --filter name=^pixorb-api$ --format '{{.Image}}' | grep -q 'localhost/pixorb:latest' && echo "  running untouched: PASS" || { echo "[HALT] running"; exit 1; }
echo "  NEXT: promote ex84check -> latest behind health gate (separate brick)"
echo "[RESULT] EX84 VERIFY PASS"
