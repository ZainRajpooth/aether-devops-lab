#!/usr/bin/env bash
# 20261029-AR — supersede AM/AQ promotion with empirical clean one-line candidate proof.
# Owns AQ result:
#   --security-opt alone is NOT the blocker; full serving failed under the fuller service shape.
# Strategy:
#   1) if already promoted and verified, exit green;
#   2) preserve native llama-embed as safe floor;
#   3) test throwaway clean one-line systemd user services in ascending isolation order:
#        clean_min              = podman security-opt + memory, systemd minimal Delegate only
#        clean_no_sec           = podman memory, no security-opt
#        clean_no_sec_no_mem    = no security-opt, no podman memory
#        clean_userns_host      = no security-opt, no podman memory, --userns=host
#   4) promote only the first candidate that reaches /health + /v1/embeddings;
#   5) verify host loopback and in-network DNS embeddings;
#   6) reconcile core stack with AA;
#   7) rollback to native if any promotion gate fails.
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
#   - throwaway units/containers cleaned by trap
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
AA="$CD/20261029-AA-green-stack-reconcile.sh"

NATIVE_SERVICE="llama-embed"
CONT_SERVICE="llama-embed-container"
CONTAINER_NAME="llama-embed"

NATIVE_UNIT_SRC="$A/infra/systemd/llama-embed.service"
NATIVE_UNIT_INST="$HOME/.config/systemd/user/llama-embed.service"

CONT_UNIT_SRC="$A/infra/systemd/llama-embed-container.service"
CONT_UNIT_INST="$HOME/.config/systemd/user/llama-embed-container.service"
CONT_UNIT_SRC_BAK="$CONT_UNIT_SRC.pre-AR.bak"
CONT_UNIT_INST_BAK="$CONT_UNIT_INST.pre-AR.bak"

RUNTIME_IMAGE="localhost/aether-llama-runtime:glibc-match-v2"
PROBE_IMAGE="ghcr.io/berriai/litellm:main-latest"
MODEL="/home/dev/DevOps/neocortex/models/embedded/nomic-embed-text-v1.5.Q8_0.gguf"
MODEL_DIR="/home/dev/DevOps/neocortex/models/embedded"
MODEL_BASE="nomic-embed-text-v1.5.Q8_0.gguf"
MODEL_CONTAINER="/models/$MODEL_BASE"

NET="aether"
PORT="8081"
SFX="$$"
SYSU="$HOME/.config/systemd/user"

AR_TOKEN="llama-embed-clean-candidate-promotion-v1"
CORRECTION_TOKEN="aq-full-serving-failure-clean-unit-candidate"
SLUG_REPLAY="20261029-AR-llama-embed-clean-promote-replay.sh"

CANDIDATES=(
  clean_min
  clean_no_sec
  clean_no_sec_no_mem
  clean_userns_host
)

declare -A CAND_RC
declare -A CAND_NU

TMPD="$(mktemp -d)"
TEST_UNITS=()
TEST_CONTAINERS=()

