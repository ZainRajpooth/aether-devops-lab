#!/usr/bin/env bash
# woodpecker-server-wait.sh — wait until woodpecker-server container is running.
set -uo pipefail
NAME="${1:-woodpecker-server}"
TRIES="${2:-90}"
DELAY="${3:-2}"
for i in $(seq 1 "$TRIES"); do
  st="$(podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null || true)"
  if [ "$st" = running ]; then
    exit 0
  fi
  sleep "$DELAY"
done
echo "woodpecker-server-wait: container '$NAME' not running after $TRIES tries" >&2
exit 1
