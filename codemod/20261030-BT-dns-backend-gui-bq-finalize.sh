#!/usr/bin/env bash
# 20261030-BT — supersede BS after /etc/hosts cleanup.
# Evidence:
#   BS proved host shadow is gone:
#     [S0] shadowed_names=none
#   But DNS probe returned none for all backends:
#     gitea/grafana/woodpecker-server/n8n = none
#   BS diagnostics were too quiet and did not ensure backend services were running first.
#
# BT does:
#   T0 loud read-only environment evidence.
#   T1 ensure rootless podman.socket, aether network, alpine diagnostic image, network DNS helper reload.
#   T2 start/wait required backend services in dependency order.
#   T3 prove in-network DNS resolution with visible stderr.
#   T4 restore strict aether-dns-wait.sh loopback rejection after proof.
#   T5 patch Podman.py Containers tab ghost rows for plain systemd user units (non-fatal if anchor missing).
#   T6 rerun BQ Traefik brick 11.
#   T7 restart dependents and re-gate direct + proxied health + agent stability.
#   T8 append guarded ledger rows.
#
# Safety:
#   - no sudo
#   - no service/model image pull; only alpine diagnostic image may be pulled if missing
#   - no ollama/open-webui
#   - no secret echo
#   - --check is pure/read-only
# Hard rules:
#   - multi-line if/then/fi only
#   - bash -n mandatory before run
#   - no heredoc inside $( )
#   - no backticks
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

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_INST_DIR="$HOME/.config/systemd/user"

BACKEND_NAMES="gitea grafana woodpecker-server n8n"
START_UNITS="postgres llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent"
REGATE_UNITS="gitea woodpecker-server woodpecker-agent n8n litellm grafana traefik"

PODMAN_PY=""
PODMAN_PY_FALLBACK="/home/dev/DevOps/apps/podman/Podman.py"

TOKEN="bt-dns-backend-gui-bq-finalize-v1"
GUI_OK_TOKEN="bt-gui-ghost-rows-user-units-v1"
GUI_FAIL_TOKEN="bt-gui-ghost-rows-anchor-or-compile-failed-v1"
BQ_TOKEN="bq-traefik-brick11-green-v1"

BAK_SUFFIX="pre-BT.bak"

PROBE_RC=0
PROBE_OUT=""
PROBE_ERR=""
PROBE_ADDR=""
GUI_STATUS="not-attempted"

