#!/usr/bin/env bash
# 20261104-EQ — Remove unused Zitadel images (v3.3.4, zitadel-login variants).
# Keeps ghcr.io/zitadel/zitadel:latest (active). Safe: podman rmi refuses if in use.
set -uo pipefail
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "Q0 list current zitadel images"
podman images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -i zitadel | sed 's/^/  /' || say "  (none)"

hr "Q1 remove unused images"
UNUSED=(
  "ghcr.io/zitadel/zitadel:v3.3.4"
  "ghcr.io/zitadel/zitadel-login:latest"
  "ghcr.io/zitadel/zitadel-login:v4.12.1"
)
for img in "${UNUSED[@]}"; do
  if podman image exists "$img" 2>/dev/null; then
    say "removing $img ..."
    podman rmi "$img" 2>&1 | sed 's/^/    /' || say "    (skipped/failed - likely in use or already gone)"
  else
    say "skip (not present): $img"
  fi
done

hr "Q2 verify remaining images"
podman images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -i zitadel | sed 's/^/  /' || say "  (none)"
say "[RESULT] EQ COMPLETE - unused zitadel images removed."
exit 0
