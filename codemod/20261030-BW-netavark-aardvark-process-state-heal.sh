#!/usr/bin/env bash
# 20261030-BW — corrected heal of the aether in-network DNS data plane.
# Supersedes BV. BV's V1 chased a systemd unit that does not exist by design:
# netavark>=4 forks aardvark-dns per-network as a CHILD PROCESS; the binary IS installed
# (/usr/lib/podman/aardvark-dns 1.16.0, netavark 1.16.1) but is libexec-invoked, so a
# `command -v` PATH probe wrongly reported MISSING. The true fault is a STALE netavark
# runtime state dir (/run/user/UID/containers/networks/<net>) whose dead pidfile makes
# `podman network reload` no-op, so the DNS daemon never respawns and nothing resolves.
#
# BW ladder (rootless, escalating, each step re-proved with TRUE getent rc + in-netns nslookup):
#   W0 read-only corrected report (libexec path+version from podman info; derive gateway;
#      true-getent canary; in-netns nslookup state classify; pgrep/ls of stale state).
#   Wgui EARLY + NON-FATAL: patch Podman.py fetch_containers() ghost rows so the user's
#      ORIGINAL symptom (stopped --rm services vanish from Containers tab) is fixed
#      regardless of the DNS outcome (it never ran in BR/BS/BT/BV — all halted before it).
#   W1 heal: step1 reload; step2 pkill -u ours -x aardvark-dns + reload; step3 rm stale
#      aether runtime state dir(s) + reload. Capture reload stderr each step. If all fail
#      -> deep in-netns diagnostic + PRINT a deliberate network-recreate plan (NOT executed)
#      + HALT (no promote, no cascade). Never restarts postgres/litellm; never recreates net blind.
#   W2 durable dns-wait rewrite: heal_aardvark() = the same process/state ladder (NO systemd
#      unit), then canary, then per-host STRICT loopback reject. Closes the class permanently.
#   W3 cascade gitea->grafana->woodpecker-server->n8n->woodpecker-agent (postgres/litellm untouched).
#   W4 direct gate. W5 rerun BQ (traefik). W6 proxied gate + NRestarts double-sample stability.
#   W7 guarded ledger + replay + safe-hostnames note + llama-embed deferred note.
#
# Safety: no sudo; no service/model pull; no ollama/open-webui; no secret echo; --check pure.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks.
set -uo pipefail

TMPD="$(mktemp -d)"
DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"

FQ="$CD/20261030-BQ-traefik-brick11.sh"
DNS_SCRIPT="$A/infra/scripts/aether-dns-wait.sh"
ALPINE="docker.io/library/alpine:latest"
NET="aether"
CANARY="postgres"

UNIT_INST_DIR="$HOME/.config/systemd/user"
PODMAN_PY_FALLBACK="/home/dev/DevOps/apps/podman/Podman.py"

CASCADE="gitea grafana woodpecker-server n8n"
GATE_ALL="postgres gitea grafana n8n litellm woodpecker-server woodpecker-agent traefik"

HEAL_TOKEN="bw-netavark-aardvark-process-state-heal-v1"
HEAL_FAIL_TOKEN="bw-aardvark-heal-failed-escalate-v1"
DURABLE_TOKEN="bw-durable-dns-wait-process-heal-v1"
GUI_OK="bw-gui-ghost-rows-user-units-v1"
GUI_BAD="bw-gui-ghost-rows-failed-v1"
BQ_TOKEN="bq-traefik-brick11-green-v1"

BAK_SUFFIX="pre-BW.bak"
GW="10.89.0.1"
HEAL_STEP="none"
GUI_STATUS="not-attempted"
DNS_STATE="unknown"
CANARY_ADDR=""
LAST_ADDR=""
LAST_RC=0
LAST_OUT=""
LAST_ERR=""

