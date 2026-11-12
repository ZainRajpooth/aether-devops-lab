#!/usr/bin/env bash
# 20261029-AM — promote the AL-proven llama.cpp container runtime to a permanent rootless Podman service.
# Result:
#   systemd user service: llama-embed-container.service
#   Podman container name: llama-embed
#   Podman network: aether
#   host admin endpoint: http://127.0.0.1:8081
#   internal LiteLLM upstream: http://llama-embed:8081/v1
#   native llama-embed.service: stopped/disabled, retained for rollback
# Safety:
#   - no sudo
#   - no ollama
#   - no open-webui
#   - no model download
#   - no secret echo
#   - no public exposure
# Hard rules:
#   - multi-line if/then/fi only
#   - bash -n mandatory before run
#   - no heredoc inside $( )
#   - no backticks
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"

NATIVE_SERVICE="llama-embed"
CONT_SERVICE="llama-embed-container"
CONTAINER_NAME="llama-embed"

NATIVE_UNIT_SRC="$A/infra/systemd/llama-embed.service"
NATIVE_UNIT_INST="$HOME/.config/systemd/user/llama-embed.service"

CONT_UNIT_SRC="$A/infra/systemd/llama-embed-container.service"
CONT_UNIT_INST="$HOME/.config/systemd/user/llama-embed-container.service"
CONT_UNIT_SRC_BAK="$CONT_UNIT_SRC.pre-AM.bak"
CONT_UNIT_INST_BAK="$CONT_UNIT_INST.pre-AM.bak"

RUNTIME_IMAGE="localhost/aether-llama-runtime:glibc-match-v2"
MODEL="/home/dev/DevOps/neocortex/models/embedded/nomic-embed-text-v1.5.Q8_0.gguf"
NET="aether"
PORT="8081"
PROBE_IMAGE="ghcr.io/berriai/litellm:main-latest"

TOKEN="llama-embed-container-promotion-v1"
SLUG_REPLAY="20261029-AM-llama-embed-container-promote-replay.sh"

TMPD="$(mktemp -d)"
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
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true
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
  local s
  s="$(podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=absent
  fi
  printf '%s' "$s"
}
container_image(){
  local s
  s="$(podman inspect "$CONTAINER_NAME" --format '{{.Config.Image}}' 2>/dev/null || true)"
  norm "$s"
}
journal_dump(){
  journalctl --user -u "$CONT_SERVICE.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 90 "$CONTAINER_NAME" 2>&1 | sed 's/^/    c: /' || true
}
rollback_to_native(){
  say "[ROLLBACK] attempting restore native llama-embed.service"
  systemctl --user disable --now "$CONT_SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [ -f "$NATIVE_UNIT_SRC" ]; then
    install -D -m 644 "$NATIVE_UNIT_SRC" "$NATIVE_UNIT_INST" >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
    systemctl --user start "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
    say "[ROLLBACK] native service start attempted"
  else
    say "[ROLLBACK] native unit source missing; cannot auto-rollback"
  fi
}

for c in bash podman systemctl curl awk sed grep python3 df cmp install; do
  need_cmd "$c"
done

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$A/infra/systemd" "$HOME/.config/systemd/user"
touch "$IDX"

# ===================== [M0] preconditions =====================
say "=== [M0] preconditions ==="
if [ ! -f "$NATIVE_UNIT_SRC" ]; then
  halt "native rollback unit source missing: $NATIVE_UNIT_SRC"
fi
if [ ! -s "$MODEL" ]; then
  halt "embedding model missing: $MODEL"
fi
if ! podman image exists "$RUNTIME_IMAGE" 2>/dev/null; then
  halt "proven runtime image missing: $RUNTIME_IMAGE; run AL first"
fi
if ! podman image exists "$PROBE_IMAGE" 2>/dev/null; then
  halt "probe image missing: $PROBE_IMAGE"
fi
if podman network exists "$NET" 2>/dev/null; then
  say "[M0] network present: $NET"
else
  say "[M0] network missing now; generated unit will create it before start"
fi
say "[M0] runtime_image=$RUNTIME_IMAGE"
say "[M0] model=$MODEL"
say "[M0] planned_container_name=$CONTAINER_NAME"
say "[M0] planned_service=$CONT_SERVICE.service"
say "[M0] planned_internal_upstream=http://$CONTAINER_NAME:$PORT/v1"
say "[M0] planned_host_endpoint=http://127.0.0.1:$PORT"

MODEL_DIR="$(dirname "$MODEL")"
MODEL_BASE="$(basename "$MODEL")"
MODEL_CONTAINER="/models/$MODEL_BASE"

