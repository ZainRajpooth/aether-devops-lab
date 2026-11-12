#!/usr/bin/env bash
# 20261029-AI — prove llama.cpp can run as a Podman container on the aether network.
# Root cause from AH/AE:
#   native host llama-embed binds 127.0.0.1;
#   rootless netavark containers cannot reach host loopback here;
#   host native service cannot bind aether gateway 10.89.0.1.
# This script does NOT promote permanently yet. It:
#   1) verifies native llama-embed is healthy on its current bind;
#   2) pulls/tests a minimal Ubuntu runtime;
#   3) builds a runtime image only if Ubuntu lacks required libs;
#   4) starts a throwaway trial container on aether, host-published only to 127.0.0.1:18081;
#   5) verifies /health and /v1/embeddings from host and from another container on aether;
#   6) removes the trial container;
#   7) writes a guarded ledger row with the measured runtime and planned permanent upstream.
# Safety:
#   - no sudo
#   - no ollama
#   - no open-webui
#   - no model download
#   - no secret echo
#   - no permanent llama-embed replacement in this turn
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

SRCU="$A/infra/systemd/llama-embed.service"
LLAMA_DIR="/home/dev/DevOps/neocortex/cpp/llama.cpp/build"
LLAMA_BIN_DIR="$LLAMA_DIR/bin"
LLAMA_LIB_DIR="$LLAMA_DIR/lib"
LLAMA_BIN="$LLAMA_BIN_DIR/llama-server"
MODEL="/home/dev/DevOps/neocortex/models/embedded/nomic-embed-text-v1.5.Q8_0.gguf"
MODEL_CONTAINER="/models/nomic-embed-text-v1.5.Q8_0.gguf"

NET="aether"
PORT="8081"
TRIAL_PORT="18081"
TRIAL_NAME="llama-embed-trial-$$"

UBUNTU="docker.io/library/ubuntu:24.04"
RUNTIME_BUILD_TAG="localhost/aether-llama-runtime:ubuntu24.04-v1"
PROBE_IMAGE="ghcr.io/berriai/litellm:main-latest"
TOKEN="llama-container-runtime-proof-v1"

# Disk policy: this may pull Ubuntu (~100MiB) and maybe build a small runtime layer.
PRECHECK_MIN_KB=25165824
RESERVE_KB=20971520

TMPD="$(mktemp -d)"
TRIAL_STARTED=no
cleanup(){
  if [ "$TRIAL_STARTED" = yes ]; then
    podman rm -f "$TRIAL_NAME" >/dev/null 2>&1 || true
  fi
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
free_kb(){
  df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'
}
used_pct(){
  df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'
}
kb_to_gib(){
  awk -v k="$(to_int "${1:-0}")" 'BEGIN{printf "%.2fGiB", k/1048576}'
}
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true
}
poll_http(){
  local url="$1"
  local want="$2"
  local tries="$3"
  local i c
  for i in $(seq 1 "$tries"); do
    c="$(norm "$(http_code "$url")")"
    if [ "$c" = "$want" ]; then
      printf 'ok'
      return 0
    fi
    sleep 2
  done
  printf 'fail(last=%s)' "${c:-000}"
  return 1
}
extract_missing(){
  local f="$1"
  if [ -s "$f" ]; then
    awk '/not found/ {print $1}' "$f" 2>/dev/null | sort -u | tr '\n' ' '
  fi
}
ldd_compatible(){
  local f="$1"
  if [ ! -s "$f" ]; then
    return 1
  fi
  if grep -q 'NO_LDD' "$f" 2>/dev/null; then
    return 1
  fi
  if grep -q 'not found' "$f" 2>/dev/null; then
    return 1
  fi
  if grep -Eq 'llama-server|statically linked' "$f" 2>/dev/null; then
    return 0
  fi
  return 1
}
probe_image_runtime(){
  local img="$1"
  local out="$2"
  local mounts=(-v "$LLAMA_BIN_DIR:/llama/bin:ro")
  local env=()

  if [ -d "$LLAMA_LIB_DIR" ]; then
    mounts+=(-v "$LLAMA_LIB_DIR:/llama/lib:ro")
    env+=(-e LD_LIBRARY_PATH=/llama/lib)
  fi

  podman run --rm \
    --network none \
    --security-opt=no-new-privileges \
    "${mounts[@]}" \
    "${env[@]}" \
    --entrypoint /bin/sh \
    "$img" \
    -c 'if command -v ldd >/dev/null 2>&1; then ldd /llama/bin/llama-server; else echo NO_LDD; fi' \
    >"$out" 2>&1
}

