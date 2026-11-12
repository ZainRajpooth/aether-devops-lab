#!/usr/bin/env bash
# 20261029-AE — corrected container->host reachability probe (netavark JSON shape) + evidence-gated
# internal-only rebind of llama-embed IF and ONLY IF containers cannot reach it.
# Owns AD defect: AD parsed CNI plugins[].ipam but netavark emits top-level subnets[]. Prints raw JSON.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks;
# no sudo; no secret echo; no image pull; no ollama/open-webui; exit 0 on every branch.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
SRCD="$A/infra/systemd"
SRCU="$SRCD/llama-embed.service"
SRCU_BAK="$SRCU.pre-AE.bak"
SYSU="$HOME/.config/systemd/user"
DSTU="$SYSU/llama-embed.service"
LLAMA_SERVER="/home/dev/DevOps/neocortex/cpp/llama.cpp/build/bin/llama-server"
MODEL="/home/dev/DevOps/neocortex/models/embedded/nomic-embed-text-v1.5.Q8_0.gguf"
PORT="8081"
NET="aether"
ALPINE="docker.io/library/alpine:latest"
PROBE_NAME="llama-path-probe-$$"
POST_NAME="llama-path-post-$$"
PARSER_TOKEN="netavark-subnets-parser-defect"
RESOLVED_TOKEN="litellm-path-resolved-v2"

TMPD="$(mktemp -d)"
cleanup(){
  podman rm -f "$PROBE_NAME" >/dev/null 2>&1 || true
  podman rm -f "$POST_NAME" >/dev/null 2>&1 || true
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

for c in bash podman curl awk sed python3 grep tr; do
  need_cmd "$c"
done
mkdir -p "$CD" "$SRCD" "$SYSU"
touch "$IDX"

# ===================== [E0] host-side llama-embed sanity (bind-aware) =====================
say "=== [E0] host-side llama-embed sanity (bind-aware) ==="
H_BIND="$(sed -n 's/^ExecStart=.*--host \([^ ]*\).*/\1/p' "$SRCU" 2>/dev/null | head -n1)"
H_BIND="$(norm "$H_BIND")"
if [ -z "$H_BIND" ]; then
  H_BIND="127.0.0.1"
fi
H_HEALTH="$(norm "$(http_code "http://$H_BIND:$PORT/health")")"
H_ACT="$(norm "$(systemctl --user is-active llama-embed.service 2>/dev/null || true)")"
if [ -z "$H_ACT" ]; then
  H_ACT=inactive
fi
say "[E0] llama-embed unit_active=$H_ACT bind=$H_BIND health=$H_HEALTH"
if [ "$H_HEALTH" != 200 ]; then
  halt "llama-embed not healthy on bind $H_BIND (health=$H_HEALTH); fix brick 5 before probing."
fi

# ===================== [E1] backend + version =====================
say "=== [E1] rootless network backend ==="
PVER="$(norm "$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)")"
BACKEND="$(norm "$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)")"
if [ -z "$BACKEND" ]; then
  BACKEND=unknown
fi
say "[E1] podman_version=${PVER:-?} network_backend=$BACKEND"

# ===================== [E2] robust netavark+CNI parse + RAW JSON evidence =====================
say "=== [E2] aether network inspect (netavark subnets[] AND CNI plugins[].ipam) ==="
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing; rerun AA reconcile first."
fi
podman network inspect "$NET" > "$TMPD/net.json" 2>/dev/null || halt "could not inspect $NET"

say "[E2] raw netavark JSON (first 1200 bytes, evidence — no secrets in network inspect):"
head -c 1200 "$TMPD/net.json" | sed 's/^/    /' || true
echo "" >/dev/null 2>&1 || true

PARSE="$TMPD/parse_net.py"
cat > "$PARSE" <<'PYEOF'
import sys, json, ipaddress
data = json.load(open(sys.argv[1]))
if isinstance(data, dict):
    data = [data]
subnet = ""
gateway = ""
shape = "unknown"
for nw in data:
    # netavark shape: top-level "subnets": [{"subnet","gateway","lease_range"}]
    subs = nw.get("subnets") or []
    if subs:
        shape = "netavark"
        for s in subs:
            if not subnet and s.get("subnet"):
                subnet = s["subnet"]
            if not gateway and s.get("gateway"):
                gateway = s["gateway"]
        if subnet and not gateway:
            try:
                gateway = str(next(ipaddress.ip_network(subnet, strict=False).hosts()))
            except Exception:
                pass
        if subnet:
            break
    # CNI shape fallback: plugins[].ipam.ranges[][] with subnet/gateway keys
    for pl in (nw.get("plugins") or []):
        ipam = pl.get("ipam") or {}
        for rng in (ipam.get("ranges") or []):
            for item in (rng or []):
                if not subnet and item.get("subnet"):
                    subnet = item["subnet"]
                    shape = "cni"
                if not gateway and item.get("gateway"):
                    gateway = item["gateway"]
