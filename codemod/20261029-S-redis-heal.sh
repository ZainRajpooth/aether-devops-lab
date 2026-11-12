#!/usr/bin/env bash
# 20261029-S-redis-heal.sh — replayable redis brick 4: derive conf atomically, render unit, start, gate.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; SRC="$A/legacy/compose/recovery-runtime.yml"
PYX="$CD/lib/redis_extract.py"; REDIRC="$HOME/.config/aether/redis"
UNIT="$QD/redis.container"; DATAPATH="/data"; WORK="$REDIRC/work.replay.$$"
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
mkdir -p "$REDIRC" "$WORK"
chmod 700 "$REDIRC" "$WORK"
systemctl --user stop redis.service 2>/dev/null || true
systemctl --user reset-failed redis.service 2>/dev/null || true
python3 "$PYX" "$SRC" "$SECRETS" "$DATAPATH" "$REDIRC" "$WORK" || { echo "  [GATE FAIL] extractor"; rm -rf "$WORK"; exit 1; }
rm -rf "$WORK"
install -D -m 644 "$UNIT" "$SYS/redis.container"
systemctl --user daemon-reload
systemctl --user enable redis.service 2>/dev/null || true
systemctl --user start redis.service
UP=no
for i in $(seq 1 30); do
  CST=$(podman inspect redis --format '{{.State.Status}}' 2>/dev/null || true)
  CST=$(norm "$CST")
  if [ "$CST" = running ]; then
    O=$(podman exec redis redis-cli ping 2>&1 || true)
    O=$(norm "$O")
    case "$O" in
      *PONG*|*NOAUTH*)
        UP=yes
        break
        ;;
    esac
  fi
  sleep 2
done
if [ "$UP" = yes ]; then
  echo "  [GATE PASS] redis up"
else
  echo "  [GATE FAIL] redis not up"
  exit 1
fi
