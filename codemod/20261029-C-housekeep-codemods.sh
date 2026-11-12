#!/usr/bin/env bash
# 20261029-C-housekeep-codemods.sh
# Purpose: Consolidate failed/intermediate scripts into codemod/; fix linger; verify pilot readiness.
set -uo pipefail
A="$HOME/DevOps/aether"; SCAFFOLD="$HOME/scaffold-aether-root.sh"

echo "--- Archiving Failed Scaffold Attempt ---"
if [ -f "$SCAFFOLD" ]; then
  install -D -m 755 "$SCAFFOLD" "$A/codemod/20261027-B-scaffold-aether-root.sh"
  echo "| $(date +%F) | B | 20261027-B-scaffold-aether-root | FAILED P2 (guard fired) | Archived failure |" >> "$A/codemod/INDEX.md"
  rm -f "$SCAFFOLD"
fi

echo "--- Cleaning Stale aether2 ---"
[ -d "$A/../aether2" ] && { rm -rf "$A/../aether2" && echo "  removed stale aether2"; } || echo "  aether2 absent"

echo "--- Fix Linger (Silent Boot Trap) ---"
L=$(loginctl show-user "$USER" --property=Linger | cut -d= -f2)
[ "$L" = "no" ] && loginctl enable-linger "$USER" && echo "  linger enabled" || echo "  linger already yes"

echo "--- Verify Pilot Units Rendered ---"
systemctl --user list-unit-files --no-legend | grep -E 'node-exporter|prometheus|mailpit' | sed 's/^/  unit: /'
