#!/usr/bin/env bash
set -uo pipefail

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
FW="$CD/20261030-BW-netavark-aardvark-process-state-heal.sh"
DNS_SCRIPT="$A/infra/scripts/aether-dns-wait.sh"
PODMAN_PY="/home/dev/DevOps/apps/podman/Podman.py"
ALPINE="docker.io/library/alpine:latest"
NET="aether"
GW="10.89.0.1"

HEAL_TOKEN="bw-netavark-aardvark-process-state-heal-v1"
HEAL_FAIL_TOKEN="bw-aardvark-heal-failed-escalate-v1"
DURABLE_TOKEN="bw-durable-dns-wait-process-heal-v1"
GUI_OK="bw-gui-ghost-rows-user-units-v1"
GUI_BAD="bw-gui-ghost-rows-failed-v1"
BQ_TOKEN="bq-traefik-brick11-green-v1"

VERDICT="UNKNOWN"

say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
tok(){ if grep -qF "$1" "$IDX" 2>/dev/null; then printf 'PRESENT'; else printf 'absent '; fi; }
active_state(){ printf '%s' "$(norm "$(systemctl --user is-active "$1" 2>/dev/null || true)")"; }
container_status(){ printf '%s' "$(norm "$(podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null || true)")"; }
nrestarts(){ printf '%s' "$(norm "$(systemctl --user show "$1" -p NRestarts --value 2>/dev/null || true)")"; }
http_code(){
  local url="$1" host="${2:-}" code
  if [ -n "$host" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $host" "$url" 2>/dev/null || true)"
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)"
  fi
  code="$(norm "$code")"
  if [ -z "$code" ]; then code=000; fi
  printf '%s' "$code"
}
is_loopback(){
  local a="${1:-}"
  case "$a" in
    127.*|::1|localhost) return 0 ;;
    '') return 0 ;;
    *) return 1 ;;
  esac
}
py_ok(){
  local f="$1"
  if [ ! -f "$f" ]; then printf 'missing'; return; fi
  if python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" 2>/dev/null; then
    printf 'ok'
  else
    printf 'CORRUPT'
  fi
}
sh_ok(){
  local f="$1"
  if [ ! -f "$f" ]; then printf 'missing'; return; fi
  if bash -n "$f" 2>/dev/null; then printf 'ok'; else printf 'CORRUPT'; fi
}
probe_getent(){
  local name="$1"
  local out="$TMPD/ge-$name.out"
  local err="$TMPD/ge-$name.err"
  local rc=0
  : > "$out"; : > "$err"
  podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" >"$out" 2>"$err" || rc=$?
  P_RC="$rc"
  P_ADDR="$(awk 'NR==1{print $1}' "$out" 2>/dev/null || true)"
  P_ADDR="$(norm "$P_ADDR")"
}
probe_ns(){
  local name="$1"
  local out="$TMPD/ns-$name.out"
  local err="$TMPD/ns-$name.err"
  local rc=0
  : > "$out"; : > "$err"
  podman run --rm --network "$NET" "$ALPINE" nslookup "$name" "$GW" >"$out" 2>"$err" || rc=$?
  NS_RC="$rc"
  NS_BLOB="$(printf '%s %s' "$(cat "$out" 2>/dev/null)" "$(cat "$err" 2>/dev/null)")"
}
classify_dns(){
  if [ -n "$P_ADDR" ] && ! is_loopback "$P_ADDR"; then printf 'alive-resolved'; return; fi
  if printf '%s' "$NS_BLOB" | grep -Eqi "can't find|nxdomain|non-existent|authoritative|servfail"; then printf 'alive-nx'; return; fi
  if printf '%s' "$NS_BLOB" | grep -Eqi "no server|connection refused|timed out|could not connect|server not found|network is unreachable"; then printf 'dead'; return; fi
  if [ "${NS_RC:-1}" = 0 ]; then printf 'alive-odd'; return; fi
  printf 'unknown'
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT

say "=== [X0] ledger tokens ==="
say "[X0] BW_green(HEAL)        = $(tok "$HEAL_TOKEN")"
say "[X0] BW_w1fail(HEAL_FAIL)  = $(tok "$HEAL_FAIL_TOKEN")"
say "[X0] BW_durable(DURABLE)   = $(tok "$DURABLE_TOKEN")"
say "[X0] BW_gui_ok             = $(tok "$GUI_OK")"
say "[X0] BW_gui_bad            = $(tok "$GUI_BAD")"
say "[X0] BQ_traefik_green      = $(tok "$BQ_TOKEN")"

say "=== [X1] on-disk integrity ==="
say "[X1] BW script        : $FW"
say "[X1]   exists=$([ -f "$FW" ] && echo yes || echo NO)  bash -n=$(sh_ok "$FW")"
say "[X1] dns-wait         : $DNS_SCRIPT"
say "[X1]   bash -n=$(sh_ok "$DNS_SCRIPT")  heal_aardvark_marker=$(grep -q 'heal_aardvark' "$DNS_SCRIPT" 2>/dev/null && echo yes || echo no)  warn_mode_left=$(grep -q 'WARN host' "$DNS_SCRIPT" 2>/dev/null && echo yes || echo no)"
say "[X1]   pre-BW backup  : $([ -f "$DNS_SCRIPT.pre-BW.bak" ] && echo present || echo none)"
say "[X1] Podman.py        : $PODMAN_PY"
say "[X1]   ast.parse=$(py_ok "$PODMAN_PY")  ghost_marker=$(grep -qF "unit:{u['unit']}" "$PODMAN_PY" 2>/dev/null && echo yes || echo no)"
say "[X1]   pre-BW backup  : $([ -f "$PODMAN_PY.pre-BW.bak" ] && echo present || echo none)"
if [ -f "$PODMAN_PY" ] && [ -f "$PODMAN_PY.pre-BW.bak" ]; then
  if cmp -s "$PODMAN_PY" "$PODMAN_PY.pre-BW.bak"; then
    say "[X1]   Podman.py == backup (patch NOT landed or already restored)"
  else
    say "[X1]   Podman.py != backup (patch landed or file changed since backup)"
  fi
fi

say "=== [X2] load / memory / OOM evidence ==="
say "[X2] nproc=$(nproc 2>/dev/null || echo ?)  loadavg=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo ?)"
free -m 2>/dev/null | sed 's/^/    free: /' || say "    free: (n/a)"
say "[X2] user-manager=$(norm "$(systemctl --user is-system-running 2>/dev/null || true)")"
journalctl -k -n 30 --no-pager 2>/dev/null | grep -Ei 'oom|out of memory|killed process' | sed 's/^/    oom?: /' || say "    oom?: (none readable / none)"
say "[X2] our aardvark-dns procs (live): $(pgrep -u "$(id -u)" -x aardvark-dns 2>/dev/null | wc -l | tr -d ' ')"

say "=== [X3] live container state ==="
for c in postgres litellm gitea grafana n8n woodpecker-server woodpecker-agent traefik; do
  say "[X3]   $c=$(container_status "$c")  unit=$(active_state "$c.service")  NRestarts=$(nrestarts "$c.service")"
done

say "=== [X3] live in-network DNS ==="
GW="$(podman network inspect "$NET" --format '{{range .subnets}}{{.gateway}} {{end}}' 2>/dev/null | awk '{print $1}')"
GW="$(norm "$GW")"
if [ -z "$GW" ]; then GW="10.89.0.1"; fi
probe_getent postgres
probe_ns postgres
DNS_STATE="$(classify_dns)"
say "[X3]   getent postgres -> '${P_ADDR:-none}' true_rc=$P_RC  nslookup_state=$DNS_STATE  gw=$GW"
for n in gitea woodpecker-server; do
  probe_getent "$n"
  say "[X3]   getent $n -> '${P_ADDR:-none}' true_rc=$P_RC"
done

say "=== [X3] direct + proxied health ==="
say "[X3]   gitea_direct=$(http_code http://127.0.0.1:3001/api/healthz)"
say "[X3]   wp_direct=$(http_code http://127.0.0.1:8000/api/health)"
say "[X3]   n8n_direct=$(http_code http://127.0.0.1:5678/healthz)"
say "[X3]   grafana_direct=$(http_code http://127.0.0.1:3000/api/health)"
say "[X3]   litellm_direct=$(http_code http://127.0.0.1:4000/health/liveliness)"
say "[X3]   traefik_api=$(http_code http://127.0.0.1:8888/api/version traefik.aether.local)"
say "[X3]   gitea_proxy=$(http_code http://127.0.0.1:8888/api/healthz gitea.aether.local)"
say "[X3]   wp_proxy=$(http_code http://127.0.0.1:8888/api/health woodpecker.aether.local)"
say "[X3]   grafana_proxy=$(http_code http://127.0.0.1:8888/api/health grafana.aether.local)"
say "[X3]   n8n_proxy=$(http_code http://127.0.0.1:8888/healthz n8n.aether.local)"

SIX="gitea grafana woodpecker-server woodpecker-agent n8n traefik"
FLAT=yes
declare -A NR1 NR2
for u in $SIX; do NR1["$u"]="$(nrestarts "$u.service")"; done
sleep 6
for u in $SIX; do NR2["$u"]="$(nrestarts "$u.service")"; done
for u in $SIX; do
  if [ "${NR1[$u]}" != "${NR2[$u]}" ]; then
    FLAT=no
    say "[X3]   NOT-FLAT $u NRestarts ${NR1[$u]} -> ${NR2[$u]} (still flapping)"
  fi
done
if [ "$FLAT" = yes ]; then say "[X3]   NRestarts flat across 6s for all six"; fi

say "=== [X4] verdict ==="
PROXIED_OK=no
if [ "$(http_code http://127.0.0.1:8888/api/version traefik.aether.local)" = 200 ] &&
   [ "$(http_code http://127.0.0.1:8888/api/healthz gitea.aether.local)" = 200 ] &&
   [ "$(http_code http://127.0.0.1:8888/api/health woodpecker.aether.local)" = 200 ] &&
   [ "$(http_code http://127.0.0.1:8888/api/health grafana.aether.local)" = 200 ] &&
   [ "$(http_code http://127.0.0.1:8888/healthz n8n.aether.local)" = 200 ]; then
  PROXIED_OK=yes
fi
ALL_RUNNING=yes
for c in gitea grafana woodpecker-server woodpecker-agent n8n traefik; do
  if [ "$(container_status "$c")" != running ]; then ALL_RUNNING=no; fi
done

PY_INTEGRITY="$(py_ok "$PODMAN_PY")"
SH_INTEGRITY="$(sh_ok "$DNS_SCRIPT")"
CORRUPT=no
if [ "$PY_INTEGRITY" = CORRUPT ] || [ "$SH_INTEGRITY" = CORRUPT ]; then CORRUPT=yes; fi

if [ "$(tok "$HEAL_TOKEN")" = PRESENT ] && [ "$PROXIED_OK" = yes ] && [ "$ALL_RUNNING" = yes ] && [ "$FLAT" = yes ]; then
  VERDICT="GREEN"
elif [ "$CORRUPT" = yes ]; then
  VERDICT="CORRUPT"
elif [ "$(tok "$HEAL_FAIL_TOKEN")" = PRESENT ] && [ "$DNS_STATE" != alive-resolved ]; then
  VERDICT="HALTED_W1"
elif [ "$(tok "$DURABLE_TOKEN")" = PRESENT ] || [ "$(tok "$GUI_OK")" = PRESENT ] || [ "$(tok "$GUI_BAD")" = PRESENT ] || [ "$(grep -q 'heal_aardvark' "$DNS_SCRIPT" 2>/dev/null && echo yes || echo no)" = yes ] || [ "$(grep -qF "unit:{u['unit']}" "$PODMAN_PY" 2>/dev/null && echo yes || echo no)" = yes ]; then
  VERDICT="HALF_CLEAN"
else
  VERDICT="NOT_STARTED"
fi
say "[X4] VERDICT = $VERDICT"
say "[X4]   (corrupt: Podman.py=$PY_INTEGRITY dns-wait=$SH_INTEGRITY; dns_state=$DNS_STATE; proxied=$PROXIED_OK all_running=$ALL_RUNNING flat=$FLAT)"

say "=== [X5] exact next action for this verdict ==="
if [ "$VERDICT" = GREEN ]; then
  cat <<'NX'
  >>> NEXT (BW already finished green; do NOT rerun BW):
      bash "$HOME/DevOps/aether/codemod/20261030-BW-replay.sh"        # expect [GATE PASS]
      pkill -f 'Podman\.py' || true
      nohup /home/dev/DevOps/.venv/bin/python /home/dev/DevOps/apps/podman/Podman.py >/tmp/aether-podman-gui.log 2>&1 &
      # then, in chat, say:  build woodpecker pipeline proof
NX
elif [ "$VERDICT" = CORRUPT ]; then
  cat <<'NX'
  >>> NEXT (a file was truncated by the kill; restore the known-good pre-BW backup, THEN rerun BW):
      # restore ONLY the corrupt one(s):
      #   Podman.py corrupt? ->
      [ -f /home/dev/DevOps/apps/podman/Podman.py.pre-BW.bak ] && cp -p /home/dev/DevOps/apps/podman/Podman.py.pre-BW.bak /home/dev/DevOps/apps/podman/Podman.py
      #   dns-wait corrupt? ->
      [ -f "$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh.pre-BW.bak" ] && cp -p "$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh.pre-BW.bak" "$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh"
      # verify integrity is now ok:
      python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read()); print('Podman.py ast OK')" /home/dev/DevOps/apps/podman/Podman.py
      bash -n "$HOME/DevOps/aether/infra/scripts/aether-dns-wait.sh" && echo "dns-wait bash -n OK"
      # then rerun BW (idempotent; it will re-apply the GUI patch + durable heal + cascade + BQ):
      OUT="/tmp/aether-bw-$(date +%Y%m%d-%H%M%S).txt"; bash "$HOME/DevOps/aether/codemod/20261030-BW-netavark-aardvark-process-state-heal.sh" 2>&1 | tee "$OUT"
