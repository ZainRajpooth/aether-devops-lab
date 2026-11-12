#!/usr/bin/env bash
# aether-dns-wait.sh v3.4 (DD): rootless-correct. Canary = IN-NETNS getent (the only
# valid DNS proof under rootless-netns). Per-host = host-side podman inspect running
# (ZERO containers). Heal = restart postgres once (proven netavark->aardvark respawn).
# Bounded: at most 4 canary getents total per invocation (NOT a 90-loop).
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
CANARY="${AETHER_DNS_CANARY:-postgres}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2; exit 2; fi
canary_up(){
  local a
  a="$(timeout 20 podman run --rm --network "$NET" "$ALPINE" getent hosts "$CANARY" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$a" in
    127.*|::1|"") return 1 ;;
    *) return 0 ;;
  esac
}
running(){ if [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; then return 0; else return 1; fi; }
heal(){ if podman inspect "$CANARY" >/dev/null 2>&1; then timeout 45 podman restart "$CANARY" >/dev/null 2>&1 || true; fi; }
if ! canary_up; then heal; fi
i=1; while [ "$i" -le 3 ]; do if canary_up; then break; fi; sleep 2; i=$((i+1)); done
if ! canary_up; then echo "dns-wait: canary $CANARY not resolvable in-netns after heal" >&2; exit 1; fi
echo "dns-wait: canary $CANARY resolves in-netns (aardvark up)"
for h in "${hosts[@]}"; do
  if running "$h"; then echo "dns-wait: $h running"; continue; fi
  ok=0; i=1
  while [ "$i" -le 60 ]; do if running "$h"; then ok=1; break; fi; sleep 1; i=$((i+1)); done
  if [ "$ok" -ne 1 ]; then echo "dns-wait: dependency '$h' not running after 60s" >&2; exit 1; fi
  echo "dns-wait: $h running"
done
exit 0