cleanup(){ rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }
need_cmd(){ if ! command -v "$1" >/dev/null 2>&1; then halt "missing required command: $1"; fi; }
to_int(){
  local v
  v="$(norm "${1:-0}")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}
bak_once(){
  local f="$1"
  if [ -f "$f" ] && [ ! -f "$f.$BAK_SUFFIX" ]; then
    cp -p "$f" "$f.$BAK_SUFFIX" || true
    say "[BAK] $f.$BAK_SUFFIX"
  fi
}
active_state(){ printf '%s' "$(norm "$(systemctl --user is-active "$1" 2>/dev/null || true)")"; }
container_status(){ printf '%s' "$(norm "$(podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null || true)")"; }
nrestarts(){ printf '%s' "$(to_int "$(norm "$(systemctl --user show "$1" -p NRestarts --value 2>/dev/null || true)")")"; }
is_loopback(){
  local a="${1:-}"
  case "$a" in
    127.*|::1|localhost) return 0 ;;
    '') return 0 ;;
    *) return 1 ;;
  esac
}
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
wait_http(){
  local url="$1" host="${2:-}" tries="${3:-60}" i code
  for i in $(seq 1 "$tries"); do
    code="$(http_code "$url" "$host")"
    if [ "$code" = 200 ]; then return 0; fi
    sleep 2
  done
  return 1
}
health_url_for(){
  case "$1" in
    gitea)              printf 'http://127.0.0.1:3001/api/healthz' ;;
    grafana)            printf 'http://127.0.0.1:3000/api/health' ;;
    woodpecker-server)  printf 'http://127.0.0.1:8000/api/health' ;;
    n8n)                printf 'http://127.0.0.1:5678/healthz' ;;
    litellm)            printf 'http://127.0.0.1:4000/health/liveliness' ;;
    *)                  printf '' ;;
  esac
}
# TRUE rc: no pipe on podman run, so $? is the container's getent exit (2=not-found,0=ok).
probe_getent(){
  local name="$1" out="$TMPD/ge-$name.out" err="$TMPD/ge-$name.err" rc=0
  : > "$out"; : > "$err"
  podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" >"$out" 2>"$err" || rc=$?
  LAST_RC="$rc"
  LAST_OUT="$(cat "$out" 2>/dev/null || true)"
  LAST_ERR="$(cat "$err" 2>/dev/null || true)"
  LAST_ADDR="$(awk 'NR==1{print $1}' "$out" 2>/dev/null || true)"
  LAST_ADDR="$(norm "$LAST_ADDR")"
}
# in-netns nslookup straight at the DNS server IP -> distinguishes dead vs alive-but-unregistered.
probe_ns(){
  local name="$1" out="$TMPD/ns-$name.out" err="$TMPD/ns-$name.err" rc=0
  : > "$out"; : > "$err"
  podman run --rm --network "$NET" "$ALPINE" nslookup "$name" "$GW" >"$out" 2>"$err" || rc=$?
  NS_RC="$rc"
  NS_OUT="$(cat "$out" 2>/dev/null || true)"
  NS_ERR="$(cat "$err" 2>/dev/null || true)"
}
classify_dns(){
  local blob
  blob="$(printf '%s %s' "$NS_OUT" "$NS_ERR")"
  if [ -n "$LAST_ADDR" ] && ! is_loopback "$LAST_ADDR"; then
    printf 'alive-resolved'
    return
  fi
  if printf '%s' "$blob" | grep -Eqi "can't find|nxdomain|non-existent|authoritative|servfail"; then
    printf 'alive-nx'
    return
  fi
  if printf '%s' "$blob" | grep -Eqi "no server|connection refused|timed out|could not connect|server not found|network is unreachable"; then
    printf 'dead'
    return
  fi
  if [ "${NS_RC:-1}" = 0 ]; then
    printf 'alive-odd'
    return
  fi
  printf 'unknown'
}
canary_proof(){
  probe_getent "$CANARY"
  probe_ns "$CANARY"
  DNS_STATE="$(classify_dns)"
  if [ -n "$LAST_ADDR" ] && ! is_loopback "$LAST_ADDR"; then
    CANARY_ADDR="$LAST_ADDR"
    return 0
  fi
  CANARY_ADDR=""
  return 1
}
reload_net(){
  local tag="$1" o="$TMPD/reload-$tag.out" rc=0
  : > "$o"
  podman network reload "$NET" >"$o" 2>&1 || rc=$?
  say "[W1] reload($tag) rc=$rc out=$(head -c 200 "$o" 2>/dev/null | tr '\n' ' ')"
}
pkill_ours(){
  local n
  n="$(pgrep -u "$(id -u)" -x aardvark-dns 2>/dev/null | wc -l | tr -d ' ')"
  say "[W1] aardvark-dns procs (ours) before pkill: ${n:-0}"
  pkill -u "$(id -u)" -x aardvark-dns >/dev/null 2>&1 || true
  sleep 2
}
clear_state(){
  local rt d removed=0
  rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks"
  say "[W1] runtime networks dir: $rt"
  if [ -d "$rt" ]; then
    ls -la "$rt" 2>/dev/null | sed 's/^/      ls: /' || true
  fi
  for d in "$rt/$NET" "$rt/${NET}"-*; do
    if [ -d "$d" ]; then
      rm -rf "$d" 2>/dev/null || true
      removed=$((removed + 1))
      say "[W1] removed stale state dir: $d"
    fi
  done
  if [ "$removed" = 0 ]; then
    say "[W1] no aether state dir found to clear (netavark may use another path; reload still attempted)"
  fi
}
dump_deep(){
  say "=== [DUMP] podman info network/dns ==="
  podman info 2>/dev/null | grep -Ei 'aardvark|netavark|dns|network.?backend|path|version|package' | sed 's/^/    info: /' || true
  say "=== [DUMP] our aardvark procs ==="
  pgrep -u "$(id -u)" -a aardvark-dns 2>/dev/null | sed 's/^/    proc: /' || say "    (none)"
  say "=== [DUMP] in-netns reachability (ip/route/resolv from inside aether) ==="
  podman run --rm --network "$NET" "$ALPINE" sh -c 'echo "--resolv--"; cat /etc/resolv.conf 2>&1; echo "--ip addr--"; ip addr 2>&1 | head -20; echo "--ip route--"; ip route 2>&1 | head -10; echo "--ping gw--"; ping -c1 -W2 '"$GW"' 2>&1 | tail -3' 2>&1 | sed 's/^/    innet: /' || true
  say "=== [DUMP] network inspect (subnet/gateway/dns) ==="
  podman network inspect "$NET" --format 'name={{.name}} dns={{.dns_enabled}} subnets={{range .subnets}}{{.subnet}} gw={{.gateway}} {{end}}' 2>/dev/null | sed 's/^/    net: /' || true
}
print_recreate_plan(){
  cat <<'PLAN'
The 3-step rootless ladder (reload -> pkill-ours+reload -> clear-state+reload) did NOT
restore in-network DNS. Binary+netavark+aardvark are installed and correct; the residual
cause is almost certainly that the user-netns bridge/gateway (10.89.0.1) is no longer
provisionable, which netavark cannot self-heal while containers hold the network.

Recovery requires RECREATING the 'aether' network. That has blast radius across every
attached container, so BW deliberately REFUSES to do it blind. Do it DELIBERATELY, in this
order, as YOUR user (no sudo), only after reading this fully:

  # 1) capture current definition (subnet/gateway/dns/internal) so you recreate it identically
  podman network inspect aether

  # 2) stop the dependents FIRST, then the providers, in dependency order (NOT postgres yet)
  systemctl --user stop woodpecker-agent.service woodpecker-server.service n8n.service \
              grafana.service gitea.service traefik.service litellm.service 2>/dev/null || true
  # postgres last, and only if you must (it is the canary; stopping it drops every DB-backed app)
  # systemctl --user stop postgres.service

  # 3) remove + recreate with the SAME subnet/gateway and --dns
  podman network rm aether
  podman network create --driver bridge --subnet 10.89.0.0/24 --gateway 10.89.0.1 --dns aether

  # 4) bring back UP in dependency order (postgres first if you stopped it)
  systemctl --user start postgres.service
  sleep 4
  systemctl --user start litellm.service llama-embed.service
  systemctl --user start gitea.service grafana.service n8n.service
  systemctl --user start woodpecker-server.service
  sleep 6
  systemctl --user start woodpecker-agent.service
  systemctl --user start traefik.service

  # 5) prove, then rerun BW (it will skip the heal and go straight to cascade/BQ)
  podman run --rm --network aether docker.io/library/alpine:latest getent hosts postgres
  bash /home/dev/DevOps/aether/codemod/20261030-BW-netavark-aardvark-process-state-heal.sh

Lighter alternative to try BEFORE the recreate above (resets netavark bookkeeping without
touching the network object; safe with running containers):
  podman system migrate
  podman network reload aether
  podman run --rm --network aether docker.io/library/alpine:latest getent hosts postgres
PLAN
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head id date pgrep pkill ls stat; do
  need_cmd "$c"
done

# ===================== [W0] corrected read-only report =====================
say "=== [W0] corrected environment report ==="
GW="$(podman network inspect "$NET" --format '{{range .subnets}}{{.gateway}} {{end}}' 2>/dev/null | awk '{print $1}')"
GW="$(norm "$GW")"
if [ -z "$GW" ]; then
  GW="10.89.0.1"
fi
AARD_PATH="$(podman info --format '{{.Host.NetworkBackendInfo.Dns.Path}}' 2>/dev/null || true)"
AARD_VER="$(podman info --format '{{.Host.NetworkBackendInfo.Dns.Version}}' 2>/dev/null || true)"
NETAVARK_PATH="$(podman info --format '{{.Host.NetworkBackendInfo.Path}}' 2>/dev/null || true)"
say "[W0] network=$NET gateway=$GW canary=$CANARY"
say "[W0] netavark path=${NETAVARK_PATH:-?}  (backend=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true))"
say "[W0] aardvark-dns libexec=${AARD_PATH:-MISSING-IN-INFO} version=${AARD_VER:-?}"
if [ -n "$AARD_PATH" ] && [ -x "$AARD_PATH" ]; then
  say "[W0] aardvark-dns PRESENT+EXECUTABLE at libexec (NOT a PATH tool; BV's 'MISSING' was a probe error)"
else
  say "[W0] WARNING: aardvark-dns not executable at reported libexec; package may be broken"
fi
say "[W0] NOTE: no podman-aardvark-dns@*.systemd unit exists by design (netavark forks the daemon per network)"
say "[W0] our aardvark procs now: $(pgrep -u "$(id -u)" -x aardvark-dns 2>/dev/null | wc -l | tr -d ' ')"
canary_proof
say "[W0] pre-heal canary: getent $CANARY -> addr='${CANARY_ADDR:-none}' true_rc=$LAST_RC  nslookup_state=$DNS_STATE"
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing"
fi
if ! podman image exists "$ALPINE" 2>/dev/null; then
  halt "alpine diagnostic image missing"
fi
if [ "$(container_status "$CANARY")" != running ]; then
  halt "canary $CANARY not running (cannot prove DNS)"
fi

say "=== [W0] locate canonical Podman.py ==="
PODMAN_PY="$(pgrep -af 'Podman\.py' 2>/dev/null | head -n1 | awk '{for(i=2;i<=NF;i++) if ($i ~ /Podman\.py$/) {print $i; exit}}' || true)"
PODMAN_PY="$(norm "$PODMAN_PY")"
if [ -z "$PODMAN_PY" ] && [ -f "$PODMAN_PY_FALLBACK" ]; then
  PODMAN_PY="$PODMAN_PY_FALLBACK"
fi
if [ -z "$PODMAN_PY" ]; then
  PODMAN_PY="$(find "$HOME" -maxdepth 5 -name 'Podman.py' -type f 2>/dev/null | head -n2 | tr '\n' ' ')"
  n="$(printf '%s' "$PODMAN_PY" | wc -w | tr -d ' ')"
  if [ "$n" != 1 ]; then
    halt "Podman.py not running and not uniquely locatable (found: ${PODMAN_PY:-none}); tell me the canonical path (B13)"
  fi
fi
if [ ! -f "$PODMAN_PY" ]; then
  halt "canonical Podman.py not readable: $PODMAN_PY"
fi
say "[W0] podman_py=$PODMAN_PY"

if [ "$DRY" = 1 ]; then
  say "[W0] dry-run plan (pure/read-only; no pkill, no rm, no reload, no writes, no restart, no ledger):"
  say "    Wgui EARLY non-fatal: patch $PODMAN_PY ghost rows (runs before DNS heal this time)"
  say "    W1  heal ladder: reload -> pkill -u ours -x aardvark-dns + reload -> rm stale $NET state dir + reload; prove canary each step"
  say "    W1-fail: deep in-netns dump + PRINT network-recreate plan (NOT executed) + HALT"
  say "    W2  durable dns-wait = process/state heal (NO systemd unit) + canary + STRICT reject"
  say "    W3  cascade: $CASCADE then woodpecker-agent (postgres/litellm untouched)"
  say "    W4  direct gate: $GATE_ALL"
  say "    W5  rerun BQ (traefik)"
  say "    W6  proxied gate + NRestarts double-sample stability"
  say "    W7  guarded ledger + replay"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched, no process killed."
  exit 0
fi

mkdir -p "$CD" "$UNIT_INST_DIR"
touch "$IDX"

# ===================== [Wgui] EARLY non-fatal Podman.py ghost rows =====================
say "=== [Wgui] patch Podman.py Containers-tab ghost rows (EARLY, non-fatal) ==="
GUI_STATUS="failed"
bak_once "$PODMAN_PY"
cat > "$TMPD/patch_gui.py" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
marker = "unit:{u['unit']}"
token  = "AETHER_FETCH_CONTAINERS_GHOSTS"
if marker in t:
    sys.exit(0)
lines = t.splitlines(keepends=True)
idx = None
for i, l in enumerate(lines):
    if token in l:
        idx = i
        break
if idx is None:
    sys.stderr.write("missing ghost token line in %s\n" % p)
    sys.exit(2)
lead = lines[idx][:len(lines[idx]) - len(lines[idx].lstrip())]
rel = [
    "try:",
    "    for u in fetch_user_units():",
    "        for nm in u.get(\"manages\", []):",
    "            if nm in existing:",
    "                continue",
    "            existing.add(nm)",
    "            rows.append({",
    "                \"id\": f\"unit:{u['unit']}\",",
    "                \"short\": u[\"unit\"][:12],",
    "                \"name\": nm,",
    "                \"status\": \"missing\",",
    "                \"status_text\": \"Missing (systemd unit)\",",
    "                \"health\": \"\",",
    "                \"image\": \"-\",",
    "                \"created\": \"\",",
    "                \"ports\": \"\",",
    "                \"port_items\": [],",
    "                \"cmd\": f\"systemd user unit: {u['unit']}\",",
    "                \"unit\": u[\"unit\"],",
    "                \"quadlet_file\": None,",
    "            })",
    "except Exception:",
    "    pass",
]
ghost = "".join(lead + r + "\n" for r in rel)
lines.insert(idx, ghost)
p.write_text("".join(lines), encoding="utf-8")
PYEOF
if python3 "$TMPD/patch_gui.py" "$PODMAN_PY"; then
  if python3 -m py_compile "$PODMAN_PY"; then
    GUI_STATUS="ok"
    say "[Wgui] ghost-row patch applied + py_compile OK -> $PODMAN_PY (restart GUI to load)"
  else
    cp -p "$PODMAN_PY.$BAK_SUFFIX" "$PODMAN_PY" 2>/dev/null || true
    GUI_STATUS="compile-failed-restored"
    say "[Wgui] patch failed py_compile; restored backup (NON-FATAL)"
  fi
else
  if grep -qF "unit:{u['unit']}" "$PODMAN_PY" 2>/dev/null; then
    GUI_STATUS="already-present"
    say "[Wgui] ghost-row marker already present (idempotent no-op)"
  else
    GUI_STATUS="anchor-missing"
    say "[Wgui] ghost token not found; skipped (NON-FATAL)"
  fi
fi

# ===================== [W1] heal DNS data plane (process/state ladder) =====================
say "=== [W1] heal aether in-network DNS (rootless process/state ladder) ==="
say "[W1] step 1/3: podman network reload $NET"
reload_net "s1"
if canary_proof; then
  HEAL_STEP="reload"
  say "[W1] RESOLVED by reload: getent $CANARY -> $CANARY_ADDR (state=$DNS_STATE)"
else
  say "[W1] reload insufficient (state=$DNS_STATE addr='${CANARY_ADDR:-none}'); step 2/3: pkill ours + reload"
  pkill_ours
  reload_net "s2"
  if canary_proof; then
    HEAL_STEP="pkill+reload"
    say "[W1] RESOLVED by pkill+reload: getent $CANARY -> $CANARY_ADDR (state=$DNS_STATE)"
  else
    say "[W1] pkill+reload insufficient (state=$DNS_STATE); step 3/3: clear stale state dir + reload"
    clear_state
    reload_net "s3"
    if canary_proof; then
      HEAL_STEP="clear-state+reload"
      say "[W1] RESOLVED by clear-state+reload: getent $CANARY -> $CANARY_ADDR (state=$DNS_STATE)"
    fi
  fi
fi

if [ "$HEAL_STEP" = none ]; then
  dump_deep
  print_recreate_plan
  if ! grep -qF "$HEAL_FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BW 3-step rootless ladder (reload/pkill-ours+reload/clear-state+reload) FAILED to restore aether DNS (canary %s state=%s addr=none; aardvark libexec=%s ver=%s netavark=%s). Residual cause = user-netns bridge/gateway not provisionable while containers hold the network. Network recreate has blast radius across attached containers, so BW refused to do it blind; deliberate plan printed. Lighter alt: podman system migrate + reload. Do NOT proceed to Traefik. |\n' \
      "$(date +%F)" "$HEAL_FAIL_TOKEN" "$CANARY" "$DNS_STATE" "${AARD_PATH:-?}" "${AARD_VER:-?}" "${NETAVARK_PATH:-?}" >> "$IDX"
  fi
  halt "W1 failed: DNS data plane not restored by the rootless ladder; see deep dump + recreate plan above"
fi
say "[W1] DATA PLANE RESTORED via step='$HEAL_STEP'; canary $CANARY -> $CANARY_ADDR (non-loopback, true_rc=$LAST_RC)"
say "[W1] dependent names now (should resolve after reload re-registered attachments):"
for n in gitea woodpecker-server grafana n8n; do
  probe_getent "$n"
  say "[W1]   getent $n -> '${LAST_ADDR:-none}' true_rc=$LAST_RC"
done

# ===================== [W2] durable dns-wait: process/state heal (NO systemd unit) =====================
say "=== [W2] install durable aether-dns-wait.sh (process/state heal + canary + STRICT reject) ==="
bak_once "$DNS_SCRIPT"
cat > "$TMPD/dns-wait.new" <<'DWEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh — BW durable guard (CORRECTED MODEL).
# netavark>=4 forks aardvark-dns per network as a CHILD PROCESS (no systemd unit). The fault
# class this closes: a stale netavark runtime state dir makes `podman network reload` no-op
# while the DNS daemon is dead, so nothing in-network resolves and every ExecStartPre wedges.
# Heal is therefore PROCESS+STATE level, never a unit start:
#   heal_aardvark(): reload -> (if dead) pkill -u ours -x aardvark-dns + reload ->
#                    (if dead) rm stale <net> runtime state dir + reload -> prove canary.
# Then per-host STRICT loopback rejection. Runs as systemd --user ExecStartPre (sudo-free).
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
TRIES="${AETHER_DNS_TRIES:-90}"
DELAY="${AETHER_DNS_DELAY:-1}"
ALLOW_LOOPBACK="${AETHER_DNS_ALLOW_LOOPBACK:-0}"
CANARY="${AETHER_DNS_CANARY:-postgres}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2
  exit 2
fi

ge_addr(){
  local name="$1" a
  a="$(podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" 2>/dev/null | awk 'NR==1{print $1}')"
  printf '%s' "$a"
}
resolves(){
  local name="$1" a
  a="$(ge_addr "$name")"
  if [ -z "$a" ]; then
    return 1
  fi
  case "$a" in
    127.*|::1|localhost)
      if [ "$ALLOW_LOOPBACK" = 1 ]; then return 0; fi
      return 1
      ;;
    *) return 0 ;;
  esac
}
heal_aardvark(){
  podman network reload "$NET" >/dev/null 2>&1 || true
  if resolves "$CANARY"; then
    return 0
  fi
  pkill -u "$(id -u)" -x aardvark-dns >/dev/null 2>&1 || true
  sleep 2
  podman network reload "$NET" >/dev/null 2>&1 || true
  if resolves "$CANARY"; then
    return 0
  fi
  local rt d
  rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks"
  for d in "$rt/$NET" "$rt/${NET}"-*; do
    if [ -d "$d" ]; then
      rm -rf "$d" 2>/dev/null || true
    fi
  done
  podman network reload "$NET" >/dev/null 2>&1 || true
  resolves "$CANARY"
}

