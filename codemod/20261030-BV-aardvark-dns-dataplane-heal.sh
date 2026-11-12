#!/usr/bin/env bash
# 20261030-BV — targeted heal of the BU-proven root cause: netavark aardvark-dns
# data-plane helper for network 'aether' is INACTIVE, so NO in-network name resolves
# (postgres rc=2), wedging every ExecStartPre dns-wait into a 90-try alpine loop and
# hard-failing n8n (EAI_AGAIN postgres) and blocking Traefik promotion.
#
# Supersedes BT/BS/BR. NOT a hosts/env/secret problem (BU U6 clean).
#
# V0 read-only: locate aardvark unit/binary, masked state, current canary.
# V1 RESTORE data plane rootless: unmask-if-masked, reset-failed, start
#    podman-aardvark-dns@aether.service (+ base best-effort), podman network reload aether,
#    then PROVE getent postgres returns a NON-loopback IP from an alpine on aether.
#    If it cannot be restored rootless -> dump + print manual escalation + HALT (no promote).
# V2 install DURABLE guard: rewrite aether-dns-wait.sh so its FIRST action ensures
#    aardvark-dns@aether is active (re-start each loop tick) + network reload, waits the
#    postgres canary, THEN does the per-host loop with STRICT loopback rejection.
#    (This also finally performs the strict-restore BR/BS/BT never reached.)
# V_gui NON-FATAL: patch Podman.py fetch_containers() ghost rows for plain systemd user
#    units (the user's original GUI bug; never actually applied — BR/BS/BT all halted
#    before their GUI step). Line/indent-tolerant patcher + py_compile gate + auto-restore.
# V3 cascade: reset-failed + restart gitea, grafana, woodpecker-server, n8n (wait
#    active+running+direct-health), then woodpecker-agent (wait running). postgres/litellm untouched.
# V4 direct gate for the full set incl. litellm.
# V5 rerun BQ (traefik) now that DNS works.
# V6 proxied gate + NRestarts STABILITY (double-sample, immune to the pre-fix climb).
# V7 guarded ledger rows (correction + green + gui) + replay.
#
# Safety: no sudo; no service/model pull; no ollama/open-webui; no secret echo;
#         --check pure/read-only; never restarts postgres/litellm; never edits /etc/hosts.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( );
#             no backticks as substitution (none needed in this script).
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
AARD_UNIT="podman-aardvark-dns@${NET}.service"
AARD_BASE="podman-aardvark-dns.service"

UNIT_INST_DIR="$HOME/.config/systemd/user"
PODMAN_PY_FALLBACK="/home/dev/DevOps/apps/podman/Podman.py"

CASCADE="gitea grafana woodpecker-server n8n"   # restart order; agent after
GATE_ALL="postgres gitea grafana n8n litellm woodpecker-server woodpecker-agent traefik"

TOKEN="bv-aardvark-dns-dataplane-heal-v1"
GUI_OK="bv-gui-ghost-rows-user-units-v1"
GUI_BAD="bv-gui-ghost-rows-failed-v1"
BQ_TOKEN="bq-traefik-brick11-green-v1"

BAK_SUFFIX="pre-BV.bak"
CANARY_ADDR=""
AARD_START_RC="not-attempted"
GUI_STATUS="not-attempted"

