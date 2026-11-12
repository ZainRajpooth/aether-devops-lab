#!/usr/bin/env bash
# Replay/verify for BI: Gitea unit installed+active, healthz pass, smoke repo retrievable.
set -uo pipefail
A="$HOME/DevOps/aether"
ENV="$A/secrets/gitea.env"
UNIT_SRC="$A/infra/systemd/gitea.service"
UNIT_INST="$HOME/.config/systemd/user/gitea.service"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable gitea.service >/dev/null 2>&1 || true
systemctl --user start gitea.service
HZ=no
for i in $(seq 1 150); do
  B="$(curl -s --max-time 5 http://127.0.0.1:3001/api/healthz 2>/dev/null || true)"
  if printf '%s' "$B" | tr -d '[:space:]' | grep -q '"status":"pass"'; then
    HZ=yes
    break
  fi
  sleep 2
done
U="$(awk -F= '/^GITEA_ADMIN_USER=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
P="$(awk -F= '/^GITEA_ADMIN_PASSWORD=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
N="/tmp/bi-replay.$$.netrc"
printf 'machine 127.0.0.1 login %s password %s\n' "$U" "$P" > "$N"
chmod 600 "$N" 2>/dev/null || true
R="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --netrc-file "$N" http://127.0.0.1:3001/api/v1/repos/$U/aether-smoke)"
rm -f "$N"
if [ "$HZ" = yes ] && [ "$R" = 200 ]; then
  echo "  [GATE PASS] gitea healthz=pass smoke_repo=ok"
else
  echo "  [GATE FAIL] gitea healthz=$HZ smoke_repo=$R"
  exit 1
fi
