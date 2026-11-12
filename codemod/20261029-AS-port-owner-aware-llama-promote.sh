#!/usr/bin/env bash
# 20261029-AS — port-owner-aware replacement for AR.
# Owns AR defect:
#   AR required 127.0.0.1:8081 to be free after stopping only llama-embed-container.service.
#   Native llama-embed.service may legitimately own 8081 as the safe floor.
# Strategy:
#   1) diagnose owner of 8081 without killing unknown processes;
#   2) clean known stale/test containers only;
#   3) keep native llama-embed as safe floor during candidate proof;
#   4) test clean one-line systemd candidates on temporary ports;
#   5) promote only the first candidate that serves /health + /v1/embeddings;
#   6) stop native only for permanent promotion;
#   7) verify host loopback and in-network DNS embeddings;
#   8) reconcile core stack with AA;
#   9) rollback to native if any promotion gate fails.
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
CONT_UNIT_SRC_BAK="$CONT_UNIT_SRC.pre-AS.bak"
CONT_UNIT_INST_BAK="$CONT_UNIT_INST.pre-AS.bak"

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

CORRECTION_TOKEN="ar-port-owner-gate-defect"
AS_TOKEN="llama-embed-port-owner-aware-promotion-v1"
SLUG_REPLAY="20261029-AS-port-owner-aware-llama-promote-replay.sh"

CANDIDATES=(
  clean_min
  clean_no_sec
  clean_no_sec_no_mem
  clean_userns_host
  clean_userns_host_cgroupfs
)

declare -A CAND_RC
declare -A CAND_NU

TMPD="$(mktemp -d)"
TEST_UNITS=()
TEST_CONTAINERS=()

PORT_OWNER=""
PORT_PIDS=""
SELECTED=""
CAND_SUMMARY=""
HOST_DIMS=0
DNS_HEALTH=0
DNS_DIMS=0
NH=0

