#!/usr/bin/env bash
# podman container metrics -> node-exporter textfile collector (valid exposition format).
set -uo pipefail
OUT="/home/dev/DevOps/aether/infra/configs/node-exporter/podman-stats.prom"
TMP="$OUT.tmp"
human2bytes(){ awk -v s="$1" 'BEGIN{
  mult=1; v=s;
  if (v ~ /KiB$/){sub(/KiB$/,"",v); mult=1024}
  else if (v ~ /MiB$/){sub(/MiB$/,"",v); mult=1048576}
  else if (v ~ /GiB$/){sub(/GiB$/,"",v); mult=1073741824}
  else if (v ~ /TiB$/){sub(/TiB$/,"",v); mult=1099511627776}
  else if (v ~ /B$/){sub(/B$/,"",v)}
  printf "%.0f", v*mult }'; }
{
  echo '# HELP podman_container_cpu_percent Container CPU usage percent'
  echo '# TYPE podman_container_cpu_percent gauge'
  podman stats --no-stream --format '{{.Name}} {{.CPUPerc}}' 2>/dev/null | while read -r name cpu; do
    printf 'podman_container_cpu_percent{name="%s"} %s\n' "$name" "${cpu%\%}"
  done
  echo '# HELP podman_container_memory_bytes Container memory usage bytes'
  echo '# TYPE podman_container_memory_bytes gauge'
  podman stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | while read -r name mem rest; do
    printf 'podman_container_memory_bytes{name="%s"} %s\n' "$name" "$(human2bytes "$mem")"
  done
} > "$TMP"
mv -f "$TMP" "$OUT"
