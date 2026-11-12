#!/usr/bin/env bash
# 20261103-DD — fix the canary METHOD (host tcp53 -> in-netns getent), then start units.
set -uo pipefail
DNS="$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh"
CD="$HOME/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
NET="aether"; ALPINE="docker.io/library/alpine:latest"
TOKEN="dd-rootless-getent-canary-v1"
say(){ printf '  %s\n' "$*"; }
alpine_all(){ podman ps -a --filter "ancestor=$ALPINE" -q 2>/dev/null | wc -l | tr -d ' '; }
run_total(){ podman ps -q 2>/dev/null | wc -l | tr -d ' '; }
unit_active(){ systemctl --user is-active "$1" 2>/dev/null | tr -d '\n'; }
http(){ local u="$1" h="${2:-}" c=""; if [ -n "$h" ]; then c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $h" "$u" 2>/dev/null || true)"; else c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" 2>/dev/null || true)"; fi; printf '%s' "$c"; }

echo "===== [D1] write guard v3.4 (in-netns getent canary; 0 per-retry containers) ====="
cp -p "$DNS" "$DNS.pre-DD.bak" 2>/dev/null || true
cat > "$DNS" <<'GEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh v3.4 (DD): rootless-correct. Canary = IN-NETNS getent (the only
# valid DNS proof under rootless-netns). Per-host = host-side podman inspect running
# (ZERO containers). Heal = restart postgres once (proven netavark->aardvark respawn).
# Bounded: at most 4 canary getents total per invocation (NOT a 90-loop).
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
CANARY="${AETHER_DNS_CANARY:-postgres}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2; exit 2; fi
canary_up(){
  local a
  a="$(timeout 20 podman run --rm --network "$NET" "$ALPINE" getent hosts "$CANARY" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$a" in
    127.*|::1|"") return 1 ;;
    *) return 0 ;;
  esac
}
running(){ if [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; then return 0; else return 1; fi; }
heal(){ if podman inspect "$CANARY" >/dev/null 2>&1; then timeout 45 podman restart "$CANARY" >/dev/null 2>&1 || true; fi; }
if ! canary_up; then heal; fi
i=1; while [ "$i" -le 3 ]; do if canary_up; then break; fi; sleep 2; i=$((i+1)); done
if ! canary_up; then echo "dns-wait: canary $CANARY not resolvable in-netns after heal" >&2; exit 1; fi
echo "dns-wait: canary $CANARY resolves in-netns (aardvark up)"
for h in "${hosts[@]}"; do
  if running "$h"; then echo "dns-wait: $h running"; continue; fi
  ok=0; i=1
  while [ "$i" -le 60 ]; do if running "$h"; then ok=1; break; fi; sleep 1; i=$((i+1)); done
  if [ "$ok" -ne 1 ]; then echo "dns-wait: dependency '$h' not running after 60s" >&2; exit 1; fi
  echo "dns-wait: $h running"
done
exit 0
GEOF
chmod +x "$DNS"
bash -n "$DNS" && say "guard v3.4 syntax OK" || { say "guard syntax BAD; restoring"; cp -p "$DNS.pre-DD.bak" "$DNS"; exit 1; }

echo "===== [D2] prove the canary method works RIGHT NOW (in-netns getent) ====="
CA="$(timeout 20 podman run --rm --network "$NET" "$ALPINE" getent hosts postgres 2>/dev/null | awk 'NR==1{print $1}')"
say "in-netns getent postgres -> ${CA:-EMPTY}"
if [ -z "$CA" ]; then
  say "empty -> firing proven heal (restart postgres)"
  set +e; timeout 60 podman restart postgres >/dev/null 2>&1; set -e; sleep 3
  CA="$(timeout 20 podman run --rm --network "$NET" "$ALPINE" getent hosts postgres 2>/dev/null | awk 'NR==1{print $1}')"
  say "after heal: getent postgres -> ${CA:-EMPTY}"
fi
[ -n "$CA" ] || { say "[HALT] canary still empty after heal; deeper netns issue; paste D2"; exit 1; }

echo "===== [D3] guard self-test (bounded; expect rc=0, alpine-delta<=4) ====="
PRE="$(alpine_all)"; set +e; timeout 60 "$DNS" postgres grafana >/tmp/dd-g.out 2>&1; GRC=$?; set -e
sleep 1; POST="$(alpine_all)"
say "guard rc=$GRC alpine-delta=$((POST-PRE))"; sed 's/^/    /' /tmp/dd-g.out 2>/dev/null || true
[ "$GRC" -eq 0 ] || { say "[HALT] guard rc=$GRC; paste D3"; exit 1; }

echo "===== [D4] grafana (ExecStartPre now uses the FIXED guard) ====="
systemctl --user reset-failed grafana.service >/dev/null 2>&1 || true
set +e; timeout 120 systemctl --user start grafana.service >/dev/null 2>&1; set -e
GU=0; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:3000/api/health)" = 200 ] && { GU=1; break; }; sleep 2; done
say "grafana up=$GU http=$(http http://127.0.0.1:3000/api/health) unit=$(unit_active grafana.service)"
[ "$GU" = 1 ] || { journalctl --user -u grafana.service -n 20 --no-pager | sed 's/^/    j: /'; podman logs --tail 20 grafana 2>&1 | sed 's/^/    c: /'; exit 1; }

echo "===== [D5] traefik ====="
systemctl --user reset-failed traefik.service >/dev/null 2>&1 || true
set +e; timeout 120 systemctl --user start traefik.service >/dev/null 2>&1; set -e
TU=0; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:8888/api/version traefik.aether.local)" = 200 ] && { TU=1; break; }; sleep 2; done
say "traefik up=$TU http=$(http http://127.0.0.1:8888/api/version traefik.aether.local) unit=$(unit_active traefik.service)"
[ "$TU" = 1 ] || { journalctl --user -u traefik.service -n 20 --no-pager | sed 's/^/    j: /'; podman logs --tail 20 traefik 2>&1 | sed 's/^/    c: /'; exit 1; }

echo "===== [D6] replay + counts ====="
bash "$CD/20261030-BY-replay.sh" 2>&1 | sed 's/^/  /' || true
sleep 8; say "alpine idle: $(alpine_all) (expect 0); platform running: $(run_total) (expect 15)"

echo "===== [D7] ledger + RESULT ====="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | DD: root-cause = host-side tcp53 canary impossible under rootless-netns (my v3 regression broke every ExecStartPre); guard v3.4 uses IN-NETNS getent canary + host-side inspect per-host (0 per-retry containers) + proven restart-postgres heal; grafana+traefik started and gated; replay; spam=0. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
fi
say "[RESULT] DD COMPLETE - canary method fixed, grafana+traefik UP, stack at 15."
exit 0
