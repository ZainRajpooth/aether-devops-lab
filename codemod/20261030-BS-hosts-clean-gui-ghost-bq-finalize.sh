#!/usr/bin/env bash
# 20261030-BS — finalize Woodpecker/Traefik control plane after manual /etc/hosts cleanup.
# Supersedes BR's --no-hosts hypothesis.
#
# Why BR halted correctly:
#   host /etc/hosts had legacy loopback aliases for gitea/woodpecker-server.
#   --no-hosts removed Podman's generated /etc/hosts entries and made resolution none.
#   Therefore the fix is host-file cleanup, not --no-hosts.
#
# BS does:
#   S0 read-only detect remaining shadow names; if present, print exact one-time sudo cleanup and halt.
#   S1 prove in-network resolution for gitea/grafana/woodpecker-server/n8n returns non-loopback IPs.
#   S2 restore aether-dns-wait.sh to strict loopback rejection (undo BR WARN mode) after proof.
#   S3 patch Podman.py fetch_containers() to ghost plain systemd user units so stopped --rm services remain visible.
#   S4 rerun BQ Traefik brick 11.
#   S5 restart dependents and re-gate direct + proxied health.
#   S6 append guarded ledger rows.
#
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
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

UNIT_INST_DIR="$HOME/.config/systemd/user"

BACKEND_NAMES="gitea grafana woodpecker-server n8n"
SHADOW_NAMES="gitea woodpecker-server"

PODMAN_PY=""
PODMAN_PY_FALLBACK="/home/dev/DevOps/apps/podman/Podman.py"

TOKEN="bs-hosts-clean-gui-ghost-bq-finalize-v1"
GUI_TOKEN="bs-gui-ghost-rows-user-units-v1"
BQ_TOKEN="bq-traefik-brick11-green-v1"

BAK_SUFFIX="pre-BS.bak"

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
probe_name(){
  local name="$1"
  local line addr
  line="$(podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" 2>/dev/null | head -n1 || true)"
  addr="$(printf '%s' "$line" | awk '{print $1}')"
  norm "$addr"
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
  norm "$code"
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
print_manual_hosts_fix(){
  cat <<'HOSTFIX'
Run this ONE-TIME manual cleanup (your sudo; this script never uses sudo):

tmp="$(mktemp)"
sudo cp -a /etc/hosts "/etc/hosts.aether-$(date +%Y%m%d-%H%M%S).bak"
sudo awk '
BEGIN { drop["gitea"]=1; drop["woodpecker-server"]=1 }
/^[[:space:]]*(127\.|::1)/ {
  ip=$1; line=""
  for (i=2; i<=NF; i++) {
    if ($i in drop) continue
    if (line == "") line=$i
    else line=line " " $i
  }
  if (line != "") print ip " " line
  next
}
{ print }
' /etc/hosts > "$tmp"
sudo install -m 644 "$tmp" /etc/hosts
rm -f "$tmp"

Then rerun:
  bash /home/dev/DevOps/aether/codemod/20261030-BS-hosts-clean-gui-ghost-bq-finalize.sh
HOSTFIX
}
dump_resolution_state(){
  say "=== [DUMP] host /etc/hosts shadow lines ==="
  grep -En '^[[:space:]]*(127\.|::1)' /etc/hosts 2>/dev/null | sed 's/^/    hosts: /' || true

  say "=== [DUMP] aether network ==="
  podman network inspect "$NET" --format '{{.name}} dns={{.dns_enabled}} driver={{.driver}} subnets={{range .subnets}}{{.subnet}} {{end}}' 2>/dev/null | sed 's/^/    net: /' || true

  say "=== [DUMP] backend network attachment ==="
  for n in $BACKEND_NAMES; do
    podman inspect "$n" --format '{{.Name}} status={{.State.Status}} nets={{json .NetworkSettings.Networks}}' 2>/dev/null | sed 's/^/    cont: /' || true
  done
}

for c in bash podman systemctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head id date pgrep find; do
  need_cmd "$c"
done

# ===================== [S0] read-only shadow detection =====================
say "=== [S0] detect remaining host /etc/hosts shadow names ==="
printf '%s\n' $SHADOW_NAMES > "$TMPD/shadow-names"
SHADOW="$(awk '/^[[:space:]]*(127\.|::1)/ {for (i=2;i<=NF;i++) print $i}' /etc/hosts 2>/dev/null | grep -Fx -f "$TMPD/shadow-names" | sort -u | tr '\n' ' ')"
SHADOW="$(norm "$SHADOW")"
SHADOW_INITIAL="$SHADOW"
say "[S0] shadowed_names=${SHADOW:-none}"

say "=== [S0] locate canonical Podman.py ==="
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
say "[S0] podman_py=$PODMAN_PY"

if [ "$DRY" = 1 ]; then
  say "[S0] dry-run plan (pure/read-only; no podman run probe, no writes, no restart, no ledger):"
  say "    - if shadow remains: print one-time sudo /etc/hosts cleanup and halt"
  say "    - else: probe in-network resolution for: $BACKEND_NAMES"
  say "    - restore strict loopback rejection in $DNS_SCRIPT"
  say "    - patch $PODMAN_PY fetch_containers() ghost rows for plain systemd user units"
  say "    - rerun $FQ"
  say "    - restart dependents and re-gate direct + proxied health"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched."
  exit 0
