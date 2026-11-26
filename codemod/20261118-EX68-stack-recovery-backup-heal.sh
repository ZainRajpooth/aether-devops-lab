#!/usr/bin/env bash
# EX68 verifier: stack healthy + backup include mechanism sound. Read-only.
set -uo pipefail
A="$HOME/DevOps/aether"; BS="$A/infra/scripts/aether-backup.sh"
[ "$(systemctl --user list-units --failed --no-legend | wc -l)" = "0" ] && echo "  failed units 0: PASS" || { echo "[HALT] failed units"; exit 1; }
podman ps --format '{{.Names}}' | grep -q '^postgres$' && echo "  postgres: PASS" || { echo "[HALT] postgres"; exit 1; }
grep -q '>>> AETHER RESTIC INCLUDES >>>' "$BS" && { echo "[HALT] marker present"; exit 1; } || echo "  marker removed: PASS"
grep -q -- '--files-from=' "$BS" && echo "  files-from: PASS" || { echo "[HALT] files-from"; exit 1; }
bash -n "$BS" && echo "  syntax: PASS" || { echo "[HALT] syntax"; exit 1; }
echo "[RESULT] EX68 VERIFY PASS"