cleanup(){
  local u c
  for u in "${TEST_UNITS[@]}"; do
    systemctl --user disable --now "$u.service" >/dev/null 2>&1 || true
    rm -f "$SYSU/$u.service" 2>/dev/null || true
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  for c in "${TEST_CONTAINERS[@]}"; do
    podman rm -f "$c" >/dev/null 2>&1 || true
  done
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
unit_prop(){
  local unit="$1"
  local prop="$2"
  local v
  v="$(systemctl --user show "$unit" -p "$prop" --value 2>/dev/null || true)"
  v="$(norm "$v")"
  if [ -z "$v" ]; then
    v=unknown
  fi
  printf '%s' "$v"
}
has_newuidmap(){
  local unit="$1"
  if journalctl --user -u "$unit.service" --no-pager 2>/dev/null | grep -q 'newuidmap'; then
    printf 'yes'
  else
    printf 'no'
  fi
}
port_free(){
  local p="$1"
  if (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; then
    return 1
  fi
  return 0
}
pick_free_port_from(){
  local start="$1"
  local p
  for p in $(seq "$start" $((start + 29))); do
    if port_free "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf ''
}
wait_tcp_port_free(){
  local p="$1"
  local tries="${2:-30}"
  local i
  for i in $(seq 1 "$tries"); do
    if port_free "$p"; then
      return 0
    fi
    sleep 1
  done
  return 1
}
mk_exec_from_cmd(){
  local exe
  exe="$(printf '%s ' "${CMD[@]}")"
  printf '%s' "${exe% }"
}
build_cmd(){
  local cand="$1"
  local cname="$2"
  local port="$3"

  CMD=("$PODMAN_BIN" run --rm --name "$cname")

  case "$cand" in
    clean_min)
      CMD+=(--security-opt=no-new-privileges --memory 1536m)
      ;;
    clean_no_sec)
      CMD+=(--memory 1536m)
      ;;
    clean_no_sec_no_mem)
      ;;
    clean_userns_host)
      CMD+=(--userns=host)
      ;;
    *)
      halt "unknown candidate: $cand"
      ;;
  esac

  CMD+=(
    --network "$NET"
    --publish "127.0.0.1:$port:8081"
    -v "$MODEL_DIR:/models:ro"
    --entrypoint /opt/llama/bin/llama-server
    "$RUNTIME_IMAGE"
    --model "$MODEL_CONTAINER"
    --host 0.0.0.0
    --port 8081
    --embedding
    --pooling mean
    --ctx-size 2048
    --threads 2
    --parallel 1
    --alias nomic-embed-text
  )
}
make_serving_unit(){
  local file="$1"
  local desc="$2"
  local exe="$3"
  local extra="$4"

  {
    printf '[Unit]\n'
    printf 'Description=%s\n\n' "$desc"
    printf '[Service]\n'
    printf 'Type=simple\n'
    printf 'ExecStart=%s\n' "$exe"
    printf 'Restart=no\n'
    printf 'TimeoutStartSec=180\n'
    printf 'Delegate=yes\n'
    if [ -n "$extra" ]; then
      printf '%s\n' "$extra"
    fi
    printf '\n[Install]\n'
    printf 'WantedBy=default.target\n'
  } > "$file"
}
make_permanent_unit(){
  local file="$1"
  local exe="$2"

  {
    printf '# Brick 5 promoted: llama.cpp embedding server as a rootless Podman container service.\n'
    printf '# AR clean candidate promotion. One-line ExecStart avoids systemd continuation fragility.\n'
    printf '# Container name: %s\n' "$CONTAINER_NAME"
    printf '# Network: %s\n' "$NET"
    printf '# Host admin endpoint: http://127.0.0.1:%s\n' "$PORT"
    printf '# Internal upstream for LiteLLM: http://%s:%s/v1\n' "$CONTAINER_NAME" "$PORT"
    printf '# Native llama-embed.service is intentionally disabled and retained for rollback.\n'
    printf '\n'
    printf '[Unit]\n'
    printf 'Description=llama.cpp embedding server container (nomic-embed-text-v1.5 Q8_0)\n'
    printf 'After=network-online.target\n'
    printf 'Wants=network-online.target\n'
    printf '\n'
    printf '[Service]\n'
    printf 'Type=simple\n'
    printf 'ExecStart=%s\n' "$exe"
    printf 'Restart=always\n'
    printf 'RestartSec=3\n'
    printf 'TimeoutStartSec=180\n'
    printf 'Delegate=yes\n'
    printf '\n'
    printf '[Install]\n'
    printf 'WantedBy=default.target\n'
  } > "$file"
}
run_serving_test(){
  local unit="$1"
  local file="$2"
  local cname="$3"
  local health="$4"

  install -D -m 644 "$file" "$SYSU/$unit.service" || return 90
  TEST_UNITS+=("$unit")
  TEST_CONTAINERS+=("$cname")

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true

  local start_rc=0
  if ! systemctl --user start "$unit.service" >"$TMPD/$unit.start.out" 2>"$TMPD/$unit.start.err"; then
    start_rc=$?
  fi

  local ok=no
  local i st cst hc
  for i in $(seq 1 75); do
    st="$(active_state "$unit.service")"
    cst="$(container_status "$cname")"
    hc="$(norm "$(http_code "$health")")"
    if [ "$st" = active ] && [ "$cst" = running ] && [ "$hc" = 200 ]; then
      ok=yes
      break
    fi
    if [ "$st" = failed ] || [ "$st" = inactive ]; then
      break
    fi
    sleep 2
  done

  say "    journal($unit):"
  journalctl --user -u "$unit.service" -n 28 --no-pager 2>/dev/null | sed 's/^/      /' || true
  podman logs --tail 35 "$cname" 2>&1 | sed 's/^/      c: /' || true
  if [ -s "$TMPD/$unit.start.err" ]; then
    say "    start-err($unit):"
    tail -n 8 "$TMPD/$unit.start.err" 2>/dev/null | sed 's/^/      /' || true
  fi

  systemctl --user disable --now "$unit.service" >/dev/null 2>&1 || true
  podman rm -f "$cname" >/dev/null 2>&1 || true

  if [ "$ok" = yes ]; then
    return 0
  fi
  if [ "$start_rc" != 0 ]; then
    return "$start_rc"
  fi
  return 1
}