for c in bash podman curl awk sed grep python3 df; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

# ===================== [I0] native llama-embed health =====================
say "=== [I0] native llama-embed health (current bind) ==="
if [ ! -f "$SRCU" ]; then
  halt "missing llama-embed unit source: $SRCU"
fi
if [ ! -x "$LLAMA_BIN" ]; then
  halt "missing llama-server binary: $LLAMA_BIN"
fi
if [ ! -s "$MODEL" ]; then
  halt "missing embedding model: $MODEL"
fi

BIND="$(sed -n 's/^ExecStart=.*--host \([^ ]*\).*/\1/p' "$SRCU" 2>/dev/null | head -n1)"
BIND="$(norm "$BIND")"
if [ -z "$BIND" ]; then
  BIND="127.0.0.1"
fi

NATIVE_HEALTH="$(norm "$(http_code "http://$BIND:$PORT/health")")"
if [ "$NATIVE_HEALTH" != 200 ]; then
  systemctl --user restart llama-embed.service >/dev/null 2>&1 || true
  NATIVE_HP="$(poll_http "http://$BIND:$PORT/health" 200 20 || true)"
  if [ "$NATIVE_HP" != ok ]; then
    journalctl --user -u llama-embed.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    halt "native llama-embed is not healthy on bind $BIND:$PORT; fix brick 5 before container proof."
  fi
  NATIVE_HEALTH="200"
fi
say "[I0] native llama-embed healthy bind=$BIND port=$PORT health=$NATIVE_HEALTH"

# ===================== [I1] host dependency evidence =====================
say "=== [I1] host llama-server dependency probe ==="
HOST_LDD="$TMPD/host-ldd.txt"
if [ -d "$LLAMA_LIB_DIR" ]; then
  LD_LIBRARY_PATH="$LLAMA_LIB_DIR" ldd "$LLAMA_BIN" >"$HOST_LDD" 2>&1 || true
else
  ldd "$LLAMA_BIN" >"$HOST_LDD" 2>&1 || true
fi
HOST_MISSING="$(norm "$(extract_missing "$HOST_LDD")")"
say "[I1] host_ldd_lines=$(wc -l < "$HOST_LDD" 2>/dev/null || echo 0) missing=${HOST_MISSING:-none}"
say "[I1] lib_dir_present=$([ -d "$LLAMA_LIB_DIR" ] && echo yes || echo no)"

# ===================== [I2] disk gate =====================
say "=== [I2] disk gate ==="
FREE_KB="$(to_int "$(free_kb /home)")"
PCT="$(norm "$(used_pct /home)")"
say "[I2] /home avail=$(kb_to_gib "$FREE_KB") used=${PCT:-?}% precheck_min=$(kb_to_gib "$PRECHECK_MIN_KB") reserve_after=$(kb_to_gib "$RESERVE_KB")"
if [ "$FREE_KB" -lt "$PRECHECK_MIN_KB" ]; then
  halt "insufficient free space for Ubuntu/runtime proof; free=$(kb_to_gib "$FREE_KB") required_at_least=$(kb_to_gib "$PRECHECK_MIN_KB")"
fi

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no pull, no build, no trial container, no ledger row."
  exit 0
fi