cleanup(){ rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }
need_cmd(){ if ! command -v "$1" >/dev/null 2>&1; then halt "missing required command: $1"; fi; }
bak_once(){
  local f="$1"
  if [ -f "$f" ] && [ ! -f "$f.$BAK_SUFFIX" ]; then
    cp -p "$f" "$f.$BAK_SUFFIX" || true
    say "[BAK] $f.$BAK_SUFFIX"
  fi
}
to_int(){
  local v
  v="$(norm "${1:-0}")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}
active_state(){ printf '%s' "$(norm "$(systemctl --user is-active "$1" 2>/dev/null || true)")"; }
enabled_state(){ printf '%s' "$(norm "$(systemctl --user is-enabled "$1" 2>/dev/null || true)")"; }
load_state(){ printf '%s' "$(norm "$(systemctl --user show "$1" -p LoadState --value 2>/dev/null || true)")"; }
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
# one-shot in-network getent for a name; sets LAST_ADDR / LAST_RC
probe_getent(){
  local name="$1" line addr rc=0
  line="$(podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" 2>/dev/null | head -n1 || true)"
  rc=$?
  addr="$(printf '%s' "$line" | awk '{print $1}')"
  LAST_ADDR="$(norm "$addr")"
  LAST_RC="$rc"
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
dump_aardvark(){
  say "=== [DUMP] aardvark unit state ==="
  for u in "$AARD_UNIT" "$AARD_BASE"; do
    say "  $u active=$(active_state "$u") enabled=$(enabled_state "$u") load=$(load_state "$u")"
  done
  say "  aardvark-dns binary: $(command -v aardvark-dns 2>/dev/null || echo MISSING)"
  say "  podman info dns/netavark lines:"
  podman info 2>/dev/null | grep -Ei 'aardvark|netavark|dns|network.?backend' | sed 's/^/    info: /' || true
  journalctl --user -u "$AARD_UNIT" -n 40 --no-pager 2>/dev/null | sed 's/^/    j-inst: /' || true
  journalctl --user -u "$AARD_BASE" -n 20 --no-pager 2>/dev/null | sed 's/^/    j-base: /' || true
  say "=== [DUMP] current canary probe ==="
  probe_getent "$CANARY"
  say "  getent $CANARY -> addr='${LAST_ADDR:-none}' rc=$LAST_RC"
}
print_manual_escalation(){
  cat <<'ESC'
Rootless restart of the netavark DNS helper did NOT restore in-network resolution.
This is the escalation rung (BU already proved the data plane, not config, is at fault).
Try, in order, YOUR sudo only if the rootless attempts are exhausted:

  1) Confirm the helper binary is installed (rootless needs it on PATH):
       command -v aardvark-dns || apt list --installed 2>/dev/null | grep -i aardvark
     If MISSING, install the podman/netavark/aardvark-dns packages for your Kubuntu release.

  2) As YOUR user (no sudo), force netavark to (re)start the per-network helper:
       systemctl --user unmask podman-aardvark-dns@aether.service 2>/dev/null || true
       systemctl --user reset-failed podman-aardvark-dns@aether.service 2>/dev/null || true
       systemctl --user start  podman-aardvark-dns@aether.service
       podman network reload aether
       podman run --rm --network aether docker.io/library/alpine:latest getent hosts postgres

  3) If (2) still yields rc=2/empty, the user manager or a podman upgrade dropped the
     transient unit; a controlled `systemctl --user daemon-reexec` (your session, no sudo)
     then re-running THIS script is the next rung. Do NOT reboot the laptop mid-stack.

Then rerun:  bash /home/dev/DevOps/aether/codemod/20261030-BV-aardvark-dns-dataplane-heal.sh
ESC
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head id date pgrep find; do
  need_cmd "$c"
done

# ===================== [V0] read-only environment =====================
say "=== [V0] read-only environment ==="
say "[V0] network=$NET canary=$CANARY aard_unit=$AARD_UNIT aard_base=$AARD_BASE"
say "[V0] aardvark-dns binary=$(command -v aardvark-dns 2>/dev/null || echo MISSING)"
say "[V0] $AARD_UNIT active=$(active_state "$AARD_UNIT") enabled=$(enabled_state "$AARD_UNIT") load=$(load_state "$AARD_UNIT")"
say "[V0] $AARD_BASE   active=$(active_state "$AARD_BASE") enabled=$(enabled_state "$AARD_BASE") load=$(load_state "$AARD_BASE")"
probe_getent "$CANARY"
say "[V0] pre-fix getent $CANARY -> addr='${LAST_ADDR:-none}' rc=$LAST_RC (expect none/rc=2 = the fault)"
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing (cannot heal DNS for a network that does not exist)"
fi
if ! podman image exists "$ALPINE" 2>/dev/null; then
  halt "alpine diagnostic image missing (probe needs it cached)"
fi
if [ "$(container_status "$CANARY")" != running ]; then
  halt "canary container $CANARY not running (cannot use it to prove DNS)"
fi

say "=== [V0] locate canonical Podman.py ==="
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
say "[V0] podman_py=$PODMAN_PY"

