#!/usr/bin/env bash
# 20261029-AK — heal AJ by matching host glibc version and resolving symlinks in copied runtime.
# Root cause:
#   AJ mounted Ubuntu 24.04 but host has glibc 2.43+ (Ubuntu 25.10/26.04 or similar).
#   Copied runtime used cp -a which preserved symlinks; targets not copied -> ldd "not found".
# This script:
#   1) detects host glibc version and distro;
#   2) selects matching base image (ubuntu:25.10, ubuntu:26.04, debian:sid, or fedora:latest);
#   3) builds copied runtime with cp -L to resolve symlinks;
#   4) starts trial container on aether;
#   5) verifies /health and /v1/embeddings from host and in-network;
#   6) removes trial;
#   7) writes guarded ledger row.
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
LLAMA_BIN="$LLAMA_BIN_DIR/llama-server"
MODEL="/home/dev/DevOps/neocortex/models/embedded/nomic-embed-text-v1.5.Q8_0.gguf"

NET="aether"
PORT="8081"
TRIAL_PORT="18081"
TRIAL_NAME="llama-embed-trial-$$"

PROBE_IMAGE="ghcr.io/berriai/litellm:main-latest"
TOKEN="llama-container-runtime-glibc-match-v1"

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
  if grep -q 'version .* not found' "$f" 2>/dev/null; then
    return 1
  fi
  if grep -q 'statically linked' "$f" 2>/dev/null; then
    return 0
  fi
  if grep -q ' => /' "$f" 2>/dev/null; then
    return 0
  fi
  return 1
}

for c in bash podman curl awk sed grep python3 df ldd dirname basename cp cat lsb_release; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

# ===================== [K0] native llama-embed health =====================
say "=== [K0] native llama-embed health (current bind) ==="
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
say "[K0] native llama-embed healthy bind=$BIND port=$PORT health=$NATIVE_HEALTH"

# ===================== [K1] host dependency + distro detection =====================
say "=== [K1] host dependency + distro detection ==="
HOST_LDD="$TMPD/host-ldd.txt"
ldd "$LLAMA_BIN" >"$HOST_LDD" 2>&1 || true
if [ ! -s "$HOST_LDD" ]; then
  halt "host ldd produced no output for $LLAMA_BIN"
fi

HOST_MISSING="$(norm "$(extract_missing "$HOST_LDD")")"
say "[K1] host_ldd_lines=$(wc -l < "$HOST_LDD" 2>/dev/null || echo 0) missing=${HOST_MISSING:-none}"

HOST_GLIBC_VERSION=""
HOST_OPENSSL_VERSION=""
HOST_DISTRO=""

if command -v ldd >/dev/null 2>&1; then
  HOST_GLIBC_VERSION="$(ldd --version 2>&1 | head -n1 | awk '{print $NF}' || true)"
  HOST_GLIBC_VERSION="$(norm "$HOST_GLIBC_VERSION")"
fi

if command -v openssl >/dev/null 2>&1; then
  HOST_OPENSSL_VERSION="$(openssl version 2>/dev/null | awk '{print $2}' || true)"
  HOST_OPENSSL_VERSION="$(norm "$HOST_OPENSSL_VERSION")"
fi

if command -v lsb_release >/dev/null 2>&1; then
  HOST_DISTRO="$(lsb_release -ds 2>/dev/null | tr -d '"' || true)"
  HOST_DISTRO="$(norm "$HOST_DISTRO")"
elif [ -f /etc/os-release ]; then
  HOST_DISTRO="$(. /etc/os-release && printf '%s %s' "$PRETTY_NAME" "$VERSION" || true)"
  HOST_DISTRO="$(norm "$HOST_DISTRO")"
fi

say "[K1] host_distro=${HOST_DISTRO:-unknown}"
say "[K1] host_glibc_version=${HOST_GLIBC_VERSION:-unknown}"
say "[K1] host_openssl_version=${HOST_OPENSSL_VERSION:-unknown}"

# Parse private dirs and files
PARSE_DIRS="$TMPD/parse_private_dirs.py"
cat > "$PARSE_DIRS" <<'PYEOF'
import sys, os, re

path = sys.argv[1]
system_prefixes = ("/lib/", "/usr/lib/", "/lib64/", "/usr/lib64/", "/snap/", "/boot/", "/proc/", "/sys/", "/dev/")
dirs = []
seen = set()

