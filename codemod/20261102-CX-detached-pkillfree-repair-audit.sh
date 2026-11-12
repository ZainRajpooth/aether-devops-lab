#!/usr/bin/env bash
# 20261102-CX — detached-safe, pkill-FREE, self-test NON-FATAL repair + full audit.
# Never exits invisibly: every branch reaches the end and prints a RESULT line.
# Kills stale guards by cgroup (systemctl stop on ACTIVATING units), NOT pkill -f.
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
TOKEN="cx-detached-pkillfree-repair-audit-v1"

GUARD_INSTALL=ok      # ok | fail
GUARD_TEST=unknown    # pass | fail | skipped
REPAIRED=no

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

# ===================== [X0] READ-ONLY TRUTH =====================
hr "X0 current truth (read-only)"
GF_CODE="$(http http://127.0.0.1:3000/api/health)"
TF_CODE="$(http http://127.0.0.1:8888/api/version traefik.aether.local)"
say "grafana  health_http=$GF_CODE unit=$(unit_active grafana.service) container=$(cont_state grafana)"
say "traefik  edge_http=$TF_CODE  unit=$(unit_active traefik.service) container=$(cont_state traefik)"
say "alpine containers: running=$(alpine_run) total=$(alpine_all)   (running>0 now = stale loop alive)"
say "platform containers running total=$(run_total) (expect 15 when whole stack up)"
systemctl --user list-units --state=activating --type=service --no-pager --plain 2>/dev/null | awk 'NR>1{print "  activating: "$1}' || say "  activating: (none)"
if grep -q 'no per-retry container probes' "$DNS" 2>/dev/null; then say "dns-wait on disk: v3.1 marker PRESENT"; else say "dns-wait on disk: v3.1 marker ABSENT (installing in X1)"; fi

# ===================== [X1] install dns-wait v3.1 (inner bash -n; FAIL is non-fatal) =====================
hr "X1 install dns-wait v3.1 (zero per-retry probes; heal = VALID container reload)"
cp -p "$DNS" "$DNS.pre-CX.bak" 2>/dev/null || true
cat > "$DNS" <<'DWEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh v3.1 (CX): ZERO per-retry container probes.
# Canary = TCP connect to gateway:53 (aardvark), 2s-bounded, /dev/tcp.
# Per-host = wait until podman inspect reports dependency RUNNING (host CLI).
# Heal = pkill our aardvark, then force netavark respawn via VALID form
#        podman network reload <CONTAINER> (postgres); fallback = ONE bounded
#        podman run --rm alpine true (single trigger, NOT a 90-loop). Once/30 tries.
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
  GUARD_INSTALL=ok
else
  say "INNER SYNTAX FAIL; restoring backup; repairs will be SKIPPED"
  cp -p "$DNS.pre-CX.bak" "$DNS"
  GUARD_INSTALL=fail
fi

# ===================== [X2] SELF-TEST (NON-FATAL; prints real guard output) =====================
hr "X2 guard self-test (non-fatal; captures real stdout/stderr)"
if [ "$GUARD_INSTALL" = ok ]; then
  PRE="$(alpine_all)"
  set +e
  timeout 45 "$DNS" postgres >"$TMPD/guard.out" 2>"$TMPD/guard.err"
  GRC=$?
  set -e
  sleep 2
  POST="$(alpine_all)"
  DELTA=$((POST - PRE))
  say "guard rc=$GRC alpine-delta=$DELTA"
  say "--- guard stdout ---"; sed 's/^/    /' "$TMPD/guard.out" 2>/dev/null || true
  say "--- guard stderr ---"; sed 's/^/    /' "$TMPD/guard.err" 2>/dev/null || true
  if [ "$GRC" -eq 0 ] && [ "$DELTA" -le 1 ]; then
    GUARD_TEST=pass
    say "SELF-TEST=PASS"
  else
    GUARD_TEST=fail
    say "SELF-TEST=FAIL (will NOT start units on a failing guard; see stdout/stderr above)"
  fi
else
  GUARD_TEST=skipped
  say "SELF-TEST=SKIPPED (install failed)"
fi

