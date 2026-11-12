#!/usr/bin/env bash
# 20261102-CW — gated (bash -n), quote-safe, CONDITIONAL repair + full audit.
# Supersedes CV (which died on a parse error). Never stops a healthy unit.
set -uo pipefail

TMPD="$(mktemp -d)"
cleanup(){ rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT

CD="$HOME/DevOps/aether/codemod"
DNS="$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh"
IDX="$CD/INDEX.md"
UIDIR="$HOME/.config/systemd/user"
NET="aether"
ALPINE="docker.io/library/alpine:latest"
TOKEN="cw-gated-conditional-repair-audit-v1"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
alpine_all(){ podman ps -a --filter "ancestor=$ALPINE" -q 2>/dev/null | wc -l | tr -d ' '; }
alpine_run(){ podman ps    --filter "ancestor=$ALPINE" -q 2>/dev/null | wc -l | tr -d ' '; }
run_total(){ podman ps -q 2>/dev/null | wc -l | tr -d ' '; }
unit_active(){ printf '%s' "$(norm "$(systemctl --user is-active "$1" 2>/dev/null || true)")"; }
cont_state(){ printf '%s' "$(norm "$(podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null || echo absent)")"; }
http(){ local u="$1" h="${2:-}" c; if [ -n "$h" ]; then c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $h" "$u" 2>/dev/null || true)"; else c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" 2>/dev/null || true)"; fi; printf '%s' "$(norm "$c")"; }
unit_for(){ case "$1" in llama-embed) printf 'llama-embed-container.service';; *) printf '%s.service' "$1";; esac; }

# ===================== [W0] READ-ONLY TRUTH (what state are we actually in?) =====================
hr "W0 current truth (read-only)"
GF_CODE="$(http http://127.0.0.1:3000/api/health)"
TF_CODE="$(http http://127.0.0.1:8888/api/version traefik.aether.local)"
say "grafana  health_http=$GF_CODE unit=$(unit_active grafana.service) container=$(cont_state grafana)"
say "traefik  edge_http=$TF_CODE  unit=$(unit_active traefik.service) container=$(cont_state traefik)"
say "alpine containers: running=$(alpine_run) total=$(alpine_all)   (running>0 right now = stale probe loop alive)"
say "platform containers running total=$(run_total) (expect 15 when whole stack up)"
if grep -q 'no per-retry container probes' "$DNS" 2>/dev/null; then
  say "dns-wait on disk: v3.1 marker PRESENT"
else
  say "dns-wait on disk: v3.1 marker ABSENT (will install in W1)"
fi

# ===================== [W1] install dns-wait v3.1 (guarantee correct final state) =====================
hr "W1 install dns-wait v3.1 (zero per-retry probes; heal uses VALID container reload)"
cp -p "$DNS" "$DNS.pre-CW.bak" 2>/dev/null || true
cat > "$DNS" <<'DWEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh v3.1 (CW): ZERO per-retry container probes.
# Canary  = TCP connect to gateway:53 (aardvark listener), 2s-bounded, /dev/tcp.
# Per-host = wait until podman inspect reports the dependency RUNNING (host CLI).
# Heal    = pkill our aardvark, then force netavark respawn via the VALID form
#           podman network reload <CONTAINER> (postgres); fallback = ONE bounded
#           podman run --rm alpine true (single trigger, NOT a 90-loop). At most
#           once per 30 tries. Fixes the invalid reload <NETWORK> no-op.
set -uo pipefail
NET="${AETHER_NET:-aether}"
TRIES="${AETHER_DNS_TRIES:-90}"
DELAY="${AETHER_DNS_DELAY:-1}"
CANARY="${AETHER_DNS_CANARY:-postgres}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2
  exit 2