# ===================== [M1] helper probe files =====================
cat > "$TMPD/dims.py" <<'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get("data", [{}])[0].get("embedding", [])))
except Exception:
    print(0)
PYEOF

cat > "$TMPD/aether_probe.py" <<'PYEOF'
import sys, json, urllib.request

base = sys.argv[1].rstrip("/")
health = 0
try:
    with urllib.request.urlopen(base + "/health", timeout=15) as r:
        health = r.status
except Exception:
    health = 0

dims = 0
try:
    payload = {"model": "nomic-embed-text", "input": "aether promote network probe"}
    req = urllib.request.Request(
        base + "/v1/embeddings",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        d = json.load(r)
        dims = len(d.get("data", [{}])[0].get("embedding", []))
except Exception:
    dims = 0

print("PROBE health=%s dims=%s" % (health, dims))
PYEOF

chmod 644 "$TMPD/dims.py" "$TMPD/aether_probe.py" 2>/dev/null || true

HOST_DIMS=0
DNS_HEALTH=0
DNS_DIMS=0

host_health_200(){
  local c
  c="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
  if [ "$c" = 200 ]; then
    return 0
  fi
  return 1
}

wait_host_health(){
  local tries="${1:-90}"
  local i c
  for i in $(seq 1 "$tries"); do
    c="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
    if [ "$c" = 200 ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

host_embedding_ok(){
  local body="$TMPD/host-body.json"
  local emb dims
  printf '%s' '{"model":"nomic-embed-text","input":"aether promote host probe"}' > "$body"
  emb="$(curl -s --max-time 60 -X POST "http://127.0.0.1:$PORT/v1/embeddings" -H 'Content-Type: application/json' -d @"$body" 2>/dev/null || true)"
  dims="$(to_int "$(printf '%s' "$emb" | python3 "$TMPD/dims.py" 2>/dev/null || echo 0)")"
  HOST_DIMS="$dims"
  if [ "$dims" -gt 0 ]; then
    return 0
  fi
  printf '%s\n' "$emb" | head -c 700 | sed 's/^/    resp: /' || true
  return 1
}

dns_probe_ok(){
  local tries="${1:-30}"
  local i out err ch dv
  DNS_HEALTH=0
  DNS_DIMS=0
  for i in $(seq 1 "$tries"); do
    out="$TMPD/dns_probe.$i.out"
    err="$TMPD/dns_probe.$i.err"
    if podman run --rm \
      --network "$NET" \
      --security-opt=no-new-privileges \
      -v "$TMPD/aether_probe.py:/probe.py:ro" \
      --entrypoint python3 \
      "$PROBE_IMAGE" \
      /probe.py "http://$CONTAINER_NAME:$PORT" \
      >"$out" 2>"$err"; then
      if grep -q '^PROBE ' "$out" 2>/dev/null; then
        ch="$(to_int "$(sed -n 's/.*health=\([0-9][0-9]*\).*/\1/p' "$out" 2>/dev/null | head -n1)")"
        dv="$(to_int "$(sed -n 's/.*dims=\([0-9][0-9]*\).*/\1/p' "$out" 2>/dev/null | head -n1)")"
        DNS_HEALTH="$ch"
        DNS_DIMS="$dv"
        if [ "$ch" = 200 ] && [ "$dv" -gt 0 ]; then
          return 0
        fi
      fi
    else
      tail -n 5 "$err" 2>/dev/null | sed 's/^/    probe-err: /' || true
    fi
    sleep 3
  done
  return 1
}

container_running_correct(){
  local st im
  st="$(container_status)"
  im="$(container_image)"
  if [ "$st" != running ]; then
    return 1
  fi
  if ! printf '%s' "$im" | grep -qF "$RUNTIME_IMAGE"; then
    return 1
  fi
  return 0
}

wait_port_free(){
  local i c
  for i in $(seq 1 30); do
    c="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
    if [ "$c" = 000 ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ===================== [M2] generate desired unit =====================
say "=== [M2] generate desired llama-embed-container.service ==="
DESIRED_UNIT="$TMPD/llama-embed-container.service.desired"

cat > "$DESIRED_UNIT" <<UNIT
# Brick 5 promoted: llama.cpp embedding server as a rootless Podman container service.
# Container name: $CONTAINER_NAME
# Network: $NET
# Host admin endpoint: http://127.0.0.1:$PORT
# Internal upstream for LiteLLM: http://$CONTAINER_NAME:$PORT/v1
# Native llama-embed.service is intentionally disabled and retained for rollback.

[Unit]
Description=llama.cpp embedding server container (nomic-embed-text-v1.5 Q8_0)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c '$PODMAN_BIN network exists $NET || $PODMAN_BIN network create $NET'
ExecStart=$PODMAN_BIN run --rm \\
  --name $CONTAINER_NAME \\
  --network $NET \\
  --publish 127.0.0.1:$PORT:8081 \\
  --memory 1536m \\
  --security-opt=no-new-privileges \\
  -v $MODEL_DIR:/models:ro \\
  --entrypoint /opt/llama/bin/llama-server \\
  $RUNTIME_IMAGE \\
  --model $MODEL_CONTAINER \\
  --host 0.0.0.0 \\
  --port 8081 \\
  --embedding \\
  --pooling mean \\
  --ctx-size 2048 \\
  --threads 2 \\
  --parallel 1 \\
  --alias nomic-embed-text
Restart=always
RestartSec=3
TimeoutStartSec=180
MemoryMax=2G
CPUQuota=50%
Nice=10
PrivateTmp=yes

Delegate=yes

[Install]
WantedBy=default.target
UNIT

say "[M2] desired unit generated"

if [ "$DRY" = 1 ]; then
  say "[M2] desired unit preview:"
  head -n 80 "$DESIRED_UNIT" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no native stop, no container start, no unit write, no ledger row."
  exit 0
fi

# ===================== [M3] stop native and detect already-promoted state =====================
say "=== [M3] stop/disable native llama-embed and detect existing promotion ==="
systemctl --user disable --now "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true

CONT_ACTIVE="$(active_state "$CONT_SERVICE.service")"
NATIVE_ACTIVE="$(active_state "$NATIVE_SERVICE.service")"
CONTAINER_ST="$(container_status)"
CONTAINER_IM="$(container_image)"
INSTALLED_MATCHES=no

if [ -f "$CONT_UNIT_INST" ] && cmp -s "$DESIRED_UNIT" "$CONT_UNIT_INST"; then
  INSTALLED_MATCHES=yes
fi

say "[M3] container_service_active=$CONT_ACTIVE"
say "[M3] native_service_active=$NATIVE_ACTIVE"
say "[M3] container_status=$CONTAINER_ST"
say "[M3] container_image=$CONTAINER_IM"
say "[M3] installed_unit_matches_desired=$INSTALLED_MATCHES"

PROMOTED_OK=no
if [ "$CONT_ACTIVE" = active ] &&
   [ "$NATIVE_ACTIVE" != active ] &&
   [ "$INSTALLED_MATCHES" = yes ] &&
   container_running_correct &&
   wait_host_health 5 &&
   host_embedding_ok &&
   dns_probe_ok 5
then
  PROMOTED_OK=yes
fi

if [ "$PROMOTED_OK" = yes ]; then
  say "[M3] already promoted and verified; ensuring enabled"
  systemctl --user enable "$CONT_SERVICE.service" >/dev/null 2>&1 || true

  if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
    echo "| $(date +%F) | B | 20261029-AM-llama-embed-container-promote | GATE=PASS | $TOKEN: already-promoted state verified; service=$CONT_SERVICE container=$CONTAINER_NAME network=$NET runtime=$RUNTIME_IMAGE host=http://127.0.0.1:$PORT internal=http://$CONTAINER_NAME:$PORT/v1 host_dims=$HOST_DIMS dns_health=$DNS_HEALTH dns_dims=$DNS_DIMS native=disabled; no model download; no ollama/open-webui. |" >> "$IDX"
    say "[M3] ledger row appended for already-promoted state."
  else
    say "[M3] ledger row already present (guard suppressed)."
  fi
  grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[M3] suppression proof: sentinel present." || say "[M3] WARNING: sentinel missing."

  cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AM: reruns the idempotent promoter/verifier.
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261029-AM-llama-embed-container-promote.sh"
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[M3] replay archived -> codemod/$SLUG_REPLAY"
  say "[RESULT] LLAMA-EMBED CONTAINER ALREADY PROMOTED — service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1; next brick LiteLLM."
  exit 0
fi

# ===================== [M4] mutate to promoted container service =====================
say "=== [M4] install permanent llama-embed-container.service ==="

if [ -f "$CONT_UNIT_SRC" ] && [ ! -f "$CONT_UNIT_SRC_BAK" ]; then
  cp -p "$CONT_UNIT_SRC" "$CONT_UNIT_SRC_BAK"
  say "[M4] container source backup -> $CONT_UNIT_SRC_BAK"
fi

if [ -f "$CONT_UNIT_INST" ] && [ ! -f "$CONT_UNIT_INST_BAK" ]; then
  cp -p "$CONT_UNIT_INST" "$CONT_UNIT_INST_BAK"
  say "[M4] container installed backup -> $CONT_UNIT_INST_BAK"
fi

systemctl --user disable --now "$CONT_SERVICE.service" >/dev/null 2>&1 || true
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

if ! wait_port_free; then
  say "[M4] port $PORT still has a listener after stopping native/container services"
  rollback_to_native
  halt "cannot promote: port 127.0.0.1:$PORT is occupied by an unknown listener"
fi

install -D -m 644 "$DESIRED_UNIT" "$CONT_UNIT_SRC" || {
  rollback_to_native
  halt "could not write container unit source"
}

install -D -m 644 "$CONT_UNIT_SRC" "$CONT_UNIT_INST" || {
  rollback_to_native
  halt "could not install container unit"
}

if ! systemctl --user daemon-reload; then
  rollback_to_native
  halt "systemctl --user daemon-reload failed"
fi

if ! systemctl --user enable "$CONT_SERVICE.service"; then
  journal_dump
  rollback_to_native
  halt "could not enable $CONT_SERVICE.service"
fi

if ! systemctl --user start "$CONT_SERVICE.service"; then
  journal_dump
  rollback_to_native
  halt "could not start $CONT_SERVICE.service"
fi

say "[M4] started $CONT_SERVICE.service"

# ===================== [M5] wait for unit/container =====================
say "=== [M5] wait for unit active and container running ==="
WAIT_OK=no
for i in $(seq 1 60); do
  CONT_ACTIVE="$(active_state "$CONT_SERVICE.service")"
  CONTAINER_ST="$(container_status)"
  if [ "$CONT_ACTIVE" = active ] && [ "$CONTAINER_ST" = running ]; then
    WAIT_OK=yes
    break
  fi
  sleep 2
done

if [ "$WAIT_OK" != yes ]; then
  journal_dump
  rollback_to_native
  halt "container service did not reach active+running"
fi

if ! container_running_correct; then
  journal_dump
  rollback_to_native
  halt "container is running but image/name state does not match proven runtime"
fi

say "[M5] unit_active=active container_status=$(container_status) container_image=$(container_image)"

# ===================== [M6] host gate =====================
say "=== [M6] host loopback gate ==="
if ! wait_host_health 90; then
  journal_dump
  rollback_to_native
  halt "permanent container did not reach /health 200 on 127.0.0.1:$PORT"
fi

if ! host_embedding_ok; then
  journal_dump
  rollback_to_native
  halt "permanent container host embedding probe failed"
fi

say "[M6] host /health=200 host /v1/embeddings dims=$HOST_DIMS"

# ===================== [M7] in-network DNS gate =====================
say "=== [M7] in-network DNS gate ==="
if ! dns_probe_ok 40; then
  journal_dump
  rollback_to_native
  halt "permanent container in-network DNS probe failed for http://$CONTAINER_NAME:$PORT"
fi

say "[M7] in-network http://$CONTAINER_NAME:$PORT health=$DNS_HEALTH dims=$DNS_DIMS"

# ===================== [M8] final state =====================
say "=== [M8] final state ==="
say "[M8] native_service_active=$(active_state "$NATIVE_SERVICE.service") native_service_enabled=$(enabled_state "$NATIVE_SERVICE.service")"
say "[M8] container_service_active=$(active_state "$CONT_SERVICE.service") container_service_enabled=$(enabled_state "$CONT_SERVICE.service")"
say "[M8] container_status=$(container_status)"
say "[M8] container_image=$(container_image)"
podman ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [M9] guarded ledger row =====================
say "=== [M9] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-AM-llama-embed-container-promote | GATE=PASS | $TOKEN: promoted llama-embed to rootless Podman container service; service=$CONT_SERVICE container=$CONTAINER_NAME network=$NET runtime=$RUNTIME_IMAGE host=http://127.0.0.1:$PORT internal_upstream=http://$CONTAINER_NAME:$PORT/v1 host_dims=$HOST_DIMS dns_health=$DNS_HEALTH dns_dims=$DNS_DIMS native_llama_embed=disabled retained for rollback; no model download; no ollama/open-webui. |" >> "$IDX"
  say "[M9] ledger row appended."
else
  say "[M9] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[M9] suppression proof: sentinel present." || say "[M9] WARNING: sentinel missing."

# ===================== [M10] replay archive =====================
cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AM: reruns the idempotent promoter/verifier.
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261029-AM-llama-embed-container-promote.sh"
REPLAY
chmod +x "$CD/$SLUG_REPLAY"
say "[M10] replay archived -> codemod/$SLUG_REPLAY"

say "[RESULT] LLAMA-EMBED CONTAINER PROMOTED — permanent service=$CONT_SERVICE container=$CONTAINER_NAME on network=$NET; host admin=http://127.0.0.1:$PORT; LiteLLM upstream=http://$CONTAINER_NAME:$PORT/v1; native llama-embed disabled for rollback; next brick LiteLLM."
exit 0
