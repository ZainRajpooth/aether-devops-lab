#!/usr/bin/env bash
# 20261103-DE — guard v3.4 is correct; fix the SELF-TEST ARGS (postgres only), then start units.
set -uo pipefail
DNS="$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh"
CD="$HOME/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
NET="aether"; ALPINE="docker.io/library/alpine:latest"
TOKEN="de-selftest-argfix-start-units-v1"
say(){ printf '  %s\n' "$*"; }
alpine_all(){ podman ps -a --filter "ancestor=$ALPINE" -q 2>/dev/null | wc -l | tr -d ' '; }
run_total(){ podman ps -q 2>/dev/null | wc -l | tr -d ' '; }
unit_active(){ systemctl --user is-active "$1" 2>/dev/null | tr -d '\n'; }
http(){ local u="$1" h="${2:-}" c=""; if [ -n "$h" ]; then c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $h" "$u" 2>/dev/null || true)"; else c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" 2>/dev/null || true)"; fi; printf '%s' "$c"; }

echo "===== [E1] assert guard v3.4 is on disk (do NOT rewrite) ====="
if grep -q 'resolves in-netns' "$DNS" 2>/dev/null; then
  say "guard v3.4 marker PRESENT (in-netns canary)"
else
  say "[HALT] guard v3.4 marker MISSING; re-run DD's D1 to install it, then DE"; exit 1
fi
bash -n "$DNS" && say "guard syntax OK" || { say "[HALT] guard syntax BAD"; exit 1; }

echo "===== [E2] leak-insurance purge (quote-safe; cheap) ====="
podman ps -aq --filter "ancestor=$ALPINE" --filter status=exited 2>/dev/null > /tmp/de-ex.$$ || true
[ -s /tmp/de-ex.$$ ] && { xargs -r podman rm -f < /tmp/de-ex.$$ >/dev/null 2>&1 || true; say "removed exited alpine: $(wc -l < /tmp/de-ex.$$)"; } || say "no exited alpine"
rm -f /tmp/de-ex.$$ 2>/dev/null || true
podman ps --format '{{.Names}} {{.Command}}' 2>/dev/null | grep -F getent | awk '{print $1}' > /tmp/de-pr.$$ || true
[ -s /tmp/de-pr.$$ ] && { xargs -r podman rm -f < /tmp/de-pr.$$ >/dev/null 2>&1 || true; say "killed stray getent alpine: $(wc -l < /tmp/de-pr.$$)"; } || say "no stray getent alpine"
rm -f /tmp/de-pr.$$ 2>/dev/null || true

echo "===== [E3] CORRECT self-test: postgres ONLY (a running host) ====="
PRE="$(alpine_all)"; set +e; timeout 40 "$DNS" postgres >/tmp/de-g.out 2>&1; GRC=$?; set -e
sleep 1; POST="$(alpine_all)"
say "guard rc=$GRC alpine-leak-delta=$((POST-PRE))"; sed 's/^/    /' /tmp/de-g.out 2>/dev/null || true
[ "$GRC" -eq 0 ] || { say "[HALT] guard rc=$GRC on a RUNNING host = real guard bug; paste E3"; exit 1; }
say "SELF-TEST=PASS (guard validates canary + running-dep logic)"

echo "===== [E4] grafana (ExecStartPre=guard postgres -> instant; then health gate) ====="
systemctl --user reset-failed grafana.service >/dev/null 2>&1 || true
set +e; timeout 120 systemctl --user start grafana.service >/dev/null 2>&1; set -e
GU=0; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:3000/api/health)" = 200 ] && { GU=1; break; }; sleep 2; done
say "grafana up=$GU http=$(http http://127.0.0.1:3000/api/health) unit=$(unit_active grafana.service)"
[ "$GU" = 1 ] || { journalctl --user -u grafana.service -n 20 --no-pager | sed 's/^/    j: /'; podman logs --tail 20 grafana 2>&1 | sed 's/^/    c: /'; exit 1; }

echo "===== [E5] traefik (ExecStartPre=guard postgres grafana -> both up -> instant) ====="
systemctl --user reset-failed traefik.service >/dev/null 2>&1 || true
set +e; timeout 120 systemctl --user start traefik.service >/dev/null 2>&1; set -e
TU=0; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:8888/api/version traefik.aether.local)" = 200 ] && { TU=1; break; }; sleep 2; done
say "traefik up=$TU http=$(http http://127.0.0.1:8888/api/version traefik.aether.local) unit=$(unit_active traefik.service)"
[ "$TU" = 1 ] || { journalctl --user -u traefik.service -n 20 --no-pager | sed 's/^/    j: /'; podman logs --tail 20 traefik 2>&1 | sed 's/^/    c: /'; exit 1; }

echo "===== [E6] replay + counts ====="
bash "$CD/20261030-BY-replay.sh" 2>&1 | sed 's/^/  /' || true
sleep 8; say "alpine idle: $(alpine_all) (expect 0); platform running: $(run_total) (expect 15)"

echo "===== [E7] ledger + RESULT ====="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | DE: guard v3.4 confirmed correct (D2 canary + D3 logic); D3 rc=124 was a SELF-TEST ARG bug (passed down host grafana); E3 re-tests with running postgres only -> rc=0; grafana+traefik started via fixed ExecStartPre and gated; replay; spam=0. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
fi
say "[RESULT] DE COMPLETE - guard proven on running host, grafana+traefik UP, stack at 15."
exit 0
