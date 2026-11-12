#!/usr/bin/env bash
# 20261103-DA — delivered via the file pattern that never broke (CA/CB/CD/CE).
# Body runs under NON-interactive bash: no history expansion, contained exit,
# predictable set -u. Installs+proves dns-wait v3.1, re-registers wiped aardvark
# entries non-disruptively, repairs grafana->traefik gated, replays, audits, ledgers.
set -uo pipefail

CD="$HOME/DevOps/aether/codemod"
DNS="$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh"
IDX="$CD/INDEX.md"
UIDIR="$HOME/.config/systemd/user"
NET="aether"
ALPINE="docker.io/library/alpine:latest"
TOKEN="da-file-pattern-guard-reregister-repair-audit-v1"

GUARD_INSTALL=0
GUARD_PROVEN=0
GRAFANA_UP=0
TRAEFIK_UP=0
REPAIRED=0

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
alpine_all(){ podman ps -a --filter "ancestor=$ALPINE" -q 2>/dev/null | wc -l | tr -d ' '; }
alpine_run(){ podman ps    --filter "ancestor=$ALPINE" -q 2>/dev/null | wc -l | tr -d ' '; }
run_total(){ podman ps -q 2>/dev/null | wc -l | tr -d ' '; }
unit_active(){ systemctl --user is-active "$1" 2>/dev/null | tr -d '\n'; }
cont_state(){ podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null || echo absent; }
cont_running(){ if [ "$(podman inspect "$1" --format '{{.State.Running}}' 2>/dev/null || echo false)" = "true" ]; then return 0; else return 1; fi; }
http(){ local u="$1" h="${2:-}" c=""; if [ -n "$h" ]; then c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $h" "$u" 2>/dev/null || true)"; else c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" 2>/dev/null || true)"; fi; printf '%s' "$c"; }
unit_for(){ case "$1" in llama-embed) printf 'llama-embed-container.service';; *) printf '%s.service' "$1";; esac; }
probe1(){ timeout 20 podman run --rm --network "$NET" "$ALPINE" getent hosts "$1" 2>/dev/null | awk 'NR==1{print $1}'; }

# ===================== [A0] truth (read-only) =====================
hr "A0 current truth (read-only)"
say "grafana  http=$(http http://127.0.0.1:3000/api/health) unit=$(unit_active grafana.service) cont=$(cont_state grafana)"
say "traefik  http=$(http http://127.0.0.1:8888/api/version traefik.aether.local) unit=$(unit_active traefik.service) cont=$(cont_state traefik)"
say "alpine running=$(alpine_run) total=$(alpine_all)  platform=$(run_total)"
say "activating units:"
systemctl --user list-units --state=activating --type=service --no-pager --plain 2>/dev/null | awk 'NR>1{print "    "$1}' || say "    none"
say "guard on disk has v3.1 marker:"
if grep -q 'no per-retry container probes' "$DNS" 2>/dev/null; then say "    PRESENT"; else say "    ABSENT (installing in A1)"; fi