cleanup(){
  rm -rf "$TMPD" 2>/dev/null || true
}
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
norm(){
  local s="${1:-}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}
halt(){
  printf '[HALT] %s\n' "$*" >&2
  exit 0
}
need_cmd(){
  if ! command -v "$1" >/dev/null 2>&1; then
    halt "missing required command: $1"
  fi
}
to_int(){
  local v
  v="$(norm "${1:-0}")"
  case "$v" in
    ''|*[!0-9]*)
      printf '0'
      ;;
    *)
      printf '%s' "$v"
      ;;
  esac
}
bak_once(){
  local f="$1"
  if [ -f "$f" ] && [ ! -f "$f.$BAK_SUFFIX" ]; then
    cp -p "$f" "$f.$BAK_SUFFIX" || true
    say "[BAK] $f.$BAK_SUFFIX"
  fi
}
active_state(){
  local s
  s="$(systemctl --user is-active "$1" 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=inactive
  fi
  printf '%s' "$s"
}
enabled_state(){
  local s
  s="$(systemctl --user is-enabled "$1" 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=unknown
  fi
  printf '%s' "$s"
}
container_status(){
  local name="$1"
  local s
  s="$(podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=absent
  fi
  printf '%s' "$s"
}
nrestarts(){
  local v
  v="$(systemctl --user show "$1" -p NRestarts --value 2>/dev/null || true)"
  printf '%s' "$(to_int "$v")"
}
is_loopback(){
  local a="${1:-}"
  case "$a" in
    127.*|::1|localhost)
      return 0
      ;;
    *)
      return 1
      ;;
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
  if [ -z "$code" ]; then
    code=000
  fi
  printf '%s' "$code"
}
wait_http(){
  local url="$1"
  local host="${2:-}"
  local tries="${3:-60}"
  local i code
  for i in $(seq 1 "$tries"); do
    code="$(http_code "$url" "$host")"
    if [ "$code" = 200 ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}
dump_unit(){
  local unit="$1"
  local cont="$2"
  systemctl --user status --no-pager "$unit.service" 2>&1 | sed 's/^/    unit: /' || true
  journalctl --user -u "$unit.service" -n 60 --no-pager 2>&1 | sed 's/^/    journal: /' || true
  podman logs --tail 80 "$cont" 2>&1 | sed 's/^/    container: /' || true
}
start_and_wait_unit(){
  local unit="$1"
  local cont="$2"
  local tries="${3:-60}"
  local i

  if [ ! -f "$UNIT_INST_DIR/$unit.service" ]; then
    say "[T2] skip missing unit: $unit.service"
    return 0
  fi

  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
  systemctl --user enable "$unit.service" >/dev/null 2>&1 || true

  if ! systemctl --user start "$unit.service"; then
    say "[T2] failed to start $unit.service"
    dump_unit "$unit" "$cont"
    return 1
  fi

  for i in $(seq 1 "$tries"); do
    if [ "$(active_state "$unit.service")" = active ] &&
       [ "$(container_status "$cont")" = running ]; then
      say "[T2] OK $unit.service active + $cont running"
      return 0
    fi
    sleep 2
  done

  say "[T2] timeout waiting for $unit.service + $cont"
  dump_unit "$unit" "$cont"
  return 1
}
probe_dns(){
  local name="$1"
  local out="$TMPD/dns-$name.out"
  local err="$TMPD/dns-$name.err"
  local rc=0

  PROBE_RC=0
  PROBE_OUT="$out"
  PROBE_ERR="$err"
  PROBE_ADDR=""

  podman run --rm --network "$NET" "$ALPINE" sh -c '
printf "RESOLVCONF\n"
cat /etc/resolv.conf 2>/dev/null || true
printf "\nHOSTS\n"
cat /etc/hosts 2>/dev/null || true
printf "\nGETENT\n"
getent hosts "$1" 2>/dev/null || true
' sh "$name" >"$out" 2>"$err" || rc=$?

  PROBE_RC="$rc"
  PROBE_ADDR="$(sed -n '/^GETENT$/,$p' "$out" 2>/dev/null | grep -v '^GETENT$' | head -n1 | awk '{print $1}' || true)"
  PROBE_ADDR="$(norm "$PROBE_ADDR")"
}
dump_dns_state(){
  say "=== [DUMP] podman version ==="
  podman version 2>&1 | sed 's/^/    podman: /' || true

  say "=== [DUMP] podman ps -a ==="
  podman ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1 | sed 's/^/    ps: /' || true

  say "=== [DUMP] podman network ls ==="
  podman network ls 2>&1 | sed 's/^/    net-ls: /' || true

  say "=== [DUMP] network inspect raw ==="
  podman network inspect "$NET" >"$TMPD/net-inspect.out" 2>"$TMPD/net-inspect.err" || true
  head -c 3000 "$TMPD/net-inspect.out" 2>/dev/null | sed 's/^/    net-out: /' || true
  head -c 1200 "$TMPD/net-inspect.err" 2>/dev/null | sed 's/^/    net-err: /' || true

  say "=== [DUMP] backend inspect ==="
  for n in $BACKEND_NAMES; do
    podman inspect "$n" --format '{{.Name}} status={{.State.Status}} networks={{json .NetworkSettings.Networks}}' >"$TMPD/inspect-$n.out" 2>"$TMPD/inspect-$n.err" || true
    head -c 800 "$TMPD/inspect-$n.out" 2>/dev/null | sed "s/^/    inspect-$n: /" || true
    head -c 800 "$TMPD/inspect-$n.err" 2>/dev/null | sed "s/^/    inspect-$n-err: /" || true
  done

  say "=== [DUMP] DNS probe outputs ==="
  if compgen -G "$TMPD/dns-*.out" >/dev/null 2>&1; then
    for f in "$TMPD"/dns-*.out; do
      say "--- $(basename "$f") ---"
      head -c 1800 "$f" 2>/dev/null | sed 's/^/    probe: /' || true
    done
  else
    say "    no dns probe output files"
  fi

  if compgen -G "$TMPD/dns-*.err" >/dev/null 2>&1; then
    for f in "$TMPD"/dns-*.err; do
      say "--- $(basename "$f") stderr ---"
      head -c 1200 "$f" 2>/dev/null | sed 's/^/    probe-err: /' || true
    done
  fi

  say "=== [DUMP] aardvark/user DNS units ==="
  systemctl --user list-units --all --no-pager 2>&1 | grep -Ei 'aardvark|podman.*dns|network' | sed 's/^/    units: /' || true
  journalctl --user -u 'podman-aardvark-dns*' -n 80 --no-pager 2>&1 | sed 's/^/    aardvark: /' || true
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head id date pgrep find; do
  need_cmd "$c"
done

# ===================== [T0] read-only environment evidence =====================
say "=== [T0] read-only environment evidence ==="

RUN_UID="$(id -u)"
PODMAN_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$RUN_UID}/podman/podman.sock"
say "[T0] uid=$RUN_UID podman_socket=$PODMAN_SOCKET"
say "[T0] podman_socket_active=$(active_state podman.socket)"
say "[T0] network=$NET"
say "[T0] backend_names=$BACKEND_NAMES"
say "[T0] start_units=$START_UNITS"

podman version 2>&1 | head -n 8 | sed 's/^/    podman: /' || true
podman network ls 2>&1 | sed 's/^/    net-ls: /' || true
podman ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1 | sed 's/^/    ps: /' || true

say "=== [T0] locate canonical Podman.py ==="
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
say "[T0] podman_py=$PODMAN_PY"

if [ "$DRY" = 1 ]; then
  say "[T0] dry-run plan (pure/read-only; no start, no pull, no writes, no ledger):"
  say "    - ensure podman.socket, aether network, alpine image"
  say "    - reload Podman network/DNS helpers if present"
  say "    - start/wait: $START_UNITS"
  say "    - prove DNS for: $BACKEND_NAMES"
  say "    - restore strict dns-wait"
  say "    - patch Podman.py ghost rows non-fatally"
  say "    - rerun BQ and re-gate"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched."
  exit 0
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$UNIT_INST_DIR"
touch "$IDX"

# ===================== [T1] ensure socket/network/diagnostic image =====================
say "=== [T1] ensure rootless Podman socket/network/alpine ==="

systemctl --user daemon-reload >/dev/null 2>&1 || true
if ! systemctl --user enable --now podman.socket >/dev/null 2>&1; then
  systemctl --user start podman.socket >/dev/null 2>&1 || true
fi

SOCK_OK=no
for i in $(seq 1 30); do
  if [ -S "$PODMAN_SOCKET" ]; then
    SOCK_OK=yes
    break
  fi
  sleep 1
done
if [ "$SOCK_OK" != yes ]; then
  halt "podman.socket is not providing $PODMAN_SOCKET"
fi
say "[T1] podman.socket present"

"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true

if ! podman network exists "$NET" 2>/dev/null; then
  say "[T1] network $NET missing; attempting create"
  podman network create "$NET" >/dev/null 2>&1 || halt "could not create network $NET"
fi
say "[T1] network present: $NET"

if ! podman image exists "$ALPINE" 2>/dev/null; then
  say "[T1] alpine diagnostic image missing; pulling only $ALPINE (tiny, free, no service/model image)"
  podman image pull "$ALPINE" >/dev/null 2>&1 || halt "could not pull alpine diagnostic image"
fi
say "[T1] alpine diagnostic image present"

if command -v podman >/dev/null 2>&1; then
  if podman network reload --help >/dev/null 2>&1; then
    podman network reload "$NET" >/dev/null 2>&1 || true
    say "[T1] attempted podman network reload $NET"
  fi
fi

for u in "podman-aardvark-dns@$NET.service" "podman-aardvark-dns.service"; do
  if systemctl --user restart "$u" >/dev/null 2>&1; then
    say "[T1] restarted $u"
  fi
done

# ===================== [T2] start/wait backend services =====================
say "=== [T2] start/wait required backend services ==="
for unit in $START_UNITS; do
  if ! start_and_wait_unit "$unit" "$unit" 75; then
    dump_dns_state
    halt "backend service failed to become active+running: $unit"
  fi
done

# ===================== [T3] prove DNS resolution =====================
say "=== [T3] prove in-network DNS resolution ==="
RESOLVE_FAIL=""
for n in $BACKEND_NAMES; do
  probe_dns "$n"
  if [ "$PROBE_RC" != 0 ]; then
    RESOLVE_FAIL="$RESOLVE_FAIL $n(run-rc=$PROBE_RC)"
    say "[T3] FAIL $n podman-run-rc=$PROBE_RC"
    head -c 800 "$PROBE_ERR" 2>/dev/null | sed 's/^/    probe-err: /' || true
  elif [ -z "$PROBE_ADDR" ]; then
    RESOLVE_FAIL="$RESOLVE_FAIL $n(none)"
    say "[T3] FAIL $n=none"
  elif is_loopback "$PROBE_ADDR"; then
    RESOLVE_FAIL="$RESOLVE_FAIL $n($PROBE_ADDR)"
    say "[T3] FAIL $n=$PROBE_ADDR loopback"
  else
    say "[T3] OK   $n=$PROBE_ADDR"
  fi
done

if [ -n "$RESOLVE_FAIL" ]; then
  dump_dns_state
  halt "in-network resolution still bad:$RESOLVE_FAIL"
fi
say "[T3] resolution PASS: gitea/grafana/woodpecker-server/n8n all non-loopback"

# ===================== [T4] restore strict DNS guard =====================
say "=== [T4] restore strict loopback rejection in aether-dns-wait.sh ==="
if [ ! -f "$DNS_SCRIPT" ]; then
  halt "missing DNS guard: $DNS_SCRIPT"
fi
bak_once "$DNS_SCRIPT"

cat > "$TMPD/patch_dns_strict.py" <<'PYEOF'
import sys, pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

warn = """          if [ "$ALLOW_LOOPBACK" = 1 ]; then
            ok=1
          else
            echo "dns-wait: WARN host '$h' resolved to loopback '$addr' (host /etc/hosts shadow?); accepting for warm-up only" >&2
            ok=1
          fi"""

strict = """          if [ "$ALLOW_LOOPBACK" = 1 ]; then
            ok=1
          else
            echo "dns-wait: host '$h' resolved to loopback '$addr'; rejecting" >&2
          fi"""

if strict in t and warn not in t:
    sys.exit(0)

if warn in t:
    t = t.replace(warn, strict, 1)
elif strict not in t:
    sys.stderr.write("missing dns-wait warn/strict anchor\n")
    sys.exit(2)

if t != orig:
    p.write_text(t, encoding="utf-8")
PYEOF

if ! python3 "$TMPD/patch_dns_strict.py" "$DNS_SCRIPT"; then
  halt "dns-wait strict patch failed"
fi

if ! bash -n "$DNS_SCRIPT"; then
  cp -p "$DNS_SCRIPT.$BAK_SUFFIX" "$DNS_SCRIPT" 2>/dev/null || true
  halt "dns-wait failed bash -n after patch; restored backup"
fi
say "[T4] dns-wait strict mode OK"

# ===================== [T5] patch Podman.py ghost rows, non-fatal =====================
say "=== [T5] patch Podman.py Containers-tab ghost rows ==="
GUI_STATUS="failed"
bak_once "$PODMAN_PY"

cat > "$TMPD/patch_gui.py" <<'PYEOF'
import sys, pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

anchor = "    return rows  # AETHER_FETCH_CONTAINERS_GHOSTS"
marker = "unit:{u['unit']}"

ghost = '''    try:
        for u in fetch_user_units():
            for nm in u.get("manages", []):
                if nm in existing:
                    continue
                existing.add(nm)
                rows.append({
                    "id": f"unit:{u['unit']}",
                    "short": u["unit"][:12],
                    "name": nm,
                    "status": "missing",
                    "status_text": "Missing (systemd unit)",
                    "health": "",
                    "image": "-",
                    "created": "",
                    "ports": "",
                    "port_items": [],
                    "cmd": f"systemd user unit: {u['unit']}",
                    "unit": u["unit"],
                    "quadlet_file": None,
                })
    except Exception:
        pass
'''

if marker in t:
    sys.exit(0)

if anchor not in t:
    sys.stderr.write("missing Podman.py ghost anchor\n")
    sys.exit(2)

t = t.replace(anchor, ghost + anchor, 1)

if t != orig:
    p.write_text(t, encoding="utf-8")
PYEOF

if python3 "$TMPD/patch_gui.py" "$PODMAN_PY"; then
  if python3 -m py_compile "$PODMAN_PY"; then
    GUI_STATUS="ok"
    say "[T5] Podman.py ghost-row patch OK; py_compile passed"
  else
    cp -p "$PODMAN_PY.$BAK_SUFFIX" "$PODMAN_PY" 2>/dev/null || true
    GUI_STATUS="compile-failed-restored"
    say "[T5] Podman.py patch failed py_compile; restored backup (non-fatal)"
  fi
else
  if grep -qF "unit:{u['unit']}" "$PODMAN_PY" 2>/dev/null; then
    GUI_STATUS="already-present"
    say "[T5] Podman.py ghost-row marker already present"
  else
    GUI_STATUS="anchor-missing"
    say "[T5] Podman.py ghost anchor missing; skipping GUI patch (non-fatal)"
  fi
fi

# ===================== [T6] rerun BQ Traefik =====================
say "=== [T6] rerun BQ Traefik brick 11 ==="
if [ ! -f "$FQ" ]; then
  halt "missing BQ script: $FQ"
fi

bash "$FQ"
BQRC=$?
say "[T6] BQ rc=$BQRC"

if ! grep -qF "$BQ_TOKEN" "$IDX" 2>/dev/null; then
  halt "BQ still not green after DNS/backend heal; inspect BQ output above"
fi
say "[T6] BQ green sentinel present"

# ===================== [T7] restart dependents + re-gate =====================
say "=== [T7] restart dependents and re-gate direct + proxied health ==="
systemctl --user daemon-reload >/dev/null 2>&1 || true

for unit in $REGATE_UNITS; do
  if [ -f "$UNIT_INST_DIR/$unit.service" ]; then
    systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
    systemctl --user restart "$unit.service" >/dev/null 2>&1 || true
    say "[T7] restarted $unit.service"
  fi
done

sleep 15

GATE_FAIL=""

if ! wait_http "http://127.0.0.1:3001/api/healthz" "" 60; then
  GATE_FAIL="$GATE_FAIL gitea-direct"
fi
if ! wait_http "http://127.0.0.1:8000/api/health" "" 60; then
  GATE_FAIL="$GATE_FAIL woodpecker-direct"
fi
if ! wait_http "http://127.0.0.1:5678/healthz" "" 60; then
  GATE_FAIL="$GATE_FAIL n8n-direct"
fi
if ! wait_http "http://127.0.0.1:4000/health/liveliness" "" 60; then
  GATE_FAIL="$GATE_FAIL litellm-direct"
fi
if ! wait_http "http://127.0.0.1:3000/api/health" "" 60; then
  GATE_FAIL="$GATE_FAIL grafana-direct"
fi

if ! wait_http "http://127.0.0.1:8888/api/version" "traefik.aether.local" 60; then
  GATE_FAIL="$GATE_FAIL traefik-api"
fi
if ! wait_http "http://127.0.0.1:8888/api/healthz" "gitea.aether.local" 60; then
  GATE_FAIL="$GATE_FAIL gitea-proxy"
fi
if ! wait_http "http://127.0.0.1:8888/api/health" "woodpecker.aether.local" 60; then
  GATE_FAIL="$GATE_FAIL woodpecker-proxy"
fi
if ! wait_http "http://127.0.0.1:8888/api/health" "grafana.aether.local" 60; then
  GATE_FAIL="$GATE_FAIL grafana-proxy"
fi
if ! wait_http "http://127.0.0.1:8888/healthz" "n8n.aether.local" 60; then
  GATE_FAIL="$GATE_FAIL n8n-proxy"
fi
if ! wait_http "http://127.0.0.1:8888/dashboard/" "traefik.aether.local" 60; then
  GATE_FAIL="$GATE_FAIL dashboard-proxy"
fi

NR_WP_SERVER="$(nrestarts woodpecker-server.service)"
NR_WP_AGENT="$(nrestarts woodpecker-agent.service)"
NR_TRAEFIK="$(nrestarts traefik.service)"

if [ "$NR_WP_SERVER" -gt 0 ]; then
  GATE_FAIL="$GATE_FAIL woodpecker-server-nrestarts=$NR_WP_SERVER"
fi
if [ "$NR_WP_AGENT" -gt 0 ]; then
  GATE_FAIL="$GATE_FAIL woodpecker-agent-nrestarts=$NR_WP_AGENT"
fi
if [ "$NR_TRAEFIK" -gt 0 ]; then
  GATE_FAIL="$GATE_FAIL traefik-nrestarts=$NR_TRAEFIK"
fi

if [ -n "$GATE_FAIL" ]; then
  say "[T7] gate failures:$GATE_FAIL"
  for unit in $REGATE_UNITS; do
    systemctl --user status --no-pager "$unit.service" 2>/dev/null | sed "s/^/    unit-$unit: /" || true
  done
  podman logs --tail 80 woodpecker-agent 2>&1 | sed 's/^/    agent-log: /' || true
  podman logs --tail 80 woodpecker-server 2>&1 | sed 's/^/    server-log: /' || true
  podman logs --tail 80 traefik 2>&1 | sed 's/^/    traefik-log: /' || true
  halt "dependent re-gate failed:$GATE_FAIL"
fi
say "[T7] re-gate PASS: direct + proxied health all 200; woodpecker-server/agent/traefik NRestarts=0"

# ===================== [T8] ledger rows =====================
say "=== [T8] ledger rows ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BT-dns-backend-gui-bq-finalize | GATE=PASS | %s: finalized after /etc/hosts cleanup; shadow=none; started/waited postgres/llama-embed/litellm/n8n/gitea/grafana/woodpecker-server/woodpecker-agent; DNS=gitea/grafana/woodpecker-server/n8n non-loopback; dns_wait=strict-restored; gui=%s; bq=%s green; dependents=gitea/woodpecker/n8n/litellm/grafana/traefik direct+proxied all 200; nrestarts woodpecker-server=%s woodpecker-agent=%s traefik=%s; no-sudo-in-script; no-service-image-pull; alpine-pull-if-missing-only; no-ollama/open-webui; no-secret-echo. |\n' \
    "$(date +%F)" "$TOKEN" "$GUI_STATUS" "$BQ_TOKEN" "$NR_WP_SERVER" "$NR_WP_AGENT" "$NR_TRAEFIK" >> "$IDX"
  say "[T8] BT finalize row appended."
else
  say "[T8] BT finalize row already present (guard suppressed)."
fi

if [ "$GUI_STATUS" = ok ] || [ "$GUI_STATUS" = already-present ]; then
  if ! grep -qF "$GUI_OK_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=PASS | Podman.py Containers tab ghost rows for plain systemd user units are present/patched; restart the GUI to load. |\n' \
      "$(date +%F)" "$GUI_OK_TOKEN" >> "$IDX"
    say "[T8] GUI OK row appended."
  else
    say "[T8] GUI OK row already present (guard suppressed)."
  fi
else
  if ! grep -qF "$GUI_FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | Podman.py ghost-row patch status=%s; Traefik finalization continued because this is non-fatal. Inspect [T5] output and send Podman.py path/version if you want the GUI patch completed. |\n' \
      "$(date +%F)" "$GUI_FAIL_TOKEN" "$GUI_STATUS" >> "$IDX"
    say "[T8] GUI non-fatal DIAG row appended."
  else
    say "[T8] GUI non-fatal DIAG row already present (guard suppressed)."
  fi
fi

grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[T8] suppression proof: finalize sentinel present." || say "[T8] WARNING: finalize sentinel missing."

say "[T8] OPTIONAL safe browser hostnames (do NOT add bare gitea/woodpecker-server):"
say "    127.0.0.1 gitea.aether.local woodpecker.aether.local grafana.aether.local n8n.aether.local traefik.aether.local"
say "[RESULT] BT FINALIZED — hosts=clean dns=non-loopback backend=running dns-wait=strict gui=$GUI_STATUS traefik=BQ-green dependents=direct+proxied-200 nrestarts=wp-server:$NR_WP_SERVER wp-agent:$NR_WP_AGENT traefik:$NR_TRAEFIK; next: build woodpecker pipeline proof; still no Ollama/OpenWebUI/chat-model."
exit 0
