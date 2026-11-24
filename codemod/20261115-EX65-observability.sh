#!/usr/bin/env bash
# EX65 - Observability: Prometheus retention, node-exporter textfile collector,
# podman-stats script/timer, Grafana Postgres datasource provisioning.
set -uo pipefail
A="$HOME/DevOps/aether"; IDX="$A/codemod/INDEX.md"; H="$HOME"
LEDGER="ex65-observability-v1"; MODE="${1:-run}"
QDIR="$H/.config/containers/systemd"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
hr "X0 gates on applied state"
grep -q 'storage.tsdb.retention.time=7d' "$QDIR/prometheus.container" && say "prometheus retention: 7d" || halt "prometheus retention missing"
grep -q 'Exec=--collector.textfile.directory=/var/lib/node_exporter' "$QDIR/node-exporter.container" && say "node-exporter textfile: wired" || halt "node-exporter textfile missing"
[ -x "$A/infra/scripts/podman-stats.sh" ] && say "podman-stats.sh: present+executable" || halt "podman-stats.sh missing"
systemctl --user is-enabled podman-stats.timer >/dev/null && say "podman-stats.timer: enabled" || halt "podman-stats.timer not enabled"
[ -f "$A/config/grafana/provisioning/datasources/postgres.yaml" ] && say "grafana postgres datasource: provisioned" || halt "grafana datasource missing"
CPU_COUNT=$(curl -s http://127.0.0.1:9100/metrics | grep -c '^podman_container_cpu_percent' || echo 0)
[ "$CPU_COUNT" -ge 17 ] && say "live metrics: $CPU_COUNT containers" || halt "live metrics < 17 (got $CPU_COUNT)"
if [ "$MODE" = check ]; then say "[RESULT] EX65 CHECK - nothing written."; exit 0; fi
hr "X1 idempotent assertions (fix if drifted)"
# Prometheus
if ! grep -q 'storage.tsdb.retention.time=7d' "$QDIR/prometheus.container"; then
  sed -i '/--storage.tsdb.path=/ s|$| --storage.tsdb.retention.time=7d|' "$QDIR/prometheus.container"
  systemctl --user daemon-reload; systemctl --user restart prometheus.service
  say "prometheus retention fixed and restarted"
else say "prometheus retention: no-op"; fi
# Node-exporter
if ! grep -q 'Exec=--collector.textfile.directory=/var/lib/node_exporter' "$QDIR/node-exporter.container"; then
  sed -i '/^\[Container\]/a Exec=--collector.textfile.directory=/var/lib/node_exporter' "$QDIR/node-exporter.container"
  systemctl --user daemon-reload; systemctl --user restart node-exporter.service
  say "node-exporter textfile fixed and restarted"
else say "node-exporter textfile: no-op"; fi
# Podman stats trigger (ensure fresh file)
systemctl --user start podman-stats.service
sleep 2
[ -f "$A/infra/configs/node-exporter/podman.prom" ] && say "podman.prom: fresh" || halt "podman.prom not written"
hr "X2 ledger"
grep -qF "$LEDGER:PASS" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "$LEDGER:PASS" "prom 7d retention; node-exp textfile; podman-stats timer; grafana pg datasource; 17 live metrics" >> "$IDX"
say "ledger: $LEDGER:PASS"
say "[RESULT] EX65 COMPLETE (record + idempotent replay)."
exit 0