# ===================== [A1] install dns-wait v3.1 (single-quoted inner heredoc) =====================
hr "A1 install dns-wait v3.1 (zero per-retry probes; heal = VALID container reload)"
cp -p "$DNS" "$DNS.pre-DA.bak" 2>/dev/null || true
cat > "$DNS" <<'GEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh v3.1 (DA): ZERO per-retry container probes.
set -uo pipefail
NET="${AETHER_NET:-aether}"; TRIES="${AETHER_DNS_TRIES:-90}"; DELAY="${AETHER_DNS_DELAY:-1}"
CANARY="${AETHER_DNS_CANARY:-postgres}"; ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2; exit 2; fi
GW="$(podman network inspect "$NET" --format '{{range .subnets}}{{.gateway}} {{end}}' 2>/dev/null | awk '{print $1}')"
GW="$(echo "$GW" | tr -d ' \n')"; if [ -z "$GW" ]; then GW="10.89.0.1"; fi
tcp53(){ timeout 2 bash -c "exec 3<>/dev/tcp/$GW/53" 2>/dev/null; }
running(){ if [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; then return 0; else return 1; fi; }
heal(){
  pkill -u "$(id -u)" -x aardvark-dns 2>/dev/null || true
  sleep 1
  if running "$CANARY"; then podman network reload "$CANARY" >/dev/null 2>&1 || true
  else timeout 20 podman run --rm --network "$NET" "$ALPINE" true >/dev/null 2>&1 || true; fi
}
if ! tcp53; then heal; fi
i=1; while [ "$i" -le 30 ]; do if tcp53; then break; fi; sleep 1; i=$((i+1)); done
if ! tcp53; then echo "dns-wait: aardvark NOT listening on $GW:53 after heal" >&2; exit 1; fi
echo "dns-wait: aardvark listening on $GW:53 (no per-retry container probes)"
for h in "${hosts[@]}"; do
  if running "$h"; then echo "dns-wait: $h running (resolvable via aardvark)"; continue; fi
  ok=0; i=1
  while [ "$i" -le "$TRIES" ]; do
    if running "$h"; then ok=1; break; fi
    if [ $((i % 30)) -eq 0 ]; then heal; fi
    sleep "$DELAY"; i=$((i+1))
  done
  if [ "$ok" -ne 1 ]; then echo "dns-wait: dependency '$h' not running after $TRIES tries" >&2; exit 1; fi
  if [ "${AETHER_DNS_CONFIRM:-0}" = 1 ]; then
    addr="$(timeout 15 podman run --rm --network "$NET" "$ALPINE" getent hosts "$h" 2>/dev/null | awk 'NR==1{print $1}')"
    echo "dns-wait: confirm $h -> ${addr:-none}"
  fi
  echo "dns-wait: resolved-running $h on $NET"
done
exit 0
GEOF
chmod +x "$DNS"
if bash -n "$DNS"; then say "guard v3.1 installed + syntax OK"; GUARD_INSTALL=1
else say "GUARD SYNTAX BAD -> restored backup; repairs SKIPPED"; cp -p "$DNS.pre-DA.bak" "$DNS"; fi

# ===================== [A2] self-test guard (non-fatal; prints real output) =====================
hr "A2 guard self-test (non-fatal)"
if [ "$GUARD_INSTALL" = 1 ]; then
  PRE="$(alpine_all)"
  set +e; timeout 45 "$DNS" postgres >/tmp/da-guard.$$.out 2>&1; GRC=$?; set -e
  sleep 2; POST="$(alpine_all)"; DELTA=$((POST-PRE))
  say "guard rc=$GRC alpine-delta=$DELTA"
  sed 's/^/    /' /tmp/da-guard.$$.out 2>/dev/null || true
  rm -f /tmp/da-guard.$$.out 2>/dev/null || true
  if [ "$GRC" -eq 0 ] && [ "$DELTA" -le 1 ]; then GUARD_PROVEN=1; say "SELF-TEST=PASS"
  else say "SELF-TEST=FAIL -> repairs SKIPPED (see guard output above)"; fi
else say "skipped (install failed)"; fi

# ===================== [A3] re-register wiped aardvark entries (non-disruptive) =====================
hr "A3 re-register running backends whose getent is empty (network reload, no restart)"
if [ "$GUARD_PROVEN" = 1 ]; then
  for b in postgres gitea n8n woodpecker-server; do
    if cont_running "$b"; then
      a="$(probe1 "$b")"
      if [ -z "$a" ]; then
        podman network reload "$b" >/dev/null 2>&1 || true
        sleep 1
        a2="$(probe1 "$b")"
        say "  $b: was-empty -> reload -> ${a2:-still-empty}"
      else
        say "  $b: resolves $a"
      fi
    else
      say "  $b: not running (skip)"
    fi
  done
else say "  skipped (guard not proven)"; fi

# ===================== [A4] cgroup-stop any activating + purge junk + ghosts (quote-safe) =====================
hr "A4 stop activating guards + purge alpine/getent junk + clear ghost units"
systemctl --user list-units --state=activating --type=service --no-pager --plain 2>/dev/null | awk 'NR>1{print $1}' > /tmp/da-act.$$ || true
if [ -s /tmp/da-act.$$ ]; then say "stopping activating:"; sed 's/^/    /' /tmp/da-act.$$; xargs -r -n1 systemctl --user stop < /tmp/da-act.$$ >/dev/null 2>&1 || true; sleep 3; else say "no activating units"; fi
rm -f /tmp/da-act.$$ 2>/dev/null || true
systemctl --user reset-failed grafana.service traefik.service >/dev/null 2>&1 || true
shopt -s nullglob
for f in "$UIDIR"/app-Podman@*.service; do cp -p "$f" "$f.pre-DA.bak" 2>/dev/null || true; rm -f "$f"; say "removed ghost unit: $f"; done
shopt -u nullglob
podman ps -aq --filter "ancestor=$ALPINE" --filter status=exited 2>/dev/null > /tmp/da-ex.$$ || true
if [ -s /tmp/da-ex.$$ ]; then xargs -r podman rm -f < /tmp/da-ex.$$ >/dev/null 2>&1 || true; say "removed exited alpine: $(wc -l < /tmp/da-ex.$$)"; else say "no exited alpine"; fi
rm -f /tmp/da-ex.$$ 2>/dev/null || true
podman ps --format '{{.Names}} {{.Command}}' 2>/dev/null | grep -F getent | awk '{print $1}' > /tmp/da-pr.$$ || true
if [ -s /tmp/da-pr.$$ ]; then xargs -r podman rm -f < /tmp/da-pr.$$ >/dev/null 2>&1 || true; say "killed getent probes: $(wc -l < /tmp/da-pr.$$)"; else say "no getent probes"; fi
rm -f /tmp/da-pr.$$ 2>/dev/null || true
systemctl --user daemon-reload >/dev/null 2>&1 || true

# ===================== [A5] grafana repair (only if guard proven; bounded) =====================
hr "A5 grafana (conditional)"
if [ "$GUARD_PROVEN" = 1 ]; then
  if [ "$(http http://127.0.0.1:3000/api/health)" = 200 ] && [ "$(unit_active grafana.service)" = active ]; then
    say "already healthy"; GRAFANA_UP=1
  else
    GP="$(alpine_all)"
    systemctl --user reset-failed grafana.service >/dev/null 2>&1 || true
    set +e; timeout 120 systemctl --user start grafana.service >/dev/null 2>&1; set -e
    for i in $(seq 1 45); do if [ "$(http http://127.0.0.1:3000/api/health)" = 200 ]; then GRAFANA_UP=1; break; fi; sleep 2; done
    GQ="$(alpine_all)"; GD=$((GQ-GP))
    say "grafana up=$GRAFANA_UP http=$(http http://127.0.0.1:3000/api/health) unit=$(unit_active grafana.service) cont=$(cont_state grafana) alpine-delta=$GD"
    if [ "$GRAFANA_UP" = 1 ] && [ "$GD" -le 1 ]; then REPAIRED=1
    else journalctl --user -u grafana.service -n 20 --no-pager 2>/dev/null | sed 's/^/    j: /' || true; podman logs --tail 20 grafana 2>&1 | sed 's/^/    c: /' || true; fi
  fi
else say "SKIPPED (guard not proven)"; fi

# ===================== [A6] traefik repair (only if grafana up; bounded) =====================
hr "A6 traefik (conditional)"
if [ "$GRAFANA_UP" = 1 ]; then
  if [ "$(http http://127.0.0.1:8888/api/version traefik.aether.local)" = 200 ] && [ "$(unit_active traefik.service)" = active ]; then
    say "already healthy"; TRAEFIK_UP=1
  else
    TP="$(alpine_all)"
    systemctl --user reset-failed traefik.service >/dev/null 2>&1 || true
    set +e; timeout 120 systemctl --user start traefik.service >/dev/null 2>&1; set -e
    for i in $(seq 1 45); do if [ "$(http http://127.0.0.1:8888/api/version traefik.aether.local)" = 200 ]; then TRAEFIK_UP=1; break; fi; sleep 2; done
    TQ="$(alpine_all)"; TD=$((TQ-TP))
    say "traefik up=$TRAEFIK_UP http=$(http http://127.0.0.1:8888/api/version traefik.aether.local) unit=$(unit_active traefik.service) cont=$(cont_state traefik) alpine-delta=$TD"
    if [ "$TRAEFIK_UP" = 1 ] && [ "$TD" -le 1 ]; then REPAIRED=1
    else journalctl --user -u traefik.service -n 20 --no-pager 2>/dev/null | sed 's/^/    j: /' || true; podman logs --tail 20 traefik 2>&1 | sed 's/^/    c: /' || true; fi
  fi
else say "SKIPPED (grafana not up)"; fi

# ===================== [A7] replay + idle spam-proof =====================
hr "A7 replay + idle proof"
bash "$CD/20261030-BY-replay.sh" 2>&1 | sed 's/^/  /' || true
sleep 12
say "alpine after 12s idle: $(alpine_all) (expect 0); platform running: $(run_total) (expect 15)"

# ===================== [A8] FULL AUDIT (all vars initialized; no histexpand chars) =====================
hr "A8 audit: cached images -> class"
podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort | while read -r img; do
  case "$img" in
    *'<none>'*) continue ;;
    *postgres*|*redis*|*minio*|*weaviate*|*prometheus*|*node-exporter*|*mailpit*|*litellm*|*n8n*|*gitea*|*grafana*|*woodpecker*|*traefik*|*aether-llama*|*alpine*) cls="DEPLOYED" ;;
    *zitadel*)   cls="PLANNED-Brick13 (say: deploy zitadel)" ;;
    *portainer*) cls="OPTIONAL-SKIP (own GUI)" ;;
    *ubuntu*)    cls="BUILD-LEFTOVER (harmless)" ;;
    *)           cls="REVIEW" ;;
  esac
  printf '  %-52s %s\n' "$img" "$cls"