# ===================== [I3] ensure Ubuntu base =====================
say "=== [I3] ensure Ubuntu base image ==="
if podman image exists "$UBUNTU" 2>/dev/null; then
  say "[I3] present: $UBUNTU"
else
  say "[I3] pulling $UBUNTU"
  if ! podman pull --quiet "$UBUNTU" >"$TMPD/pull.out" 2>"$TMPD/pull.err"; then
    tail -n 8 "$TMPD/pull.err" 2>/dev/null | sed 's/^/    /' || true
    halt "could not pull $UBUNTU"
  fi
  say "[I3] pulled $UBUNTU"
fi

# ===================== [I4] probe Ubuntu runtime compatibility =====================
say "=== [I4] probe Ubuntu runtime compatibility ==="
UBUNTU_LDD="$TMPD/ubuntu-ldd.txt"
probe_image_runtime "$UBUNTU" "$UBUNTU_LDD"
UBUNTU_MISSING="$(norm "$(extract_missing "$UBUNTU_LDD")")"
say "[I4] ubuntu_missing=${UBUNTU_MISSING:-none}"

RUNTIME_IMAGE=""
if ldd_compatible "$UBUNTU_LDD"; then
  RUNTIME_IMAGE="$UBUNTU"
  say "[I4] Ubuntu is directly compatible; no build required"
else
  say "[I4] Ubuntu missing libs; building minimal runtime image"
  cat > "$TMPD/Containerfile" <<'CFEOF'
