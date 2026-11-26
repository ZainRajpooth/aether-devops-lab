#!/usr/bin/env bash
# EX-PIXORB-10c verifier. Read-only.
set -uo pipefail
P="$HOME/DevOps/pixorb"; EW="$P/infra/.env.worker"
grep -q '^REDIS_PASSWORD=' "$EW" && [ "$(stat -c %a "$EW")" = 600 ] && git -C "$P" check-ignore -q infra/.env.worker \
  && echo "  secret hygiene: PASS" || { echo "[HALT] secret"; exit 1; }
grep -q '^HealthCmd=none' "$P/infra/quadlets/pixorb-worker.container" && echo "  worker healthcheck disabled: PASS" || { echo "[HALT] healthcheck"; exit 1; }
podman ps --filter name=^pixorb-worker$ --format '{{.Names}} {{.Status}}' | grep -q '^pixorb-worker Up' && echo "  worker Up: PASS" || { echo "[HALT] worker"; exit 1; }
N1=$(systemctl --user show pixorb-worker.service -p NRestarts --value); sleep 20
N2=$(systemctl --user show pixorb-worker.service -p NRestarts --value)
[ "$N1" = "$N2" ] && echo "  no crash-loop (20s): PASS" || { echo "[HALT] crash-loop"; exit 1; }
[ "$(systemctl --user list-units --failed --no-legend 2>/dev/null | wc -l)" = 0 ] && echo "  zero failed units: PASS" || { echo "[HALT] failed units"; exit 1; }
echo "[RESULT] EX-PIXORB-10c VERIFY PASS"