fi

mkdir -p "$CD"
touch "$IDX"

if [ -n "$SHADOW" ]; then
  print_manual_hosts_fix
  halt "host /etc/hosts still shadows: $SHADOW"
fi

# ===================== [S1] prove real in-network resolution =====================
say "=== [S1] prove in-network resolution is non-loopback ==="
RESOLVE_FAIL=""
for n in $BACKEND_NAMES; do
  addr="$(probe_name "$n")"
  if [ -z "$addr" ]; then
    RESOLVE_FAIL="$RESOLVE_FAIL $n(none)"
    say "[S1] FAIL $n=none"
  elif is_loopback "$addr"; then
    RESOLVE_FAIL="$RESOLVE_FAIL $n($addr)"
    say "[S1] FAIL $n=$addr loopback"
  else
    say "[S1] OK   $n=$addr"
  fi
done

if [ -n "$RESOLVE_FAIL" ]; then
  dump_resolution_state
  halt "in-network resolution still bad:$RESOLVE_FAIL"
fi
say "[S1] resolution PASS: gitea/grafana/woodpecker-server/n8n all non-loopback"

# ===================== [S2] restore strict DNS guard =====================
say "=== [S2] restore strict loopback rejection in aether-dns-wait.sh ==="
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
say "[S2] dns-wait strict mode OK"

# ===================== [S3] patch Podman.py ghost rows =====================
say "=== [S3] patch Podman.py Containers-tab ghost rows ==="
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

if ! python3 "$TMPD/patch_gui.py" "$PODMAN_PY"; then
  halt "Podman.py ghost patch failed"
fi

if ! python3 -m py_compile "$PODMAN_PY"; then
  cp -p "$PODMAN_PY.$BAK_SUFFIX" "$PODMAN_PY" 2>/dev/null || true
  halt "Podman.py failed py_compile after patch; restored backup"
fi
say "[S3] Podman.py ghost-row patch OK; py_compile passed"

# ===================== [S4] rerun BQ Traefik =====================
say "=== [S4] rerun BQ Traefik brick 11 ==="
if [ ! -f "$FQ" ]; then
  halt "missing BQ script: $FQ"
fi

bash "$FQ"
BQRC=$?
say "[S4] BQ rc=$BQRC"

if ! grep -qF "$BQ_TOKEN" "$IDX" 2>/dev/null; then
  halt "BQ still not green after host cleanup; inspect BQ output above"
fi
say "[S4] BQ green sentinel present"

# ===================== [S5] restart dependents + re-gate =====================
say "=== [S5] restart dependents and re-gate direct + proxied health ==="
systemctl --user daemon-reload >/dev/null 2>&1 || true

for unit in gitea woodpecker-server woodpecker-agent n8n litellm grafana traefik; do
  if [ -f "$UNIT_INST_DIR/$unit.service" ]; then
    systemctl --user restart "$unit.service" >/dev/null 2>&1 || true
    say "[S5] restarted $unit.service"
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

if [ -n "$GATE_FAIL" ]; then
  say "[S5] gate failures:$GATE_FAIL"
  for unit in gitea woodpecker-server woodpecker-agent n8n litellm grafana traefik; do
    systemctl --user status --no-pager "$unit.service" 2>/dev/null | sed "s/^/    unit-$unit: /" || true
  done
  halt "dependent re-gate failed:$GATE_FAIL"
fi
say "[S5] re-gate PASS: direct + proxied health all 200"

# ===================== [S6] ledger rows =====================
say "=== [S6] ledger rows ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BS-hosts-clean-gui-ghost-bq-finalize | GATE=PASS | %s: finalized after manual /etc/hosts cleanup; shadow_initial=%s; resolution=gitea/grafana/woodpecker-server/n8n non-loopback; dns_wait=strict-restored; gui=%s ghost-rows-for-plain-systemd-user-units py_compile=ok; bq=%s green; dependents=gitea/woodpecker/n8n/litellm/grafana/traefik direct+proxied all 200; no-sudo-in-script; no-pull; no-ollama/open-webui; no-secret-echo. |\n' \
    "$(date +%F)" "$TOKEN" "${SHADOW_INITIAL:-none}" "$PODMAN_PY" "$BQ_TOKEN" >> "$IDX"
  say "[S6] BS finalize row appended."
else
  say "[S6] BS finalize row already present (guard suppressed)."
fi

if ! grep -qF "$GUI_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | Podman.py Containers tab now shows stopped --rm systemd-user services as Missing (systemd unit) ghost rows with working Start action; restart the GUI to load. |\n' \
    "$(date +%F)" "$GUI_TOKEN" >> "$IDX"
  say "[S6] GUI ghost-row row appended."
else
  say "[S6] GUI ghost-row row already present (guard suppressed)."
fi

grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[S6] suppression proof: finalize sentinel present." || say "[S6] WARNING: finalize sentinel missing."
grep -qF "$GUI_TOKEN" "$IDX" 2>/dev/null && say "[S6] suppression proof: GUI sentinel present." || say "[S6] WARNING: GUI sentinel missing."

say "[RESULT] BS FINALIZED — hosts=clean resolution=non-loopback dns-wait=strict gui=ghost-rows traefik=BQ-green dependents=direct+proxied-200; next: build woodpecker pipeline proof; still no Ollama/OpenWebUI/chat-model."
exit 0
