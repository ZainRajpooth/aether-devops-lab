#!/usr/bin/env bash
# 20261030-BY — supersedes BW. Fixes the two BW crashes (set -u local split; false
# "package broken" from a bad Go template), adds DECISIVE read-only aardvark
# observability (live proc cmdline + netavark registration dir) BEFORE healing, bounds
# every probe with timeout, then runs the proven process/state ladder + durable guard +
# cascade + BQ + early GUI ghost + guarded ledger. Mutates nothing until W1, and W1 only
# touches OUR aardvark procs / OUR stale runtime state dir (never postgres/litellm, never
# the network object). No sudo, no pull, no secret echo. --check pure.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( );
#             no backticks; every `local` on its own line (never reference a same-stmt local).
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
GW="10.89.0.1"

UNIT_INST_DIR="$HOME/.config/systemd/user"
PODMAN_PY_FALLBACK="/home/dev/DevOps/apps/podman/Podman.py"

CASCADE="gitea grafana woodpecker-server n8n"
GATE_ALL="postgres gitea grafana n8n litellm woodpecker-server woodpecker-agent traefik"

TOKEN="by-aardvark-observability-ladder-heal-v1"
FAIL_TOKEN="by-aardvark-ladder-failed-escalate-v1"
DURABLE_TOKEN="by-durable-dns-wait-timeout-bounded-heal-v1"
GUI_OK="by-gui-ghost-rows-user-units-v1"
GUI_BAD="by-gui-ghost-rows-failed-v1"
BQ_TOKEN="bq-traefik-brick11-green-v1"