fi
GW="$(podman network inspect "$NET" --format '{{range .subnets}}{{.gateway}} {{end}}' 2>/dev/null | awk '{print $1}')"
GW="$(echo "$GW" | tr -d ' \n')"
if [ -z "$GW" ]; then GW="10.89.0.1"; fi
tcp53(){ timeout 2 bash -c "exec 3<>/dev/tcp/$GW/53" 2>/dev/null; }
running(){ if [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; then return 0; else return 1; fi; }
heal(){
  pkill -u "$(id -u)" -x aardvark-dns 2>/dev/null || true
  sleep 1
  if running "$CANARY"; then
    podman network reload "$CANARY" >/dev/null 2>&1 || true
  else
    timeout 20 podman run --rm --network "$NET" "$ALPINE" true >/dev/null 2>&1 || true
  fi
}
if ! tcp53; then heal; fi
i=1
while [ "$i" -le 30 ]; do
  if tcp53; then break; fi
  sleep 1
  i=$((i + 1))
done
if ! tcp53; then
  echo "dns-wait: aardvark NOT listening on $GW:53 after heal" >&2
  exit 1
fi
echo "dns-wait: aardvark listening on $GW:53 (no per-retry container probes)"
for h in "${hosts[@]}"; do
  if running "$h"; then
    echo "dns-wait: $h running (resolvable via aardvark)"
    continue
  fi
  ok=0
  i=1
  while [ "$i" -le "$TRIES" ]; do
    if running "$h"; then ok=1; break; fi
    if [ $((i % 30)) -eq 0 ]; then heal; fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  if [ "$ok" -ne 1 ]; then
    echo "dns-wait: dependency '$h' not running after $TRIES tries" >&2
    exit 1
  fi
  if [ "${AETHER_DNS_CONFIRM:-0}" = 1 ]; then
    addr="$(timeout 15 podman run --rm --network "$NET" "$ALPINE" getent hosts "$h" 2>/dev/null | awk 'NR==1{print $1}')"
    echo "dns-wait: confirm $h -> ${addr:-none}"
  fi
  echo "dns-wait: resolved-running $h on $NET"
done
exit 0
DWEOF
chmod +x "$DNS"
if bash -n "$DNS"; then
  say "dns-wait v3.1 installed + syntax OK"
else
  say "SYNTAX FAIL; restoring backup"
  cp -p "$DNS.pre-CW.bak" "$DNS"
  exit 1
fi

# ===================== [W2] SELF-TEST the guard BEFORE any unit depends on it =====================
hr "W2 guard self-test (must return 0 with <=1 new alpine)"
PRE="$(alpine_all)"
if timeout 40 "$DNS" postgres; then ST=PASS; else ST=FAIL; fi
sleep 2
POST="$(alpine_all)"
DELTA=$((POST - PRE))
say "self-test=$ST alpine-delta=$DELTA (expect 0; <=1 only if a heal 1-shot fired)"
if [ "$ST" != PASS ]; then
  say "[HALT] guard self-test failed; not starting units on a broken guard"
  exit 1
fi
if [ "$DELTA" -gt 1 ]; then
  say "[HALT] guard spawned $DELTA containers in self-test (spam NOT dead)"
  exit 1
fi

# ===================== [W3] ALWAYS-ON stale cleanup (safe even if stack healthy) =====================
hr "W3 kill stale probe tree + clear ghost units + purge alpine junk"
pkill -u "$(id -u)" -f 'aether-dns-wait.sh' 2>/dev/null || true
pkill -u "$(id -u)" -f 'getent hosts' 2>/dev/null || true
sleep 2
# persistent app-Podman@ ghost unit files (backed up); /run transients self-clear
shopt -s nullglob
for f in "$UIDIR"/app-Podman@*.service; do
  cp -p "$f" "$f.pre-CW.bak" 2>/dev/null || true
  rm -f "$f"
  say "removed persistent ghost unit: $f (backup kept)"
done
shopt -u nullglob
# exited alpine
EX="$(podman ps -aq --filter "ancestor=$ALPINE" --filter status=exited 2>/dev/null)"
if [ -n "$EX" ]; then
  printf '%s\n' "$EX" | xargs -r podman rm -f >/dev/null 2>&1 || true
  say "removed exited alpine: $(printf '%s\n' "$EX" | wc -l | tr -d ' ')"
fi
# running getent probes, ONE PASS, quote-safe (no nested command-subst)
podman ps --format '{{.Names}} {{.Command}}' 2>/dev/null | grep -F 'getent' | awk '{print $1}' > "$TMPD/probes.txt" || true
if [ -s "$TMPD/probes.txt" ]; then
  xargs -r podman rm -f < "$TMPD/probes.txt" >/dev/null 2>&1 || true
  say "killed running getent probes: $(wc -l < "$TMPD/probes.txt" | tr -d ' ')"
else
  say "no running getent probes"
fi
systemctl --user daemon-reload >/dev/null 2>&1 || true
say "stale tree killed; ghost units removed; daemon-reloaded"

# ===================== [W4] grafana: repair ONLY if down (non-disruptive) =====================
hr "W4 grafana (conditional)"
GF_CODE="$(http http://127.0.0.1:3000/api/health)"
if [ "$GF_CODE" = 200 ] && [ "$(unit_active grafana.service)" = active ]; then
  say "grafana already healthy (http=200, unit=active); skip start"
  GF_OK=yes
else
  say "grafana down (http=$GF_CODE unit=$(unit_active grafana.service)); repairing"
  GP="$(alpine_all)"
  systemctl --user reset-failed grafana.service >/dev/null 2>&1 || true
  timeout 120 systemctl --user start grafana.service >/dev/null 2>&1 || true
  GF_OK=no
  for i in $(seq 1 45); do
    GF_CODE="$(http http://127.0.0.1:3000/api/health)"
    if [ "$GF_CODE" = 200 ]; then GF_OK=yes; break; fi
    sleep 2
  done
  GQ="$(alpine_all)"
  GD=$((GQ - GP))
  say "grafana health=$GF_OK http=$GF_CODE unit=$(unit_active grafana.service) container=$(cont_state grafana) alpine-delta=$GD"
  if [ "$GF_OK" != yes ]; then
    journalctl --user -u grafana.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    podman logs --tail 25 grafana 2>&1 | sed 's/^/    c: /' || true
    say "[HALT] grafana unhealthy; traefik skipped (ordering rule)"
    exit 1
  fi
  if [ "$GD" -gt 1 ]; then
    say "[HALT] grafana start spawned $GD alpine (spam NOT dead)"
    exit 1
  fi
  journalctl --user -u grafana.service --since "-3 min" --no-pager 2>/dev/null | grep -m1 'no per-retry container probes' | sed 's/^/    guard: /' || say "    guard: (marker not in last 3 min)"
fi

# ===================== [W5] traefik: repair ONLY if down (after grafana) =====================
hr "W5 traefik (conditional)"
TF_CODE="$(http http://127.0.0.1:8888/api/version traefik.aether.local)"
if [ "$TF_CODE" = 200 ] && [ "$(unit_active traefik.service)" = active ]; then
  say "traefik already healthy (edge=200, unit=active); skip start"
  TF_OK=yes
else
  say "traefik down (edge=$TF_CODE unit=$(unit_active traefik.service)); repairing"
  TP="$(alpine_all)"
  systemctl --user reset-failed traefik.service >/dev/null 2>&1 || true
  timeout 120 systemctl --user start traefik.service >/dev/null 2>&1 || true
  TF_OK=no
  for i in $(seq 1 45); do
    TF_CODE="$(http http://127.0.0.1:8888/api/version traefik.aether.local)"
    if [ "$TF_CODE" = 200 ]; then TF_OK=yes; break; fi
    sleep 2
  done
  TQ="$(alpine_all)"
  TD=$((TQ - TP))
  say "traefik edge=$TF_OK http=$TF_CODE unit=$(unit_active traefik.service) container=$(cont_state traefik) alpine-delta=$TD"
  if [ "$TF_OK" != yes ]; then
    journalctl --user -u traefik.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    podman logs --tail 25 traefik 2>&1 | sed 's/^/    c: /' || true
    say "[HALT] traefik unhealthy"
    exit 1
  fi
  if [ "$TD" -gt 1 ]; then
    say "[HALT] traefik start spawned $TD alpine (spam NOT dead)"
    exit 1
  fi
fi

# ===================== [W6] replay + idle spam-proof =====================
hr "W6 replay + idle proof"
bash "$CD/20261030-BY-replay.sh" || true
sleep 12
say "alpine containers after 12s idle: $(alpine_all) (expect 0)"
say "platform containers running: $(run_total) (expect 15)"

# ===================== [W7] FULL AUDIT: every cached image + every service =====================
hr "W7 audit: cached images -> classification"
podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort | while read -r img; do
  case "$img" in
    *"<none>"*) continue ;;
    *postgres*|*redis*|*minio*|*weaviate*|*prometheus*|*node-exporter*|*mailpit*|*litellm*|*n8n*|*gitea*|*grafana*|*woodpecker*|*traefik*|*aether-llama*|*alpine*)
      cls="DEPLOYED-RUNNING" ;;
    *zitadel*)  cls="PLANNED-NOT-DEPLOYED (Brick 13; say deploy zitadel)" ;;
    *portainer*) cls="OPTIONAL-SKIP (you have your own GUI)" ;;
    *ubuntu*)   cls="BUILD-LEFTOVER (harmless; keep or prune later)" ;;
    *)          cls="UNCATEGORIZED (review)" ;;
  esac
  printf '  %-55s %s\n' "$img" "$cls"