for line in open(path, encoding="utf-8", errors="replace"):
    if "=>" not in line:
        continue
    rhs = line.split("=>", 1)[1].strip()
    if rhs.startswith("not found"):
        continue
    m = re.match(r"^(\S+)", rhs)
    if not m:
        continue
    p = m.group(1)
    if not p.startswith("/"):
        continue
    if any(p.startswith(pref) for pref in system_prefixes):
        continue
    d = os.path.dirname(p)
    if d and d not in seen:
        seen.add(d)
        dirs.append(d)

print("\n".join(dirs))
PYEOF

PARSE_FILES="$TMPD/parse_private_files.py"
cat > "$PARSE_FILES" <<'PYEOF'
import sys, os, re

path = sys.argv[1]
system_prefixes = ("/lib/", "/usr/lib/", "/lib64/", "/usr/lib64/", "/snap/", "/boot/", "/proc/", "/sys/", "/dev/")
files = []
seen = set()

for line in open(path, encoding="utf-8", errors="replace"):
    if "=>" not in line:
        continue
    rhs = line.split("=>", 1)[1].strip()
    if rhs.startswith("not found"):
        continue
    m = re.match(r"^(\S+)", rhs)
    if not m:
        continue
    p = m.group(1)
    if not p.startswith("/"):
        continue
    if any(p.startswith(pref) for pref in system_prefixes):
        continue
    if p not in seen:
        seen.add(p)
        files.append(p)

print("\n".join(files))
PYEOF

if ! python3 "$PARSE_DIRS" "$HOST_LDD" >"$TMPD/private_dirs.txt" 2>"$TMPD/private_dirs.err"; then
  cat "$TMPD/private_dirs.err" 2>/dev/null | sed 's/^/    /' || true
  halt "private dir parser failed"
fi

if ! python3 "$PARSE_FILES" "$HOST_LDD" >"$TMPD/private_files.txt" 2>"$TMPD/private_files.err"; then
  cat "$TMPD/private_files.err" 2>/dev/null | sed 's/^/    /' || true
  halt "private file parser failed"
fi

PRIVATE_DIRS=()
while IFS= read -r d; do
  if [ -n "$d" ] && [ -d "$d" ]; then
    PRIVATE_DIRS+=("$d")
  fi
done < "$TMPD/private_dirs.txt"

PRIVATE_FILES=()
while IFS= read -r f; do
  if [ -n "$f" ] && [ -f "$f" ]; then
    PRIVATE_FILES+=("$f")
  fi
done < "$TMPD/private_files.txt"

say "[K1] private_dirs=${#PRIVATE_DIRS[@]} private_files=${#PRIVATE_FILES[@]}"

# ===================== [K2] disk gate =====================
say "=== [K2] disk gate ==="
FREE_KB="$(to_int "$(free_kb /home)")"
PCT="$(norm "$(used_pct /home)")"
say "[K2] /home avail=$(kb_to_gib "$FREE_KB") used=${PCT:-?}% precheck_min=$(kb_to_gib "$PRECHECK_MIN_KB") reserve_after=$(kb_to_gib "$RESERVE_KB")"
if [ "$FREE_KB" -lt "$PRECHECK_MIN_KB" ]; then
  halt "insufficient free space for runtime proof; free=$(kb_to_gib "$FREE_KB") required_at_least=$(kb_to_gib "$PRECHECK_MIN_KB")"
fi

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no pull, no build, no trial container, no ledger row."
  exit 0
fi

# ===================== [K3] select matching base image =====================
say "=== [K3] select matching base image ==="
BASE_IMAGE=""

# Try ubuntu:26.04 first (if host is Ubuntu 26.04+)
if printf '%s' "$HOST_DISTRO" | grep -qi 'ubuntu.*26'; then
  BASE_IMAGE="docker.io/library/ubuntu:26.04"
elif printf '%s' "$HOST_DISTRO" | grep -qi 'ubuntu.*25'; then
  BASE_IMAGE="docker.io/library/ubuntu:25.10"
elif printf '%s' "$HOST_DISTRO" | grep -qi 'fedora'; then
  BASE_IMAGE="docker.io/library/fedora:latest"
elif printf '%s' "$HOST_DISTRO" | grep -qi 'arch'; then
  BASE_IMAGE="docker.io/library/archlinux:latest"
elif printf '%s' "$HOST_DISTRO" | grep -qi 'debian.*sid'; then
  BASE_IMAGE="docker.io/library/debian:sid"
