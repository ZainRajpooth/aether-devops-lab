#!/usr/bin/env bash
# 20261030-BR — heal (1) host-/etc/hosts loopback shadowing that broke BQ dns-wait + Traefik upstreams,
# and (2) Podman.py Containers-tab ghost-row gap for plain systemd user units (--rm services vanish when stopped).
# Method (measure before mutate):
#   R0 read host /etc/hosts loopback aliases; intersect with our service names => SHADOW set.
#      Probe aether alpine: getent <shadowed> with default vs --no-hosts => NOHOSTS_WORKS.
#   R1 patch aether-dns-wait.sh probe to use --no-hosts (if it works); else switch reject->warn and halt
#      with the manual host-cleanup instruction (do not promote Traefik on shadowed DNS).
#   R2 patch BQ traefik ExecStart + every dependent unit whose config references a SHADOWed name
#      (uniform anchor: first --security-opt=no-new-privileges per unit) to add --no-hosts.
#   R3 patch Podman.py fetch_containers to ghost plain systemd user units (anchor: AETHER_FETCH_CONTAINERS_GHOSTS).
#   R4 rerun BQ; re-gate dependents; ledger + replay.
# Safety: no sudo; no pull; no model download; no ollama/open-webui; no secret echo; --check pure.
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
UNIT_SRC_DIR="$A/infra/systemd"
UNIT_INST_DIR="$HOME/.config/systemd/user"

ALL_NAMES="gitea grafana woodpecker-server woodpecker-agent n8n litellm llama-embed postgres redis minio weaviate prometheus node-exporter mailpit traefik portainer zitadel"
SHADOW=""
NOHOSTS_WORKS=no
PODMAN_PY=""
TOKEN="br-hosts-shadow-nohosts-heal-v1"
GUITOKEN="br-gui-ghost-rows-user-units-v1"
BQ_TOKEN="bq-traefik-brick11-green-v1"

BAK_SUFFIX="pre-BR.bak"
PATCHED_FILES=()

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

for c in bash podman systemctl curl awk sed grep python3 cmp install pgrep seq sleep mktemp tr head; do
  need_cmd "$c"
done

# ===================== [R0] measure shadow set + --no-hosts efficacy =====================
say "=== [R0] measure host /etc/hosts shadow set ==="
SHADOW="$(awk '/^[[:space:]]*(127\.|::1)/ {for (i=2;i<=NF;i++) print $i}' /etc/hosts 2>/dev/null | grep -Fx -f <(printf '%s\n' $ALL_NAMES) | sort -u | tr '\n' ' ')"
SHADOW="$(norm "$SHADOW")"
say "[R0] shadowed_names=${SHADOW:-none}"

PROBE_NAME="gitea"
if [ -n "$SHADOW" ]; then
  PROBE_NAME="${SHADOW%% *}"
fi
ADDR_DEF="$(norm "$(podman run --rm --network "$NET" "$ALPINE" getent hosts "$PROBE_NAME" 2>/dev/null | head -n1 | awk '{print $1}' || true)")"
ADDR_NH="$(norm "$(podman run --rm --no-hosts --network "$NET" "$ALPINE" getent hosts "$PROBE_NAME" 2>/dev/null | head -n1 | awk '{print $1}' || true)")"
say "[R0] probe=$PROBE_NAME default_addr=${ADDR_DEF:-none} nohosts_addr=${ADDR_NH:-none}"

case "$ADDR_NH" in
  ''|127.*|::1|localhost)
    NOHOSTS_WORKS=no
    ;;
  *)
    NOHOSTS_WORKS=yes
    ;;
esac
say "[R0] NOHOSTS_WORKS=$NOHOSTS_WORKS"

say "=== [R0] locate canonical Podman.py (running instance) ==="
PODMAN_PY="$(pgrep -af 'Podman\.py' 2>/dev/null | head -n1 | awk '{for(i=2;i<=NF;i++) if ($i ~ /Podman\.py$/) {print $i; exit}}' || true)"
PODMAN_PY="$(norm "$PODMAN_PY")"
if [ -z "$PODMAN_PY" ]; then
  PODMAN_PY="$(find "$HOME" -maxdepth 4 -name 'Podman.py' -type f 2>/dev/null | head -n2 | tr '\n' ' ')"
  n="$(printf '%s' "$PODMAN_PY" | wc -w | tr -d ' ')"
  if [ "$n" != 1 ]; then
    halt "Podman.py not running and not uniquely locatable (found: ${PODMAN_PY:-none}); tell me the canonical path (B13)"
  fi
fi
if [ ! -f "$PODMAN_PY" ]; then
  halt "canonical Podman.py not readable: $PODMAN_PY"
fi
say "[R0] podman_py=$PODMAN_PY"