print("SHAPE=%s" % shape)
print("SUBNET=%s" % subnet)
print("GATEWAY=%s" % gateway)
PYEOF

NETV="$(python3 "$PARSE" "$TMPD/net.json" 2>/dev/null || true)"
SHAPE="$(printf '%s\n' "$NETV" | sed -n 's/^SHAPE=//p' | head -n1)"
SUBNET="$(norm "$(printf '%s\n' "$NETV" | sed -n 's/^SUBNET=//p' | head -n1)")"
GATEWAY="$(norm "$(printf '%s\n' "$NETV" | sed -n 's/^GATEWAY=//p' | head -n1)")"
say "[E2] parsed shape=${SHAPE:-?} subnet=${SUBNET:-?} gateway=${GATEWAY:-?}"
if [ -z "$GATEWAY" ]; then
  say "[E2] FULL raw JSON for manual shape read:"
  cat "$TMPD/net.json" | sed 's/^/    /' || true
  halt "could not resolve $NET gateway from either netavark or CNI shape; paste [E2] raw JSON."
fi

# ===================== [E3] throwaway container reachability matrix =====================
say "=== [E3] container->host reachability (throwaway alpine on $NET) ==="
PROBE="$TMPD/probe.sh"
cat > "$PROBE" <<'SH'
#!/bin/sh
t() {
  lbl="$1"; url="$2"
  out=$(wget -q -O - --timeout=5 "$url" 2>/dev/null); rc=$?
  len=$(printf '%s' "$out" | wc -c)
  printf 'PROBE %s rc=%s len=%s\n' "$lbl" "$rc" "$len"
}
t hci_health "http://host.containers.internal:__PORT__/health"
t hci_models "http://host.containers.internal:__PORT__/v1/models"
t gw_health  "http://__GW__:__PORT__/health"
t gw_models  "http://__GW__:__PORT__/v1/models"
t lo_health  "http://127.0.0.1:__PORT__/health"
SH
sed -i "s|__GW__|$GATEWAY|g; s|__PORT__|$PORT|g" "$PROBE"

COUT="$TMPD/container.out"
podman run --rm --name "$PROBE_NAME" --network "$NET" \
  -v "$PROBE:/probe.sh:ro" \
  "$ALPINE" sh /probe.sh >"$COUT" 2>"$TMPD/container.err"
CRC=$?
if [ "$CRC" != 0 ]; then
  say "[E3] probe container rc=$CRC stderr:"
  tail -n 8 "$TMPD/container.err" 2>/dev/null | sed 's/^/    /' || true
fi
say "[E3] container probe lines:"
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
say "[E3] matrix hci_health=${HCI_H:-?} hci_models=${HCI_M:-?} gw_health=${GW_H:-?} gw_models=${GW_M:-?} lo_health=${LO_H:-?} (0=reachable)"

# ===================== [E4] decide + conditional internal-only rebind =====================
say "=== [E4] upstream decision ==="
UPSTREAM=""
RETROFIT="no"
BASIS=""
if [ "$HCI_H" = 0 ] && [ "$HCI_M" = 0 ]; then
  UPSTREAM="http://host.containers.internal:$PORT/v1"
  BASIS="container reaches loopback-bound llama-embed via host.containers.internal; brick 5 left pristine on 127.0.0.1"
elif [ "$GW_H" = 0 ] && [ "$GW_M" = 0 ]; then
  UPSTREAM="http://$GATEWAY:$PORT/v1"
  BASIS="container reaches llama-embed via aether gateway; brick 5 left pristine"
else
  RETROFIT="yes"
  BASIS="neither host.containers.internal nor gateway reached loopback-bound llama-embed; rebinding --host $GATEWAY (internal-only bridge IP, NOT 0.0.0.0)"
fi
say "[E4] retrofit=$RETROFIT basis=$BASIS"

if [ "$RETROFIT" = yes ] && [ "$DRY" = 0 ]; then
  say "=== [E5] internal-only rebind of llama-embed to aether gateway ==="
  if [ -f "$SRCU" ] && [ ! -f "$SRCU_BAK" ]; then
    cp -p "$SRCU" "$SRCU_BAK"
    say "[E5] unit backup -> $SRCU_BAK"
  fi
  systemctl --user stop llama-embed.service >/dev/null 2>&1 || true
  sleep 1
  # Recompose ExecStart from the SAME capability-probed flags, only --host changed to the gateway.
  EMBED_FLAG="--embedding"
  NEW_EXEC="$LLAMA_SERVER --model $MODEL --host $GATEWAY --port $PORT $EMBED_FLAG --pooling mean --ctx-size 2048 --threads 2 --parallel 1 --alias nomic-embed-text"
  cat > "$SRCU" <<UNIT
