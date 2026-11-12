#!/usr/bin/env bash
# 20261029-E-podman-foundation-exemplar.sh — replayable: ensure net + render/start/gate node-exporter.
# (P0 engine-smoke + P1 secrets-skeleton are one-time/ idempotent; omitted here. Run from a green engine.)
set -uo pipefail
A="$HOME/DevOps/aether"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
podman network exists aether 2>/dev/null || podman network create aether >/dev/null
install -D -m 644 "$QD/node-exporter.container" "$SYS/node-exporter.container"
systemctl --user daemon-reload
systemctl --user enable node-exporter.service 2>/dev/null || true
systemctl --user start node-exporter.service
for i in $(seq 1 15); do systemctl --user is-active --quiet node-exporter.service && break; sleep 2; done
ACT=$(systemctl --user is-active node-exporter.service); HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:9100/metrics)
[ "$ACT" = active ] && [ "$HTTP" = 200 ] && echo "  [GATE PASS] node-exporter" || { echo "  [GATE FAIL] active=$ACT http=$HTTP"; exit 1; }
