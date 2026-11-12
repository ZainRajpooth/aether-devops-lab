#!/usr/bin/env bash
# 20261030-AW — install LiteLLM as brick 6 using a clean one-line systemd ExecStart.
# Supersedes AU:
#   AU failed because generated ExecStart contained literal backslash-space fragments,
#   causing Podman: parsing reference "\ ": invalid reference format.
# This script:
#   1) verifies llama-embed and aether are healthy;
#   2) writes LiteLLM config and secret env file without echoing secrets;
#   3) generates a clean one-line litellm.service using an argument array;
#   4) stops/cleans known failed LiteLLM state only;
#   5) starts litellm.service;
#   6) verifies:
#        /health/liveliness
#        host embedding round-trip through LiteLLM
#        in-network DNS embedding round-trip through LiteLLM
#   7) appends guarded ledger rows and archives replay.
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama
#   - no open-webui
#   - no secret echo
#   - loopback-only publish
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

SERVICE="litellm"
CONTAINER="litellm"
IMAGE="ghcr.io/berriai/litellm:main-latest"
PORT="4000"
NET="aether"

LLAMA_SERVICE="llama-embed-container"
LLAMA_CONTAINER="llama-embed"
LLAMA_PORT="8081"
LLAMA_UPSTREAM="http://$LLAMA_CONTAINER:$LLAMA_PORT/v1"

MODEL_NAME="local-embed"
UPSTREAM_MODEL="nomic-embed-text"

CFG_DIR="$A/config/litellm"
CONFIG="$CFG_DIR/config.yaml"
CONFIG_BAK="$CONFIG.pre-AW.bak"

SECRET_DIR="$A/secrets"
ENV_FILE="$SECRET_DIR/litellm.env"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/litellm.service"
UNIT_INST="$HOME/.config/systemd/user/litellm.service"
UNIT_SRC_BAK="$UNIT_SRC.pre-AW.bak"
UNIT_INST_BAK="$UNIT_INST.pre-AW.bak"

CORRECTION_TOKEN="au-exec-literal-backslash-defect"
TOKEN="litellm-brick6-clean-exec-v2"
SLUG_REPLAY="20261030-AW-litellm-brick6-clean-exec-replay.sh"

CONFIG_CHANGED=no
UNIT_CHANGED=no
HOST_DIMS=0
DNS_HEALTH=0
DNS_DIMS=0

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
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true
}
read_master_key(){
  awk -F= '/^LITELLM_MASTER_KEY=/{print substr($0, index($0, "=") + 1); exit}' "$ENV_FILE" 2>/dev/null || true
}
listener_pids_on_port(){
  local out=""
  local pat="127\.0\.0\.1:$PORT|\[::1\]:$PORT|\*:$PORT|0\.0\.0\.0:$PORT"

  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltnp 2>/dev/null | grep -E "$pat" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
  fi

  if [ -z "$out" ] && command -v lsof >/dev/null 2>&1; then
    out="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>2 {print $2}' | sort -u || true)"
  fi

  printf '%s\n' "$out" | grep -E '^[0-9]+$' || true
}
pid_cmdline(){
  local pid="$1"
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true
  fi
}
pid_cgroup(){
  local pid="$1"
  if [ -r "/proc/$pid/cgroup" ]; then
    tr '\n' ' ' < "/proc/$pid/cgroup" 2>/dev/null || true
  fi
}
known_litellm_container_exists(){
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}
classify_port_pid(){
  local pid="$1"
  local cmd cg
  cmd="$(pid_cmdline "$pid")"
  cg="$(pid_cgroup "$pid")"

  if printf '%s' "$cg" | grep -q "$SERVICE.service"; then
    printf 'known-service'
    return
  fi

  if printf '%s' "$cg" | grep -q 'libpod'; then
    if known_litellm_container_exists; then
      printf 'known-container'
      return
    fi
  fi

  printf 'unknown'
}
port_owner_report(){
  local pids pid cls
  pids="$(listener_pids_on_port)"

  if [ -z "$pids" ]; then
    printf 'free'
    return
  fi

  while IFS= read -r pid; do
    if [ -z "$pid" ]; then
      continue
    fi

    cls="$(classify_port_pid "$pid")"
    say "[W0] listener pid=$pid class=$cls"
    say "[W0] cmd=$(printf '%s' "$(pid_cmdline "$pid")" | cut -c1-180)"
    say "[W0] cgroup=$(printf '%s' "$(pid_cgroup "$pid")" | cut -c1-220)"

    if [ "$cls" = unknown ]; then
      printf 'unknown'
      return
    fi
  done <<< "$pids"

  printf 'known'
}
wait_tcp_port_free(){
  local p="$1"
  local tries="${2:-30}"
  local i
  for i in $(seq 1 "$tries"); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}