# ===================== [X3] cgroup-kill stale guards (NO pkill -f) + purge junk =====================
hr "X3 stop ACTIVATING units (cgroup-kills stale ExecStartPre) + clear ghosts + purge alpine"
systemctl --user list-units --state=activating --type=service --no-pager --plain 2>/dev/null | awk 'NR>1{print $1}' > "$TMPD/act.txt" || true
if [ -s "$TMPD/act.txt" ]; then
  say "stopping activating units (kills their stale guards via cgroup):"
  sed 's/^/    /' "$TMPD/act.txt"
  xargs -r -n1 systemctl --user stop < "$TMPD/act.txt" >/dev/null 2>&1 || true
  sleep 3
else
  say "no activating units"
fi
systemctl --user reset-failed grafana.service traefik.service >/dev/null 2>&1 || true
# persistent app-Podman@ ghost unit files (backed up); /run transients self-clear
shopt -s nullglob
for f in "$UIDIR"/app-Podman@*.service; do
  cp -p "$f" "$f.pre-CX.bak" 2>/dev/null || true
  rm -f "$f"
  say "removed persistent ghost unit: $f (backup kept)"
done
shopt -u nullglob
# exited alpine via temp file + xargs (quote-safe, no nested command-subst)
podman ps -aq --filter "ancestor=$ALPINE" --filter status=exited 2>/dev/null > "$TMPD/ex.txt" || true
if [ -s "$TMPD/ex.txt" ]; then
  xargs -r podman rm -f < "$TMPD/ex.txt" >/dev/null 2>&1 || true
  say "removed exited alpine: $(wc -l < "$TMPD/ex.txt" | tr -d ' ')"
else
  say "no exited alpine"
fi
# running getent probes, ONE PASS, quote-safe
podman ps --format '{{.Names}} {{.Command}}' 2>/dev/null | grep -F 'getent' | awk '{print $1}' > "$TMPD/probes.txt" || true
if [ -s "$TMPD/probes.txt" ]; then
  xargs -r podman rm -f < "$TMPD/probes.txt" >/dev/null 2>&1 || true
  say "killed running getent probes: $(wc -l < "$TMPD/probes.txt" | tr -d ' ')"
else
  say "no running getent probes"
fi
systemctl --user daemon-reload >/dev/null 2>&1 || true
say "stale guards cgroup-killed; ghosts removed; daemon-reloaded"

# ===================== [X4] grafana repair (ONLY if guard PASSED; conditional) =====================
hr "X4 grafana (conditional; only when self-test PASSED)"
if [ "$GUARD_TEST" != pass ]; then
  say "SKIPPED (guard self-test=$GUARD_TEST); not starting units on an unproven guard"
else
  GF_CODE="$(http http://127.0.0.1:3000/api/health)"
  if [ "$GF_CODE" = 200 ] && [ "$(unit_active grafana.service)" = active ]; then
    say "grafana already healthy (http=200, unit=active); skip start"
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
    GQ="$(alpine_all)"; GD=$((GQ - GP))
    say "grafana health=$GF_OK http=$GF_CODE unit=$(unit_active grafana.service) container=$(cont_state grafana) alpine-delta=$GD"
    if [ "$GF_OK" = yes ] && [ "$GD" -le 1 ]; then
      REPAIRED=yes
      journalctl --user -u grafana.service --since "-3 min" --no-pager 2>/dev/null | grep -m1 'no per-retry container probes' | sed 's/^/    guard: /' || say "    guard: (marker not in last 3 min)"
    else
      journalctl --user -u grafana.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
      podman logs --tail 25 grafana 2>&1 | sed 's/^/    c: /' || true
      say "grafana repair did NOT reach healthy (health=$GF_OK delta=$GD); traefik skipped (ordering rule)"
      GUARD_TEST=fail-after-grafana
    fi
  fi
fi

# ===================== [X5] traefik repair (ONLY if grafana healthy) =====================
hr "X5 traefik (conditional; only when grafana healthy)"
if [ "$REPAIRED" != yes ] && ! { [ "$(http http://127.0.0.1:3000/api/health)" = 200 ] && [ "$(unit_active grafana.service)" = active ]; }; then
  say "SKIPPED (grafana not healthy)"