cleanup(){
  if [ "${#TEST_UNITS[@]}" -gt 0 ]; then
    for u in "${TEST_UNITS[@]}"; do
      systemctl --user disable --now "$u.service" >/dev/null 2>&1 || true
      rm -f "$SYSU/$u.service" 2>/dev/null || true
    done
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi

  if [ "${#TEST_CONTAINERS[@]}" -gt 0 ]; then
    for c in "${TEST_CONTAINERS[@]}"; do
      podman rm -f "$c" >/dev/null 2>&1 || true
    done
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
native_main_pid(){
  norm "$(systemctl --user show "$NATIVE_SERVICE.service" -p MainPID --value 2>/dev/null || true)"
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
known_container_names(){
  local pat="^($CONTAINER_NAME|ar-|aether-q-|llama-embed-trial-)"
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$pat" || true
}
listener_pids_on_port(){
  local out=""
  local pat="127\.0\.0\.1:$PORT|\[::1\]:$PORT|\*:$PORT"

  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltnp 2>/dev/null | grep -E "$pat" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
  fi

  if [ -z "$out" ] && command -v lsof >/dev/null 2>&1; then
    out="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>2 {print $2}' | sort -u || true)"
  fi

  printf '%s\n' "$out" | grep -E '^[0-9]+$' || true
}
classify_pid(){
  local pid="$1"
  local cmd cg nmp known
  cmd="$(pid_cmdline "$pid")"
  cg="$(pid_cgroup "$pid")"
  nmp="$(native_main_pid)"
  known="$(known_container_names)"

  if [ -n "$nmp" ] && [ "$pid" = "$nmp" ]; then
    printf 'native'
    return
  fi

  if printf '%s' "$cmd" | grep -q 'llama-server'; then
    if printf '%s' "$cg" | grep -q 'llama-embed.service'; then
      printf 'native'
      return
    fi
    if printf '%s' "$cg" | grep -Eq 'libpod|containers/|conmon'; then
      printf 'container'
      return
    fi
    if [ -n "$known" ]; then
      printf 'container'
      return
    fi
    printf 'unknown'
    return
  fi

  if printf '%s' "$cmd" | grep -Eq 'conmon|podman|pasta|slirp4netns|rootlessport'; then
    if [ -n "$known" ]; then
      printf 'container'
      return
    fi
    printf 'helper'
    return
  fi

  printf 'unknown'
}
port_owner_report(){
  PORT_PIDS="$(listener_pids_on_port)"
  if [ -z "$PORT_PIDS" ]; then
    PORT_OWNER=free
    say "[S0] port_$PORT=free"
    return 0
  fi

  PORT_OWNER=unknown
  while IFS= read -r pid; do
    if [ -z "$pid" ]; then
      continue
    fi
    cls="$(classify_pid "$pid")"
    say "[S0] listener pid=$pid class=$cls"
    say "[S0] cmd=$(printf '%s' "$(pid_cmdline "$pid")" | cut -c1-180)"
    say "[S0] cgroup=$(printf '%s' "$(pid_cgroup "$pid")" | cut -c1-220)"

    if [ "$cls" = native ]; then
      PORT_OWNER=native
    elif [ "$cls" = container ]; then
      if [ "$PORT_OWNER" != native ]; then
        PORT_OWNER=container
      fi
    elif [ "$cls" = helper ]; then
      if [ "$PORT_OWNER" = unknown ]; then
        PORT_OWNER=helper
      fi
    fi
  done <<< "$PORT_PIDS"
}
port_free(){
  local p="$1"
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    return 1
  fi
  return 0
}
pick_free_port_from(){
  local start="$1"
  local p
  for p in $(seq "$start" $((start + 39))); do
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
  printf '%s' '{"model":"nomic-embed-text","input":"aether AS host probe"}' > "$body"
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
build_cmd(){
  local cand="$1"
  local cname="$2"
  local port="$3"

  case "$cand" in
    clean_min)
      CMD=("$PODMAN_BIN" run --rm --name "$cname" --security-opt=no-new-privileges --memory 1536m)
      ;;
    clean_no_sec)
      CMD=("$PODMAN_BIN" run --rm --name "$cname" --memory 1536m)
      ;;
    clean_no_sec_no_mem)
      CMD=("$PODMAN_BIN" run --rm --name "$cname")
      ;;
    clean_userns_host)
      CMD=("$PODMAN_BIN" run --rm --name "$cname" --userns=host)
      ;;
    clean_userns_host_cgroupfs)
      CMD=("$PODMAN_BIN" --cgroup-manager=cgroupfs run --rm --name "$cname" --userns=host)
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
mk_exec_from_cmd(){
  local exe="" part
  for part in "${CMD[@]}"; do
    exe="$exe$part "
  done
  printf '%s' "${exe% }"
}
make_unit_file(){
  local file="$1"
  local desc="$2"
  local exe="$3"
  local restart="$4"

  {
    printf '[Unit]\n'
    printf 'Description=%s\n\n' "$desc"
    printf '[Service]\n'
    printf 'Type=simple\n'
    printf 'ExecStart=%s\n' "$exe"
    printf 'Restart=%s\n' "$restart"
    printf 'RestartSec=3\n'
    printf 'TimeoutStartSec=180\n'
    printf 'Delegate=yes\n\n'
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
  journalctl --user -u "$unit.service" -n 30 --no-pager 2>/dev/null | sed 's/^/      /' || true
  podman logs --tail 40 "$cname" 2>&1 | sed 's/^/      c: /' || true
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
ensure_network(){
  if podman network exists "$NET" 2>/dev/null; then
    say "[S1] network present: $NET"
  else
    say "[S1] creating network: $NET"
    podman network create "$NET" >/dev/null 2>&1 || halt "could not create network $NET"
  fi
}
cleanup_known_state(){
  say "[S2] cleaning known stale container state"
  systemctl --user disable --now "$CONT_SERVICE.service" >/dev/null 2>&1 || true

  local names n
  names="$(known_container_names)"
  if [ -n "$names" ]; then
    while IFS= read -r n; do
      if [ -n "$n" ]; then
        say "[S2] removing known container: $n"
        podman rm -f "$n" >/dev/null 2>&1 || true
      fi
    done <<< "$names"
  fi

  podman system migrate >/dev/null 2>&1 || true
}
ensure_native_floor(){
  if [ "$PORT_OWNER" = native ]; then
    NH="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
    if [ "$NH" != 200 ]; then
      say "[S3] native health=$NH; restarting native llama-embed.service"
      systemctl --user restart "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
      if [ "$(poll_http "http://127.0.0.1:$PORT/health" 200 45 || true)" != ok ]; then
        journalctl --user -u "$NATIVE_SERVICE.service" -n 35 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
        halt "native llama-embed unhealthy; fix safe floor before candidate proof"
      fi
      NH=200
    fi
    say "[S3] native llama-embed healthy on 127.0.0.1:$PORT health=$NH"
    return 0
  fi

  if [ "$PORT_OWNER" = free ]; then
    say "[S3] port free; starting native llama-embed safe floor"
    systemctl --user enable "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
    systemctl --user start "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
    if [ "$(poll_http "http://127.0.0.1:$PORT/health" 200 45 || true)" != ok ]; then
      journalctl --user -u "$NATIVE_SERVICE.service" -n 35 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
      halt "could not start native llama-embed safe floor"
    fi
    PORT_OWNER=native
    say "[S3] native llama-embed healthy on 127.0.0.1:$PORT health=200"
    return 0
  fi

  halt "unexpected port owner after cleanup: $PORT_OWNER"
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
write_replay(){
  cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AS: reruns the idempotent port-owner-aware promoter/verifier.
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261029-AS-port-owner-aware-llama-promote.sh"
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[REPLAY] archived -> codemod/$SLUG_REPLAY"
}
already_promoted_green(){
  if [ "$(active_state "$CONT_SERVICE.service")" != active ]; then
    return 1
  fi
  if [ "$(container_status "$CONTAINER_NAME")" != running ]; then
    return 1
  fi
  if ! wait_host_health 5; then
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

for c in bash podman systemctl journalctl curl awk sed grep python3 install cmp tr cut sort uniq; do
  need_cmd "$c"
done

if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
  halt "missing required port diagnostic tool: ss or lsof"
fi

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$A/infra/systemd" "$SYSU"
touch "$IDX"

# ===================== [S0] preconditions =====================
say "=== [S0] preconditions ==="
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
    payload = {"model": "nomic-embed-text", "input": "aether AS network probe"}
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

port_owner_report
say "[S0] initial_port_owner=$PORT_OWNER"

if [ "$DRY" = 1 ]; then
  say "[S0] dry-run candidate plan:"
  for cand in "${CANDIDATES[@]}"; do
    say "    candidate=$cand"
  done
  say "[RESULT] DRY-RUN complete; no cleanup, no candidate services, no promotion, no AA run, no ledger row."
  exit 0
fi

# ===================== [S1] audit AR gate defect =====================
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AR halted because it required 127.0.0.1:8081 to be free after stopping only llama-embed-container.service. Native llama-embed.service may legitimately own 8081 as the safe floor. AS supersedes AR with port-owner-aware diagnosis and temporary-port candidate proof. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" >> "$IDX"
  say "[S1] AR port-owner correction row appended."
else
  say "[S1] AR port-owner correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[S1] suppression proof: correction sentinel present." || say "[S1] WARNING: correction sentinel missing."

ensure_network

# ===================== [S2] already promoted? =====================
if already_promoted_green; then
  say "[S2] already promoted and verified; ensuring enabled"
  systemctl --user enable "$CONT_SERVICE.service" >/dev/null 2>&1 || true

  if ! grep -qF "$AS_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | B | 20261029-AS-port-owner-aware-llama-promote | GATE=PASS | %s: already-promoted state verified; service=%s container=%s network=%s runtime=%s host=http://127.0.0.1:%s internal_upstream=http://%s:%s/v1 host_dims=%s dns_health=%s dns_dims=%s native=disabled; no model download; no ollama/open-webui. |\n' \
      "$(date +%F)" "$AS_TOKEN" "$CONT_SERVICE" "$CONTAINER_NAME" "$NET" "$RUNTIME_IMAGE" "$PORT" "$CONTAINER_NAME" "$PORT" "$HOST_DIMS" "$DNS_HEALTH" "$DNS_DIMS" >> "$IDX"
    say "[S2] ledger row appended for already-promoted state."
  else
    say "[S2] ledger row already present (guard suppressed)."
  fi
  grep -qF "$AS_TOKEN" "$IDX" 2>/dev/null && say "[S2] suppression proof: sentinel present." || say "[S2] WARNING: sentinel missing."
  write_replay
  say "[RESULT] LLAMA-EMBED CONTAINER ALREADY PROMOTED (PORT-OWNER-AWARE) — service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1; next brick LiteLLM."
  exit 0
fi

# ===================== [S3] clean known stale state =====================
cleanup_known_state
port_owner_report
say "[S3] post_cleanup_port_owner=$PORT_OWNER"

if [ "$PORT_OWNER" = container ] || [ "$PORT_OWNER" = helper ] || [ "$PORT_OWNER" = unknown ]; then
  say "[S3] port 8081 is still occupied by non-native state."
  say "[S3] pids=$PORT_PIDS"
  halt "unknown or stale non-native listener owns 8081; inspect [S3] evidence before promotion"
fi

ensure_native_floor

# ===================== [S4] candidate proof =====================
say "=== [S4] clean one-line candidate proof under throwaway systemd user services ==="
idx=0
for cand in "${CANDIDATES[@]}"; do
  idx=$((idx + 1))
  port="$(pick_free_port_from $((18120 + idx * 10)))"
  if [ -z "$port" ]; then
    halt "could not allocate temporary port for candidate $cand"
  fi

  cname="as-$cand-$SFX"
  unit="as-$cand-$SFX"
  file="$TMPD/$unit.service"

  build_cmd "$cand" "$cname" "$port"
  exe="$(mk_exec_from_cmd)"
  make_unit_file "$file" "AS candidate $cand $SFX" "$exe" "no"

  say "[S4] testing candidate=$cand container=$cname port=$port"
  run_serving_test "$unit" "$file" "$cname" "http://127.0.0.1:$port/health"
  rc=$?
  nu="no"
  if journalctl --user -u "$unit.service" --no-pager 2>/dev/null | grep -q 'newuidmap'; then
    nu="yes"
  fi

  CAND_RC["$cand"]="$rc"
  CAND_NU["$cand"]="$nu"
  say "[S4] candidate=$cand rc=$rc newuidmap=$nu"

  if [ "$rc" = 0 ]; then
    SELECTED="$cand"
    say "[S4] selected candidate=$SELECTED"
    break
  fi
done

if [ -z "$SELECTED" ]; then
  say "[S4] all candidates failed."
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

# ===================== [S5] promote selected candidate permanently =====================
say "=== [S5] promote selected candidate=$SELECTED ==="

if [ -f "$CONT_UNIT_SRC" ] && [ ! -f "$CONT_UNIT_SRC_BAK" ]; then
  cp -p "$CONT_UNIT_SRC" "$CONT_UNIT_SRC_BAK"
  say "[S5] container source backup -> $CONT_UNIT_SRC_BAK"
fi

if [ -f "$CONT_UNIT_INST" ] && [ ! -f "$CONT_UNIT_INST_BAK" ]; then
  cp -p "$CONT_UNIT_INST" "$CONT_UNIT_INST_BAK"
  say "[S5] container installed backup -> $CONT_UNIT_INST_BAK"
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
make_unit_file "$CONT_UNIT_SRC" "llama.cpp embedding server container (nomic-embed-text-v1.5 Q8_0)" "$PERM_EXE" "always"

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

say "[S5] started $CONT_SERVICE.service with candidate=$SELECTED"

# ===================== [S6] wait for unit/container =====================
say "=== [S6] wait for unit active and container running ==="
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

say "[S6] unit_active=active container_status=$(container_status "$CONTAINER_NAME")"

# ===================== [S7] host gate =====================
say "=== [S7] host loopback gate ==="
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

say "[S7] host /health=200 host /v1/embeddings dims=$HOST_DIMS"

# ===================== [S8] in-network DNS gate =====================
say "=== [S8] in-network DNS gate ==="
if ! dns_probe_ok 40; then
  journalctl --user -u "$CONT_SERVICE.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 80 "$CONTAINER_NAME" 2>&1 | sed 's/^/    c: /' || true
  rollback_to_native
  halt "permanent container in-network DNS probe failed for http://$CONTAINER_NAME:$PORT"
fi

say "[S8] in-network http://$CONTAINER_NAME:$PORT health=$DNS_HEALTH dims=$DNS_DIMS"

# ===================== [S9] final state =====================
say "=== [S9] final state ==="
say "[S9] selected_candidate=$SELECTED"
say "[S9] native_service_active=$(active_state "$NATIVE_SERVICE.service") native_service_enabled=$(enabled_state "$NATIVE_SERVICE.service")"
say "[S9] container_service_active=$(active_state "$CONT_SERVICE.service") container_service_enabled=$(enabled_state "$CONT_SERVICE.service")"
say "[S9] container_status=$(container_status "$CONTAINER_NAME")"
podman ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [S10] reconcile core stack =====================
if [ -f "$AA" ]; then
  say "=== [S10] run AA green-stack reconcile ==="
  bash "$AA"
  AARC=$?
  say "[S10] AA rc=$AARC"
else
  say "[S10] AA script missing: $AA"
fi

# ===================== [S11] core gate =====================
say "=== [S11] core stack gate ==="
CORE_OK=yes
for s in postgres redis minio weaviate; do
  ACT="$(active_state "$s.service")"
  CST="$(container_status "$s")"
  say "[S11] $s active=$ACT container=$CST"
  if [ "$ACT" != active ] || [ "$CST" != running ]; then
    CORE_OK=no
  fi
done

if [ "$CORE_OK" != yes ]; then
  say "[S11] core stack not fully active+running; paste [S10]/[S11]."
  halt "llama-embed container promoted but core stack not green"
fi

# ===================== [S12] guarded promotion ledger row =====================
say "=== [S12] ledger promotion row ==="
if ! grep -qF "$AS_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261029-AS-port-owner-aware-llama-promote | GATE=PASS | %s: promoted llama-embed to rootless Podman container service using port-owner-aware clean candidate=%s; service=%s container=%s network=%s runtime=%s host=http://127.0.0.1:%s internal_upstream=http://%s:%s/v1 host_dims=%s dns_health=%s dns_dims=%s native_llama_embed=disabled retained for rollback; candidates=%s; no model download; no ollama/open-webui. |\n' \
    "$(date +%F)" \
    "$AS_TOKEN" \
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
  say "[S12] ledger row appended."
else
  say "[S12] ledger row already present (guard suppressed)."
fi
grep -qF "$AS_TOKEN" "$IDX" 2>/dev/null && say "[S12] suppression proof: sentinel present." || say "[S12] WARNING: sentinel missing."

write_replay

say "[RESULT] LLAMA-EMBED CONTAINER PROMOTED VIA PORT-OWNER-AWARE CLEAN CANDIDATE — selected=$SELECTED service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1 host_admin=http://127.0.0.1:$PORT; AR owner-blind gate superseded; native llama-embed retained disabled for rollback; next brick LiteLLM; still no Ollama/OpenWebUI/chat-model."
exit 0