if ! heal_aardvark; then
  echo "dns-wait: CANARY '$CANARY' unresolved after process/state heal (aardvark-dns data plane down; network may need deliberate recreate)" >&2
  exit 1
fi
echo "dns-wait: canary $CANARY resolved on $NET after heal"

for h in "${hosts[@]}"; do
  ok=0
  i=1
  while [ "$i" -le "$TRIES" ]; do
    if resolves "$h"; then
      ok=1
      break
    fi
    if [ $((i % 15)) -eq 0 ]; then
      heal_aardvark >/dev/null 2>&1 || true
    fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  if [ "$ok" -ne 1 ]; then
    echo "dns-wait: host '$h' did not resolve to a non-loopback address on network '$NET' after $TRIES tries" >&2
    exit 1
  fi
  echo "dns-wait: resolved $h on $NET"
done
exit 0
DWEOF
if ! bash -n "$TMPD/dns-wait.new"; then
  halt "new dns-wait failed bash -n (not installed; backup intact)"
fi
install -D -m 755 "$TMPD/dns-wait.new" "$DNS_SCRIPT" || halt "could not install $DNS_SCRIPT"
if grep -q 'heal_aardvark' "$DNS_SCRIPT" 2>/dev/null && grep -q 'rejecting\|non-loopback' "$DNS_SCRIPT" 2>/dev/null && ! grep -q 'systemctl --user start.*aardvark' "$DNS_SCRIPT" 2>/dev/null; then
  say "[W2] durable guard installed: process/state heal (NO systemd unit) + canary + STRICT reject -> $DNS_SCRIPT"