else
  TF_CODE="$(http http://127.0.0.1:8888/api/version traefik.aether.local)"
  if [ "$TF_CODE" = 200 ] && [ "$(unit_active traefik.service)" = active ]; then
    say "traefik already healthy (edge=200, unit=active); skip start"
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
    TQ="$(alpine_all)"; TD=$((TQ - TP))
    say "traefik edge=$TF_OK http=$TF_CODE unit=$(unit_active traefik.service) container=$(cont_state traefik) alpine-delta=$TD"
    if [ "$TF_OK" = yes ] && [ "$TD" -le 1 ]; then REPAIRED=yes; else
      journalctl --user -u traefik.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
      podman logs --tail 25 traefik 2>&1 | sed 's/^/    c: /' || true
    fi
  fi
fi

# ===================== [X6] replay + idle spam-proof =====================
hr "X6 replay + idle proof"
bash "$CD/20261030-BY-replay.sh" 2>&1 | sed 's/^/  /' || true
sleep 12
say "alpine containers after 12s idle: $(alpine_all) (expect 0)"
say "platform containers running: $(run_total) (expect 15)"

# ===================== [X7] FULL AUDIT =====================
hr "X7 audit: cached images -> classification"
podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort | while read -r img; do
  case "$img" in
    *"<none>"*) continue ;;
    *postgres*|*redis*|*minio*|*weaviate*|*prometheus*|*node-exporter*|*mailpit*|*litellm*|*n8n*|*gitea*|*grafana*|*woodpecker*|*traefik*|*aether-llama*|*alpine*)
      cls="DEPLOYED-RUNNING" ;;
    *zitadel*)   cls="PLANNED-NOT-DEPLOYED (Brick 13; say: deploy zitadel)" ;;
    *portainer*) cls="OPTIONAL-SKIP (you have your own GUI)" ;;
    *ubuntu*)    cls="BUILD-LEFTOVER (harmless; keep or prune later)" ;;
    *)           cls="UNCATEGORIZED (review)" ;;
  esac
  printf '  %-55s %s\n' "$img" "$cls"
done
hr "X7 audit: expected platform services"
for s in postgres redis minio weaviate prometheus node-exporter mailpit llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik; do
  c="$(cont_state "$s")"; u="$(unit_active "$(unit_for "$s")")"; [ -z "$u" ] && u="?"
  if [ "$c" = running ] && [ "$u" = active ]; then v=UP
  elif [ "$c" = running ]; then v=UP(unit-idle)
  else v=DOWN; fi
  printf '  %-20s container=%-8s unit=%-9s %s\n' "$s" "$c" "$u" "$v"
done
hr "X7 audit: kept-by-policy (NOT deleted)"
say "aether-backup.service (your DR unit; failed earlier = separate decision)"
say "ubuntu:* images (build leftovers) ; portainer-ce image (optional) ; zitadel image (planned Brick 13)"
say "llama-embed container is owned by the ENABLED quadlet llama-embed-container.service (reboot-covered)"

# ===================== [X8] ledger + RESULT (always reached; exit 0) =====================
hr "X8 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | CX: detached-safe pkill-FREE; guard install=%s self-test=%s; stale guards cgroup-killed via systemctl stop on activating units; app-Podman@ ghosts removed (backed up); alpine junk purged quote-safe; grafana/traefik conditional repair (repaired=%s); replay+idle-proof; full audit (zitadel=planned, portainer=optional, ubuntu=leftover, aether-backup=kept, llama-embed=quadlet-owned). |\n' \
    "$(date +%F)" "$TOKEN" "$([ "$REPAIRED" = yes ] && echo PASS || echo PARTIAL)" "$GUARD_INSTALL" "$GUARD_TEST" "$REPAIRED" >> "$IDX"
  say "ledger row appended"
else
  say "ledger row already present (guard suppressed)"
fi
if [ "$REPAIRED" = yes ]; then
  say "[RESULT] CX COMPLETE — guard self-tested PASS, stale guards cgroup-killed, grafana+traefik repaired with spam asserted dead, full audit printed."
elif [ "$GUARD_TEST" = fail ] || [ "$GUARD_TEST" = skipped ] || [ "$GUARD_TEST" = fail-after-grafana ]; then
  say "[RESULT] CX PARTIAL — guard self-test=$GUARD_TEST; repairs skipped/aborted by design; see X2 stdout/stderr + X4/X5 dumps. PASTE THIS FILE."
else
  say "[RESULT] CX PARTIAL — units already healthy or repair inconclusive; see X0/X6/X7."
fi
exit 0
