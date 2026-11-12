#!/usr/bin/env bash
# 20261029-F-replicate-pilots.sh — replayable from a green engine: clean prom+mailpit, pull, vol, render, gate.
set -uo pipefail
A="$HOME/DevOps/aether"; QD="$A/infra/quadlet"; CFG="$A/infra/configs/prometheus"; SYS="$HOME/.config/containers/systemd"
mkdir -p "$CFG"
podman pull docker.io/prom/prometheus:latest >/dev/null && podman pull docker.io/axllent/mailpit:latest >/dev/null || { echo "  [ABORT] pull"; exit 3; }
podman volume exists prometheus_data 2>/dev/null || podman volume create prometheus_data >/dev/null
for u in prometheus mailpit; do install -D -m 644 "$QD/$u.container" "$SYS/$u.container"; systemctl --user daemon-reload; systemctl --user enable "$u.service" 2>/dev/null||true; systemctl --user start "$u.service"; done
for i in $(seq 1 15); do a=$(systemctl --user is-active prometheus.service); b=$(systemctl --user is-active mailpit.service); [ "$a" = active ]&&[ "$b" = active ]&&break; sleep 2; done
p=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:9090/-/healthy); m=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:8025/)
[ "$p" = 200 ]&&[ "$m" = 200 ]&&echo "  [GATE PASS] pilots"||{ echo "  [GATE FAIL] prom=$p mail=$m"; exit 1; }
