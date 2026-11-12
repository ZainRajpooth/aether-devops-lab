#!/usr/bin/env bash
# 20261029-C-purge-docker-init-podman.sh
# Purpose: Remove dead Docker state after volume loss; initialize clean Podman workspace.
# Context: /var/lib/docker/volumes was empty (data lost); daemon unresponsive.
set -uo pipefail
A="$HOME/DevOps/aether"

echo "--- Removing obsolete directories ---"
rm -rf "$A/02_data_plane" && echo "  removed $A/02_data_plane"
ls -la "$A/legacy/compose/" | sed 's/^/    legacy-ref: /' || true

echo "--- Final Docker Residual Cleanup ---"
sudo rm -rf /var/lib/docker /etc/docker ~/.docker /usr/local/bin/docker* 2>/dev/null || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true
command -v docker >/dev/null && echo "  [WARN] docker binary still in PATH" || echo "  [OK] docker fully purged"

echo "--- Initialize Clean Podman Workspace Structure ---"
mkdir -p "$A/podman"/{quadlets,volumes,configs}
cat > "$A/podman/README.md" <<'INNER'
# Podman Workspace
- quadlets/: systemd .container/.network/.volume units
- volumes/: backup tarballs or import sources
- configs/: static config files (traefik.yml, litellm-config.yaml, etc.)
INNER
echo "  created $A/podman/{quadlets,volumes,configs}"