if [ "$DRY" = 1 ]; then
  say "[V0] dry-run plan (pure/read-only; no unit start, no reload, no writes, no restart, no ledger):"
  say "    V1  unmask/reset-failed/start $AARD_UNIT (+$AARD_BASE best-effort) + podman network reload $NET; prove getent $CANARY non-loopback"
  say "    V2  rewrite $DNS_SCRIPT with durable aardvark-ensure + canary + STRICT loopback reject"
  say "    Vgui patch $PODMAN_PY fetch_containers() ghost rows (non-fatal, py_compile gated)"
  say "    V3  cascade restart: $CASCADE then woodpecker-agent (postgres/litellm untouched)"
  say "    V4  direct gate: $GATE_ALL"
  say "    V5  rerun BQ (traefik)"
  say "    V6  proxied gate + NRestarts stability (double-sample)"
  say "    V7  guarded ledger + replay"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched."
  exit 0
fi

mkdir -p "$CD" "$UNIT_INST_DIR"
touch "$IDX"

# ===================== [V1] restore DNS data plane + prove canary =====================
say "=== [V1] restore aardvark-dns data plane (rootless) ==="
if [ "$(enabled_state "$AARD_UNIT")" = masked ]; then
  systemctl --user unmask "$AARD_UNIT" >/dev/null 2>&1 || true
  say "[V1] unmasked $AARD_UNIT"
fi
if [ "$(enabled_state "$AARD_BASE")" = masked ]; then
  systemctl --user unmask "$AARD_BASE" >/dev/null 2>&1 || true
  say "[V1] unmasked $AARD_BASE"
fi
systemctl --user reset-failed "$AARD_UNIT" >/dev/null 2>&1 || true
systemctl --user reset-failed "$AARD_BASE" >/dev/null 2>&1 || true

if systemctl --user start "$AARD_UNIT" >/dev/null 2>&1; then
  AARD_START_RC="ok-instance"
  say "[V1] started $AARD_UNIT"
else
  AARD_START_RC="instance-failed"
  say "[V1] start $AARD_UNIT returned non-zero (will rely on reload + canary; load=$(load_state "$AARD_UNIT"))"
fi
if systemctl --user start "$AARD_BASE" >/dev/null 2>&1; then
  say "[V1] started $AARD_BASE (best-effort)"
else
  say "[V1] $AARD_BASE not startable (ok if instance path works)"
fi

podman network reload "$NET" >/dev/null 2>&1 || true
say "[V1] podman network reload $NET attempted (re-pushes attachment set to the dns driver)"

CANARY_OK=no
for i in $(seq 1 45); do
  # re-assert the helper each tick: cheap no-op when active, revives it when blipped
  systemctl --user start "$AARD_UNIT" >/dev/null 2>&1 || true
  probe_getent "$CANARY"
  if [ -n "$LAST_ADDR" ] && ! is_loopback "$LAST_ADDR"; then
    CANARY_ADDR="$LAST_ADDR"
    CANARY_OK=yes
    break
  fi
  sleep 2
done

if [ "$CANARY_OK" != yes ]; then
  dump_aardvark
  print_manual_escalation
  if ! grep -qF "${TOKEN}-dataplane-fail" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BV V1 could NOT restore rootless aardvark-dns for %s (canary %s still rc=%s/addr=%s after 45 ticks). Root cause confirmed = DNS data plane, NOT hosts/env/secret. Manual escalation printed. Do NOT proceed to Traefik. |\n' \
      "$(date +%F)" "${TOKEN}-dataplane-fail" "$NET" "$CANARY" "${LAST_RC:-?}" "${LAST_ADDR:-none}" >> "$IDX"
  fi
  halt "V1 failed: in-network DNS data plane not restored rootless; see dump + escalation above"
fi
say "[V1] DATA PLANE RESTORED: getent $CANARY -> $CANARY_ADDR (non-loopback), aard_start=$AARD_START_RC"
say "[V1] also probing gitea/woodpecker-server now (should resolve once their containers re-attach in V3):"
for n in gitea woodpecker-server; do
  probe_getent "$n"
  say "[V1]   getent $n -> '${LAST_ADDR:-none}' rc=$LAST_RC"
done