host_liveliness_ok(){
  local mk c
  mk="$(read_master_key)"
  if [ -z "$mk" ]; then
    return 1
  fi

  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $mk" "http://127.0.0.1:$PORT/health/liveliness" 2>/dev/null || true)"
  c="$(norm "$c")"
  if [ "$c" = 200 ]; then
    return 0
  fi

  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/health/liveliness" 2>/dev/null || true)"
  c="$(norm "$c")"
  if [ "$c" = 200 ]; then
    return 0
  fi

  return 1
}
wait_host_liveliness(){
  local tries="${1:-90}"
  local i
  for i in $(seq 1 "$tries"); do
    if host_liveliness_ok; then
      return 0
    fi
    sleep 2
  done
  return 1
}
host_embedding_ok(){
  local mk body emb dims
  mk="$(read_master_key)"
  if [ -z "$mk" ]; then
    return 1
  fi

  body="$TMPD/host-litellm-body.json"
  printf '{"model":"%s","input":"aether litellm AW host probe"}' "$MODEL_NAME" > "$body"

  emb="$(curl -s --max-time 90 -X POST "http://127.0.0.1:$PORT/v1/embeddings" -H "Authorization: Bearer $mk" -H 'Content-Type: application/json' -d @"$body" 2>/dev/null || true)"
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
  local attempt ep out err ch dv

  DNS_HEALTH=0
  DNS_DIMS=0

  for attempt in $(seq 1 "$tries"); do
    for ep in python3 /usr/local/bin/python3 /usr/bin/python3; do
      out="$TMPD/dns_probe.$attempt.$ep.out"
      err="$TMPD/dns_probe.$attempt.$ep.err"

      if podman run --rm \
        --network "$NET" \
        --security-opt=no-new-privileges \
        --env-file "$ENV_FILE" \
        -v "$TMPD/litellm_probe.py:/probe.py:ro" \
        --entrypoint "$ep" \
        "$IMAGE" \
        /probe.py "http://$CONTAINER:$PORT" \
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
        say "    dns-probe-err ep=$ep attempt=$attempt:"
        tail -n 5 "$err" 2>/dev/null | sed 's/^/      /' || true
      fi
    done

    sleep 3
  done

  return 1
}
journal_dump(){
  journalctl --user -u "$SERVICE.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 90 "$CONTAINER" 2>&1 | sed 's/^/    c: /' || true
}
rollback_liteLLM_only(){
  say "[ROLLBACK] stopping/disabling litellm service"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}
