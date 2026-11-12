#!/usr/bin/env bash
# 20261029-AL — heal AK by adding libgomp1 / OpenMP runtime to the copied llama.cpp container runtime.
# Root cause:
#   AK matched Ubuntu 26.04 and copied private llama .so files, but minimal Ubuntu lacks libgomp.so.1.
# This script:
#   1) verifies native llama-embed is healthy;
#   2) detects host distro/glibc and private llama dependencies;
#   3) builds copied runtime with apt libgomp1;
#   4) falls back to copying host libgomp.so.1 if apt build/install fails;
#   5) starts a throwaway trial container on aether, published only to 127.0.0.1:18081;
#   6) verifies /health and /v1/embeddings from host and from another container on aether;
#   7) removes trial;
#   8) appends guarded ledger rows.
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

APT_TAG="localhost/aether-llama-runtime:glibc-match-v2"
HOSTLIB_TAG="localhost/aether-llama-runtime:glibc-match-v2-hostlib"

CORRECTION_TOKEN="ak-missing-libgomp-runtime-dependency"
TOKEN="llama-container-runtime-libgomp-heal-v2"

PRECHECK_MIN_KB=25165824
RESERVE_KB=20971520

TMPD="$(mktemp -d)"
chmod 755 "$TMPD" 2>/dev/null || true

TRIAL_STARTED=no
HOST_LIBGOMP=""
RUNTIME_MODE=""
RUNTIME_IMAGE=""
BASE_IMAGE=""
USED_TARGET=""
APT_MISSING=""
HOSTLIB_MISSING=""
CONT_HEALTH=0
CONT_DIMS=0
HOST_DIMS=0

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
find_host_libgomp(){
  local p=""
  if command -v ldconfig >/dev/null 2>&1; then
    p="$(ldconfig -p 2>/dev/null | awk '/libgomp\.so\.1/ {print $NF; exit}' || true)"
  fi
  if [ -z "$p" ] || [ ! -e "$p" ]; then
    p="$(find /usr/lib /lib /usr/lib64 /lib64 -maxdepth 4 -name 'libgomp.so.1*' -type f -print 2>/dev/null | head -n1 || true)"
  fi
  norm "$p"
}
probe_runtime_ldd(){
  local img="$1"
  local out="$2"
  podman run --rm \
    --network none \
    --security-opt=no-new-privileges \
    --entrypoint /bin/sh \
    "$img" \
    -c "if command -v ldd >/dev/null 2>&1; then ldd '/opt/llama/bin/llama-server'; else echo NO_LDD; fi" \
    >"$out" 2>&1 || true
}

for c in bash podman curl awk sed grep python3 df ldd dirname basename cp cat find; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

# ===================== [L0] native llama-embed health =====================
say "=== [L0] native llama-embed health (current bind) ==="
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
say "[L0] native llama-embed healthy bind=$BIND port=$PORT health=$NATIVE_HEALTH"

# ===================== [L1] host dependency + distro detection =====================
say "=== [L1] host dependency + distro detection ==="
HOST_LDD="$TMPD/host-ldd.txt"
ldd "$LLAMA_BIN" >"$HOST_LDD" 2>&1 || true
if [ ! -s "$HOST_LDD" ]; then
  halt "host ldd produced no output for $LLAMA_BIN"
fi

HOST_MISSING="$(norm "$(extract_missing "$HOST_LDD")")"
say "[L1] host_ldd_lines=$(wc -l < "$HOST_LDD" 2>/dev/null || echo 0) missing=${HOST_MISSING:-none}"

HOST_GLIBC_VERSION=""
HOST_OPENSSL_VERSION=""
HOST_DISTRO=""

HOST_GLIBC_VERSION="$(ldd --version 2>&1 | head -n1 | awk '{print $NF}' || true)"
HOST_GLIBC_VERSION="$(norm "$HOST_GLIBC_VERSION")"

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

