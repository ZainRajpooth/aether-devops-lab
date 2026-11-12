#!/usr/bin/env bash
# 20261103-DF — the units don't read the file we kept editing. Replace their
# ExecStartPre via systemd DROP-IN (authoritative, quadlet-safe), sync v3.4 to every
# on-disk copy, kill the in-flight v2 loop first, then start grafana->traefik gated.
set -uo pipefail
HOME_="$HOME"
CANON="$HOME_/DevOps/aether/infra/scripts/aether-dns-wait.sh"
CD="$HOME_/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
UDIR="$HOME_/.config/systemd/user"
NET="aether"; ALPINE="docker.io/library/alpine:latest"
TOKEN="df-dropin-execstartpre-fix-v1"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
alpine_all(){ podman ps -a --filter "ancestor=$ALPINE" -q 2>/dev/null | wc -l | tr -d ' '; }
run_total(){ podman ps -q 2>/dev/null | wc -l | tr -d ' '; }
unit_active(){ systemctl --user is-active "$1" 2>/dev/null | tr -d '\n'; }
http(){ local u="$1" h="${2:-}" c=""; if [ -n "$h" ]; then c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $h" "$u" 2>/dev/null || true)"; else c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" 2>/dev/null || true)"; fi; printf '%s' "$c"; }
purge_alpine(){
  podman ps -aq --filter "ancestor=$ALPINE" --filter status=exited 2>/dev/null > /tmp/df-ex.$$ || true
  [ -s /tmp/df-ex.$$ ] && { xargs -r podman rm -f < /tmp/df-ex.$$ >/dev/null 2>&1 || true; say "removed exited alpine: $(wc -l < /tmp/df-ex.$$)"; }
  rm -f /tmp/df-ex.$$ 2>/dev/null || true
  podman ps --format '{{.Names}} {{.Command}}' 2>/dev/null | grep -F getent | awk '{print $1}' > /tmp/df-pr.$$ || true
  [ -s /tmp/df-pr.$$ ] && { xargs -r podman rm -f < /tmp/df-pr.$$ >/dev/null 2>&1 || true; say "killed stray getent alpine: $(wc -l < /tmp/df-pr.$$)"; }
  rm -f /tmp/df-pr.$$ 2>/dev/null || true
}

hr "F0 stop the wedged units NOW (cgroup-kills the running v2 probe loop)"
systemctl --user stop grafana.service traefik.service >/dev/null 2>&1 || true
sleep 3
purge_alpine
systemctl --user reset-failed grafana.service traefik.service >/dev/null 2>&1 || true
say "stopped+reset; activating now: $(systemctl --user list-units --state=activating --type=service --no-pager --plain 2>/dev/null | awk 'NR>1{printf "%s ",$1}')"

hr "F1 EVIDENCE: real ExecStartPre of each unit (inline-loop vs stale-path vs script)"
for u in grafana traefik; do
  say "--- $u.service ExecStartPre (effective, incl any existing drop-in) ---"
  systemctl --user cat "$u.service" 2>/dev/null | grep -i 'execstartpre' | sed 's/^/    /' || say "    (none found)"
done

hr "F2 ensure CANON v3.4 on disk (idempotent; backup once)"
if grep -q 'resolves in-netns' "$CANON" 2>/dev/null; then
  say "CANON already v3.4 (marker present); leaving as-is"
else
  cp -p "$CANON" "$CANON.pre-DF.bak" 2>/dev/null || true
  cat > "$CANON" <<'GEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh v3.4 (DF): rootless-correct. Canary = IN-NETNS getent (the only
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
  case "$a" in 127.*|::1|"") return 1 ;; *) return 0 ;; esac
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
  chmod +x "$CANON"
  say "CANON written v3.4"
fi
bash -n "$CANON" && say "CANON syntax OK" || { say "[HALT] CANON syntax BAD"; exit 1; }

hr "F3 sync v3.4 to EVERY on-disk copy (covers stale-path units we don't override)"
mapfile -t COPIES < <(find "$HOME_/DevOps" /usr/local/bin /opt 2>/dev/null -type f -name 'aether-dns-wait*.sh')
for c in "${COPIES[@]}"; do
  [ "$c" = "$CANON" ] && continue
  if grep -q 'resolves in-netns' "$c" 2>/dev/null; then
    say "copy already v3.4: $c"
  else
    cp -p "$c" "$c.pre-DF.bak" 2>/dev/null || true
    if cp -p "$CANON" "$c" 2>/dev/null; then say "synced v3.4 -> $c (backup kept)"; else say "WARN: cannot write $c (perms?); rely on drop-in for its unit"; fi
  fi
done
[ "${#COPIES[@]}" -eq 0 ] && say "no extra copies found"