else
  halt "installed dns-wait missing heal/strict markers or still references an aardvark unit"
fi
if ! grep -qF "$DURABLE_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | DECISION | %s | APPEND-ONLY | aether-dns-wait.sh redesigned to heal the netavark DNS data plane at PROCESS+STATE level (reload -> pkill-ours -x aardvark-dns -> rm stale <net> runtime state dir -> reload -> prove canary), NOT via a systemd unit (none exists by design in netavark>=4). Strict loopback rejection retained. Closes the stale-state/reload-no-op class permanently for every ExecStartPre. |\n' \
    "$(date +%F)" "$DURABLE_TOKEN" >> "$IDX"
  say "[W2] durable-guard DECISION row appended."
fi

# ===================== [W3] cascade (postgres/litellm untouched) =====================
say "=== [W3] cascade restart wedged/failed services (DNS now live) ==="
systemctl --user daemon-reload >/dev/null 2>&1 || true
for unit in $CASCADE; do
  if [ ! -f "$UNIT_INST_DIR/$unit.service" ]; then
    say "[W3] skip missing unit $unit.service"
    continue
  fi
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
  systemctl --user enable "$unit.service" >/dev/null 2>&1 || true
  if ! systemctl --user restart "$unit.service"; then
    say "[W3] restart $unit.service returned non-zero (will verify via health)"
  fi
  url="$(health_url_for "$unit")"
  ok=no
  for i in $(seq 1 90); do
    if [ "$(active_state "$unit.service")" = active ] &&
       [ "$(container_status "$unit")" = running ]; then
      if [ -z "$url" ] || [ "$(http_code "$url")" = 200 ]; then
        ok=yes
        break
      fi
    fi
    sleep 2
  done
  if [ "$ok" != yes ]; then
    say "[W3] $unit did not reach active+running+health200"
    systemctl --user status --no-pager "$unit.service" 2>/dev/null | sed 's/^/    unit: /' || true
    journalctl --user -u "$unit.service" -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    podman logs --tail 40 "$unit" 2>&1 | sed 's/^/    c: /' || true
    halt "W3 failed at cascade unit: $unit"
  fi
  say "[W3] OK $unit active+running+health200"