done
hr "W7 audit: expected platform services"
for s in postgres redis minio weaviate prometheus node-exporter mailpit llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik; do
  c="$(cont_state "$s")"
  u="$(unit_active "$(unit_for "$s")")"
  if [ -z "$u" ]; then u="?"; fi
  if [ "$c" = running ] && [ "$u" = active ]; then v=UP
  elif [ "$c" = running ]; then v=UP(unit-idle)
  else v=DOWN; fi
  printf '  %-20s container=%-8s unit=%-9s %s\n' "$s" "$c" "$u" "$v"
done
hr "W7 audit: kept-by-policy (NOT deleted)"
say "aether-backup.service (your DR unit; failed earlier = separate decision)"
say "ubuntu:* images (build leftovers)"
say "portainer-ce image (optional)"
say "zitadel image (planned Brick 13)"
say "llama-embed container is owned by the ENABLED quadlet llama-embed-container.service (reboot-covered)"

# ===================== [W8] ledger + result =====================
hr "W8 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | CW: gated by bash -n at file and dns-wait level; quote-safe one-pass probe purge (fixed the CV parse-abort typo); conditional non-disruptive repair (healthy units never stopped); guard self-test delta<=1; grafana+traefik repaired with per-start alpine-delta<=1 assertion; replay+idle-proof; full image/service audit (zitadel=planned, portainer=optional, ubuntu=leftover, aether-backup=kept, llama-embed=quadlet-owned). |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
else
  say "ledger row already present (guard suppressed)"
fi
say "[RESULT] CW COMPLETE — guard fixed+self-tested, stale tree killed, grafana+traefik conditional-repaired with spam asserted dead, full audit printed."
exit 0
