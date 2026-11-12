#!/usr/bin/env bash
# Hang-free ordered bring-up; client-side timeout only (killing client does NOT
# cancel the systemd job). State capture trimmed so activating shows cleanly.
set -uo pipefail
order=(postgres redis minio weaviate prometheus node-exporter mailpit llama-embed-container litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik)
for u in "${order[@]}"; do
  timeout 45 systemctl --user start "$u.service" >/dev/null 2>&1
  rc=$?
  st="$(systemctl --user is-active "$u.service" 2>/dev/null | tr -d '\n')"
  [ -z "$st" ] && st="?"
  printf '  %-26s dispatch_rc=%-4s state=%s\n' "$u" "$rc" "$st"
done
sleep 6
printf 'containers running: %s\n' "$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)"