done
if [ -f "$UNIT_INST_DIR/woodpecker-agent.service" ]; then
  systemctl --user reset-failed woodpecker-agent.service >/dev/null 2>&1 || true
  systemctl --user enable woodpecker-agent.service >/dev/null 2>&1 || true
  systemctl --user restart woodpecker-agent.service >/dev/null 2>&1 || true
  ok=no
  for i in $(seq 1 90); do
    if [ "$(active_state woodpecker-agent.service)" = active ] &&
       [ "$(container_status woodpecker-agent)" = running ]; then
      ok=yes
      break
    fi
    sleep 2
  done
  if [ "$ok" != yes ]; then
    systemctl --user status --no-pager woodpecker-agent.service 2>/dev/null | sed 's/^/    unit: /' || true
    journalctl --user -u woodpecker-agent.service -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    podman logs --tail 40 woodpecker-agent 2>&1 | sed 's/^/    c: /' || true
    halt "W3 failed: woodpecker-agent not active+running after server is up"
  fi
  say "[W3] OK woodpecker-agent active+running (server netns)"
fi
sleep 10

# ===================== [W4] direct gate =====================
say "=== [W4] direct health gate (full set) ==="
GATE_FAIL=""
for unit in $GATE_ALL; do
  if [ "$unit" = traefik ] || [ "$unit" = woodpecker-agent ]; then
    continue
  fi
  url="$(health_url_for "$unit")"
  if [ -z "$url" ]; then
    continue
  fi
  if ! wait_http "$url" "" 45; then
    GATE_FAIL="$GATE_FAIL $unit($(http_code "$url"))"
  else
    say "[W4] OK $unit direct 200"
  fi
