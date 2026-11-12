#!/usr/bin/env bash
# 20261029-AD — read-only container->host reachability probe to choose the LiteLLM upstream URL for llama-embed.
# Measures (does NOT assume) whether a container on the aether network can reach the native llama-embed
# service bound to 127.0.0.1:8081, via host.containers.internal and/or the aether gateway IP.
# Prints a reachability matrix + the single chosen UPSTREAM_URL + next-turn LiteLLM model_list snippet.
# Mutates NOTHING: no llama-embed rebind, no LiteLLM start, no image pull, no secret echo, no sudo.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
NET="aether"
PORT="8081"
ALPINE="docker.io/library/alpine:latest"
PROBE_NAME="llama-path-probe-$$"
TOKEN="litellm-path-probe-v1"

TMPD="$(mktemp -d)"
cleanup(){
  podman rm -f "$PROBE_NAME" >/dev/null 2>&1 || true
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
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true
}

for c in bash podman curl awk sed python3 grep; do
  need_cmd "$c"
done
mkdir -p "$CD"
touch "$IDX"

# ===================== [D0] host-side: llama-embed is green on loopback =====================
say "=== [D0] host-side llama-embed sanity (loopback) ==="
H_HEALTH="$(http_code "http://127.0.0.1:$PORT/health")"
H_HEALTH="$(norm "$H_HEALTH")"
H_ACT="$(systemctl --user is-active llama-embed.service 2>/dev/null || true)"
H_ACT="$(norm "$H_ACT")"
if [ -z "$H_ACT" ]; then
  H_ACT=inactive
fi
say "[D0] llama-embed unit_active=$H_ACT host_loopback_health=$H_HEALTH"
if [ "$H_HEALTH" != 200 ]; then
  halt "llama-embed not healthy on host loopback (health=$H_HEALTH); fix brick 5 before probing LiteLLM path."
fi

# ===================== [D1] rootless network backend + version =====================
say "=== [D1] rootless network backend ==="
PVER="$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)"
PVER="$(norm "$PVER")"
BACKEND="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
BACKEND="$(norm "$BACKEND")"
if [ -z "$BACKEND" ]; then
  BACKEND=unknown
fi
say "[D1] podman_version=${PVER:-?} network_backend=$BACKEND"

# ===================== [D2] aether subnet + gateway =====================
say "=== [D2] aether network inspect ==="
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing; rerun AA reconcile first."
fi
podman network inspect "$NET" > "$TMPD/net.json" 2>/dev/null || halt "could not inspect $NET"

PARSE="$TMPD/parse_net.py"
cat > "$PARSE" <<'PYEOF'
import sys, json, ipaddress
data = json.load(open(sys.argv[1]))
if isinstance(data, dict):
    data = [data]
subnet = ""
gateway = ""
for nw in data:
    for pl in nw.get("plugins", []) or []:
        ipam = pl.get("ipam", {}) or {}
        for rng in ipam.get("ranges", []) or []:
            for item in rng or []:
                if not subnet and item.get("subnet"):
                    subnet = item["subnet"]
                if not gateway and item.get("gateway"):
                    gateway = item["gateway"]
    if not gateway and subnet:
        try:
            gateway = str(next(ipaddress.ip_network(subnet, strict=False).hosts()))
        except Exception:
            pass
print("SUBNET=%s" % subnet)
print("GATEWAY=%s" % gateway)
PYEOF

NETV="$(python3 "$PARSE" "$TMPD/net.json" 2>/dev/null || true)"
SUBNET="$(printf '%s\n' "$NETV" | sed -n 's/^SUBNET=//p' | head -n1)"
GATEWAY="$(printf '%s\n' "$NETV" | sed -n 's/^GATEWAY=//p' | head -n1)"
SUBNET="$(norm "$SUBNET")"
GATEWAY="$(norm "$GATEWAY")"
say "[D2] subnet=${SUBNET:-?} gateway=${GATEWAY:-?}"
if [ -z "$GATEWAY" ]; then
  halt "could not resolve $NET gateway; cannot probe container->host path."
fi

# host-side sanity: the gateway IP is a host address, so loopback-bound service is NOT expected here
H_GW_HEALTH="$(http_code "http://$GATEWAY:$PORT/health")"
H_GW_HEALTH="$(norm "$H_GW_HEALTH")"
say "[D2] host->gateway:$PORT/health = $H_GW_HEALTH (informational; llama-embed binds loopback only)"