# Brick 5: llama.cpp embedding server (native systemd user service; NOT a container; NOT Ollama).
# AE rebind: --host changed from 127.0.0.1 to the aether gateway $GATEWAY so rootless containers
# (netavark) can reach it via host.containers.internal / gateway. Internal-only bridge IP, NOT 0.0.0.0.
# Cold-boot iface race is absorbed by Restart=always (aether bridge is up via the running core stack).
[Unit]
Description=llama.cpp embedding server (nomic-embed-text-v1.5 Q8_0)
After=network.target

[Service]
Type=simple
ExecStart=$NEW_EXEC
Restart=always
RestartSec=3
TimeoutStartSec=120
MemoryMax=1G
CPUQuota=50%
Nice=10
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
UNIT
  install -D -m 644 "$SRCU" "$DSTU"
  systemctl --user daemon-reload || halt "[E5] daemon-reload failed after rebind"
  systemctl --user start llama-embed.service || true
  # re-gate on the gateway from the host
  GH=""
  for i in $(seq 1 30); do
    GH="$(norm "$(http_code "http://$GATEWAY:$PORT/health")")"
    if [ "$GH" = 200 ]; then
      break
    fi
    sleep 2
  done
  say "[E5] host->gateway:$PORT/health = ${GH:-000}"
  if [ "$GH" != 200 ]; then
    journalctl --user -u llama-embed.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    cp -p "$SRCU_BAK" "$SRCU" 2>/dev/null || true
    install -D -m 644 "$SRCU" "$DSTU" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user restart llama-embed.service 2>/dev/null || true
    halt "[E5] rebind to gateway did not reach health 200; rolled unit back to loopback."
  fi
  # re-measure FROM A CONTAINER through the new bind (this is the proof the path works end-to-end)
  PROBE2="$TMPD/probe2.sh"
  cat > "$PROBE2" <<'SH2'
#!/bin/sh
gh=$(wget -q -O - --timeout=6 "http://host.containers.internal:__PORT__/health" 2>/dev/null); grc=$?
body=$(wget -q -O - --timeout=20 --header 'Content-Type: application/json' \
  --post-data '{"model":"nomic-embed-text","input":"aether path verify"}' \
  "http://host.containers.internal:__PORT__/v1/embeddings" 2>/dev/null); prc=$?
printf 'POST_HCI rc=%s hci_health_rc=%s\n' "$prc" "$grc"
printf '%s' "$body"
SH2
  sed -i "s|__PORT__|$PORT|g" "$PROBE2"
  P2OUT="$TMPD/post.out"
  podman run --rm --name "$POST_NAME" --network "$NET" \
    -v "$PROBE2:/probe2.sh:ro" \
    "$ALPINE" sh /probe2.sh >"$P2OUT" 2>"$TMPD/post.err"
  P2RC=$?
  HEAD2="$(head -n1 "$P2OUT" 2>/dev/null | sed 's/^/    /')"
  say "[E5] container post-probe rc=$P2RC $HEAD2"
  DIMS="$(tail -n +2 "$P2OUT" 2>/dev/null | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(len(d.get("data",[{}])[0].get("embedding",[])))
except Exception:
    print(0)' 2>/dev/null || echo 0)"
  DIMS="$(norm "$DIMS")"
  case "$DIMS" in ''|*[!0-9]*) DIMS=0 ;; esac
  say "[E5] container->host embeddings dims=$DIMS (expected 768)"
  if [ "$DIMS" -lt 1 ]; then
    cp -p "$SRCU_BAK" "$SRCU" 2>/dev/null || true
    install -D -m 644 "$SRCU" "$DSTU" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user restart llama-embed.service 2>/dev/null || true
    halt "[E5] rebind did not yield a container-reachable embedding vector; rolled unit back to loopback."
  fi
  UPSTREAM="http://host.containers.internal:$PORT/v1"
  say "[E5] rebind verified; containers reach llama-embed via host.containers.internal -> $GATEWAY:$PORT"
fi

if [ "$DRY" = 1 ]; then
  say "[E4-dry] planned UPSTREAM_URL=$UPSTREAM retrofit=$RETROFIT"
  say "[RESULT] DRY-RUN complete; no rebind, no ledger row."
  exit 0
fi