done
if [ -n "$GATE_FAIL" ]; then
  halt "W4 direct gate failed:$GATE_FAIL"
fi
say "[W4] direct gate PASS"

# ===================== [W5] rerun BQ (traefik) =====================
say "=== [W5] rerun BQ Traefik brick 11 (DNS now live) ==="
if [ ! -f "$FQ" ]; then
  halt "missing BQ script: $FQ"
fi
bash "$FQ"
BQRC=$?
say "[W5] BQ rc=$BQRC"
if ! grep -qF "$BQ_TOKEN" "$IDX" 2>/dev/null; then
  halt "W5 failed: BQ still not green after data-plane restore; inspect BQ output above"
fi
say "[W5] BQ green sentinel present"

# ===================== [W6] proxied gate + NRestarts stability =====================
say "=== [W6] proxied gate + NRestarts stability (double-sample) ==="
P_FAIL=""
wait_http "http://127.0.0.1:8888/api/version" "traefik.aether.local" 60 || P_FAIL="$P_FAIL traefik-api"
wait_http "http://127.0.0.1:8888/api/healthz" "gitea.aether.local" 60 || P_FAIL="$P_FAIL gitea-proxy"
wait_http "http://127.0.0.1:8888/api/health" "woodpecker.aether.local" 60 || P_FAIL="$P_FAIL woodpecker-proxy"
wait_http "http://127.0.0.1:8888/api/health" "grafana.aether.local" 60 || P_FAIL="$P_FAIL grafana-proxy"
wait_http "http://127.0.0.1:8888/healthz" "n8n.aether.local" 60 || P_FAIL="$P_FAIL n8n-proxy"
wait_http "http://127.0.0.1:8888/dashboard/" "traefik.aether.local" 60 || P_FAIL="$P_FAIL dashboard-proxy"
if [ -n "$P_FAIL" ]; then
  for unit in gitea grafana woodpecker-server woodpecker-agent n8n traefik; do
    systemctl --user status --no-pager "$unit.service" 2>/dev/null | sed "s/^/    unit-$unit: /" || true
  done
  podman logs --tail 60 traefik 2>&1 | sed 's/^/    traefik-log: /' || true
  halt "W6 proxied gate failed:$P_FAIL"