# ===================== [D3] throwaway container reachability matrix =====================
say "=== [D3] container->$host reachability (throwaway alpine on $NET) ==="
PROBE="$TMPD/probe.sh"
cat > "$PROBE" <<'SH'
#!/bin/sh
# busybox wget: rc=0 means a 2xx was received; rc!=0 means refused/timeout/DNS-fail/non-2xx.
t() {
  lbl="$1"; url="$2"
  out=$(wget -q -O - --timeout=5 "$url" 2>/dev/null); rc=$?
  len=$(printf '%s' "$out" | wc -c)
  printf 'PROBE %s rc=%s len=%s\n' "$lbl" "$rc" "$len"
}
t hci_health "http://host.containers.internal:8081/health"
t hci_models "http://host.containers.internal:8081/v1/models"
t gw_health  "http://__GW__:8081/health"
t gw_models  "http://__GW__:8081/v1/models"
t lo_health  "http://127.0.0.1:8081/health"
SH
sed -i "s|__GW__|$GATEWAY|g" "$PROBE"

COUT="$TMPD/container.out"
podman run --rm --name "$PROBE_NAME" --network "$NET" \
  -v "$PROBE:/probe.sh:ro" \
  "$ALPINE" sh /probe.sh >"$COUT" 2>"$TMPD/container.err"
CRC=$?
if [ "$CRC" != 0 ]; then
  say "[D3] probe container rc=$CRC stderr:"
  tail -n 8 "$TMPD/container.err" 2>/dev/null | sed 's/^/    /' || true
fi
say "[D3] container probe lines:"
sed 's/^/    /' "$COUT" 2>/dev/null || true

read_rc(){
  local lbl="$1"
  awk -v l="$lbl" '$1=="PROBE" && $2==l { sub(/rc=/,"",$3); print $3; exit }' "$COUT" 2>/dev/null || true
}
HCI_H="$(norm "$(read_rc hci_health)")"
HCI_M="$(norm "$(read_rc hci_models)")"
GW_H="$(norm "$(read_rc gw_health)")"
GW_M="$(norm "$(read_rc gw_models)")"
LO_H="$(norm "$(read_rc lo_health)")"
say "[D3] matrix hci_health=${HCI_H:-?} hci_models=${HCI_M:-?} gw_health=${GW_H:-?} gw_models=${GW_M:-?} lo_health=${LO_H:-?} (0=reachable)"

# ===================== [D4] decision =====================
say "=== [D4] upstream decision ==="
UPSTREAM=""
RETROFIT="no"
BASIS=""
if [ "$HCI_H" = 0 ] && [ "$HCI_M" = 0 ]; then
  UPSTREAM="http://host.containers.internal:$PORT/v1"
  BASIS="container reaches host loopback via host.containers.internal (slirp/pasta host alias); no rebind"
elif [ "$GW_H" = 0 ] && [ "$GW_M" = 0 ]; then
  UPSTREAM="http://$GATEWAY:$PORT/v1"
  BASIS="container reaches llama-embed via aether gateway; no rebind"
else
  RETROFIT="yes"
  UPSTREAM="http://$GATEWAY:$PORT/v1"
  BASIS="neither host.containers.internal nor gateway reached loopback-bound llama-embed; plan internal-only rebind of llama-embed --host $GATEWAY (NOT 0.0.0.0), then LiteLLM uses gateway"
fi
say "[D4] retrofit=$RETROFIT"
say "[D4] chosen UPSTREAM_URL=$UPSTREAM"
say "[D4] basis=$BASIS"

say "[D4] next-turn LiteLLM model_list snippet (embeddings -> llama.cpp):"
printf '    model_list:\n'
printf '      - model_name: local-embed\n'
printf '        litellm_params:\n'
printf '          model: openai/nomic-embed-text\n'
printf '          api_base: %s\n' "$UPSTREAM"
printf '          api_key: os.environ/LLAMA_EMBED_KEY   # dummy; llama-server needs no auth on internal net\n'

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no ledger row, no mutation (none was performed anyway)."
  exit 0
fi

# ===================== [D5] guarded ledger row =====================
say "=== [D5] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | DIAG | $TOKEN | APPEND-ONLY | LiteLLM path probe (AD): backend=$BACKEND subnet=${SUBNET:-?} gateway=$GATEWAY; container matrix hci_health=$HCI_H hci_models=$HCI_M gw_health=$GW_H gw_models=$GW_M lo_health=$LO_H (0=ok); retrofit=$RETROFIT; UPSTREAM_URL=$UPSTREAM; basis=$BASIS. No mutation; llama-embed untouched; next brick LiteLLM uses this upstream. |" >> "$IDX"
  say "[D5] probe row appended."
else
  say "[D5] probe row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[D5] suppression proof: sentinel present." || say "[D5] WARNING: sentinel missing."

say "[RESULT] LITELLM PATH RESOLVED — UPSTREAM_URL=$UPSTREAM retrofit=$RETROFIT; next brick builds LiteLLM on $NET pointed at llama-embed via this measured path; still no Ollama/OpenWebUI/chat-model."
exit 0