say "[L1] host_distro=${HOST_DISTRO:-unknown}"
say "[L1] host_glibc_version=${HOST_GLIBC_VERSION:-unknown}"
say "[L1] host_openssl_version=${HOST_OPENSSL_VERSION:-unknown}"

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

say "[L1] private_dirs=${#PRIVATE_DIRS[@]} private_files=${#PRIVATE_FILES[@]}"

# ===================== [L2] disk gate =====================
say "=== [L2] disk gate ==="
FREE_KB="$(to_int "$(free_kb /home)")"
PCT="$(norm "$(used_pct /home)")"
say "[L2] /home avail=$(kb_to_gib "$FREE_KB") used=${PCT:-?}% precheck_min=$(kb_to_gib "$PRECHECK_MIN_KB") reserve_after=$(kb_to_gib "$RESERVE_KB")"
if [ "$FREE_KB" -lt "$PRECHECK_MIN_KB" ]; then
  halt "insufficient free space for runtime proof; free=$(kb_to_gib "$FREE_KB") required_at_least=$(kb_to_gib "$PRECHECK_MIN_KB")"
fi

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no pull, no build, no trial container, no ledger row."
  exit 0
fi

# ===================== [L3] reclaim obsolete llama runtime images =====================
say "=== [L3] reclaim obsolete llama runtime images ==="
for old in \
  localhost/aether-llama-runtime:ubuntu24.04-v1 \
  localhost/aether-llama-runtime:copied-v1 \
  localhost/aether-llama-runtime:glibc-match-v1
do
  if podman image exists "$old" 2>/dev/null; then
    podman rmi "$old" >/dev/null 2>&1 || true
    say "[L3] removed old runtime image: $old"
  fi
done

# ===================== [L4] select matching base image =====================
say "=== [L4] select matching base image ==="
if printf '%s' "$HOST_DISTRO" | grep -qi 'ubuntu.*26'; then
  BASE_IMAGE="docker.io/library/ubuntu:26.04"
elif printf '%s' "$HOST_DISTRO" | grep -qi 'ubuntu.*25'; then
  BASE_IMAGE="docker.io/library/ubuntu:25.10"
elif printf '%s' "$HOST_GLIBC_VERSION" | grep -q '^2\.43'; then
  BASE_IMAGE="docker.io/library/ubuntu:26.04"
else
  BASE_IMAGE="docker.io/library/ubuntu:25.10"
fi
say "[L4] selected BASE_IMAGE=$BASE_IMAGE based on host_distro=${HOST_DISTRO:-unknown} host_glibc=${HOST_GLIBC_VERSION:-unknown}"

# ===================== [L5] ensure base image =====================
say "=== [L5] ensure base image ==="
if podman image exists "$BASE_IMAGE" 2>/dev/null; then
  say "[L5] present: $BASE_IMAGE"
else
  say "[L5] pulling $BASE_IMAGE"
  if ! podman pull --quiet "$BASE_IMAGE" >"$TMPD/pull.out" 2>"$TMPD/pull.err"; then
    tail -n 8 "$TMPD/pull.err" 2>/dev/null | sed 's/^/    /' || true
    halt "could not pull $BASE_IMAGE"
  fi
  say "[L5] pulled $BASE_IMAGE"
fi

# ===================== [L6] prepare copied runtime context =====================
say "=== [L6] prepare copied runtime context ==="
CTX="$TMPD/runtime-ctx"
mkdir -p "$CTX/bin" "$CTX/lib"
chmod 755 "$CTX" "$CTX/bin" "$CTX/lib" 2>/dev/null || true
printf 'placeholder\n' > "$CTX/lib/placeholder.txt"

if ! cp -L "$LLAMA_BIN" "$CTX/bin/llama-server"; then
  halt "could not copy llama-server into runtime context"
fi

if [ "${#PRIVATE_FILES[@]}" -gt 0 ]; then
  for f in "${PRIVATE_FILES[@]}"; do
    bn="$(basename "$f")"
    dest="$CTX/lib/$bn"
    if [ ! -e "$dest" ]; then
      if ! cp -L "$f" "$dest" 2>>"$TMPD/copy.err"; then
        if ! cp "$f" "$dest" 2>>"$TMPD/copy.err"; then
          halt "could not copy private dependency: $f"
        fi
      fi
    fi
  done