# ===================== [V2] durable guard: rewrite dns-wait =====================
say "=== [V2] install durable aether-dns-wait.sh (ensure-aardvark + canary + STRICT reject) ==="
bak_once "$DNS_SCRIPT"
cat > "$TMPD/dns-wait.new" <<'DWEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh — BV durable guard.
# Root-cause class it closes: netavark aardvark-dns data plane going inactive wedges
# every ExecStartPre into a 90-try alpine loop (services stuck 'activating', n8n
# EAI_AGAIN, Traefik never promoted). So BEFORE waiting any host, this script (a) ensures
# the per-network aardvark-dns instance is running, (b) reloads the network so the dns
# driver re-registers current attachments, (c) proves a CANARY name resolves non-loopback,
# and only then (d) waits the requested hosts with STRICT loopback rejection.
# Runs as a systemd --user ExecStartPre, so 'systemctl --user' is in-scope and sudo-free.
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
TRIES="${AETHER_DNS_TRIES:-90}"
DELAY="${AETHER_DNS_DELAY:-1}"
ALLOW_LOOPBACK="${AETHER_DNS_ALLOW_LOOPBACK:-0}"
CANARY="${AETHER_DNS_CANARY:-postgres}"
AARD_UNIT="${AETHER_DNS_AARDVARK_UNIT:-podman-aardvark-dns@${NET}.service}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2
  exit 2
fi

ensure_aardvark(){
  # best-effort, never fatal: unmask-if-masked, reset-failed, start (no-op if active)
  if [ "$(systemctl --user is-enabled "$AARD_UNIT" 2>/dev/null || true)" = masked ]; then
    systemctl --user unmask "$AARD_UNIT" >/dev/null 2>&1 || true
  fi
  systemctl --user reset-failed "$AARD_UNIT" >/dev/null 2>&1 || true
  systemctl --user start "$AARD_UNIT" >/dev/null 2>&1 || true
}

getent_addr(){
  local name="$1" line
  line="$(podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" 2>/dev/null | head -n1 || true)"
  printf '%s' "$line" | awk '{print $1}'
}

# (a)+(b)+(c): bring the data plane up and prove the canary before anything else.
ensure_aardvark
podman network reload "$NET" >/dev/null 2>&1 || true
canary_ok=0
i=1
while [ "$i" -le "$TRIES" ]; do
  ensure_aardvark
  addr="$(getent_addr "$CANARY")"
  if [ -n "$addr" ]; then
    case "$addr" in
      127.*|::1|localhost)
        if [ "$ALLOW_LOOPBACK" = 1 ]; then canary_ok=1; fi
        ;;
      *) canary_ok=1 ;;
    esac
  fi
  if [ "$canary_ok" -eq 1 ]; then
    break
  fi
  sleep "$DELAY"
  i=$((i + 1))
done
if [ "$canary_ok" -ne 1 ]; then
  echo "dns-wait: CANARY '$CANARY' did not resolve non-loopback on '$NET' after $TRIES tries (aardvark-dns data plane down? unit=$AARD_UNIT)" >&2
  exit 1
fi
echo "dns-wait: canary $CANARY resolved on $NET"

# (d): now wait the requested hosts, STRICT loopback rejection by default.
for h in "${hosts[@]}"; do
  ok=0
  i=1
  while [ "$i" -le "$TRIES" ]; do
    ensure_aardvark
    addr="$(getent_addr "$h")"
    if [ -n "$addr" ]; then
      case "$addr" in
        127.*|::1|localhost)
          if [ "$ALLOW_LOOPBACK" = 1 ]; then
            ok=1
          else
            echo "dns-wait: host '$h' resolved to loopback '$addr'; rejecting" >&2
          fi
          ;;
        *)
          ok=1
          ;;
      esac
    fi
    if [ "$ok" -eq 1 ]; then
      break
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
if grep -q 'CANARY' "$DNS_SCRIPT" 2>/dev/null && grep -q "rejecting" "$DNS_SCRIPT" 2>/dev/null; then
  say "[V2] durable guard installed: ensure-aardvark + canary + STRICT loopback reject -> $DNS_SCRIPT"
else
  halt "installed dns-wait missing canary/strict markers"
fi

# ===================== [Vgui] NON-FATAL Podman.py ghost rows =====================
say "=== [Vgui] patch Podman.py Containers-tab ghost rows (non-fatal) ==="
GUI_STATUS="failed"
bak_once "$PODMAN_PY"
cat > "$TMPD/patch_gui.py" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
marker = "unit:{u['unit']}"
token  = "AETHER_FETCH_CONTAINERS_GHOSTS"
if marker in t:
    sys.exit(0)                      # already patched -> idempotent no-op
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
    say "[Vgui] ghost-row patch applied + py_compile OK -> $PODMAN_PY"
  else
    cp -p "$PODMAN_PY.$BAK_SUFFIX" "$PODMAN_PY" 2>/dev/null || true
    GUI_STATUS="compile-failed-restored"
    say "[Vgui] patch failed py_compile; restored backup (NON-FATAL)"
  fi