HOST_DIMS=0
DNS_HEALTH=0
DNS_DIMS=0

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
  printf '%s' '{"model":"nomic-embed-text","input":"aether AR host probe"}' > "$body"
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
      say "    dns-probe-err:"
      tail -n 5 "$err" 2>/dev/null | sed 's/^/      /' || true
    fi
    sleep 3
  done
  return 1
}

rollback_to_native(){
  say "[ROLLBACK] restoring native llama-embed.service"
  systemctl --user disable --now "$CONT_SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -f "$CONT_UNIT_INST" 2>/dev/null || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true

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

for c in bash podman systemctl journalctl curl awk sed grep python3 install cmp; do
  need_cmd "$c"
done

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$A/infra/systemd" "$SYSU"
touch "$IDX"

# ===================== [R0] preconditions =====================
say "=== [R0] preconditions ==="
if [ ! -f "$NATIVE_UNIT_SRC" ]; then
  halt "native rollback unit source missing: $NATIVE_UNIT_SRC"
fi
if [ ! -s "$MODEL" ]; then
  halt "embedding model missing: $MODEL"
fi
if ! podman image exists "$RUNTIME_IMAGE" 2>/dev/null; then
  halt "proven runtime image missing: $RUNTIME_IMAGE"
fi
if ! podman image exists "$PROBE_IMAGE" 2>/dev/null; then
  halt "probe image missing: $PROBE_IMAGE"
fi
if podman network exists "$NET" 2>/dev/null; then
  say "[R0] network present: $NET"
else
  say "[R0] creating missing network: $NET"
  podman network create "$NET" >/dev/null 2>&1 || halt "could not create network $NET"
fi

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
    payload = {"model": "nomic-embed-text", "input": "aether AR network probe"}
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

# Already promoted? Verify and exit green without touching native.
if [ "$(active_state "$CONT_SERVICE.service")" = active ] &&
   [ "$(container_status "$CONTAINER_NAME")" = running ] &&
   wait_host_health 5 &&
   host_embedding_ok &&
   dns_probe_ok 5
then
  say "[R0] already promoted and verified; ensuring enabled"
  systemctl --user enable "$CONT_SERVICE.service" >/dev/null 2>&1 || true

  if ! grep -qF "$AR_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | B | 20261029-AR-llama-embed-clean-promote | GATE=PASS | %s: already-promoted clean state verified; service=%s container=%s network=%s runtime=%s host=http://127.0.0.1:%s internal_upstream=http://%s:%s/v1 host_dims=%s dns_health=%s dns_dims=%s native=disabled; no model download; no ollama/open-webui. |\n' \
      "$(date +%F)" "$AR_TOKEN" "$CONT_SERVICE" "$CONTAINER_NAME" "$NET" "$RUNTIME_IMAGE" "$PORT" "$CONTAINER_NAME" "$PORT" "$HOST_DIMS" "$DNS_HEALTH" "$DNS_DIMS" >> "$IDX"
    say "[R0] ledger row appended for already-promoted state."
  else
    say "[R0] ledger row already present (guard suppressed)."
  fi
  grep -qF "$AR_TOKEN" "$IDX" 2>/dev/null && say "[R0] suppression proof: sentinel present." || say "[R0] WARNING: sentinel missing."

  cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AR: reruns the idempotent clean candidate promoter/verifier.
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261029-AR-llama-embed-clean-candidate-promote.sh"
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[R0] replay archived -> codemod/$SLUG_REPLAY"
  say "[RESULT] LLAMA-EMBED CONTAINER ALREADY PROMOTED (CLEAN) — service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1; next brick LiteLLM."
  exit 0
fi

# Not green: stop any broken container state and restore native safe floor.
say "[R0] stopping/disabling existing container service before native safe floor"
systemctl --user disable --now "$CONT_SERVICE.service" >/dev/null 2>&1 || true
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

if ! wait_tcp_port_free "$PORT" 30; then
  halt "port 127.0.0.1:$PORT remains occupied after stopping container service; identify listener before promotion"
fi

NH="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
if [ "$NH" != 200 ]; then
  say "[R0] native health=$NH; restarting native llama-embed.service"
  systemctl --user restart "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
  if [ "$(poll_http "http://127.0.0.1:$PORT/health" 200 30 || true)" != ok ]; then
    journalctl --user -u "$NATIVE_SERVICE.service" -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    halt "native llama-embed unhealthy; fix safe floor before candidate proof"
  fi
  NH=200
fi
say "[R0] native llama-embed healthy on 127.0.0.1:$PORT health=$NH (safe floor established)"

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no candidate services, no promotion, no AA run, no ledger row."
  exit 0
fi

# ===================== [R1] candidate proof =====================
say "=== [R1] clean one-line candidate proof under throwaway systemd user services ==="
SELECTED=""
idx=0
for cand in "${CANDIDATES[@]}"; do
  idx=$((idx + 1))
  port="$(pick_free_port_from $((18120 + idx * 10)))"
  if [ -z "$port" ]; then
    halt "could not allocate temporary port for candidate $cand"
  fi

  cname="ar-$cand-$SFX"
  unit="ar-$cand-$SFX"
  file="$TMPD/$unit.service"

  build_cmd "$cand" "$cname" "$port"
  exe="$(mk_exec_from_cmd)"
  make_serving_unit "$file" "AR candidate $cand $SFX" "$exe" ""

  say "[R1] testing candidate=$cand container=$cname port=$port"
  run_serving_test "$unit" "$file" "$cname" "http://127.0.0.1:$port/health"
  rc=$?
  nu="$(has_newuidmap "$unit")"
  CAND_RC["$cand"]="$rc"
  CAND_NU["$cand"]="$nu"
  say "[R1] candidate=$cand rc=$rc newuidmap=$nu"

  if [ "$rc" = 0 ]; then
    SELECTED="$cand"
    say "[R1] selected candidate=$SELECTED"
    break
  fi
done

if [ -z "$SELECTED" ]; then
  say "[R1] all candidates failed."
  for cand in "${CANDIDATES[@]}"; do
    say "    $cand rc=${CAND_RC[$cand]:-skipped} newuidmap=${CAND_NU[$cand]:-?}"
  done
  halt "no clean llama-embed container candidate passed; native llama-embed remains safe floor"
fi

CAND_SUMMARY=""
for cand in "${CANDIDATES[@]}"; do
  CAND_SUMMARY="${CAND_SUMMARY}${cand}=${CAND_RC[$cand]:-skipped}/${CAND_NU[$cand]:-?} "
done
CAND_SUMMARY="$(norm "$CAND_SUMMARY")"

# ===================== [R2] ledger correction/selection row =====================
say "=== [R2] ledger candidate-selection row ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AQ proved --security-opt alone was not the rootless llama blocker; full serving still failed under fuller systemd/service shape. AR supersedes AM/AQ promotion by testing clean one-line throwaway systemd candidates and selecting first passing service. selected=%s candidates=%s; native floor retained until promotion gates pass. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" "$SELECTED" "$CAND_SUMMARY" >> "$IDX"
  say "[R2] candidate-selection correction row appended."
else
  say "[R2] candidate-selection correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[R2] suppression proof: correction sentinel present." || say "[R2] WARNING: correction sentinel missing."

# ===================== [R3] promote selected candidate permanently =====================
say "=== [R3] promote selected candidate=$SELECTED ==="

if [ -f "$CONT_UNIT_SRC" ] && [ ! -f "$CONT_UNIT_SRC_BAK" ]; then
  cp -p "$CONT_UNIT_SRC" "$CONT_UNIT_SRC_BAK"
  say "[R3] container source backup -> $CONT_UNIT_SRC_BAK"
fi

if [ -f "$CONT_UNIT_INST" ] && [ ! -f "$CONT_UNIT_INST_BAK" ]; then
  cp -p "$CONT_UNIT_INST" "$CONT_UNIT_INST_BAK"
  say "[R3] container installed backup -> $CONT_UNIT_INST_BAK"
fi

systemctl --user disable --now "$CONT_SERVICE.service" >/dev/null 2>&1 || true
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
systemctl --user disable --now "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true

if ! wait_tcp_port_free "$PORT" 30; then
  rollback_to_native
  halt "port 127.0.0.1:$PORT is occupied before permanent promotion"
fi

build_cmd "$SELECTED" "$CONTAINER_NAME" "$PORT"
PERM_EXE="$(mk_exec_from_cmd)"
make_permanent_unit "$CONT_UNIT_SRC" "$PERM_EXE"

if ! install -D -m 644 "$CONT_UNIT_SRC" "$CONT_UNIT_INST"; then
  rollback_to_native
  halt "could not install permanent container unit"
fi

"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true

if ! systemctl --user daemon-reload; then
  rollback_to_native
  halt "systemctl --user daemon-reload failed"
fi

if ! systemctl --user enable "$CONT_SERVICE.service"; then
  journalctl --user -u "$CONT_SERVICE.service" -n 35 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  rollback_to_native
  halt "could not enable $CONT_SERVICE.service"
fi

if ! systemctl --user start "$CONT_SERVICE.service"; then
  journalctl --user -u "$CONT_SERVICE.service" -n 35 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 60 "$CONTAINER_NAME" 2>&1 | sed 's/^/    c: /' || true
  rollback_to_native
  halt "could not start $CONT_SERVICE.service"
fi

say "[R3] started $CONT_SERVICE.service with candidate=$SELECTED"

# ===================== [R4] wait for unit/container =====================
say "=== [R4] wait for unit active and container running ==="
WAIT_OK=no
for i in $(seq 1 60); do
  if [ "$(active_state "$CONT_SERVICE.service")" = active ] &&
     [ "$(container_status "$CONTAINER_NAME")" = running ]; then
    WAIT_OK=yes
    break
  fi
  sleep 2
done

if [ "$WAIT_OK" != yes ]; then
  journalctl --user -u "$CONT_SERVICE.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 80 "$CONTAINER_NAME" 2>&1 | sed 's/^/    c: /' || true
  rollback_to_native
  halt "permanent container service did not reach active+running"
fi

say "[R4] unit_active=active container_status=$(container_status "$CONTAINER_NAME")"

# ===================== [R5] host gate =====================
say "=== [R5] host loopback gate ==="
if ! wait_host_health 90; then
  journalctl --user -u "$CONT_SERVICE.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 80 "$CONTAINER_NAME" 2>&1 | sed 's/^/    c: /' || true
  rollback_to_native
  halt "permanent container did not reach /health 200 on 127.0.0.1:$PORT"
fi

if ! host_embedding_ok; then
  journalctl --user -u "$CONT_SERVICE.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 80 "$CONTAINER_NAME" 2>&1 | sed 's/^/    c: /' || true
  rollback_to_native
  halt "permanent container host embedding probe failed"
fi

say "[R5] host /health=200 host /v1/embeddings dims=$HOST_DIMS"

# ===================== [R6] in-network DNS gate =====================
say "=== [R6] in-network DNS gate ==="
if ! dns_probe_ok 40; then
  journalctl --user -u "$CONT_SERVICE.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 80 "$CONTAINER_NAME" 2>&1 | sed 's/^/    c: /' || true
  rollback_to_native
  halt "permanent container in-network DNS probe failed for http://$CONTAINER_NAME:$PORT"
fi

say "[R6] in-network http://$CONTAINER_NAME:$PORT health=$DNS_HEALTH dims=$DNS_DIMS"

# ===================== [R7] final state =====================
say "=== [R7] final state ==="
say "[R7] selected_candidate=$SELECTED"
say "[R7] native_service_active=$(active_state "$NATIVE_SERVICE.service") native_service_enabled=$(enabled_state "$NATIVE_SERVICE.service")"
say "[R7] container_service_active=$(active_state "$CONT_SERVICE.service") container_service_enabled=$(enabled_state "$CONT_SERVICE.service")"
say "[R7] container_status=$(container_status "$CONTAINER_NAME")"
podman ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [R8] reconcile core stack =====================
if [ -f "$AA" ]; then
  say "=== [R8] run AA green-stack reconcile ==="
  bash "$AA"
  AARC=$?
  say "[R8] AA rc=$AARC"
else
  say "[R8] AA script missing: $AA"
fi

# ===================== [R9] core gate =====================
say "=== [R9] core stack gate ==="
CORE_OK=yes
for s in postgres redis minio weaviate; do
  ACT="$(active_state "$s.service")"
  CST="$(container_status "$s")"
  say "[R9] $s active=$ACT container=$CST"
  if [ "$ACT" != active ] || [ "$CST" != running ]; then
    CORE_OK=no
  fi
done

if [ "$CORE_OK" != yes ]; then
  say "[R9] core stack not fully active+running; paste [R8]/[R9]."
  halt "llama-embed container promoted but core stack not green"
fi

# ===================== [R10] guarded promotion ledger row =====================
say "=== [R10] ledger promotion row ==="
if ! grep -qF "$AR_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261029-AR-llama-embed-clean-promote | GATE=PASS | %s: promoted llama-embed to rootless Podman container service using clean candidate=%s; service=%s container=%s network=%s runtime=%s host=http://127.0.0.1:%s internal_upstream=http://%s:%s/v1 host_dims=%s dns_health=%s dns_dims=%s native_llama_embed=disabled retained for rollback; candidates=%s; no model download; no ollama/open-webui. |\n' \
    "$(date +%F)" \
    "$AR_TOKEN" \
    "$SELECTED" \
    "$CONT_SERVICE" \
    "$CONTAINER_NAME" \
    "$NET" \
    "$RUNTIME_IMAGE" \
    "$PORT" \
    "$CONTAINER_NAME" \
    "$PORT" \
    "$HOST_DIMS" \
    "$DNS_HEALTH" \
    "$DNS_DIMS" \
    "$CAND_SUMMARY" >> "$IDX"
  say "[R10] ledger row appended."
else
  say "[R10] ledger row already present (guard suppressed)."
fi
grep -qF "$AR_TOKEN" "$IDX" 2>/dev/null && say "[R10] suppression proof: sentinel present." || say "[R10] WARNING: sentinel missing."

# ===================== [R11] replay archive =====================
cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AR: reruns the idempotent clean candidate promoter/verifier.
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261029-AR-llama-embed-clean-candidate-promote.sh"
REPLAY
chmod +x "$CD/$SLUG_REPLAY"
say "[R11] replay archived -> codemod/$SLUG_REPLAY"

say "[RESULT] LLAMA-EMBED CONTAINER PROMOTED VIA CLEAN CANDIDATE — selected=$SELECTED service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1 host_admin=http://127.0.0.1:$PORT; AM/AQ promoter shape superseded; native llama-embed retained disabled for rollback; next brick LiteLLM; still no Ollama/OpenWebUI/chat-model."
exit 0