BAK_SUFFIX="pre-BY.bak"
HEAL_STEP="none"
GUI_STATUS="not-attempted"
DNS_STATE="unknown"
CANARY_ADDR=""
P_ADDR=""
P_RC=0
NS_RC=0
NS_BLOB=""
AARD_PATH=""
AARD_SRC="none"
AARD_VER=""
PODMAN_PY=""

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
  local url="$1"
  local host="${2:-}"
  local code
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
  local url="$1"
  local host="${2:-}"
  local tries="${3:-60}"
  local i
  local code
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
run_probe(){
  # bounded podman run; sets PROBE_RC / PROBE_OUT / PROBE_ERR
  local body="$1"
  local tag="$2"
  local o="$TMPD/p-$tag.out"
  local e="$TMPD/p-$tag.err"
  local rc=0
  : > "$o"; : > "$e"
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 podman run --rm --network "$NET" "$ALPINE" sh -c "$body" >"$o" 2>"$e" || rc=$?
  else
    podman run --rm --network "$NET" "$ALPINE" sh -c "$body" >"$o" 2>"$e" || rc=$?
  fi
  PROBE_RC="$rc"
  PROBE_OUT="$(cat "$o" 2>/dev/null || true)"
  PROBE_ERR="$(cat "$e" 2>/dev/null || true)"
}
probe_getent(){
  local name="$1"
  run_probe "getent hosts '$name'" "ge-$name"
  P_RC="$PROBE_RC"
  P_ADDR="$(printf '%s' "$PROBE_OUT" | awk 'NR==1{print $1}')"
  P_ADDR="$(norm "$P_ADDR")"
}
probe_ns(){
  local name="$1"
  run_probe "nslookup '$name' '$GW'" "ns-$name"
  NS_RC="$PROBE_RC"
  NS_BLOB="$(printf '%s %s' "$PROBE_OUT" "$PROBE_ERR")"
}
classify_dns(){
  if [ -n "$P_ADDR" ] && ! is_loopback "$P_ADDR"; then printf 'alive-resolved'; return; fi
  if printf '%s' "$NS_BLOB" | grep -Eqi "can't find|nxdomain|non-existent|authoritative|servfail"; then printf 'alive-nx'; return; fi
  if printf '%s' "$NS_BLOB" | grep -Eqi "no server|connection refused|timed out|could not connect|server not found|network is unreachable"; then printf 'dead'; return; fi
  if [ "${NS_RC:-1}" = 0 ]; then printf 'alive-odd'; return; fi
  printf 'unknown'
}
canary_proof(){
  probe_getent "$CANARY"
  probe_ns "$CANARY"
  DNS_STATE="$(classify_dns)"
  if [ -n "$P_ADDR" ] && ! is_loopback "$P_ADDR"; then
    CANARY_ADDR="$P_ADDR"
    return 0
  fi
  CANARY_ADDR=""
  return 1
}
detect_aardvark(){
  AARD_PATH=""
  AARD_SRC="none"
  local cand
  for cand in /usr/lib/podman/aardvark-dns /usr/libexec/podman/aardvark-dns /usr/bin/aardvark-dns; do
    if [ -x "$cand" ]; then
      AARD_PATH="$cand"
      AARD_SRC="known-libexec"
      break
    fi
  done
  if [ -z "$AARD_PATH" ]; then
    AARD_PATH="$(podman info 2>/dev/null | awk '/[[:space:]]dns:/{f=1;next} f&&/[[:space:]]path:/{print $2;exit}')"
    AARD_PATH="$(norm "$AARD_PATH")"
    if [ -n "$AARD_PATH" ] && [ -x "$AARD_PATH" ]; then
      AARD_SRC="podman-info"
    fi
  fi
  if [ -n "$AARD_PATH" ]; then
    AARD_VER="$(norm "$("$AARD_PATH" --version 2>/dev/null | head -n1 || true)")"
  else
    AARD_VER=""
  fi
}
dump_aard_procs(){
  local pids pid cmd
  pids="$(pgrep -u "$(id -u)" -x aardvark-dns 2>/dev/null | tr '\n' ' ')"
  pids="$(norm "$pids")"
  say "  aardvark pids (ours): ${pids:-none}"
  for pid in $pids; do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    say "    pid=$pid cmdline=${cmd:-?}"
  done
}
dump_reg_dir(){
  local rt
  rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks"
  say "  netavark runtime networks dir: $rt"
  ls -la "$rt" 2>/dev/null | sed 's/^/    ls: /' || say "    ls: (n/a)"
  say "  aether registration dir ($rt/$NET):"
  ls -la "$rt/$NET" 2>/dev/null | sed 's/^/    reg: /' || say "    reg: (missing/empty)"
}
reload_net(){
  local tag="$1"
  local o="$TMPD/reload-$tag.out"
  local rc=0
  : > "$o"
  podman network reload "$NET" >"$o" 2>&1 || rc=$?
  say "  reload($tag) rc=$rc out=$(head -c 200 "$o" 2>/dev/null | tr '\n' ' ')"
}
pkill_ours(){
  local n
  n="$(pgrep -u "$(id -u)" -x aardvark-dns 2>/dev/null | wc -l | tr -d ' ')"
  say "  aardvark procs (ours) before pkill: ${n:-0}"
  pkill -u "$(id -u)" -x aardvark-dns >/dev/null 2>&1 || true
  sleep 2
}
clear_state(){
  local rt d removed
  removed=0
  rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks"
  for d in "$rt/$NET" "$rt/${NET}"-*; do
    if [ -d "$d" ]; then
      rm -rf "$d" 2>/dev/null || true
      removed=$((removed + 1))
      say "  removed stale state dir: $d"
    fi
  done
  if [ "$removed" = 0 ]; then
    say "  no aether state dir to clear (netavark may use another path; reload still attempted)"
  fi
}
dump_deep(){
  say "=== [DUMP] podman info network/dns ==="
  podman info 2>/dev/null | grep -Ei 'aardvark|netavark|dns|network.?backend|path|version|package' | sed 's/^/    info: /' || true
  say "=== [DUMP] aardvark procs + cmdline ==="
  dump_aard_procs
  say "=== [DUMP] netavark registration dir ==="
  dump_reg_dir
  say "=== [DUMP] in-netns reachability (resolv/ip/route/ping gw) ==="
  run_probe "echo '--resolv--'; cat /etc/resolv.conf 2>&1; echo '--ip addr--'; ip addr 2>&1 | head -20; echo '--ip route--'; ip route 2>&1 | head -10; echo '--ping gw--'; ping -c1 -W2 '$GW' 2>&1 | tail -3" "deep"
  printf '%s\n' "$PROBE_OUT" | sed 's/^/    innet: /' || true
  printf '%s\n' "$PROBE_ERR" | sed 's/^/    innet-err: /' || true
  say "  deep probe rc=$PROBE_RC"
}
print_recreate_plan(){
  cat <<'PLAN'
The 3-step rootless ladder (reload -> pkill-ours+reload -> clear-state+reload) did NOT
restore in-network DNS. The DUMP above now tells us WHICH sub-case:
  - cmdline dir != $RT/aether  -> orphan daemon serving a stale/other network (pkill should
    have fixed it; if not, netavark is not respawning -> likely needs the recreate below).
  - cmdline dir == aether but reg dir empty -> registrations lost; reload should re-push;
    if not, the bridge/gateway IP is gone in the netns -> recreate below.
  - no proc at all -> daemon not spawning -> recreate below.
Recreating 'aether' has blast radius across every attached container, so BY REFUSES to do
it blind. Do it DELIBERATELY, as YOUR user (no sudo), only after reading fully:

  podman network inspect aether                      # capture subnet/gateway/dns first
  systemctl --user stop woodpecker-agent.service woodpecker-server.service n8n.service \
              grafana.service gitea.service traefik.service litellm.service 2>/dev/null || true
  # postgres LAST, only if needed:
  # systemctl --user stop postgres.service
  podman network rm aether
  podman network create --driver bridge --subnet 10.89.0.0/24 --gateway 10.89.0.1 --dns aether
  systemctl --user start postgres.service            # if you stopped it
  sleep 4
  systemctl --user start litellm.service llama-embed.service
  systemctl --user start gitea.service grafana.service n8n.service
  systemctl --user start woodpecker-server.service
  sleep 6
  systemctl --user start woodpecker-agent.service
  systemctl --user start traefik.service
  podman run --rm --network aether docker.io/library/alpine:latest getent hosts postgres
  bash /home/dev/DevOps/aether/codemod/20261030-BY-aardvark-observability-ladder-heal.sh

Lighter alt to try FIRST (resets netavark bookkeeping without touching the network object;
safe with running containers):
  podman system migrate
  podman network reload aether
  podman run --rm --network aether docker.io/library/alpine:latest getent hosts postgres
PLAN
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head id date pgrep pkill ls stat timeout; do
  need_cmd "$c"
done

# ===================== [Y0] corrected read-only report + DECISIVE observability =====================
say "=== [Y0] corrected environment report ==="
GW="$(podman network inspect "$NET" --format '{{range .subnets}}{{.gateway}} {{end}}' 2>/dev/null | awk '{print $1}')"
GW="$(norm "$GW")"
if [ -z "$GW" ]; then GW="10.89.0.1"; fi
detect_aardvark
say "[Y0] network=$NET gateway=$GW canary=$CANARY"
say "[Y0] netavark backend=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true) path=$(podman info --format '{{.Host.NetworkBackendInfo.Path}}' 2>/dev/null || true)"
say "[Y0] aardvark-dns=${AARD_PATH:-NOT-FOUND} src=$AARD_SRC ver=${AARD_VER:-?}"
if [ -n "$AARD_PATH" ]; then
  say "[Y0] aardvark-dns PRESENT+EXECUTABLE (BW's 'package broken' was a bad-template false alarm)"
else
  say "[Y0] WARNING: aardvark-dns not found at known libexec nor via podman info; package may truly be broken"
fi
say "[Y0] no podman-aardvark-dns@*.systemd unit exists by design (netavark forks the daemon per network)"
say "[Y0] --- DECISIVE: what is the live aardvark actually serving? ---"
dump_aard_procs
say "[Y0] --- DECISIVE: what did netavark register for aether? ---"
dump_reg_dir
canary_proof
say "[Y0] pre-heal canary: getent $CANARY -> addr='${CANARY_ADDR:-none}' true_rc=$P_RC  nslookup_state=$DNS_STATE"
if ! podman network exists "$NET" 2>/dev/null; then halt "network $NET missing"; fi
if ! podman image exists "$ALPINE" 2>/dev/null; then halt "alpine diagnostic image missing"; fi
if [ "$(container_status "$CANARY")" != running ]; then halt "canary $CANARY not running"; fi

say "=== [Y0] locate canonical Podman.py ==="
PODMAN_PY="$(pgrep -af 'Podman\.py' 2>/dev/null | head -n1 | awk '{for(i=2;i<=NF;i++) if ($i ~ /Podman\.py$/) {print $i; exit}}' || true)"
PODMAN_PY="$(norm "$PODMAN_PY")"
if [ -z "$PODMAN_PY" ] && [ -f "$PODMAN_PY_FALLBACK" ]; then PODMAN_PY="$PODMAN_PY_FALLBACK"; fi
if [ -z "$PODMAN_PY" ]; then
  PODMAN_PY="$(find "$HOME" -maxdepth 5 -name 'Podman.py' -type f 2>/dev/null | head -n2 | tr '\n' ' ')"
  n="$(printf '%s' "$PODMAN_PY" | wc -w | tr -d ' ')"
  if [ "$n" != 1 ]; then halt "Podman.py not running and not uniquely locatable (found: ${PODMAN_PY:-none}); tell me the canonical path"; fi
fi
if [ ! -f "$PODMAN_PY" ]; then halt "canonical Podman.py not readable: $PODMAN_PY"; fi
say "[Y0] podman_py=$PODMAN_PY"

if [ "$DRY" = 1 ]; then
  say "[Y0] dry-run plan (pure/read-only; no pkill, no rm, no reload, no writes, no restart, no ledger):"
  say "    Ygui EARLY non-fatal: patch $PODMAN_PY ghost rows"
  say "    Y1  ladder: reload -> pkill -u ours -x aardvark-dns + reload -> rm stale $NET state dir + reload; prove canary each step"
  say "    Y1-fail: deep dump (cmdline+reg+in-netns) + PRINT recreate plan (NOT executed) + HALT"
  say "    Y2  durable dns-wait = timeout-bounded process/state heal + canary + STRICT reject"
  say "    Y3  cascade: $CASCADE then woodpecker-agent (postgres/litellm untouched)"
  say "    Y4  direct gate: $GATE_ALL"
  say "    Y5  rerun BQ (traefik)"
  say "    Y6  proxied gate + NRestarts double-sample stability"
  say "    Y7  guarded ledger + replay"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched, no process killed."
  exit 0
fi

mkdir -p "$CD" "$UNIT_INST_DIR"
touch "$IDX"

# ===================== [Ygui] EARLY non-fatal Podman.py ghost rows =====================
say "=== [Ygui] patch Podman.py Containers-tab ghost rows (EARLY, non-fatal) ==="
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
    say "[Ygui] ghost-row patch applied + py_compile OK -> $PODMAN_PY (restart GUI to load)"
  else
    cp -p "$PODMAN_PY.$BAK_SUFFIX" "$PODMAN_PY" 2>/dev/null || true
    GUI_STATUS="compile-failed-restored"
    say "[Ygui] patch failed py_compile; restored backup (NON-FATAL)"
  fi
else
  if grep -qF "unit:{u['unit']}" "$PODMAN_PY" 2>/dev/null; then
    GUI_STATUS="already-present"
    say "[Ygui] ghost-row marker already present (idempotent no-op)"
  else
    GUI_STATUS="anchor-missing"
    say "[Ygui] ghost token not found; skipped (NON-FATAL)"
  fi
fi

# ===================== [Y1] heal DNS data plane (process/state ladder) =====================
say "=== [Y1] heal aether in-network DNS (rootless process/state ladder) ==="
say "[Y1] step 1/3: podman network reload $NET"
reload_net "s1"
if canary_proof; then
  HEAL_STEP="reload"
  say "[Y1] RESOLVED by reload: getent $CANARY -> $CANARY_ADDR (state=$DNS_STATE)"
else
  say "[Y1] reload insufficient (state=$DNS_STATE addr='${CANARY_ADDR:-none}'); step 2/3: pkill ours + reload"
  dump_aard_procs
  pkill_ours
  reload_net "s2"
  say "[Y1] after pkill+reload, aardvark procs:"
  dump_aard_procs
  if canary_proof; then
    HEAL_STEP="pkill+reload"
    say "[Y1] RESOLVED by pkill+reload: getent $CANARY -> $CANARY_ADDR (state=$DNS_STATE)"
  else
    say "[Y1] pkill+reload insufficient (state=$DNS_STATE); step 3/3: clear stale state dir + reload"
    clear_state
    reload_net "s3"
    say "[Y1] after clear-state+reload, aardvark procs:"
    dump_aard_procs
    if canary_proof; then
      HEAL_STEP="clear-state+reload"
      say "[Y1] RESOLVED by clear-state+reload: getent $CANARY -> $CANARY_ADDR (state=$DNS_STATE)"
    fi
  fi
fi

if [ "$HEAL_STEP" = none ]; then
  dump_deep
  print_recreate_plan
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BY 3-step ladder FAILED to restore aether DNS (canary %s state=%s addr=none; aardvark=%s src=%s ver=%s; live-procs+cmdline+reg-dir dumped above). Residual cause isolated by the DUMP to one of: orphan-daemon-wrong-dir / empty-registration / no-spawn / bridge-ip-gone. Network recreate has blast radius; BY refused to do it blind; deliberate plan printed. Lighter alt: podman system migrate + reload. Do NOT proceed to Traefik. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" "$CANARY" "$DNS_STATE" "${AARD_PATH:-?}" "$AARD_SRC" "${AARD_VER:-?}" >> "$IDX"
  fi
  halt "Y1 failed: DNS data plane not restored by the ladder; see DUMP + recreate plan above"
fi
say "[Y1] DATA PLANE RESTORED via step='$HEAL_STEP'; canary $CANARY -> $CANARY_ADDR (non-loopback, true_rc=$P_RC)"
say "[Y1] aardvark procs after heal:"
dump_aard_procs
say "[Y1] dependent names (resolve after their containers re-attach in Y3):"
for n in gitea woodpecker-server grafana n8n; do
  probe_getent "$n"
  say "[Y1]   getent $n -> '${P_ADDR:-none}' true_rc=$P_RC"
done

# ===================== [Y2] durable dns-wait: timeout-bounded process/state heal =====================
say "=== [Y2] install durable aether-dns-wait.sh (timeout-bounded heal + canary + STRICT reject) ==="
bak_once "$DNS_SCRIPT"
cat > "$TMPD/dns-wait.new" <<'DWEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh — BY durable guard (timeout-bounded; closes the wedge at the source).
# netavark>=4 forks aardvark-dns per network as a CHILD PROCESS (no systemd unit). Fault
# class: stale netavark runtime state / orphan-daemon-wrong-dir makes `network reload` no-op
# while the DNS daemon does not answer, so nothing in-network resolves and every ExecStartPre
# wedges (and, unbounded, can hang a unit forever). Heal is PROCESS+STATE level and EVERY
# probe is `timeout`-bounded so this script can never hang the unit:
#   heal_aardvark(): reload -> (if dead) pkill -u ours -x aardvark-dns + reload ->
#                    (if dead) rm stale <net> runtime state dir + reload -> prove canary.
# Then per-host STRICT loopback rejection. Runs as systemd --user ExecStartPre (sudo-free).
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
TRIES="${AETHER_DNS_TRIES:-90}"
DELAY="${AETHER_DNS_DELAY:-1}"
PROBE_TIMEOUT="${AETHER_DNS_PROBE_TIMEOUT:-25}"
ALLOW_LOOPBACK="${AETHER_DNS_ALLOW_LOOPBACK:-0}"
CANARY="${AETHER_DNS_CANARY:-postgres}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2
  exit 2
fi
_pt(){
  if command -v timeout >/dev/null 2>&1; then
    timeout "$PROBE_TIMEOUT" "$@"
  else
    "$@"
  fi
}
ge_addr(){
  local name="$1"
  local a
  a="$(_pt podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" 2>/dev/null | awk 'NR==1{print $1}')"
  printf '%s' "$a"
}
resolves(){
  local name="$1"
  local a
  a="$(ge_addr "$name")"
  if [ -z "$a" ]; then return 1; fi
  case "$a" in
    127.*|::1|localhost)
      if [ "$ALLOW_LOOPBACK" = 1 ]; then return 0; fi
      return 1
      ;;
    *) return 0 ;;
  esac
}
heal_aardvark(){
  _pt podman network reload "$NET" >/dev/null 2>&1 || true
  if resolves "$CANARY"; then return 0; fi
  pkill -u "$(id -u)" -x aardvark-dns >/dev/null 2>&1 || true
  sleep 2
  _pt podman network reload "$NET" >/dev/null 2>&1 || true
  if resolves "$CANARY"; then return 0; fi
  local rt
  local d
  rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks"
  for d in "$rt/$NET" "$rt/${NET}"-*; do
    if [ -d "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
  _pt podman network reload "$NET" >/dev/null 2>&1 || true
  resolves "$CANARY"
}
if ! heal_aardvark; then
  echo "dns-wait: CANARY '$CANARY' unresolved after timeout-bounded process/state heal" >&2
  exit 1
fi
echo "dns-wait: canary $CANARY resolved on $NET after heal"
for h in "${hosts[@]}"; do
  ok=0
  i=1
  while [ "$i" -le "$TRIES" ]; do
    if resolves "$h"; then ok=1; break; fi
    if [ $((i % 15)) -eq 0 ]; then heal_aardvark >/dev/null 2>&1 || true; fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  if [ "$ok" -ne 1 ]; then
    echo "dns-wait: host '$h' did not resolve non-loopback on '$NET' after $TRIES tries" >&2
    exit 1
  fi
  echo "dns-wait: resolved $h on $NET"
done
exit 0
DWEOF
if ! bash -n "$TMPD/dns-wait.new"; then halt "new dns-wait failed bash -n (not installed; backup intact)"; fi
install -D -m 755 "$TMPD/dns-wait.new" "$DNS_SCRIPT" || halt "could not install $DNS_SCRIPT"
if grep -q 'heal_aardvark' "$DNS_SCRIPT" 2>/dev/null && grep -q 'PROBE_TIMEOUT' "$DNS_SCRIPT" 2>/dev/null && ! grep -q 'systemctl --user start.*aardvark' "$DNS_SCRIPT" 2>/dev/null; then
  say "[Y2] durable guard installed: timeout-bounded process/state heal (NO unit) + canary + STRICT reject -> $DNS_SCRIPT"
else
  halt "installed dns-wait missing heal/timeout markers or still references an aardvark unit"
fi
if ! grep -qF "$DURABLE_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | DECISION | %s | APPEND-ONLY | aether-dns-wait.sh redesigned: heal the netavark DNS data plane at PROCESS+STATE level (reload -> pkill-ours -x aardvark-dns -> rm stale <net> runtime state dir -> reload -> prove canary), NO systemd unit (none exists by design in netavark>=4), and EVERY probe wrapped in `timeout` so an ExecStartPre can NEVER hang a unit (the wedge class is closed at the source, not just papered over). Strict loopback rejection retained. |\n' \
    "$(date +%F)" "$DURABLE_TOKEN" >> "$IDX"
  say "[Y2] durable-guard DECISION row appended."
fi

# ===================== [Y3] cascade (postgres/litellm untouched) =====================
say "=== [Y3] cascade restart wedged/failed services (DNS now live) ==="
systemctl --user daemon-reload >/dev/null 2>&1 || true
for unit in $CASCADE; do
  if [ ! -f "$UNIT_INST_DIR/$unit.service" ]; then say "[Y3] skip missing unit $unit.service"; continue; fi
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
  systemctl --user enable "$unit.service" >/dev/null 2>&1 || true
  if ! systemctl --user restart "$unit.service"; then say "[Y3] restart $unit.service returned non-zero (verify via health)"; fi
  url="$(health_url_for "$unit")"
  ok=no
  for i in $(seq 1 90); do
    if [ "$(active_state "$unit.service")" = active ] && [ "$(container_status "$unit")" = running ]; then
      if [ -z "$url" ] || [ "$(http_code "$url")" = 200 ]; then ok=yes; break; fi
    fi
    sleep 2
  done
  if [ "$ok" != yes ]; then
    say "[Y3] $unit did not reach active+running+health200"
    systemctl --user status --no-pager "$unit.service" 2>/dev/null | sed 's/^/    unit: /' || true
    journalctl --user -u "$unit.service" -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    podman logs --tail 40 "$unit" 2>&1 | sed 's/^/    c: /' || true
    halt "Y3 failed at cascade unit: $unit"
  fi
  say "[Y3] OK $unit active+running+health200"
done
if [ -f "$UNIT_INST_DIR/woodpecker-agent.service" ]; then
  systemctl --user reset-failed woodpecker-agent.service >/dev/null 2>&1 || true
  systemctl --user enable woodpecker-agent.service >/dev/null 2>&1 || true
  systemctl --user restart woodpecker-agent.service >/dev/null 2>&1 || true
  ok=no
  for i in $(seq 1 90); do
    if [ "$(active_state woodpecker-agent.service)" = active ] && [ "$(container_status woodpecker-agent)" = running ]; then ok=yes; break; fi
    sleep 2
  done
  if [ "$ok" != yes ]; then
    systemctl --user status --no-pager woodpecker-agent.service 2>/dev/null | sed 's/^/    unit: /' || true
    journalctl --user -u woodpecker-agent.service -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    podman logs --tail 40 woodpecker-agent 2>&1 | sed 's/^/    c: /' || true
    halt "Y3 failed: woodpecker-agent not active+running after server is up"
  fi
  say "[Y3] OK woodpecker-agent active+running (server netns)"
fi
sleep 10

# ===================== [Y4] direct gate =====================
say "=== [Y4] direct health gate (full set) ==="
GATE_FAIL=""
for unit in $GATE_ALL; do
  if [ "$unit" = traefik ] || [ "$unit" = woodpecker-agent ]; then continue; fi
  url="$(health_url_for "$unit")"
  if [ -z "$url" ]; then continue; fi
  if ! wait_http "$url" "" 45; then GATE_FAIL="$GATE_FAIL $unit($(http_code "$url"))"; else say "[Y4] OK $unit direct 200"; fi
done
if [ -n "$GATE_FAIL" ]; then halt "Y4 direct gate failed:$GATE_FAIL"; fi
say "[Y4] direct gate PASS"

# ===================== [Y5] rerun BQ (traefik) =====================
say "=== [Y5] rerun BQ Traefik brick 11 (DNS now live) ==="
if [ ! -f "$FQ" ]; then halt "missing BQ script: $FQ"; fi
bash "$FQ"
BQRC=$?
say "[Y5] BQ rc=$BQRC"
if ! grep -qF "$BQ_TOKEN" "$IDX" 2>/dev/null; then halt "Y5 failed: BQ still not green after data-plane restore; inspect BQ output above"; fi
say "[Y5] BQ green sentinel present"

# ===================== [Y6] proxied gate + NRestarts stability =====================
say "=== [Y6] proxied gate + NRestarts stability (double-sample) ==="
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
  halt "Y6 proxied gate failed:$P_FAIL"
fi
say "[Y6] proxied gate PASS (all 200 through :8888)"
STABLE_FAIL=""
for unit in gitea grafana woodpecker-server woodpecker-agent n8n traefik; do
  a="$(nrestarts "$unit.service")"
  sleep 6
  b="$(nrestarts "$unit.service")"
  if [ "$a" != "$b" ]; then STABLE_FAIL="$STABLE_FAIL $unit($a->$b)"
  elif [ "$(active_state "$unit.service")" != active ] || [ "$(container_status "$unit")" != running ]; then STABLE_FAIL="$STABLE_FAIL $unit(not-active-running)"
  else say "[Y6] stable $unit NRestarts=$a (flat) active+running"; fi
done
if [ -n "$STABLE_FAIL" ]; then halt "Y6 stability failed:$STABLE_FAIL"; fi
say "[Y6] NRestarts stability PASS (flat across 12s for all six)"

# ===================== [Y7] ledger + replay =====================
say "=== [Y7] ledger rows ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BY-aardvark-observability-ladder-heal | GATE=PASS | %s: supersedes BW (BW crashed in W0 on a set -u local-split bug and falsely flagged aardvark broken via a bad Go template; the ladder was NEVER attempted before BY). BY adds DECISIVE read-only observability (live aardvark proc cmdline + netavark registration dir) BEFORE healing, detects the binary by known-libexec probe (/usr/lib/podman/aardvark-dns v%s), bounds EVERY probe with timeout so no unit can hang, then runs the process/state ladder (step=%s): reload -> pkill -u ours -x aardvark-dns -> rm stale %s state dir, each re-proved with true getent rc + in-netns nslookup (state=%s); canary %s -> %s non-loopback. Installed DURABLE timeout-bounded dns-wait (process/state heal, NO unit) + STRICT reject. GUI ghost rows patched EARLY+non-fatal (status=%s). Cascaded gitea/grafana/woodpecker-server/n8n/woodpecker-agent to active+running+health200 (postgres/litellm untouched); reran BQ (traefik green); proxied gate all 200 via :8888; NRestarts flat across 12s for all six; no-sudo; no-service-pull; no-etc-hosts-edit; no-network-recreate-blind; no-ollama/open-webui; no-secret-echo. |\n' \
    "$(date +%F)" "$TOKEN" "${AARD_VER:-?}" "$HEAL_STEP" "$NET" "$DNS_STATE" "$CANARY" "$CANARY_ADDR" "$GUI_STATUS" >> "$IDX"
  say "[Y7] BY correction+green row appended."
else
  say "[Y7] BY row already present (guard suppressed)."
fi
if [ "$GUI_STATUS" = ok ] || [ "$GUI_STATUS" = already-present ]; then
  if ! grep -qF "$GUI_OK" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=PASS | Podman.py Containers tab ghost rows for plain systemd user units patched + py_compile OK; restart the GUI to load (stopped --rm services now show as Missing (systemd unit) with working Start). |\n' \
      "$(date +%F)" "$GUI_OK" >> "$IDX"
    say "[Y7] GUI OK row appended."
  fi
else
  if ! grep -qF "$GUI_BAD" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | Podman.py ghost-row patch status=%s (NON-FATAL; control plane unaffected). |\n' \
      "$(date +%F)" "$GUI_BAD" "$GUI_STATUS" >> "$IDX"
    say "[Y7] GUI non-fatal DIAG row appended."
  fi
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[Y7] suppression proof: BY sentinel present." || say "[Y7] WARNING: BY sentinel missing."

cat > "$CD/20261030-BY-replay.sh" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BY: data plane live (true rc, timeout-bounded) + cascade up + traefik proxied green + NRestarts flat.
set -uo pipefail
NET=aether; ALPINE=docker.io/library/alpine:latest
GE(){ timeout 30 podman run --rm --network "$NET" "$ALPINE" getent hosts "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
hc(){ local u="$1"; local h="${2:-}"; if [ -n "$h" ]; then curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "$u" 2>/dev/null || echo 000; else curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000; fi; }
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
  echo "  [GATE PASS] by dataplane=live postgres=$CA proxied=all200 agent-NR-flat=$A1"
else
  echo "  [GATE FAIL] postgres=$CA gitea=$P1 wp=$P2 grafana=$P3 n8n=$P4 traefik=$P5 agent-NR=$A1->$A2"; exit 1
fi
REPLAY
chmod +x "$CD/20261030-BY-replay.sh"
say "[Y7] replay archived -> codemod/20261030-BY-replay.sh"

say "[Y7] NOTE (deferred, NOT touched): llama-embed unit disabled though container runs (litellm healthy) — durability gap for brick 5; enabling forces a model-reload spike on this box, logged for a controlled later brick. Foreign bc-*/bd-* failed units are not our stack (scope discipline)."
say "[Y7] SAFE browser hostnames only (NEVER bare internal names): 127.0.0.1 gitea.aether.local woodpecker.aether.local grafana.aether.local n8n.aether.local traefik.aether.local"
say "[RESULT] BY FINALIZED — model=netavark-child-process(no-unit) aard=${AARD_PATH:-?}($AARD_SRC) heal_step=$HEAL_STEP canary=$CANARY:$CANARY_ADDR dns_state=$DNS_STATE dns-wait=durable-timeout-bounded gui=$GUI_STATUS cascade=up direct+proxied=200 NRestarts=flat; next: build woodpecker pipeline proof; still no Ollama/OpenWebUI/chat-model."
exit 0