else
  # Fallback: try ubuntu:25.10, then ubuntu:26.04, then debian:sid
  BASE_IMAGE="docker.io/library/ubuntu:25.10"
fi

say "[K3] selected BASE_IMAGE=$BASE_IMAGE based on host_distro=$HOST_DISTRO"

# ===================== [K4] ensure base image =====================
say "=== [K4] ensure base image ==="
if podman image exists "$BASE_IMAGE" 2>/dev/null; then
  say "[K4] present: $BASE_IMAGE"
else
  say "[K4] pulling $BASE_IMAGE"
  if ! podman pull --quiet "$BASE_IMAGE" >"$TMPD/pull.out" 2>"$TMPD/pull.err"; then
    tail -n 8 "$TMPD/pull.err" 2>/dev/null | sed 's/^/    /' || true
    halt "could not pull $BASE_IMAGE"
  fi
  say "[K4] pulled $BASE_IMAGE"
fi

# ===================== [K5] build copied runtime with symlink resolution =====================
say "=== [K5] build copied runtime with symlink resolution ==="
COPIED_TAG="localhost/aether-llama-runtime:glibc-match-v1"
CTX="$TMPD/runtime-ctx"
mkdir -p "$CTX/bin" "$CTX/lib"
printf 'placeholder\n' > "$CTX/lib/placeholder.txt"

if ! cp -L "$LLAMA_BIN" "$CTX/bin/llama-server"; then
  halt "could not copy llama-server into runtime context"
fi

for f in "${PRIVATE_FILES[@]}"; do
  bn="$(basename "$f")"
  dest="$CTX/lib/$bn"
  if [ ! -e "$dest" ]; then
    cp -L "$f" "$dest" 2>>"$TMPD/copy.err" || cp "$f" "$dest" 2>>"$TMPD/copy.err" || true
  fi
done

cat > "$CTX/Containerfile" <<CFEOF
FROM $BASE_IMAGE
COPY bin/llama-server /opt/llama/bin/llama-server
COPY lib/ /opt/llama/lib/
ENV LD_LIBRARY_PATH=/opt/llama/lib
ENTRYPOINT ["/opt/llama/bin/llama-server"]
CFEOF

if ! podman build --tag "$COPIED_TAG" --file "$CTX/Containerfile" "$CTX" >"$TMPD/build.out" 2>&1; then
  tail -n 30 "$TMPD/build.out" 2>/dev/null | sed 's/^/    /' || true
  halt "podman build failed for $COPIED_TAG"
fi
say "[K5] built $COPIED_TAG"

COPIED_LDD="$TMPD/copied-ldd.txt"
COPIED_PROBE_CMD="if command -v ldd >/dev/null 2>&1; then ldd '/opt/llama/bin/llama-server'; else echo NO_LDD; fi"
podman run --rm \
  --network none \
  --security-opt=no-new-privileges \
  --entrypoint /bin/sh \
  "$COPIED_TAG" \
  -c "$COPIED_PROBE_CMD" >"$COPIED_LDD" 2>&1 || true

COPIED_MISSING="$(norm "$(extract_missing "$COPIED_LDD")")"
say "[K5] copied runtime missing=${COPIED_MISSING:-none}"

if ldd_compatible "$COPIED_LDD"; then
  say "[K5] copied runtime compatible"
else
  say "[K5] copied ldd output:"
  tail -n 40 "$COPIED_LDD" 2>/dev/null | sed 's/^/    /' || true
  halt "no compatible runtime found; copied_missing=${COPIED_MISSING:-none}"
fi

RUNTIME_MODE="copied"
RUNTIME_IMAGE="$COPIED_TAG"
say "[K5] selected RUNTIME_MODE=$RUNTIME_MODE RUNTIME_IMAGE=$RUNTIME_IMAGE"

# ===================== [K6] trial port precheck =====================
say "=== [K6] trial port precheck ==="
PRE_TRIAL="$(norm "$(http_code "http://127.0.0.1:$TRIAL_PORT/health")")"
if [ "$PRE_TRIAL" = 200 ]; then
  halt "trial port 127.0.0.1:$TRIAL_PORT is already occupied; choose another port or stop the occupant deliberately."
fi
say "[K6] trial port free (pre-code=${PRE_TRIAL:-000})"

# ===================== [K7] start trial container =====================
say "=== [K7] start llama-embed trial container on $NET ==="
MODEL_DIR="$(dirname "$MODEL")"
MODEL_BASE="$(basename "$MODEL")"
MODEL_CONTAINER="/models/$MODEL_BASE"