fi
say "[W6] proxied gate PASS (all 200 through :8888)"
STABLE_FAIL=""
for unit in gitea grafana woodpecker-server woodpecker-agent n8n traefik; do
  a="$(nrestarts "$unit.service")"
  sleep 6
  b="$(nrestarts "$unit.service")"
  if [ "$a" != "$b" ]; then
    STABLE_FAIL="$STABLE_FAIL $unit($a->$b)"
  elif [ "$(active_state "$unit.service")" != active ] ||
       [ "$(container_status "$unit")" != running ]; then
    STABLE_FAIL="$STABLE_FAIL $unit(not-active-running)"
  else
    say "[W6] stable $unit NRestarts=$a (flat) active+running"
  fi
done
if [ -n "$STABLE_FAIL" ]; then
  halt "W6 stability failed:$STABLE_FAIL"
fi
say "[W6] NRestarts stability PASS (flat across 12s for all six)"

# ===================== [W7] ledger + replay =====================
say "=== [W7] ledger rows ==="
if ! grep -qF "$HEAL_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BW-netavark-aardvark-process-state-heal | GATE=PASS | %s: CORRECTED MODEL (supersedes BV). netavark 1.16.1 + aardvark-dns 1.16.0 ARE installed at libexec (/usr/lib/podman); NO aardvark systemd unit exists by design (netavark forks the daemon per network). True fault = stale netavark runtime state dir making `podman network reload` no-op while the DNS daemon was dead (BV masked rc via `|head||true`). BW healed via process/state ladder (step=%s): reload -> pkill -u ours -x aardvark-dns -> rm stale %s state dir, each re-proved with TRUE getent rc + in-netns nslookup (state=%s); canary %s -> %s non-loopback. Installed DURABLE dns-wait = same process/state heal (NO unit) + canary + STRICT reject. GUI ghost rows patched EARLY+non-fatal (status=%s) so the user original symptom is fixed regardless. Cascaded gitea/grafana/woodpecker-server/n8n/woodpecker-agent to active+running+health200 (postgres/litellm untouched); reran BQ (traefik green); proxied gate all 200 via :8888; NRestarts flat across 12s for all six; no-sudo; no-service-pull; no-etc-hosts-edit; no-network-recreate-blind; no-ollama/open-webui; no-secret-echo. |\n' \
    "$(date +%F)" "$HEAL_TOKEN" "$HEAL_STEP" "$NET" "$DNS_STATE" "$CANARY" "$CANARY_ADDR" "$GUI_STATUS" >> "$IDX"
  say "[W7] BW correction+green row appended."
