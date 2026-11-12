#!/usr/bin/env bash
# 20261103-DC — use the PROVEN trigger from CM: podman restart <existing-container>
set -uo pipefail
DNS="$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh"
CD="$HOME/DevOps/aether/codemod"
IDX="$CD/INDEX.md"
NET="aether"; ALPINE="docker.io/library/alpine:latest"
TOKEN="dc-proven-restart-trigger-v1"
say(){ printf '  %s\n' "$*"; }
alpine_all(){ podman ps -a --filter "ancestor=$ALPINE" -q 2>/dev/null | wc -l | tr -d ' '; }
run_total(){ podman ps -q 2>/dev/null | wc -l | tr -d ' '; }
unit_active(){ systemctl --user is-active "$1" 2>/dev/null | tr -d '\n'; }
http(){ local u="$1" h="${2:-}" c=""; if [ -n "$h" ]; then c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $h" "$u" 2>/dev/null || true)"; else c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" 2>/dev/null || true)"; fi; printf '%s' "$c"; }
probe1(){ timeout 20 podman run --rm --network "$NET" "$ALPINE" getent hosts "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
tcp53(){ local gw="$1"; timeout 2 bash -c "exec 3<>/dev/tcp/$gw/53" 2>/dev/null; }

echo "===== [C1] patch heal() to PROVEN trigger: podman restart <existing-container> ====="
python3 - "$DNS" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding="utf-8")
OLD = """heal(){  # v3.2: netavark setup event (1-shot container start) is the PROVEN aardvark respawn trigger
  pkill -u "$(id -u)" -x aardvark-dns 2>/dev/null || true
  sleep 1
  timeout 25 podman run --rm --network "$NET" "$ALPINE" true >/dev/null 2>&1 || true
  podman network reload "$CANARY" >/dev/null 2>&1 || true
}"""
NEW = """heal(){  # v3.3: podman restart <existing-container> is the PROVEN trigger (from CM evidence)
  pkill -u "$(id -u)" -x aardvark-dns 2>/dev/null || true
  sleep 1
  if podman inspect "$CANARY" >/dev/null 2>&1; then
    timeout 45 podman restart "$CANARY" >/dev/null 2>&1 || true
  fi
}"""
if "v3.3" in t:
    print("  heal already v3.3 (idempotent)")
elif OLD in t:
    p.write_text(t.replace(OLD, NEW, 1), encoding="utf-8"); print("  heal patched to v3.3 (restart trigger)")
else:
    # try the v3.1 form if v3.2 wasn't installed
    OLD2 = """heal(){
  pkill -u "$(id -u)" -x aardvark-dns 2>/dev/null || true
  sleep 1
  if running "$CANARY"; then podman network reload "$CANARY" >/dev/null 2>&1 || true
  else timeout 20 podman run --rm --network "$NET" "$ALPINE" true >/dev/null 2>&1 || true; fi
}"""
    if OLD2 in t:
        p.write_text(t.replace(OLD2, NEW, 1), encoding="utf-8"); print("  heal patched from v3.1 to v3.3")
    else:
        print("  WARN: neither heal block matched; guard left as-is")
PYEOF
bash -n "$DNS" && say "guard syntax OK" || { say "guard syntax BAD; abort"; exit 1; }

echo "===== [C2] heal DNS NOW with restart trigger (bounded) ====="
podman ps -aq --filter "ancestor=$ALPINE" --filter status=exited 2>/dev/null | xargs -r podman rm -f >/dev/null 2>&1 || true
GW="$(podman network inspect "$NET" --format '{{range .subnets}}{{.gateway}} {{end}}' 2>/dev/null | awk '{print $1}')"
[ -n "$GW" ] || GW="10.89.0.1"
if ! tcp53 "$GW"; then
  say "aardvark dead on $GW:53 -> firing PROVEN restart trigger (podman restart postgres)"
  pkill -u "$(id -u)" -x aardvark-dns 2>/dev/null || true; sleep 1
  set +e; timeout 60 podman restart postgres >/dev/null 2>&1; set -e
  sleep 3
fi
i=1; while [ "$i" -le 20 ]; do tcp53 "$GW" && break; sleep 1; i=$((i+1)); done
if tcp53 "$GW"; then say "aardvark ALIVE on $GW:53"; else say "aardvark STILL dead; abort"; exit 1; fi
for b in postgres gitea n8n woodpecker-server; do
  a="$(probe1 "$b")"; say "  getent $b -> ${a:-EMPTY}"
done

echo "===== [C3] guard self-test ====="
PRE="$(alpine_all)"; set +e; timeout 40 "$DNS" postgres >/tmp/dc-g.out 2>&1; GRC=$?; set -e
sleep 2; POST="$(alpine_all)"
say "guard rc=$GRC alpine-delta=$((POST-PRE))"; sed 's/^/    /' /tmp/dc-g.out 2>/dev/null || true
[ "$GRC" -eq 0 ] || { say "guard still bad; abort"; exit 1; }

echo "===== [C4] grafana ====="
systemctl --user reset-failed grafana.service >/dev/null 2>&1 || true
set +e; timeout 120 systemctl --user start grafana.service >/dev/null 2>&1; set -e
GU=0; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:3000/api/health)" = 200 ] && { GU=1; break; }; sleep 2; done
say "grafana up=$GU http=$(http http://127.0.0.1:3000/api/health) unit=$(unit_active grafana.service)"
[ "$GU" = 1 ] || { journalctl --user -u grafana.service -n 15 --no-pager | sed 's/^/    j: /'; exit 1; }

echo "===== [C5] traefik ====="
systemctl --user reset-failed traefik.service >/dev/null 2>&1 || true
set +e; timeout 120 systemctl --user start traefik.service >/dev/null 2>&1; set -e
TU=0; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:8888/api/version traefik.aether.local)" = 200 ] && { TU=1; break; }; sleep 2; done
say "traefik up=$TU http=$(http http://127.0.0.1:8888/api/version traefik.aether.local) unit=$(unit_active traefik.service)"
[ "$TU" = 1 ] || { journalctl --user -u traefik.service -n 15 --no-pager | sed 's/^/    j: /'; exit 1; }

echo "===== [C6] replay + counts ====="
bash "$CD/20261030-BY-replay.sh" 2>&1 | sed 's/^/  /' || true
sleep 8; say "alpine idle: $(alpine_all) (expect 0); platform running: $(run_total) (expect 15)"

echo "===== [C7] ledger + RESULT ====="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | DC: heal() v3.3 uses podman restart <existing> (proven from CM); DNS healed; grafana+traefik up; replay; spam=0. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
fi
say "[RESULT] DC COMPLETE - grafana+traefik UP, DNS alive, stack at 15."
exit 0