TRIAL_MOUNTS=(-v "$MODEL_DIR:/models:ro")
TRIAL_ENTRY=(--entrypoint /opt/llama/bin/llama-server)

podman run -d \
  --name "$TRIAL_NAME" \
  --network "$NET" \
  --publish "127.0.0.1:$TRIAL_PORT:8081" \
  --memory 1g \
  --security-opt=no-new-privileges \
  "${TRIAL_MOUNTS[@]}" \
  "${TRIAL_ENTRY[@]}" \
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
TRIAL_RC=$?
TRIAL_STARTED=yes

if [ "$TRIAL_RC" != 0 ]; then
  tail -n 15 "$TMPD/trial.err" 2>/dev/null | sed 's/^/    /' || true
  halt "trial container failed to start rc=$TRIAL_RC"
fi
say "[K7] trial container started name=$TRIAL_NAME host_port=$TRIAL_PORT runtime_mode=$RUNTIME_MODE runtime=$RUNTIME_IMAGE"

# ===================== [K8] host-side trial gate =====================
say "=== [K8] host-side trial gate ==="
TH="$(poll_http "http://127.0.0.1:$TRIAL_PORT/health" 200 90 || true)"
say "[K8] trial /health: $TH"
if [ "$TH" != ok ]; then
  podman logs --tail 100 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
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
say "[K8] trial host /v1/embeddings dims=$HOST_DIMS"
if [ "$HOST_DIMS" -lt 1 ]; then
  printf '%s\n' "$HOST_EMB" | head -c 700 | sed 's/^/    resp: /' || true
  podman logs --tail 80 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "trial container host embedding probe returned no vector"
fi

# ===================== [K9] in-network DNS + POST gate =====================
say "=== [K9] in-network trial gate from another container ==="
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
PROBEOK=no
probe_i=0
for ep in python3 /usr/local/bin/python3 /usr/bin/python3; do
  probe_i=$((probe_i + 1))
  POUT="$TMPD/probe.$probe_i.out"
  PERR="$TMPD/probe.$probe_i.err"

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
      say "[K9] probe entrypoint=$ep health=$CH dims=$CD"
      if [ "$CH" = 200 ] && [ "$CD" -gt 0 ]; then
        CONT_HEALTH="$CH"
        CONT_DIMS="$CD"
        PROBEOK=yes
        break
      fi
    fi
  else
    say "[K9] probe entrypoint=$ep failed"
    tail -n 5 "$PERR" 2>/dev/null | sed 's/^/    /' || true
  fi
done

if [ "$PROBEOK" != yes ]; then
  podman logs --tail 100 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "in-network trial probe failed; containers cannot reach $TRIAL_NAME:8081 or embeddings POST failed"
fi

say "[K9] in-network probe passed health=$CONT_HEALTH dims=$CONT_DIMS"

# ===================== [K10] remove trial =====================
say "=== [K10] remove trial container ==="
podman rm -f "$TRIAL_NAME" >/dev/null 2>&1 || true
TRIAL_STARTED=no
say "[K10] trial removed; native llama-embed remains on $BIND:$PORT"

# ===================== [K11] guarded ledger row =====================
say "=== [K11] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | DIAG | $TOKEN | APPEND-ONLY | llama.cpp container runtime glibc-match proof: native bind=$BIND:$PORT remains healthy; host_distro=$HOST_DISTRO host_glibc=$HOST_GLIBC_VERSION host_openssl=$HOST_OPENSSL_VERSION; base_image=$BASE_IMAGE; runtime_mode=$RUNTIME_MODE runtime_image=$RUNTIME_IMAGE; private_dirs=${#PRIVATE_DIRS[@]} private_files=${#PRIVATE_FILES[@]}; host_trial_dims=$HOST_DIMS; in_network_dims=$CONT_DIMS; planned permanent upstream=http://llama-embed:8081/v1; no ollama/open-webui; no model download; trial removed. |" >> "$IDX"
  say "[K11] ledger row appended."
else
  say "[K11] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[K11] suppression proof: sentinel present." || say "[K11] WARNING: sentinel missing."

say "[RESULT] LLAMA CONTAINER RUNTIME PROVEN (GLIBC-MATCH) — built self-contained runtime image $RUNTIME_IMAGE from $BASE_IMAGE matching host glibc $HOST_GLIBC_VERSION; next brick should promote this to permanent llama-embed; LiteLLM upstream will be http://llama-embed:8081/v1."
exit 0