already_green(){
  if [ "$CONFIG_CHANGED" = yes ] || [ "$UNIT_CHANGED" = yes ]; then
    return 1
  fi
  if [ "$(active_state "$SERVICE.service")" != active ]; then
    return 1
  fi
  if [ "$(container_status "$CONTAINER")" != running ]; then
    return 1
  fi
  if ! wait_host_liveliness 5; then
    return 1
  fi
  if ! host_embedding_ok; then
    return 1
  fi
  if ! dns_probe_ok 5; then
    return 1
  fi
  return 0
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install tr cut sort uniq seq sleep mktemp; do
  need_cmd "$c"
done

if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
  halt "missing required port diagnostic tool: ss or lsof"
fi

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$CFG_DIR" "$SECRET_DIR" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user"
touch "$IDX"

# ===================== [W0] preconditions =====================
say "=== [W0] preconditions ==="

if ! podman image exists "$IMAGE" 2>/dev/null; then
  halt "LiteLLM image missing: $IMAGE"
fi

if [ "$(active_state "$LLAMA_SERVICE.service")" != active ]; then
  halt "llama-embed service is not active; run AS first"
fi

if [ "$(container_status "$LLAMA_CONTAINER")" != running ]; then
  halt "llama-embed container is not running; run AS first"
fi

LLAMA_HEALTH="$(norm "$(http_code "http://127.0.0.1:$LLAMA_PORT/health")")"
if [ "$LLAMA_HEALTH" != 200 ]; then
  halt "llama-embed health is not 200 on 127.0.0.1:$LLAMA_PORT; got $LLAMA_HEALTH"
fi
say "[W0] llama-embed healthy health=$LLAMA_HEALTH"

if podman network exists "$NET" 2>/dev/null; then
  say "[W0] network present: $NET"
else
  say "[W0] creating network: $NET"
  podman network create "$NET" >/dev/null 2>&1 || halt "could not create network $NET"
fi

PORT_OWNER="$(port_owner_report)"
say "[W0] initial_port_owner=$PORT_OWNER"

cat > "$TMPD/dims.py" <<'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get("data", [{}])[0].get("embedding", [])))
except Exception:
    print(0)
PYEOF

cat > "$TMPD/litellm_probe.py" <<'PYEOF'
import sys, os, json, urllib.request

base = sys.argv[1].rstrip("/")
key = os.environ.get("LITELLM_MASTER_KEY", "")
headers = {"Content-Type": "application/json"}
if key:
    headers["Authorization"] = "Bearer " + key

health = 0
try:
    req = urllib.request.Request(base + "/health/liveliness", headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=15) as r:
        health = r.status
except Exception:
    try:
        with urllib.request.urlopen(base + "/health/liveliness", timeout=15) as r:
            health = r.status
    except Exception:
        health = 0

dims = 0
try:
    payload = {"model": "local-embed", "input": "aether litellm AW network probe"}
    req = urllib.request.Request(
        base + "/v1/embeddings",
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=90) as r:
        d = json.load(r)
        dims = len(d.get("data", [{}])[0].get("embedding", []))
except Exception:
    dims = 0

print("PROBE health=%s dims=%s" % (health, dims))
PYEOF

chmod 644 "$TMPD/dims.py" "$TMPD/litellm_probe.py" 2>/dev/null || true

if [ "$DRY" = 1 ]; then
  say "[W0] dry-run plan:"
  say "    config      -> $CONFIG"
  say "    secret env  -> $ENV_FILE (mode 600, contents not echoed)"
  say "    unit source -> $UNIT_SRC"
  say "    unit inst   -> $UNIT_INST"
  say "    service     -> $SERVICE.service"
  say "    container   -> $CONTAINER"
  say "    host        -> http://127.0.0.1:$PORT"
  say "    internal    -> http://$CONTAINER:$PORT/v1"
  say "    model       -> $MODEL_NAME -> $LLAMA_UPSTREAM"
  say "[RESULT] DRY-RUN complete; no config write, no secret write, no unit write, no service start, no ledger row."
  exit 0
fi

# ===================== [W1] correction ledger =====================
say "=== [W1] correction ledger row ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AU generated litellm.service ExecStart with literal backslash-space fragments from multi-line shell continuation. Podman received a bogus reference and failed with: parsing reference "\\ ": invalid reference format. AW supersedes AU by building ExecStart from a flat argument array with no backslashes. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" >> "$IDX"
  say "[W1] AU ExecStart correction row appended."
else
  say "[W1] AU ExecStart correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[W1] suppression proof: correction sentinel present." || say "[W1] WARNING: correction sentinel missing."

# ===================== [W2] desired LiteLLM config =====================
say "=== [W2] desired LiteLLM config ==="

cat > "$TMPD/config.yaml.desired" <<'YEOF'
model_list:
  - model_name: local-embed
    litellm_params:
      model: openai/nomic-embed-text
      api_base: http://llama-embed:8081/v1
      api_key: os.environ/LLAMA_API_KEY
      drop_params: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

litellm_settings:
  drop_params: true
  num_retries: 1
  request_timeout: 120
YEOF

if [ ! -f "$CONFIG" ] || ! cmp -s "$TMPD/config.yaml.desired" "$CONFIG"; then
  if [ -f "$CONFIG" ] && [ ! -f "$CONFIG_BAK" ]; then
    cp -p "$CONFIG" "$CONFIG_BAK"
    say "[W2] config backup -> $CONFIG_BAK"
  fi

  install -D -m 644 "$TMPD/config.yaml.desired" "$CONFIG" || halt "could not install LiteLLM config"
  CONFIG_CHANGED=yes
  say "[W2] installed LiteLLM config -> $CONFIG"
else
  say "[W2] LiteLLM config already desired -> $CONFIG"
fi

# ===================== [W3] secret env file =====================
say "=== [W3] secret env file ==="

umask 077

if [ ! -f "$ENV_FILE" ]; then
  MASTER_KEY="sk-$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  {
    printf 'LITELLM_MASTER_KEY=%s\n' "$MASTER_KEY"
    printf 'LLAMA_API_KEY=not-needed\n'
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "[W3] created secret env file -> $ENV_FILE (key not echoed)"
else
  chmod 600 "$ENV_FILE" 2>/dev/null || true

  if ! grep -q '^LITELLM_MASTER_KEY=' "$ENV_FILE" 2>/dev/null; then
    MASTER_KEY="sk-$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    printf 'LITELLM_MASTER_KEY=%s\n' "$MASTER_KEY" >> "$ENV_FILE"
    say "[W3] appended missing LITELLM_MASTER_KEY"
  fi

  if ! grep -q '^LLAMA_API_KEY=' "$ENV_FILE" 2>/dev/null; then
    printf 'LLAMA_API_KEY=not-needed\n' >> "$ENV_FILE"
    say "[W3] appended missing LLAMA_API_KEY"
  fi

  say "[W3] secret env file present -> $ENV_FILE"
fi

MK_PRESENT="$(read_master_key)"
if [ -z "$MK_PRESENT" ]; then
  halt "could not read LITELLM_MASTER_KEY from $ENV_FILE"
fi
say "[W3] master key present=yes length=$(printf '%s' "$MK_PRESENT" | wc -c | tr -d ' ')"

# ===================== [W4] desired systemd unit =====================
say "=== [W4] desired litellm.service ==="

LITELLM_ARGS=(
  run --rm --replace
  --name "$CONTAINER"
  --network "$NET"
  --publish "127.0.0.1:$PORT:4000"
  --memory 1536m
  --security-opt=no-new-privileges
  --env-file "$ENV_FILE"
  -v "$CONFIG:/app/config.yaml:ro"
  "$IMAGE"
  --config /app/config.yaml
  --port 4000
  --num_workers 1
)

EXEC="$PODMAN_BIN $(printf '%s ' "${LITELLM_ARGS[@]}")"
EXEC="${EXEC% }"

{
  printf '# Brick 6: LiteLLM gateway as a rootless Podman container service.\n'
  printf '# AW clean ExecStart: flat argument array, no backslash continuations.\n'
  printf '# Container name: %s\n' "$CONTAINER"
  printf '# Network: %s\n' "$NET"
  printf '# Host admin endpoint: http://127.0.0.1:%s\n' "$PORT"
  printf '# Internal upstream for n8n/RAG: http://%s:%s/v1\n' "$CONTAINER" "$PORT"
  printf '# Model: %s -> %s\n' "$MODEL_NAME" "$LLAMA_UPSTREAM"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=LiteLLM gateway (local OpenAI-compatible router)\n'
  printf 'After=network-online.target %s.service\n' "$LLAMA_SERVICE"
  printf 'Wants=network-online.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStart=%s\n' "$EXEC"
  printf 'Restart=always\n'
  printf 'RestartSec=3\n'
  printf 'TimeoutStartSec=180\n'
  printf 'Delegate=yes\n'
  printf '\n'
  printf '[Install]\n'
  printf 'WantedBy=default.target\n'
} > "$TMPD/litellm.service.desired"

if [ ! -f "$UNIT_SRC" ] || ! cmp -s "$TMPD/litellm.service.desired" "$UNIT_SRC"; then
  if [ -f "$UNIT_SRC" ] && [ ! -f "$UNIT_SRC_BAK" ]; then
    cp -p "$UNIT_SRC" "$UNIT_SRC_BAK"
    say "[W4] unit source backup -> $UNIT_SRC_BAK"
  fi

  install -D -m 644 "$TMPD/litellm.service.desired" "$UNIT_SRC" || halt "could not write litellm unit source"
  UNIT_CHANGED=yes
  say "[W4] installed litellm unit source -> $UNIT_SRC"
else
  say "[W4] litellm unit source already desired -> $UNIT_SRC"
fi

if [ ! -f "$UNIT_INST" ] || ! cmp -s "$UNIT_SRC" "$UNIT_INST"; then
  if [ -f "$UNIT_INST" ] && [ ! -f "$UNIT_INST_BAK" ]; then
    cp -p "$UNIT_INST" "$UNIT_INST_BAK"
    say "[W4] unit installed backup -> $UNIT_INST_BAK"
  fi

  install -D -m 644 "$UNIT_SRC" "$UNIT_INST" || halt "could not install litellm unit"
  UNIT_CHANGED=yes
  say "[W4] installed litellm unit -> $UNIT_INST"
else
  say "[W4] litellm installed unit already desired -> $UNIT_INST"
fi

# ===================== [W5] already green? =====================
if already_green; then
  say "[W5] already promoted and verified; ensuring enabled"
  systemctl --user enable "$SERVICE.service" >/dev/null 2>&1 || true

  if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | B | 20261030-AW-litellm-brick6-clean-exec | GATE=PASS | %s: already-promoted LiteLLM state verified; service=%s container=%s network=%s image=%s host=http://127.0.0.1:%s internal_upstream=http://%s:%s/v1 model=%s upstream=%s host_dims=%s dns_health=%s dns_dims=%s; no db; no ollama/open-webui; no secret echo. |\n' \
      "$(date +%F)" \
      "$TOKEN" \
      "$SERVICE" \
      "$CONTAINER" \
      "$NET" \
      "$IMAGE" \
      "$PORT" \
      "$CONTAINER" \
      "$PORT" \
      "$MODEL_NAME" \
      "$LLAMA_UPSTREAM" \
      "$HOST_DIMS" \
      "$DNS_HEALTH" \
      "$DNS_DIMS" >> "$IDX"
    say "[W5] ledger row appended for already-promoted state."
  else
    say "[W5] ledger row already present (guard suppressed)."
  fi
  grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[W5] suppression proof: sentinel present." || say "[W5] WARNING: sentinel missing."

  cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AW: reruns the idempotent clean LiteLLM promoter/verifier.
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261030-AW-litellm-brick6-clean-exec.sh"
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[W5] replay archived -> codemod/$SLUG_REPLAY"
  say "[RESULT] LITELLM ALREADY GREEN — service=$SERVICE container=$CONTAINER internal_upstream=http://$CONTAINER:$PORT/v1 model=$MODEL_NAME -> $LLAMA_UPSTREAM; next: build n8n or rag pilot."
  exit 0
fi

# ===================== [W6] clean known LiteLLM state =====================
say "=== [W6] clean known LiteLLM state ==="

PORT_OWNER="$(port_owner_report)"
say "[W6] pre_cleanup_port_owner=$PORT_OWNER"

if [ "$PORT_OWNER" = unknown ]; then
  halt "port 127.0.0.1:$PORT is occupied by an unknown process; not killing it blindly"
fi

if [ "$PORT_OWNER" = known ]; then
  say "[W6] stopping known litellm state"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

if ! wait_tcp_port_free "$PORT" 30; then
  PORT_OWNER="$(port_owner_report)"
  say "[W6] post_cleanup_port_owner=$PORT_OWNER"
  halt "port 127.0.0.1:$PORT remains occupied after known-state cleanup"
fi

say "[W6] port 127.0.0.1:$PORT is free"

# ===================== [W7] start LiteLLM service =====================
say "=== [W7] start litellm.service ==="

"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true

if ! systemctl --user daemon-reload; then
  rollback_liteLLM_only
  halt "systemctl --user daemon-reload failed"
fi

if ! systemctl --user enable "$SERVICE.service"; then
  journal_dump
  rollback_liteLLM_only
  halt "could not enable $SERVICE.service"
fi

if ! systemctl --user start "$SERVICE.service"; then
  journal_dump
  rollback_liteLLM_only
  halt "could not start $SERVICE.service"
fi

say "[W7] started $SERVICE.service"

# ===================== [W8] wait for unit/container =====================
say "=== [W8] wait for unit active and container running ==="
WAIT_OK=no
for i in $(seq 1 60); do
  if [ "$(active_state "$SERVICE.service")" = active ] &&
     [ "$(container_status "$CONTAINER")" = running ]; then
    WAIT_OK=yes
    break
  fi
  sleep 2
done

if [ "$WAIT_OK" != yes ]; then
  journal_dump
  rollback_liteLLM_only
  halt "litellm service did not reach active+running"
fi

say "[W8] unit_active=active container_status=$(container_status "$CONTAINER")"

# ===================== [W9] host liveliness gate =====================
say "=== [W9] host liveliness gate ==="
if ! wait_host_liveliness 90; then
  journal_dump
  rollback_liteLLM_only
  halt "litellm did not reach /health/liveliness 200 on 127.0.0.1:$PORT"
fi

say "[W9] host /health/liveliness=200"

# ===================== [W10] host embedding gate through LiteLLM =====================
say "=== [W10] host embedding gate through LiteLLM ==="
if ! host_embedding_ok; then
  journal_dump
  rollback_liteLLM_only
  halt "host embedding round-trip through LiteLLM failed"
fi

say "[W10] host /v1/embeddings through LiteLLM dims=$HOST_DIMS"

# ===================== [W11] in-network DNS embedding gate =====================
say "=== [W11] in-network DNS embedding gate ==="
if ! dns_probe_ok 40; then
  journal_dump
  rollback_liteLLM_only
  halt "in-network embedding round-trip through LiteLLM failed for http://$CONTAINER:$PORT"
fi

say "[W11] in-network http://$CONTAINER:$PORT health=$DNS_HEALTH dims=$DNS_DIMS"

# ===================== [W12] final state =====================
say "=== [W12] final state ==="
say "[W12] service_active=$(active_state "$SERVICE.service") service_enabled=$(enabled_state "$SERVICE.service")"
say "[W12] container_status=$(container_status "$CONTAINER")"
say "[W12] host_endpoint=http://127.0.0.1:$PORT"
say "[W12] internal_upstream=http://$CONTAINER:$PORT/v1"
say "[W12] model=$MODEL_NAME -> $LLAMA_UPSTREAM"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [W13] guarded ledger row =====================
say "=== [W13] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-AW-litellm-brick6-clean-exec | GATE=PASS | %s: installed LiteLLM as rootless Podman container service using clean one-line ExecStart; service=%s container=%s network=%s image=%s host=http://127.0.0.1:%s internal_upstream=http://%s:%s/v1 model=%s upstream=%s host_dims=%s dns_health=%s dns_dims=%s; no db; no ollama/open-webui; no secret echo; loopback-only publish. |\n' \
    "$(date +%F)" \
    "$TOKEN" \
    "$SERVICE" \
    "$CONTAINER" \
    "$NET" \
    "$IMAGE" \
    "$PORT" \
    "$CONTAINER" \
    "$PORT" \
    "$MODEL_NAME" \
    "$LLAMA_UPSTREAM" \
    "$HOST_DIMS" \
    "$DNS_HEALTH" \
    "$DNS_DIMS" >> "$IDX"
  say "[W13] ledger row appended."
else
  say "[W13] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[W13] suppression proof: sentinel present." || say "[W13] WARNING: sentinel missing."

# ===================== [W14] replay archive =====================
cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AW: reruns the idempotent clean LiteLLM promoter/verifier.
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261030-AW-litellm-brick6-clean-exec.sh"
REPLAY
chmod +x "$CD/$SLUG_REPLAY"
say "[W14] replay archived -> codemod/$SLUG_REPLAY"

say "[RESULT] LITELLM BRICK 6 GREEN — service=$SERVICE container=$CONTAINER on network=$NET; host admin=http://127.0.0.1:$PORT; internal upstream=http://$CONTAINER:$PORT/v1; model=$MODEL_NAME -> $LLAMA_UPSTREAM; functional embedding round-trip passed through LiteLLM; next: build n8n or rag pilot; still no Ollama/OpenWebUI/chat-model."
exit 0