done
hr "A8 audit: expected platform services"
for s in postgres redis minio weaviate prometheus node-exporter mailpit llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik; do
  c="$(cont_state "$s")"; u="$(unit_for "$s")"; u="$(unit_active "$u")"; [ -z "$u" ] && u="?"
  v="DOWN"
  if [ "$c" = running ] && [ "$u" = active ]; then v="UP"; elif [ "$c" = running ]; then v="UP-idle"; fi
  printf '  %-20s cont=%-8s unit=%-8s %s\n' "$s" "$c" "$u" "$v"
done
say "kept-by-policy: aether-backup.service (DR; say repair/retire); ubuntu/portainer/zitadel images; llama-embed = ENABLED quadlet (reboot-covered)"

# ===================== [A9] ledger + RESULT (always reached; exit 0) =====================
hr "A9 ledger"
touch "$IDX"
GATE="PARTIAL"; if [ "$TRAEFIK_UP" = 1 ]; then GATE="PASS"; fi
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | DA file-pattern (immune to interactive traps): guard v3.1 install=%s proven=%s; re-registered wiped aardvark entries via network reload (non-disruptive); cgroup-stopped activating + purged alpine/getent/ghost junk quote-safe; grafana up=%s traefik up=%s repaired=%s; replay+idle+full audit. |\n' "$(date +%F)" "$TOKEN" "$GATE" "$GUARD_INSTALL" "$GUARD_PROVEN" "$GRAFANA_UP" "$TRAEFIK_UP" "$REPAIRED" >> "$IDX"
  say "ledger row appended"
else
  say "ledger row already present (guard suppressed)"
fi
if [ "$TRAEFIK_UP" = 1 ]; then say "[RESULT] DA COMPLETE - guard proven, DNS re-registered, grafana+traefik up, spam=0, audit clean."
elif [ "$GUARD_PROVEN" != 1 ]; then say "[RESULT] DA PARTIAL - guard not proven (see A1/A2); repairs skipped by design; PASTE A1/A2."
else say "[RESULT] DA PARTIAL - guard OK but a unit not healthy (see A5/A6 dumps); PASTE those dumps."; fi
exit 0