fi
say "[L6] context prepared: bin=1 lib_files=${#PRIVATE_FILES[@]}"

# ===================== [L7] build apt runtime with libgomp1 =====================
say "=== [L7] build apt runtime with libgomp1 ==="
cat > "$CTX/Containerfile.apt" <<CFEOF
FROM $BASE_IMAGE
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libgomp1 && rm -rf /var/lib/apt/lists/*
COPY bin/llama-server /opt/llama/bin/llama-server
COPY lib/ /opt/llama/lib/
ENV LD_LIBRARY_PATH=/opt/llama/lib:/usr/lib/x86_64-linux-gnu
ENTRYPOINT ["/opt/llama/bin/llama-server"]
CFEOF

APT_LDD="$TMPD/apt-ldd.txt"
if podman build --tag "$APT_TAG" --file "$CTX/Containerfile.apt" "$CTX" >"$TMPD/apt-build.out" 2>&1; then
  say "[L7] built $APT_TAG"
  probe_runtime_ldd "$APT_TAG" "$APT_LDD"
  APT_MISSING="$(norm "$(extract_missing "$APT_LDD")")"
  say "[L7] apt runtime missing=${APT_MISSING:-none}"
  if ldd_compatible "$APT_LDD"; then
    RUNTIME_MODE="apt"
    RUNTIME_IMAGE="$APT_TAG"
    say "[L7] apt runtime compatible"
  else
    say "[L7] apt ldd output:"
    tail -n 40 "$APT_LDD" 2>/dev/null | sed 's/^/    /' || true
  fi
else
  say "[L7] apt build failed"
  tail -n 25 "$TMPD/apt-build.out" 2>/dev/null | sed 's/^/    /' || true
fi

# ===================== [L8] fallback: copy host libgomp.so.1 =====================
if [ -z "$RUNTIME_MODE" ]; then
  say "=== [L8] fallback: copy host libgomp.so.1 into runtime ==="
  HOST_LIBGOMP="$(find_host_libgomp)"
  if [ -z "$HOST_LIBGOMP" ]; then
    halt "apt runtime failed and host libgomp.so.1 could not be located"
  fi
  say "[L8] host_libgomp=$HOST_LIBGOMP"

  if ! cp -L "$HOST_LIBGOMP" "$CTX/lib/libgomp.so.1" 2>>"$TMPD/copy.err"; then
    if ! cp "$HOST_LIBGOMP" "$CTX/lib/libgomp.so.1" 2>>"$TMPD/copy.err"; then
      halt "could not copy host libgomp into runtime context"
    fi
  fi

  cat > "$CTX/Containerfile.hostlib" <<CFEOF
FROM $BASE_IMAGE
COPY bin/llama-server /opt/llama/bin/llama-server
COPY lib/ /opt/llama/lib/
ENV LD_LIBRARY_PATH=/opt/llama/lib:/usr/lib/x86_64-linux-gnu
ENTRYPOINT ["/opt/llama/bin/llama-server"]
CFEOF

  HOSTLIB_LDD="$TMPD/hostlib-ldd.txt"
  if podman build --tag "$HOSTLIB_TAG" --file "$CTX/Containerfile.hostlib" "$CTX" >"$TMPD/hostlib-build.out" 2>&1; then
    say "[L8] built $HOSTLIB_TAG"
    probe_runtime_ldd "$HOSTLIB_TAG" "$HOSTLIB_LDD"
    HOSTLIB_MISSING="$(norm "$(extract_missing "$HOSTLIB_LDD")")"
    say "[L8] hostlib runtime missing=${HOSTLIB_MISSING:-none}"
    if ldd_compatible "$HOSTLIB_LDD"; then
      RUNTIME_MODE="hostlib"
      RUNTIME_IMAGE="$HOSTLIB_TAG"
      say "[L8] hostlib runtime compatible"
    else
      say "[L8] hostlib ldd output:"
      tail -n 40 "$HOSTLIB_LDD" 2>/dev/null | sed 's/^/    /' || true
      halt "no compatible runtime found; apt_missing=${APT_MISSING:-none} hostlib_missing=${HOSTLIB_MISSING:-none}"
    fi
  else
    say "[L8] hostlib build failed"
    tail -n 25 "$TMPD/hostlib-build.out" 2>/dev/null | sed 's/^/    /' || true
    halt "no compatible runtime found; apt_missing=${APT_MISSING:-none}"
  fi
fi

say "[L8] selected RUNTIME_MODE=$RUNTIME_MODE RUNTIME_IMAGE=$RUNTIME_IMAGE"

# ===================== [L9] trial port precheck =====================
say "=== [L9] trial port precheck ==="
PRE_TRIAL="$(norm "$(http_code "http://127.0.0.1:$TRIAL_PORT/health")")"
if [ "$PRE_TRIAL" = 200 ]; then
  halt "trial port 127.0.0.1:$TRIAL_PORT is already occupied; choose another port or stop the occupant deliberately."
fi
say "[L9] trial port free (pre-code=${PRE_TRIAL:-000})"

# ===================== [L10] start trial container =====================
say "=== [L10] start llama-embed trial container on $NET ==="
MODEL_DIR="$(dirname "$MODEL")"
MODEL_BASE="$(basename "$MODEL")"
MODEL_CONTAINER="/models/$MODEL_BASE"

TRIAL_STARTED=yes
podman run -d \
  --name "$TRIAL_NAME" \
  --network "$NET" \
  --publish "127.0.0.1:$TRIAL_PORT:8081" \
  --memory 1536m \
  --security-opt=no-new-privileges \
  -v "$MODEL_DIR:/models:ro" \
  --entrypoint /opt/llama/bin/llama-server \
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

if [ "$TRIAL_RC" != 0 ]; then
  tail -n 15 "$TMPD/trial.err" 2>/dev/null | sed 's/^/    /' || true
  halt "trial container failed to start rc=$TRIAL_RC"
fi
say "[L10] trial container started name=$TRIAL_NAME host_port=$TRIAL_PORT runtime_mode=$RUNTIME_MODE runtime=$RUNTIME_IMAGE"

# ===================== [L11] host-side trial gate =====================
say "=== [L11] host-side trial gate ==="
TH="$(poll_http "http://127.0.0.1:$TRIAL_PORT/health" 200 90 || true)"
say "[L11] trial /health: $TH"
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
say "[L11] trial host /v1/embeddings dims=$HOST_DIMS"
if [ "$HOST_DIMS" -lt 1 ]; then
  printf '%s\n' "$HOST_EMB" | head -c 700 | sed 's/^/    resp: /' || true
  podman logs --tail 80 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "trial container host embedding probe returned no vector"
fi

# ===================== [L12] in-network DNS/IP + POST gate =====================
say "=== [L12] in-network trial gate from another container ==="
if ! podman image exists "$PROBE_IMAGE" 2>/dev/null; then
  podman logs --tail 40 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "probe image missing: $PROBE_IMAGE; cannot verify in-network POST"
fi

TRIAL_IP_RAW="$(podman inspect "$TRIAL_NAME" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null || true)"
TRIAL_IP_RAW="$(norm "$TRIAL_IP_RAW")"
TRIAL_IP="${TRIAL_IP_RAW%% *}"

TARGETS=("$TRIAL_NAME:8081")
if [ -n "$TRIAL_IP" ]; then
  TARGETS+=("$TRIAL_IP:8081")
fi
say "[L12] targets=${TARGETS[*]}"

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
chmod 644 "$TMPD/aether_probe.py"

PROBE_OK=no
probe_i=0
for ep in python3 /usr/local/bin/python3 /usr/bin/python3; do
  probe_i=$((probe_i + 1))
  for target in "${TARGETS[@]}"; do
    POUT="$TMPD/probe.$probe_i.out"
    PERR="$TMPD/probe.$probe_i.err"

    if podman run --rm \
      --network "$NET" \
      --security-opt=no-new-privileges \
      -v "$TMPD/aether_probe.py:/probe.py:ro" \
      --entrypoint "$ep" \
      "$PROBE_IMAGE" \
      /probe.py "http://$target" \
      >"$POUT" 2>"$PERR"; then
      if grep -q '^PROBE ' "$POUT" 2>/dev/null; then
        CH="$(to_int "$(sed -n 's/.*health=\([0-9][0-9]*\).*/\1/p' "$POUT" 2>/dev/null | head -n1)")"
        DV="$(to_int "$(sed -n 's/.*dims=\([0-9][0-9]*\).*/\1/p' "$POUT" 2>/dev/null | head -n1)")"
        say "[L12] probe entrypoint=$ep target=$target health=$CH dims=$DV"
        if [ "$CH" = 200 ] && [ "$DV" -gt 0 ]; then
          CONT_HEALTH="$CH"
          CONT_DIMS="$DV"
          USED_TARGET="$target"
          PROBE_OK=yes
          break 2
        fi
      fi
    else
      say "[L12] probe entrypoint=$ep target=$target failed"
      tail -n 5 "$PERR" 2>/dev/null | sed 's/^/    /' || true
    fi
  done