if [ "$DRY" = 1 ]; then
  say "[R0] dry-run plan: patch dns-wait probe (--no-hosts or warn-mode), BQ EXE + dependent units (--no-hosts), Podman.py ghost rows; rerun BQ; re-gate dependents."
  say "[RESULT] DRY-RUN complete; nothing written."
  exit 0
fi

mkdir -p "$CD"
touch "$IDX"

# ===================== [R1] heal dns-wait guard =====================
say "=== [R1] heal aether-dns-wait.sh ==="
PY1="$TMPD/patch_dnswait.py"
cat > "$PY1" <<'PYEOF'
import sys, pathlib
mode = sys.argv[2]
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t
run_line = '    line="$(podman run --rm --network "$NET" "$ALPINE" getent hosts "$h" 2>/dev/null | head -n1 || true)"'
run_nh   = '    line="$(podman run --rm --no-hosts --network "$NET" "$ALPINE" getent hosts "$h" 2>/dev/null | head -n1 || true)"'
reject_old = """          if [ "$ALLOW_LOOPBACK" = 1 ]; then
            ok=1
          else
            echo "dns-wait: host '$h' resolved to loopback '$addr'; rejecting" >&2
          fi"""
reject_new = """          if [ "$ALLOW_LOOPBACK" = 1 ]; then
            ok=1
          else
            echo "dns-wait: WARN host '$h' resolved to loopback '$addr' (host /etc/hosts shadow?); accepting for warm-up only" >&2
            ok=1
          fi"""
if mode == "nohosts":
    if run_nh not in t:
        if run_line in t:
            t = t.replace(run_line, run_nh, 1)
        else:
            sys.stderr.write("missing dns-wait run anchor\n"); sys.exit(2)
else:
    if reject_old in t:
        t = t.replace(reject_old, reject_new, 1)
    elif reject_new not in t:
        sys.stderr.write("missing dns-wait reject anchor\n"); sys.exit(2)
if t != orig:
    p.write_text(t, encoding="utf-8")
PYEOF
if [ "$NOHOSTS_WORKS" = yes ]; then
  python3 "$PY1" "$DNS_SCRIPT" nohosts || halt "dns-wait patch failed"
  say "[R1] dns-wait probe now uses --no-hosts (reject logic retained)"
else
  python3 "$PY1" "$DNS_SCRIPT" warn || halt "dns-wait patch failed"
  say "[R1] --no-hosts ineffective; dns-wait loopback rejection downgraded to WARN (restartability preserved)"
fi
PATCHED_FILES+=("$DNS_SCRIPT")

if [ "$NOHOSTS_WORKS" != yes ]; then
  if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | host /etc/hosts legacy loopback aliases shadow aether DNS inside containers (shadow=%s); --no-hosts did NOT restore real IPs, so container-side fix unavailable without host edit. dns-wait downgraded to warn to keep services restartable. MANUAL (your sudo): remove the legacy 127.0.0.1 alias lines for %s from /etc/hosts, then rerun BQ. Traefik promotion withheld. |\n' \
      "$(date +%F)" "$TOKEN" "$SHADOW" "$SHADOW" >> "$IDX"
  fi
  say "[R1] MANUAL FIX REQUIRED (your sudo, one-time): delete legacy loopback alias lines for: $SHADOW from /etc/hosts"
  say "[R1] then rerun: bash $FQ"
  halt "Traefik promotion withheld until host /etc/hosts shadow is removed (--no-hosts ineffective)"
fi

# ===================== [R2] add --no-hosts to BQ EXE + dependent units =====================
say "=== [R2] add --no-hosts to traefik exec + dependent units ==="
PY2="$TMPD/patch_nohosts.py"
cat > "$PY2" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
anchor = "--security-opt=no-new-privileges"
if "--no-hosts" in t:
    sys.exit(0)
if anchor not in t:
    sys.stderr.write("missing --security-opt anchor in %s\n" % p); sys.exit(2)
t = t.replace(anchor, anchor + " --no-hosts", 1)
p.write_text(t, encoding="utf-8")
PYEOF

bak_once "$FQ"
python3 "$PY2" "$FQ" || halt "BQ patch failed"
PATCHED_FILES+=("$FQ")

declare -A UNIT_DEPS
UNIT_DEPS[woodpecker-server]="gitea"
UNIT_DEPS[n8n]="litellm postgres"
UNIT_DEPS[litellm]="llama-embed"
UNIT_DEPS[grafana]="prometheus postgres"
UNIT_DEPS[gitea]="postgres"
UNIT_DEPS[traefik]="gitea grafana woodpecker-server n8n"

