#!/usr/bin/env bash
# EX-PIXORB-2 verifier: gitea repo, pg TCP auth, restic include, venv. Read-only.
set -uo pipefail
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"
U=$(cat "$A/secrets/gitea-admin.user"); PSS=$(cat "$A/secrets/gitea-admin.pass")
PORT=$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')
DB_PASS=$(grep '^DB_PASSWORD=' "$P/infra/.env.local" | cut -d= -f2)
curl -s -o /dev/null -w "%{http_code}" -u "$U:$PSS" "http://127.0.0.1:$PORT/api/v1/repos/$U/pixorb" | grep -q '200' && echo "  gitea: PASS" || { echo "[HALT] gitea"; exit 1; }
podman exec -e PGPASSWORD="$DB_PASS" postgres psql -U pixorb_user -h 127.0.0.1 -d pixorb -Atc 'SELECT 1' | grep -q '^1$' && echo "  postgres: PASS" || { echo "[HALT] postgres"; exit 1; }
grep -q '/home/dev/DevOps/pixorb' "$A/infra/scripts/aether-backup.sh" && echo "  restic: PASS" || { echo "[HALT] restic"; exit 1; }
[ -d "$HOME/.venvs/pixorb" ] && echo "  venv: PASS" || { echo "[HALT] venv"; exit 1; }
echo "[RESULT] EX-PIXORB-2 VERIFY PASS"