NX
elif [ "$VERDICT" = HALTED_W1 ]; then
  cat <<'NX'
  >>> NEXT (BW's 3-step ladder could NOT revive aardvark-dns; try the lighter bookkeeping reset BEFORE any network recreate):
      podman system migrate
      podman network reload aether
      podman run --rm --network aether docker.io/library/alpine:latest getent hosts postgres   # expect 10.89.x.x
      # If that prints a 10.89.x.x IP -> rerun BW (it will heal via reload and finish):
      #   OUT="/tmp/aether-bw-$(date +%Y%m%d-%H%M%S).txt"; bash "$HOME/DevOps/aether/codemod/20261030-BW-netavark-aardvark-process-state-heal.sh" 2>&1 | tee "$OUT"
      # If STILL empty -> DO NOT recreate the network yourself; paste this BX output + the getent result and I will ship
      #   the deliberate aether recreate with the exact dependency stop/start order for your unit set (blast-radius control).
NX
elif [ "$VERDICT" = HALF_CLEAN ]; then
  cat <<'NX'
  >>> NEXT (BW was killed between phases; files are intact; rerun BW — it is idempotent and resumes/finishes):
      OUT="/tmp/aether-bw-$(date +%Y%m%d-%H%M%S).txt"; bash "$HOME/DevOps/aether/codemod/20261030-BW-netavark-aardvark-process-state-heal.sh" 2>&1 | tee "$OUT"
      # OPTIONAL, only if [X2] showed high load / OOM and the box feels sluggish: stop the bleeders first to halt the
      # alpine-probe CPU burn (BW W3 restarts them anyway; postgres/litellm left running; data retained):
      #   systemctl --user stop woodpecker-agent.service woodpecker-server.service gitea.service grafana.service n8n.service traefik.service 2>/dev/null || true
NX
else
  cat <<'NX'
  >>> NEXT (terminal closed before BW applied anything; nothing was touched; just run BW):
      OUT="/tmp/aether-bw-$(date +%Y%m%d-%H%M%S).txt"; bash "$HOME/DevOps/aether/codemod/20261030-BW-netavark-aardvark-process-state-heal.sh" 2>&1 | tee "$OUT"
NX
fi

say "[X5] triage saved to: $OUT"
say "[RESULT] BX TRIAGE — verdict=$VERDICT dns_state=$DNS_STATE proxied=$PROXIED_OK all_running=$ALL_RUNNING flat=$FLAT corrupt=$CORRUPT (read-only; no persistent state changed)"
exit 0