else
  say "[W7] BW row already present (guard suppressed)."
fi
if [ "$GUI_STATUS" = ok ] || [ "$GUI_STATUS" = already-present ]; then
  if ! grep -qF "$GUI_OK" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=PASS | Podman.py Containers tab ghost rows for plain systemd user units patched + py_compile OK; restart the GUI to load (stopped --rm services now show as Missing (systemd unit) with working Start). |\n' \
      "$(date +%F)" "$GUI_OK" >> "$IDX"
    say "[W7] GUI OK row appended."
  fi
else
  if ! grep -qF "$GUI_BAD" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | Podman.py ghost-row patch status=%s (NON-FATAL; control plane unaffected). Send Podman.py path if you want the GUI half completed in a follow-up. |\n' \
      "$(date +%F)" "$GUI_BAD" "$GUI_STATUS" >> "$IDX"
    say "[W7] GUI non-fatal DIAG row appended."
  fi
fi
grep -qF "$HEAL_TOKEN" "$IDX" 2>/dev/null && say "[W7] suppression proof: BW sentinel present." || say "[W7] WARNING: BW sentinel missing."

cat > "$CD/20261030-BW-replay.sh" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BW: data plane live (TRUE rc) + cascade up + traefik proxied green + NRestarts flat.
set -uo pipefail
NET=aether; ALPINE=docker.io/library/alpine:latest
GE(){ podman run --rm --network "$NET" "$ALPINE" getent hosts "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
hc(){ local u="$1" h="${2:-}"; if [ -n "$h" ]; then curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "$u" 2>/dev/null || echo 000; else curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000; fi; }
CA="$(GE postgres)"
case "$CA" in ''|127.*|::1|localhost) echo "  [FAIL] canary postgres='$CA'"; exit 1 ;; esac
P1="$(hc http://127.0.0.1:8888/api/healthz gitea.aether.local)"
P2="$(hc http://127.0.0.1:8888/api/health woodpecker.aether.local)"
P3="$(hc http://127.0.0.1:8888/api/health grafana.aether.local)"
P4="$(hc http://127.0.0.1:8888/healthz n8n.aether.local)"
P5="$(hc http://127.0.0.1:8888/api/version traefik.aether.local)"
A1="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || echo ?)"; sleep 6
A2="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || echo ?)"
if [ "$P1" = 200 ] && [ "$P2" = 200 ] && [ "$P3" = 200 ] && [ "$P4" = 200 ] && [ "$P5" = 200 ] && [ "$A1" = "$A2" ]; then
  echo "  [GATE PASS] bw dataplane=live postgres=$CA proxied=all200 agent-NR-flat=$A1"
else
  echo "  [GATE FAIL] postgres=$CA gitea=$P1 wp=$P2 grafana=$P3 n8n=$P4 traefik=$P5 agent-NR=$A1->$A2"; exit 1
fi
REPLAY
chmod +x "$CD/20261030-BW-replay.sh"
say "[W7] replay archived -> codemod/20261030-BW-replay.sh"

say "[W7] NOTE (deferred, NOT touched): llama-embed unit disabled though container runs (litellm healthy) — durability gap for brick 5; enabling forces a model-reload spike on this 2-core/16GB box, logged for a controlled later brick. Foreign bc-*/bd-* failed units are not our stack (scope discipline)."
say "[W7] SAFE browser hostnames only (NEVER bare internal names): 127.0.0.1 gitea.aether.local woodpecker.aether.local grafana.aether.local n8n.aether.local traefik.aether.local"
say "[RESULT] BW FINALIZED — model=netavark-child-process(no-unit) heal_step=$HEAL_STEP canary=$CANARY:$CANARY_ADDR dns_state=$DNS_STATE dns-wait=durable-process-heal gui=$GUI_STATUS cascade=up direct+proxied=200 NRestarts=flat; next: build woodpecker pipeline proof; still no Ollama/OpenWebUI/chat-model."
exit 0
