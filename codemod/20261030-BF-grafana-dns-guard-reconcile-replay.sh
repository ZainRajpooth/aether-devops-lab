#!/usr/bin/env bash
# Replay/verify for BF: hardened Grafana unit installed+active, live observable gate green.
set -uo pipefail
A="$HOME/DevOps/aether"
ENV="$A/secrets/grafana.env"
UNIT_SRC="$A/infra/systemd/grafana.service"
UNIT_INST="$HOME/.config/systemd/user/grafana.service"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable grafana.service >/dev/null 2>&1 || true
systemctl --user restart grafana.service
HZ=no
for i in $(seq 1 120); do
  B="$(curl -s --max-time 5 http://127.0.0.1:3000/api/health 2>/dev/null || true)"
  if printf '%s' "$B" | tr -d '[:space:]' | grep -q '"database":"ok"'; then
    HZ=yes
    break
  fi
  sleep 2
done
U="$(awk -F= '/^GF_SECURITY_ADMIN_USER=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
P="$(awk -F= '/^GF_SECURITY_ADMIN_PASSWORD=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
N="/tmp/bf-replay.$$.netrc"
printf 'machine 127.0.0.1 login %s password %s\n' "$U" "$P" > "$N"
chmod 600 "$N" 2>/dev/null || true
DS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "$N" http://127.0.0.1:3000/api/datasources/uid/prometheus-aether)"
DASH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "$N" http://127.0.0.1:3000/api/dashboards/uid/aether-overview)"
Q="$(curl -s --max-time 15 --netrc-file "$N" 'http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus-aether/api/v1/query?query=1')"
rm -f "$N"
if [ "$HZ" = yes ] && [ "$DS" = 200 ] && [ "$DASH" = 200 ] && printf '%s' "$Q" | grep -q '"status":"success"'; then
  echo "  [GATE PASS] grafana health=ok datasource=ok dashboard=ok prom_query=success"
else
  echo "  [GATE FAIL] grafana health=$HZ datasource=$DS dashboard=$DASH"
  exit 1
fi