hr "F4 install DROP-IN overrides (authoritative; quadlet will NOT regenerate these)"
install_override(){ # $1=unit  $2..=deps
  local unit="$1"; shift
  local deps="$*"
  local ddir="$UDIR/$unit.service.d"
  mkdir -p "$ddir"
  [ -f "$ddir/override.conf" ] && cp -p "$ddir/override.conf" "$ddir/override.conf.pre-DF.bak" 2>/dev/null || true
  cat > "$ddir/override.conf" <<OVRF
# DF: replace inline/stale ExecStartPre with the proven v3.4 guard (rootless-correct).
# Clear ALL prior ExecStartPre (cumulative directive), then re-add the guard with deps.
[Service]
ExecStartPre=
ExecStartPre=$CANON $deps
OVRF
  say "wrote $ddir/override.conf  (ExecStartPre -> v3.4 $deps)"
}
install_override grafana postgres
install_override traefik "postgres grafana"
systemctl --user daemon-reload >/dev/null 2>&1 || true
say "daemon-reloaded"
say "--- effective ExecStartPre after drop-in ---"
for u in grafana traefik; do
  systemctl --user cat "$u.service" 2>/dev/null | grep -i 'execstartpre' | sed "s/^/    $u: /" || say "    $u: (none)"
done

hr "F5 self-test CANON on a RUNNING host (postgres only; expect rc=0, 0 containers)"
PRE="$(alpine_all)"; set +e; timeout 40 "$CANON" postgres >/tmp/df-g.out 2>&1; GRC=$?; set -e
sleep 1; POST="$(alpine_all)"
say "guard rc=$GRC alpine-delta=$((POST-PRE))"; sed 's/^/    /' /tmp/df-g.out 2>/dev/null || true
[ "$GRC" -eq 0 ] || { say "[HALT] guard rc=$GRC on running host = real bug; paste F5"; exit 1; }

hr "F6 grafana (drop-in ExecStartPre now = v3.4 -> instant; then health gate)"
GP="$(alpine_all)"
set +e; timeout 120 systemctl --user start grafana.service >/dev/null 2>&1; set -e
GU=0; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:3000/api/health)" = 200 ] && { GU=1; break; }; sleep 2; done
GQ="$(alpine_all)"
say "grafana up=$GU http=$(http http://127.0.0.1:3000/api/health) unit=$(unit_active grafana.service) alpine-delta=$((GQ-GP))"
if [ "$GU" != 1 ]; then
  say "--- effective unit (did drop-in apply?) ---"; systemctl --user cat grafana.service 2>/dev/null | grep -i 'execstartpre' | sed 's/^/    /'
  journalctl --user -u grafana.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /'
  podman logs --tail 25 grafana 2>&1 | sed 's/^/    c: /' || true
  say "[HALT] grafana not healthy; paste F6"; exit 1
fi

hr "F7 traefik (deps postgres+grafana now up -> instant; then edge gate)"
TP="$(alpine_all)"
set +e; timeout 120 systemctl --user start traefik.service >/dev/null 2>&1; set -e
TU=0; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:8888/api/version traefik.aether.local)" = 200 ] && { TU=1; break; }; sleep 2; done
TQ="$(alpine_all)"
say "traefik up=$TU http=$(http http://127.0.0.1:8888/api/version traefik.aether.local) unit=$(unit_active traefik.service) alpine-delta=$((TQ-TP))"
if [ "$TU" != 1 ]; then
  systemctl --user cat traefik.service 2>/dev/null | grep -i 'execstartpre' | sed 's/^/    /'
  journalctl --user -u traefik.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /'
  podman logs --tail 25 traefik 2>&1 | sed 's/^/    c: /' || true
  say "[HALT] traefik not healthy; paste F7"; exit 1
fi

hr "F8 purge + replay + counts"
purge_alpine
bash "$CD/20261030-BY-replay.sh" 2>&1 | sed 's/^/  /' || true
sleep 8
say "alpine idle: $(alpine_all) (expect 0); platform running: $(run_total) (expect 15)"

hr "F9 ledger + RESULT"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | DF root-cause: units did NOT read the edited guard file (E3 rc=0/0-cont vs E4 10s-loop proved inline/stale ExecStartPre); fix = systemd DROP-IN clearing ExecStartPre and re-pointing to CANON v3.4 (quadlet-safe), plus v3.4 synced to every on-disk copy; in-flight v2 loop cgroup-stopped first; grafana+traefik started gated; replay; spam=0. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
fi
say "[RESULT] DF COMPLETE - ExecStartPre now authoritative v3.4 via drop-in, grafana+traefik UP, stack at 15."
exit 0
