#!/usr/bin/env bash
# EX-PIXORB-8d verifier. Read-only.
set -uo pipefail
Q="$HOME/.config/containers/systemd/pixorb-web.container"
grep -q '^PublishPort=127.0.0.1:8101:80$' "$Q" && echo "  PublishPort loopback: PASS" || { echo "[HALT] port"; exit 1; }
ss -ltn 2>/dev/null | grep -q '127.0.0.1:8101 ' && echo "  loopback bound: PASS" || { echo "[HALT] bind"; exit 1; }
! ss -ltn 2>/dev/null | grep -q '0.0.0.0:8101 ' && echo "  no 0.0.0.0 leak: PASS" || { echo "[HALT] leak"; exit 1; }
curl -s --max-time 4 http://127.0.0.1:8101/ | grep -qi '<html' && echo "  direct site: PASS" || { echo "[HALT] direct"; exit 1; }
curl -s --max-time 4 -H 'Host: shop.pixorb.localhost' http://127.0.0.1:8888/ | grep -qi '<html' && echo "  edge site: PASS" || { echo "[HALT] edge"; exit 1; }
echo "[RESULT] EX-PIXORB-8d VERIFY PASS"