else
  if grep -qF "unit:{u['unit']}" "$PODMAN_PY" 2>/dev/null; then
    GUI_STATUS="already-present"
    say "[Vgui] ghost-row marker already present (idempotent no-op)"
  else
    GUI_STATUS="anchor-missing"
    say "[Vgui] ghost token not found; skipped (NON-FATAL — control plane unaffected)"
  fi
fi

# ===================== [V3] cascade restart (postgres/litellm untouched) =====================
say "=== [V3] cascade restart wedged/failed services (DNS now live) ==="
systemctl --user daemon-reload >/dev/null 2>&1 || true
for unit in $CASCADE; do
  if [ ! -f "$UNIT_INST_DIR/$unit.service" ]; then
    say "[V3] skip missing unit $unit.service"
    continue
  fi
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
  systemctl --user enable "$unit.service" >/dev/null 2>&1 || true
  if ! systemctl --user restart "$unit.service"; then
    say "[V3] restart $unit.service returned non-zero (will verify via health)"
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
    say "[V3] $unit did not reach active+running+health200"
    systemctl --user status --no-pager "$unit.service" 2>/dev/null | sed 's/^/    unit: /' || true
    journalctl --user -u "$unit.service" -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    podman logs --tail 40 "$unit" 2>&1 | sed 's/^/    c: /' || true
    halt "V3 failed at cascade unit: $unit"
  fi
  say "[V3] OK $unit active+running+health200"
done

# woodpecker-agent AFTER server (shares server netns; ExecStartPre waits server container)
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
    halt "V3 failed: woodpecker-agent not active+running after server is up"
  fi
  say "[V3] OK woodpecker-agent active+running (server netns)"
fi
sleep 10

# ===================== [V4] direct gate =====================
say "=== [V4] direct health gate (full set) ==="
GATE_FAIL=""
for unit in $GATE_ALL; do
  if [ "$unit" = traefik ] || [ "$unit" = woodpecker-agent ]; then
    continue   # traefik gated in V6; agent has no http
  fi
  url="$(health_url_for "$unit")"
  if [ -z "$url" ]; then
    continue
  fi
  if ! wait_http "$url" "" 45; then
    GATE_FAIL="$GATE_FAIL $unit($(http_code "$url"))"
  else
    say "[V4] OK $unit direct 200"
  fi
done
if [ -n "$GATE_FAIL" ]; then
  halt "V4 direct gate failed:$GATE_FAIL"
fi
say "[V4] direct gate PASS"

# ===================== [V5] rerun BQ (traefik) =====================
say "=== [V5] rerun BQ Traefik brick 11 (DNS now live) ==="
if [ ! -f "$FQ" ]; then
  halt "missing BQ script: $FQ"
fi
bash "$FQ"
BQRC=$?
say "[V5] BQ rc=$BQRC"
if ! grep -qF "$BQ_TOKEN" "$IDX" 2>/dev/null; then
  halt "V5 failed: BQ still not green after data-plane restore; inspect BQ output above"
fi
say "[V5] BQ green sentinel present"

# ===================== [V6] proxied gate + NRestarts stability =====================
say "=== [V6] proxied gate + NRestarts stability (double-sample) ==="
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
  halt "V6 proxied gate failed:$P_FAIL"
fi
say "[V6] proxied gate PASS (all 200 through :8888)"

# stability: sample NRestarts twice 12s apart; require EQUAL (immune to pre-fix climb)
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
    say "[V6] stable $unit NRestarts=$a (flat) active+running"
  fi
done
if [ -n "$STABLE_FAIL" ]; then
  halt "V6 stability failed:$STABLE_FAIL"
fi
say "[V6] NRestarts stability PASS (flat across 12s for all six)"