FROM docker.io/library/ubuntu:24.04
RUN apt-get update && \
    for pkg in libc-bin libstdc++6 libgomp1 libatomic1 libblas3 liblapack3 libopenblas0-pthread; do \
      apt-get install -y --no-install-recommends "$pkg" || true; \
    done && \
    rm -rf /var/lib/apt/lists/*
CFEOF

  if ! podman build --tag "$RUNTIME_BUILD_TAG" --file "$TMPD/Containerfile" "$TMPD" >"$TMPD/build.out" 2>&1; then
    tail -n 20 "$TMPD/build.out" 2>/dev/null | sed 's/^/    /' || true
    halt "podman build failed for $RUNTIME_BUILD_TAG"
  fi
  say "[I4] built $RUNTIME_BUILD_TAG"

  RUNTIME_LDD="$TMPD/runtime-ldd.txt"
  probe_image_runtime "$RUNTIME_BUILD_TAG" "$RUNTIME_LDD"
  RUNTIME_MISSING="$(norm "$(extract_missing "$RUNTIME_LDD")")"
  say "[I4] runtime_missing=${RUNTIME_MISSING:-none}"

  if ldd_compatible "$RUNTIME_LDD"; then
    RUNTIME_IMAGE="$RUNTIME_BUILD_TAG"
    say "[I4] built runtime image is compatible"
  else
    say "[I4] runtime ldd output:"
    tail -n 40 "$RUNTIME_LDD" 2>/dev/null | sed 's/^/    /' || true
    halt "no compatible runtime found; missing=${RUNTIME_MISSING:-unknown}"
  fi
fi

say "[I4] selected RUNTIME_IMAGE=$RUNTIME_IMAGE"

# ===================== [I5] trial port precheck =====================
say "=== [I5] trial port precheck ==="
PRE_TRIAL="$(norm "$(http_code "http://127.0.0.1:$TRIAL_PORT/health")")"
if [ "$PRE_TRIAL" = 200 ]; then
  halt "trial port 127.0.0.1:$TRIAL_PORT is already occupied; choose another port or stop the occupant deliberately."
fi
say "[I5] trial port free (pre-code=${PRE_TRIAL:-000})"

# ===================== [I6] start trial container =====================
say "=== [I6] start llama-embed trial container on $NET ==="
MOUNTS=(-v "$LLAMA_BIN_DIR:/llama/bin:ro" -v "$MODEL:$MODEL_CONTAINER:ro")
ENV=()
if [ -d "$LLAMA_LIB_DIR" ]; then
  MOUNTS+=(-v "$LLAMA_LIB_DIR:/llama/lib:ro")
  ENV+=(-e LD_LIBRARY_PATH=/llama/lib)
fi

if [ "${#ENV[@]}" -gt 0 ]; then
  podman run -d \
    --name "$TRIAL_NAME" \
    --network "$NET" \
    --publish "127.0.0.1:$TRIAL_PORT:8081" \
    --memory 1g \
    --security-opt=no-new-privileges \
    "${MOUNTS[@]}" \
    "${ENV[@]}" \
    --entrypoint /llama/bin/llama-server \
    "$RUNTIME_IMAGE" \
    --model "$MODEL_CONTAINER" \
    --host 0.0.0.0 \
    --port 8081 \
    --embedding \
    --pooling mean \
    --ctx-size 2048 \
    --threads 2 \
    --parallel 1 \
    --alias nomic-embed-text \
    >"$TMPD/trial.out" 2>"$TMPD/trial.err"
else
  podman run -d \
    --name "$TRIAL_NAME" \
    --network "$NET" \
    --publish "127.0.0.1:$TRIAL_PORT:8081" \
    --memory 1g \
    --security-opt=no-new-privileges \
    "${MOUNTS[@]}" \
    --entrypoint /llama/bin/llama-server \
    "$RUNTIME_IMAGE" \
    --model "$MODEL_CONTAINER" \
    --host 0.0.0.0 \
    --port 8081 \
    --embedding \
    --pooling mean \
    --ctx-size 2048 \
    --threads 2 \
    --parallel 1 \
    --alias nomic-embed-text \
    >"$TMPD/trial.out" 2>"$TMPD/trial.err"
fi
TRIAL_RC=$?
TRIAL_STARTED=yes

if [ "$TRIAL_RC" != 0 ]; then
  tail -n 12 "$TMPD/trial.err" 2>/dev/null | sed 's/^/    /' || true
  halt "trial container failed to start rc=$TRIAL_RC"
fi
say "[I6] trial container started name=$TRIAL_NAME host_port=$TRIAL_PORT runtime=$RUNTIME_IMAGE"

# ===================== [I7] host-side trial gate =====================
say "=== [I7] host-side trial gate ==="
TH="$(poll_http "http://127.0.0.1:$TRIAL_PORT/health" 200 90 || true)"
say "[I7] trial /health: $TH"
if [ "$TH" != ok ]; then
  podman logs --tail 80 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "trial container did not reach /health 200 on host loopback"
fi

cat > "$TMPD/dims.py" <<'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get("data", [{}])[0].get("embedding", [])))
except Exception:
    print(0)
PYEOF

printf '%s' '{"model":"nomic-embed-text","input":"aether trial host probe"}' > "$TMPD/host-body.json"
HOST_EMB="$(curl -s --max-time 60 -X POST "http://127.0.0.1:$TRIAL_PORT/v1/embeddings" -H 'Content-Type: application/json' -d @"$TMPD/host-body.json" 2>/dev/null || true)"
HOST_DIMS="$(to_int "$(printf '%s' "$HOST_EMB" | python3 "$TMPD/dims.py" 2>/dev/null || echo 0)")"
say "[I7] trial host /v1/embeddings dims=$HOST_DIMS"
if [ "$HOST_DIMS" -lt 1 ]; then
  printf '%s\n' "$HOST_EMB" | head -c 500 | sed 's/^/    resp: /' || true
  podman logs --tail 60 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "trial container host embedding probe returned no vector"
fi

# ===================== [I8] in-network DNS + POST gate =====================
say "=== [I8] in-network trial gate from another container ==="
if ! podman image exists "$PROBE_IMAGE" 2>/dev/null; then
  podman logs --tail 40 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "probe image missing: $PROBE_IMAGE; cannot verify in-network POST"
fi

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
    payload = {"model": "nomic-embed-text", "input": "aether trial network probe"}
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

CONT_HEALTH=0
CONT_DIMS=0
PROBE_OK=no
i=0
for ep in python3 /usr/local/bin/python3 /usr/bin/python3; do
  i=$((i + 1))
  POUT="$TMPD/probe.$i.out"
  PERR="$TMPD/probe.$i.err"

  if podman run --rm \
    --network "$NET" \
    --security-opt=no-new-privileges \
    -v "$TMPD/aether_probe.py:/probe.py:ro" \
    --entrypoint "$ep" \
    "$PROBE_IMAGE" \
    /probe.py "http://$TRIAL_NAME:8081" \
    >"$POUT" 2>"$PERR"; then
    if grep -q '^PROBE ' "$POUT" 2>/dev/null; then
      CH="$(to_int "$(sed -n 's/.*health=\([0-9][0-9]*\).*/\1/p' "$POUT" 2>/dev/null | head -n1)")"
      CD="$(to_int "$(sed -n 's/.*dims=\([0-9][0-9]*\).*/\1/p' "$POUT" 2>/dev/null | head -n1)")"
      say "[I8] probe entrypoint=$ep health=$CH dims=$CD"
      if [ "$CH" = 200 ] && [ "$CD" -gt 0 ]; then
        CONT_HEALTH="$CH"
        CONT_DIMS="$CD"
        PROBE_OK=yes
        break
      fi
    fi
  else
    say "[I8] probe entrypoint=$ep failed"
    tail -n 4 "$PERR" 2>/dev/null | sed 's/^/    /' || true
  fi
