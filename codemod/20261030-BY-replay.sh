#!/usr/bin/env bash
# Replay/verify for brick 11 (CA): all four resolve + traefik proxied :8888 all 200 + agent flat.
set -uo pipefail
NET=aether; ALPINE=docker.io/library/alpine:latest
GE(){ timeout 15 podman run --rm --network "$NET" "$ALPINE" getent hosts "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
hc(){ local u="$1"; local h="${2:-}"; if [ -n "$h" ]; then curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "$u" 2>/dev/null || echo 000; else curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000; fi; }
FAIL=""
for n in postgres gitea grafana woodpecker-server n8n; do
  a="$(GE "$n")"
  case "$a" in ''|127.*|::1|localhost) FAIL="$FAIL $n('$a')" ;; esac
done
P1="$(hc http://127.0.0.1:8888/api/version traefik.aether.local)"
P2="$(hc http://127.0.0.1:8888/api/healthz gitea.aether.local)"
P3="$(hc http://127.0.0.1:8888/api/health woodpecker.aether.local)"
P4="$(hc http://127.0.0.1:8888/api/health grafana.aether.local)"
P5="$(hc http://127.0.0.1:8888/healthz n8n.aether.local)"
[ "$P1" = 200 ] || FAIL="$FAIL traefik-api($P1)"
[ "$P2" = 200 ] || FAIL="$FAIL gitea($P2)"
[ "$P3" = 200 ] || FAIL="$FAIL woodpecker($P3)"
[ "$P4" = 200 ] || FAIL="$FAIL grafana($P4)"
[ "$P5" = 200 ] || FAIL="$FAIL n8n($P5)"
A1="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || echo ?)"; sleep 6
A2="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || echo ?)"
[ "$A1" = "$A2" ] || FAIL="$FAIL agent-NR($A1->$A2)"
if [ -z "$FAIL" ]; then
  echo "  [GATE PASS] brick11 dns=all-resolve proxied=all200 agent-NR-flat=$A1"
else
  echo "  [GATE FAIL]$FAIL"; exit 1
fi