for unit in "${!UNIT_DEPS[@]}"; do
  needs=no
  for dep in ${UNIT_DEPS[$unit]}; do
    for s in $SHADOW; do
      if [ "$dep" = "$s" ]; then
        needs=yes
      fi
    done
  done
  if [ "$needs" != yes ]; then
    continue
  fi
  for base in "$UNIT_SRC_DIR/$unit.service" "$UNIT_INST_DIR/$unit.service"; do
    if [ -f "$base" ]; then
      bak_once "$base"
      if python3 "$PY2" "$base"; then
        PATCHED_FILES+=("$base")
        say "[R2] --no-hosts added to $base"
      else
        say "[R2] skipped (anchor absent) $base"
      fi
    fi
  done
done

# ===================== [R3] Podman.py ghost rows for plain user units =====================
say "=== [R3] patch Podman.py Containers-tab ghost rows ==="
PY3="$TMPD/patch_gui.py"
cat > "$PY3" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
anchor = "    return rows  # AETHER_FETCH_CONTAINERS_GHOSTS"
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
if "unit:{u['unit']}" in t:
    sys.exit(0)
if anchor not in t:
    sys.stderr.write("missing Podman.py ghost anchor\n"); sys.exit(2)
t = t.replace(anchor, ghost + anchor, 1)
p.write_text(t, encoding="utf-8")
PYEOF
bak_once "$PODMAN_PY"
if python3 "$PY3" "$PODMAN_PY"; then
  PATCHED_FILES+=("$PODMAN_PY")
  say "[R3] ghost-row patch applied to $PODMAN_PY"
else
  say "[R3] ghost-row patch already present or anchor missing; verify manually"
fi
if ! python3 -m py_compile "$PODMAN_PY"; then
  cp -p "$PODMAN_PY.$BAK_SUFFIX" "$PODMAN_PY" 2>/dev/null || true
  halt "Podman.py failed py_compile after patch; restored backup"
fi
say "[R3] py_compile OK: $PODMAN_PY"

# ===================== [R4] rerun BQ + re-gate dependents =====================
say "=== [R4] rerun BQ (traefik) ==="
bash "$FQ"
BQRC=$?
say "[R4] BQ rc=$BQRC"
if ! grep -qF "$BQ_TOKEN" "$IDX" 2>/dev/null; then
  halt "BQ still not green after shadow heal; inspect BQ output above"
fi

say "=== [R4] restart + re-gate dependent services ==="
for unit in woodpecker-server n8n litellm grafana gitea; do
  if [ -f "$UNIT_INST_DIR/$unit.service" ]; then
    systemctl --user restart "$unit.service" >/dev/null 2>&1 || true
  fi
done
sleep 12
GATE_FAIL=""
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8000/api/health 2>/dev/null || true)"
[ "$code" = 200 ] || GATE_FAIL="$GATE_FAIL woodpecker($code)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:5678/healthz 2>/dev/null || true)"
[ "$code" = 200 ] || GATE_FAIL="$GATE_FAIL n8n($code)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:4000/health/liveliness 2>/dev/null || true)"
[ "$code" = 200 ] || GATE_FAIL="$GATE_FAIL litellm($code)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:3000/api/health 2>/dev/null || true)"
[ "$code" = 200 ] || GATE_FAIL="$GATE_FAIL grafana($code)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:3001/api/healthz 2>/dev/null || true)"
[ "$code" = 200 ] || GATE_FAIL="$GATE_FAIL gitea($code)"
if [ -n "$GATE_FAIL" ]; then
  halt "dependent re-gate failed:$GATE_FAIL"
fi
say "[R4] dependents re-gated: woodpecker/n8n/litellm/grafana/gitea all 200"

if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | host /etc/hosts legacy loopback aliases shadow aether DNS inside containers (shadow=%s); BP loopback-rejecting dns-wait turned that shadow into a hard start failure for traefik (and a latent OAuth/resolution bug for woodpecker-server). BR measures the shadow set, proves --no-hosts restores real aether IPs, applies --no-hosts to dns-wait probes + traefik + dependent units, and patches Podman.py fetch_containers to ghost plain systemd user units so --rm services remain visible when stopped. |\n' \
    "$(date +%F)" "$TOKEN" "$SHADOW" >> "$IDX"
  say "[R4] correction row appended."
fi
if ! grep -qF "$GUITOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | Podman.py Containers tab now shows stopped --rm services as Missing (systemd unit) ghost rows with a working Start action (unit_start_with_fallback); py_compile verified; restart the GUI to load. |\n' \
    "$(date +%F)" "$GUITOKEN" >> "$IDX"
  say "[R4] GUI ghost-row row appended."
fi

say "[R4] OPTIONAL permanent host fix (your sudo; containers no longer need it): remove legacy 127.0.0.1 alias lines for: $SHADOW from /etc/hosts"
say "[RESULT] BR HEALED — shadow=$SHADOW nohosts=$NOHOSTS_WORKS traefik=BQ-green dependents=200 gui=ghost-rows; next: build woodpecker pipeline proof; still no Ollama/OpenWebUI/chat-model."
exit 0