done

if [ "$PROBE_OK" != yes ]; then
  podman logs --tail 100 "$TRIAL_NAME" 2>&1 | sed 's/^/    j: /' || true
  halt "in-network trial probe failed; containers cannot reach trial or embeddings POST failed"
fi

say "[L12] in-network probe passed target=$USED_TARGET health=$CONT_HEALTH dims=$CONT_DIMS"

# ===================== [L13] remove trial =====================
say "=== [L13] remove trial container ==="
podman rm -f "$TRIAL_NAME" >/dev/null 2>&1 || true
TRIAL_STARTED=no
say "[L13] trial removed; native llama-embed remains on $BIND:$PORT"

# ===================== [L14] guarded ledger rows =====================
say "=== [L14] ledger rows ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $CORRECTION_TOKEN | APPEND-ONLY | AK matched Ubuntu 26.04 and copied private llama .so files but omitted libgomp1/OpenMP runtime; copied runtime ldd failed on libgomp.so.1. AL adds apt libgomp1 with host-library fallback and re-proves container embeddings. |" >> "$IDX"
  say "[L14] AK libgomp correction row appended."
else
  say "[L14] AK libgomp correction row already present."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[L14] suppression proof: correction sentinel present." || say "[L14] WARNING: correction sentinel missing."

if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | DIAG | $TOKEN | APPEND-ONLY | llama.cpp container runtime libgomp heal: native bind=$BIND:$PORT remains healthy; host_distro=${HOST_DISTRO:-unknown} host_glibc=${HOST_GLIBC_VERSION:-unknown} base_image=$BASE_IMAGE; runtime_mode=$RUNTIME_MODE runtime_image=$RUNTIME_IMAGE; host_libgomp=${HOST_LIBGOMP:-none}; private_files=${#PRIVATE_FILES[@]}; host_trial_dims=$HOST_DIMS; in_network_target=${USED_TARGET:-none}; in_network_dims=$CONT_DIMS; planned permanent upstream=http://llama-embed:8081/v1; no ollama/open-webui; no model download; trial removed. |" >> "$IDX"
  say "[L14] ledger row appended."
else
  say "[L14] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[L14] suppression proof: sentinel present." || say "[L14] WARNING: sentinel missing."

say "[RESULT] LLAMA CONTAINER RUNTIME PROVEN (LIBGOMP-HEAL) — runtime_mode=$RUNTIME_MODE image=$RUNTIME_IMAGE; host dims=$HOST_DIMS; in-network dims=$CONT_DIMS; next brick should promote this to permanent llama-embed; LiteLLM upstream will be http://llama-embed:8081/v1."
exit 0
