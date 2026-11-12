#!/usr/bin/env bash
# Replay/verify for BP: Woodpecker server+agent shared-network install is active and stable.
set -uo pipefail
A="$HOME/DevOps/aether"
UNIT_SRC_SERVER="$A/infra/systemd/woodpecker-server.service"
UNIT_INST_SERVER="$HOME/.config/systemd/user/woodpecker-server.service"
UNIT_SRC_AGENT="$A/infra/systemd/woodpecker-agent.service"
UNIT_INST_AGENT="$HOME/.config/systemd/user/woodpecker-agent.service"

install -D -m 644 "$UNIT_SRC_SERVER" "$UNIT_INST_SERVER"
install -D -m 644 "$UNIT_SRC_AGENT" "$UNIT_INST_AGENT"
systemctl --user daemon-reload
systemctl --user enable woodpecker-server.service >/dev/null 2>&1 || true
systemctl --user enable woodpecker-agent.service >/dev/null 2>&1 || true
systemctl --user restart woodpecker-server.service
sleep 5
systemctl --user restart woodpecker-agent.service

HZ=no
for i in $(seq 1 150); do
  for ep in /api/health /healthz /; do
    C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8000$ep" 2>/dev/null || true)"
    if [ "$C" = 200 ]; then
      HZ=yes
      break
    fi
  done
  if [ "$HZ" = yes ]; then
    break
  fi
  sleep 2
done

sleep 20
SA="$(systemctl --user is-active woodpecker-server.service 2>/dev/null || true)"
AA="$(systemctl --user is-active woodpecker-agent.service 2>/dev/null || true)"
SN="$(systemctl --user show woodpecker-server.service -p NRestarts --value 2>/dev/null || true)"
AN="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || true)"

if [ "$HZ" = yes ] && [ "$SA" = active ] && [ "$AA" = active ] && [ "$SN" = 0 ] && [ "$AN" = 0 ]; then
  echo "  [GATE PASS] woodpecker shared-net server=active agent=active health=ok nrestarts=0"
else
  echo "  [GATE FAIL] woodpecker server=$SA/$SN agent=$AA/$AN health=$HZ"
  exit 1
fi