done

if [ "$PROBE_OK" != yes ]; then
  podman logs --tail 80 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "in-network trial probe failed; containers cannot reach $TRIAL_NAME:8081 or embeddings POST failed"
fi

say "[I8] in-network probe passed health=$CONT_HEALTH dims=$CONT_DIMS"

# ===================== [I9] remove trial =====================
say "=== [I9] remove trial container ==="
podman rm -f "$TRIAL_NAME" >/dev/null 2>&1 || true
TRIAL_STARTED=no
say "[I9] trial removed; native llama-embed remains on $BIND:$PORT"

# ===================== [I10] guarded ledger row =====================
say "=== [I10] ledger row ==="
UBUNTU_MISSING="$(norm "$(extract_missing "$UBUNTU_LDD")")"
RUNTIME_MISSING=""
if [ "$RUNTIME_IMAGE" = "$RUNTIME_BUILD_TAG" ] && [ -s "$TMPD/runtime-ldd.txt" ]; then
  RUNTIME_MISSING="$(norm "$(extract_missing "$TMPD/runtime-ldd.txt")")"
fi

if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | DIAG | $TOKEN | APPEND-ONLY | llama.cpp container runtime proof: native bind=$BIND:$PORT remains healthy; rootless netavark gateway rebind invalid; selected RUNTIME_IMAGE=$RUNTIME_IMAGE; host_missing=${HOST_MISSING:-none}; ubuntu_missing=${UBUNTU_MISSING:-none}; runtime_missing=${RUNTIME_MISSING:-none}; trial host_port=$TRIAL_PORT health=200 dims=$HOST_DIMS; in-network probe health=$CONT_HEALTH dims=$CONT_DIMS; planned permanent upstream=http://llama-embed:8081/v1; no ollama/open-webui; no model download; trial removed. |" >> "$IDX"
  say "[I10] ledger row appended."
else
  say "[I10] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[I10] suppression proof: sentinel present." || say "[I10] WARNING: sentinel missing."

say "[RESULT] LLAMA CONTAINER RUNTIME PROVEN — existing llama.cpp binary + nomic GGUF can run as a Podman container on $NET; next brick should promote this to permanent llama-embed and disable native loopback service; LiteLLM upstream will be http://llama-embed:8081/v1."
exit 0