# ===================== [E6] update replay to runtime gateway discovery (survives rebind) =====================
SLUG_REPLAY="20261029-AB-llama-embed.sh"
cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# 20261029-AB-llama-embed.sh — replayable brick 5: ensure unit installed+active, gate /health + /v1/embeddings.
# AE: discovers the bind host at runtime (loopback OR aether gateway) so it survives the internal-only rebind.
set -uo pipefail
A="$HOME/DevOps/aether"
SYSU="$HOME/.config/systemd/user"
SRCU="$A/infra/systemd/llama-embed.service"
PORT=8081
install -D -m 644 "$SRCU" "$SYSU/llama-embed.service"
systemctl --user daemon-reload
systemctl --user enable llama-embed.service >/dev/null 2>&1 || true
systemctl --user start llama-embed.service
BIND="$(sed -n 's/^ExecStart=.*--host \([^ ]*\).*/\1/p' "$SRCU" | head -n1)"
if [ -z "$BIND" ]; then
  BIND="127.0.0.1"
fi
C=""
for i in $(seq 1 30); do
  C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://$BIND:$PORT/health" 2>/dev/null || true)
  if [ "$C" = 200 ]; then
    break
  fi
  sleep 2
done
D=$(curl -s --max-time 30 -X POST "http://$BIND:$PORT/v1/embeddings" -H 'Content-Type: application/json' \
  -d '{"model":"nomic-embed-text","input":"replay"}' 2>/dev/null | python3 -c 'import sys,json
try:
    print(len(json.load(sys.stdin).get("data",[{}])[0].get("embedding",[])))
except Exception:
    print(0)' 2>/dev/null || echo 0)
if [ "$C" = 200 ] && [ "${D:-0}" -gt 0 ]; then
  echo "  [GATE PASS] llama-embed bind=$BIND health=200 dims=$D"
else
  echo "  [GATE FAIL] bind=$BIND health=${C:-000} dims=${D:-0}"
  exit 1
fi
REPLAY
chmod +x "$CD/$SLUG_REPLAY"
say "[E6] replay updated for runtime bind discovery -> codemod/$SLUG_REPLAY"

# ===================== [E7] guarded ledger rows =====================
say "=== [E7] ledger rows ==="
if ! grep -qF "$PARSER_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $PARSER_TOKEN | APPEND-ONLY | AD halted at [D2] subnet=?/gateway=? because it parsed CNI plugins[].ipam but Podman 5.7.0 netavark emits top-level subnets[]. Gate held: zero containers run, zero mutation. AE parses both shapes + prints raw JSON evidence. |" >> "$IDX"
  say "[E7] parser-correction row appended."
else
  say "[E7] parser-correction row already present."
fi
grep -qF "$PARSER_TOKEN" "$IDX" 2>/dev/null && say "[E7] suppression proof: parser sentinel present." || say "[E7] WARNING: parser sentinel missing."

if ! grep -qF "$RESOLVED_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-AE-litellm-path | GATE=PASS | $RESOLVED_TOKEN: backend=$BACKEND shape=${SHAPE:-?} subnet=$SUBNET gateway=$GATEWAY; container matrix hci=$HCI_H/$HCI_M gw=$GW_H/$GW_M lo=$LO_H; retrofit=$RETROFIT; FINAL UPSTREAM_URL=$UPSTREAM; $(if [ "$RETROFIT" = yes ]; then echo "llama-embed rebound --host $GATEWAY internal-only and re-verified from container dims=$DIMS"; else echo "brick 5 left pristine on 127.0.0.1"; fi); replay now discovers bind at runtime; no ollama/open-webui. |" >> "$IDX"
  say "[E7] path-resolved row appended."
else
  say "[E7] path-resolved row already present (guard suppressed)."
fi
grep -qF "$RESOLVED_TOKEN" "$IDX" 2>/dev/null && say "[E7] suppression proof: resolved sentinel present." || say "[E7] WARNING: resolved sentinel missing."

say "[E7] next-turn LiteLLM model_list snippet (embeddings -> llama.cpp via measured path):"
printf '    model_list:\n'
printf '      - model_name: local-embed\n'
printf '        litellm_params:\n'
printf '          model: openai/nomic-embed-text\n'
printf '          api_base: %s\n' "$UPSTREAM"
printf '          api_key: os.environ/LLAMA_EMBED_KEY   # dummy; llama-server needs no auth on internal net\n'

say "[RESULT] LITELLM PATH RESOLVED — UPSTREAM_URL=$UPSTREAM retrofit=$RETROFIT; next brick builds LiteLLM on $NET pointed at llama-embed via this measured+verified path; still no Ollama/OpenWebUI/chat-model."
exit 0