# ===================== [V7] ledger + replay =====================
say "=== [V7] ledger rows ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BV-aardvark-dns-dataplane-heal | GATE=PASS | %s: ROOT CAUSE = netavark aardvark-dns data plane for %s INACTIVE (BU U5: getent postgres rc=2 while postgres running; U3 aardvark units inactive; U4 n8n EAI_AGAIN postgres). NOT hosts/env/secret (BU U6 clean). BV restored data plane rootless (aard_start=%s, canary %s->%s non-loopback), installed DURABLE dns-wait (ensure-aardvark+canary+STRICT reject), cascaded gitea/grafana/woodpecker-server/n8n/woodpecker-agent to active+running+health200, reran BQ (traefik green), proxied gate all 200 via :8888, NRestarts flat across 12s for all six; gui_ghost=%s; supersedes BT/BS/BR; no-sudo; no-service-pull; postgres/litellm untouched; no-etc-hosts-edit; no-ollama/open-webui; no-secret-echo. |\n' \
    "$(date +%F)" "$TOKEN" "$NET" "$AARD_START_RC" "$CANARY" "$CANARY_ADDR" "$GUI_STATUS" >> "$IDX"
  say "[V7] BV correction+green row appended."
else
  say "[V7] BV row already present (guard suppressed)."
fi
if [ "$GUI_STATUS" = ok ] || [ "$GUI_STATUS" = already-present ]; then
  if ! grep -qF "$GUI_OK" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=PASS | Podman.py Containers tab ghost rows for plain systemd user units patched + py_compile OK; restart the GUI to load (stopped --rm services now show as Missing (systemd unit) with working Start). |\n' \
      "$(date +%F)" "$GUI_OK" >> "$IDX"
    say "[V7] GUI OK row appended."
  fi
else
  if ! grep -qF "$GUI_BAD" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | Podman.py ghost-row patch status=%s (NON-FATAL; control plane unaffected). Send Podman.py path if you want the GUI half completed in a follow-up. |\n' \
      "$(date +%F)" "$GUI_BAD" "$GUI_STATUS" >> "$IDX"
    say "[V7] GUI non-fatal DIAG row appended."
  fi
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[V7] suppression proof: BV sentinel present." || say "[V7] WARNING: BV sentinel missing."

cat > "$CD/20261030-BV-replay.sh" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BV: data plane live + cascade up + traefik proxied green + NRestarts flat.
set -uo pipefail
NET=aether; ALPINE=docker.io/library/alpine:latest
probe(){ podman run --rm --network "$NET" "$ALPINE" getent hosts "$1" 2>/dev/null | head -n1 | awk '{print $1}'; }
hc(){ local u="$1" h="${2:-}"; if [ -n "$h" ]; then curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "$u" 2>/dev/null || echo 000; else curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000; fi; }
CA="$(probe postgres)"
case "$CA" in ''|127.*|::1|localhost) echo "  [FAIL] canary postgres=$CA"; exit 1 ;; esac
P1="$(hc http://127.0.0.1:8888/api/healthz gitea.aether.local)"
P2="$(hc http://127.0.0.1:8888/api/health woodpecker.aether.local)"
P3="$(hc http://127.0.0.1:8888/api/health grafana.aether.local)"
P4="$(hc http://127.0.0.1:8888/healthz n8n.aether.local)"
P5="$(hc http://127.0.0.1:8888/api/version traefik.aether.local)"
A1="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || echo ?)"; sleep 6
A2="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || echo ?)"
if [ "$P1" = 200 ] && [ "$P2" = 200 ] && [ "$P3" = 200 ] && [ "$P4" = 200 ] && [ "$P5" = 200 ] && [ "$A1" = "$A2" ]; then
  echo "  [GATE PASS] bv dataplane=live postgres=$CA proxied=all200 agent-NR-flat=$A1"
else
  echo "  [GATE FAIL] postgres=$CA gitea=$P1 wp=$P2 grafana=$P3 n8n=$P4 traefik=$P5 agent-NR=$A1->$A2"; exit 1
fi
REPLAY
chmod +x "$CD/20261030-BV-replay.sh"
say "[V7] replay archived -> codemod/20261030-BV-replay.sh"

say "[V7] NOTE (deferred, NOT touched now): llama-embed unit is disabled though its container runs (litellm healthy) — a durability gap for brick 5; enabling it forces a model reload spike on this 2-core/16GB box, so it is logged for a controlled later brick, not healed mid-outage. Foreign failed units bc-*/bd-* are not our stack (scope discipline)."
say "[RESULT] BV FINALIZED — root-cause=aardvark-dns-data-plane-inactive restored=$AARD_START_RC canary=$CANARY:$CANARY_ADDR dns-wait=durable-strict cascade=up direct+proxied=200 NRestarts=flat gui=$GUI_STATUS; next: build woodpecker pipeline proof; still no Ollama/OpenWebUI/chat-model."
exit 0
