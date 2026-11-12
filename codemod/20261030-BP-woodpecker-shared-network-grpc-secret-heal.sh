#!/usr/bin/env bash
# 20261030-BP — stabilize Woodpecker brick 10A after BO.
# Evidence:
#   BO changed agent backend to docker via rootless Podman socket.
#   Agent still failed with:
#     authenticate with server: dial tcp 127.0.0.1:9000: connect: connection refused
#   Server logged:
#     WOODPECKER_GRPC_SECRET is not set; generated a temporary random secret
#   DNS guard falsely accepted:
#     127.0.0.1 woodpecker-server
#
# Fix:
#   1) Persist and synchronize WOODPECKER_GRPC_SECRET + WOODPECKER_AGENT_SECRET.
#   2) Bind Woodpecker server gRPC to 127.0.0.1:9000.
#   3) Run woodpecker-agent with --network container:woodpecker-server.
#      This places agent in the server network namespace, so 127.0.0.1:9000 is correct.
#   4) Update shared aether DNS guard to reject loopback false positives by default.
#   5) Gate on:
#        P1 server healthy
#        P2 agent active/running
#        P3 20s no-crash stability
#        P4 no fatal/connection-refused/ephemeral-secret log markers
#
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
#   - --check is pure/read-only
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

SERVICE_SERVER="woodpecker-server"
CONTAINER_SERVER="woodpecker-server"
IMAGE_SERVER="docker.io/woodpeckerci/woodpecker-server:v3"

SERVICE_AGENT="woodpecker-agent"
CONTAINER_AGENT="woodpecker-agent"
IMAGE_AGENT="docker.io/woodpeckerci/woodpecker-agent:v3"

HOST_PORT="8000"
SERVER_PORT="8000"
GRPC_PORT="9000"
GRPC_ADDR="127.0.0.1:9000"
NET="aether"

VOL_SERVER="woodpecker_server_data"
VOL_AGENT="woodpecker_agent_data"

WP_ENV="$A/secrets/woodpecker.env"
DNS_SCRIPT="$A/infra/scripts/aether-dns-wait.sh"
SERVER_WAIT_SCRIPT="$A/infra/scripts/woodpecker-server-wait.sh"
ALPINE="docker.io/library/alpine:latest"

PG_CONTAINER="postgres"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC_SERVER="$UNIT_SRC_DIR/woodpecker-server.service"
UNIT_INST_SERVER="$HOME/.config/systemd/user/woodpecker-server.service"
UNIT_SRC_AGENT="$UNIT_SRC_DIR/woodpecker-agent.service"
UNIT_INST_AGENT="$HOME/.config/systemd/user/woodpecker-agent.service"

UNIT_SRC_SERVER_BAK="$UNIT_SRC_SERVER.pre-BP.bak"
UNIT_INST_SERVER_BAK="$UNIT_INST_SERVER.pre-BP.bak"
UNIT_SRC_AGENT_BAK="$UNIT_SRC_AGENT.pre-BP.bak"
UNIT_INST_AGENT_BAK="$UNIT_INST_AGENT.pre-BP.bak"

CORRECTION_TOKEN="bp-woodpecker-shared-network-grpc-secret-loopback-defect"
FAIL_TOKEN="bp-woodpecker-brick10-failed-v1"
TOKEN="bp-woodpecker-brick10-podless-shared-net-green-v1"
SLUG_REPLAY="20261030-BP-woodpecker-shared-network-replay.sh"

IMAGE_SERVER_DIGEST=""
IMAGE_AGENT_DIGEST=""
IMAGE_SERVER_DIGEST_SOURCE=""
IMAGE_AGENT_DIGEST_SOURCE=""

SERVER_ENDPOINT=""
SERVER_CODE="000"
NRESTARTS_SERVER_AFTER=0
NRESTARTS_AGENT_AFTER=0

BAD_RE='authenticate with server|connection refused|cannot connect to woodpecker-server|shutdown of whole agent|"level":"fatal"|"level":"panic"|unauthenticated|authentication failed|invalid secret|WOODPECKER_GRPC_SECRET is not set|unsupported backend|unknown backend|invalid backend|permission denied.*docker|no such file.*docker.sock'
GOOD_RE='agent connected|connected to server|grpc.*agent|registered agent|agent .*connected'

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
nrestarts(){
  local v
  v="$(systemctl --user show "$1" -p NRestarts --value 2>/dev/null || true)"
  printf '%s' "$(to_int "$v")"
}
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true
}
env_has(){
  grep -q "^$1=." "$WP_ENV" 2>/dev/null
}
read_env_value(){
  awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$WP_ENV" 2>/dev/null || true
}
set_env(){
  local key="$1"
  local val="$2"
  local tmp="$TMPD/setenv.tmp"
  if [ -f "$WP_ENV" ]; then
    grep -v "^${key}=" "$WP_ENV" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$WP_ENV"
  chmod 600 "$WP_ENV" 2>/dev/null || true
}
gen_secret(){
  python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(43)))" 2>/dev/null || true
}
port_free(){
  local p="$1"
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    return 1
  fi
  return 0
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
server_health_ok(){
  local ep code
  SERVER_ENDPOINT=""
  SERVER_CODE="000"
  for ep in /api/health /healthz /; do
    code="$(norm "$(http_code "http://127.0.0.1:$HOST_PORT$ep")")"
    if [ "$code" = 200 ]; then
      SERVER_ENDPOINT="$ep"
      SERVER_CODE="$code"
      return 0
    fi
    SERVER_CODE="$code"
  done
  return 1
}
wait_server_health(){
  local tries="${1:-150}"
  local i
  for i in $(seq 1 "$tries"); do
    if server_health_ok; then
      return 0
    fi
    sleep 2
  done
  return 1
}
logs_have_bad(){
  local logs="${1:-}"
  if printf '%s' "$logs" | grep -Eiq "$BAD_RE"; then
    return 0
  fi
  return 1
}
logs_have_good(){
  local logs="${1:-}"
  if printf '%s' "$logs" | grep -Eiq "$GOOD_RE"; then
    return 0
  fi
  return 1
}
dump_state(){
  say "=== [DUMP] woodpecker-server unit ==="
  systemctl --user status --no-pager "$SERVICE_SERVER.service" 2>/dev/null | sed 's/^/    unit-server: /' || true
  journalctl --user -u "$SERVICE_SERVER.service" -n 80 --no-pager 2>/dev/null | sed 's/^/    j-server: /' || true
  podman logs --tail 120 "$CONTAINER_SERVER" 2>&1 | sed 's/^/    c-server: /' || true

  say "=== [DUMP] woodpecker-agent unit ==="
  systemctl --user status --no-pager "$SERVICE_AGENT.service" 2>/dev/null | sed 's/^/    unit-agent: /' || true
  journalctl --user -u "$SERVICE_AGENT.service" -n 80 --no-pager 2>/dev/null | sed 's/^/    j-agent: /' || true
  podman logs --tail 160 "$CONTAINER_AGENT" 2>&1 | sed 's/^/    c-agent: /' || true
}
rollback_woodpecker_only(){
  say "[ROLLBACK] stopping/disabling woodpecker services (data retained)"
  systemctl --user disable --now "$SERVICE_AGENT.service" >/dev/null 2>&1 || true
  systemctl --user disable --now "$SERVICE_SERVER.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE_AGENT.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE_SERVER.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER_AGENT" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER_SERVER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}
install_unit_if_changed(){
  local desired="$1"
  local dest="$2"
  local bak="$3"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  if [ ! -f "$dest" ] || ! cmp -s "$desired" "$dest"; then
    if [ -f "$dest" ] && [ ! -f "$bak" ]; then
      cp -p "$dest" "$bak"
      say "[BP] backup -> $bak"
    fi
    install -D -m 644 "$desired" "$dest" || halt "could not install $dest"
    say "[BP] installed -> $dest"
  else
    say "[BP] already desired -> $dest"
  fi
}
write_replay_bp(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BP: Woodpecker server+agent shared-network install is active and stable.
set -uo pipefail
A="$HOME/DevOps/aether"
UNIT_SRC_SERVER="$A/infra/systemd/woodpecker-server.service"
UNIT_INST_SERVER="$HOME/.config/systemd/user/woodpecker-server.service"
UNIT_SRC_AGENT="$A/infra/systemd/woodpecker-agent.service"
UNIT_INST_AGENT="$HOME/.config/systemd/user/woodpecker-agent.service"

install -D -m 644 "$UNIT_SRC_SERVER" "$UNIT_INST_SERVER"
install -D -m 644 "$UNIT_SRC_AGENT" "$UNIT_INST_AGENT"
systemctl --user daemon-reload
systemctl --user enable woodpecker-server.service >/dev/null 2>&1 || true
systemctl --user enable woodpecker-agent.service >/dev/null 2>&1 || true
systemctl --user restart woodpecker-server.service
sleep 5
systemctl --user restart woodpecker-agent.service

HZ=no
for i in $(seq 1 150); do
  for ep in /api/health /healthz /; do
    C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8000$ep" 2>/dev/null || true)"
    if [ "$C" = 200 ]; then
      HZ=yes
      break
    fi
  done
  if [ "$HZ" = yes ]; then
    break
  fi
  sleep 2
done

sleep 20
SA="$(systemctl --user is-active woodpecker-server.service 2>/dev/null || true)"
AA="$(systemctl --user is-active woodpecker-agent.service 2>/dev/null || true)"
SN="$(systemctl --user show woodpecker-server.service -p NRestarts --value 2>/dev/null || true)"
AN="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || true)"

if [ "$HZ" = yes ] && [ "$SA" = active ] && [ "$AA" = active ] && [ "$SN" = 0 ] && [ "$AN" = 0 ]; then
  echo "  [GATE PASS] woodpecker shared-net server=active agent=active health=ok nrestarts=0"
else
  echo "  [GATE FAIL] woodpecker server=$SA/$SN agent=$AA/$AN health=$HZ"
  exit 1
fi
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[REPLAY] archived -> codemod/$SLUG_REPLAY"
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head tail mv id; do
  need_cmd "$c"
done
if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
  halt "missing required port diagnostic tool: ss or lsof"
fi
PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

# ===================== [B0] read-only preconditions =====================
say "=== [B0] preconditions ==="

if ! podman image exists "$IMAGE_SERVER" 2>/dev/null; then
  halt "Woodpecker server image missing: $IMAGE_SERVER (cached image required; do not pull ad hoc)"
fi
if ! podman image exists "$IMAGE_AGENT" 2>/dev/null; then
  halt "Woodpecker agent image missing: $IMAGE_AGENT (cached image required; do not pull ad hoc)"
fi
if ! podman image exists "$ALPINE" 2>/dev/null; then
  halt "alpine image missing (DNS guard needs it cached)"
fi
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing"
fi
if [ "$(container_status "$PG_CONTAINER")" != running ]; then
  halt "postgres container not running"
fi
if [ "$(active_state gitea.service)" != active ] ||
   [ "$(container_status gitea)" != running ]; then
  halt "gitea service/container not active+running"
fi

RUN_UID="$(id -u)"
PODMAN_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$RUN_UID}/podman/podman.sock"
SOCK_ACTIVE="$(active_state podman.socket)"
say "[B0] podman_socket=$PODMAN_SOCKET active=$SOCK_ACTIVE"
if [ ! -S "$PODMAN_SOCKET" ]; then
  say "[B0] podman socket not present yet; apply phase will enable podman.socket"
fi

PORT_FREE=yes
if ! port_free "$HOST_PORT"; then
  PORT_FREE=no
fi
say "[B0] host_port=$HOST_PORT free=$PORT_FREE"

IMAGE_SERVER_DIGEST="$(norm "$(podman image inspect "$IMAGE_SERVER" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | awk '{print $1}' || true)")"
if [ -n "$IMAGE_SERVER_DIGEST" ]; then
  IMAGE_SERVER_DIGEST_SOURCE="repodigest"
else
  IMAGE_SERVER_DIGEST="$(norm "$(podman image inspect "$IMAGE_SERVER" --format '{{.Id}}' 2>/dev/null || true)")"
  IMAGE_SERVER_DIGEST_SOURCE="image-id"
fi

IMAGE_AGENT_DIGEST="$(norm "$(podman image inspect "$IMAGE_AGENT" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | awk '{print $1}' || true)")"
if [ -n "$IMAGE_AGENT_DIGEST" ]; then
  IMAGE_AGENT_DIGEST_SOURCE="repodigest"
else
  IMAGE_AGENT_DIGEST="$(norm "$(podman image inspect "$IMAGE_AGENT" --format '{{.Id}}' 2>/dev/null || true)")"
  IMAGE_AGENT_DIGEST_SOURCE="image-id"
fi

say "[B0] server_image=$IMAGE_SERVER digest(${IMAGE_SERVER_DIGEST_SOURCE})=${IMAGE_SERVER_DIGEST:-none}"
say "[B0] agent_image=$IMAGE_AGENT digest(${IMAGE_AGENT_DIGEST_SOURCE})=${IMAGE_AGENT_DIGEST:-none}"
say "[B0] mode=shared-network-container agent_network=container:$CONTAINER_SERVER grpc_addr=$GRPC_ADDR"

if [ "$DRY" = 1 ]; then
  say "[B0] dry-run plan (pure/read-only; no env writes, no socket enable, no unit writes, no restart, no ledger):"
  say "    - synchronize WOODPECKER_GRPC_SECRET and WOODPECKER_AGENT_SECRET in $WP_ENV"
  say "    - set WOODPECKER_GRPC_ADDR=$GRPC_ADDR"
  say "    - set WOODPECKER_SERVER=$GRPC_ADDR"
  say "    - set WOODPECKER_BACKEND=docker"
  say "    - set DOCKER_HOST=unix:///var/run/docker.sock"
  say "    - update $DNS_SCRIPT to reject loopback false positives"
  say "    - install $SERVER_WAIT_SCRIPT"
  say "    - stop old woodpecker-server/woodpecker-agent containers and units"
  say "    - install new units where agent uses --network container:woodpecker-server"
  say "    - enable/start podman.socket"
  say "    - gate server health + agent 20s no-crash stability"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched."
  exit 0
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user" "$A/secrets" "$A/infra/scripts"
touch "$IDX"

# ===================== [B1] correction ledger =====================
say "=== [B1] correction ledger row ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BO fixed Woodpecker agent backend but agent still crash-looped because server gRPC secret was ephemeral and cross-container DNS/name resolution produced loopback false positives. Evidence: server logged WOODPECKER_GRPC_SECRET is not set; agent logged dial tcp 127.0.0.1:9000 connection refused; DNS guard accepted 127.0.0.1 woodpecker-server. BP supersedes BO by persisting/synchronizing WOODPECKER_GRPC_SECRET and WOODPECKER_AGENT_SECRET, binding server gRPC to 127.0.0.1:9000, running agent with --network container:woodpecker-server, and updating the shared DNS guard to reject loopback by default. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" >> "$IDX"
  say "[B1] BP correction row appended."
else
  say "[B1] BP correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[B1] suppression proof: present." || say "[B1] WARNING: missing."

# ===================== [B2] stop old state =====================
say "=== [B2] stop old Woodpecker state ==="
rollback_woodpecker_only
if ! wait_tcp_port_free "$HOST_PORT" 30; then
  halt "port 127.0.0.1:$HOST_PORT still occupied after old-state cleanup"
fi
say "[B2] port 127.0.0.1:$HOST_PORT free"

# ===================== [B3] env secrets/config =====================
say "=== [B3] Woodpecker env synchronization ==="
umask 077
if [ ! -f "$WP_ENV" ]; then
  : > "$WP_ENV"
  chmod 600 "$WP_ENV" 2>/dev/null || true
  say "[B3] created Woodpecker env file -> $WP_ENV"
else
  chmod 600 "$WP_ENV" 2>/dev/null || true
  say "[B3] Woodpecker env file present -> $WP_ENV"
fi

AGENT_SEC="$(read_env_value WOODPECKER_AGENT_SECRET)"
GRPC_SEC="$(read_env_value WOODPECKER_GRPC_SECRET)"

if [ -z "$AGENT_SEC" ] && [ -z "$GRPC_SEC" ]; then
  SEC="$(gen_secret)"
  if [ -z "$SEC" ]; then
    halt "could not generate Woodpecker gRPC/agent secret"
  fi
  set_env WOODPECKER_AGENT_SECRET "$SEC"
  set_env WOODPECKER_GRPC_SECRET "$SEC"
  say "[B3] generated matched WOODPECKER_AGENT_SECRET + WOODPECKER_GRPC_SECRET (values not echoed)"
elif [ -z "$GRPC_SEC" ]; then
  set_env WOODPECKER_GRPC_SECRET "$AGENT_SEC"
  say "[B3] synchronized WOODPECKER_GRPC_SECRET from existing WOODPECKER_AGENT_SECRET (values not echoed)"
elif [ -z "$AGENT_SEC" ]; then
  set_env WOODPECKER_AGENT_SECRET "$GRPC_SEC"
  say "[B3] synchronized WOODPECKER_AGENT_SECRET from existing WOODPECKER_GRPC_SECRET (values not echoed)"
else
  set_env WOODPECKER_AGENT_SECRET "$GRPC_SEC"
  say "[B3] forced WOODPECKER_AGENT_SECRET to match WOODPECKER_GRPC_SECRET (values not echoed)"
fi
unset AGENT_SEC GRPC_SEC SEC

set_env WOODPECKER_GRPC_ADDR "$GRPC_ADDR"
set_env WOODPECKER_SERVER "$GRPC_ADDR"
set_env WOODPECKER_BACKEND "docker"
set_env DOCKER_HOST "unix:///var/run/docker.sock"
set_env WOODPECKER_HOST "http://127.0.0.1:$HOST_PORT"
say "[B3] gRPC/address/backend env synchronized"

# ===================== [B4] update DNS guard =====================
say "=== [B4] update shared DNS guard to reject loopback ==="
if [ ! -f "$DNS_SCRIPT" ] || ! grep -q "BP: reject loopback" "$DNS_SCRIPT" 2>/dev/null; then
  cat > "$TMPD/dns-wait.sh" <<'SEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh — BP: reject loopback false positives by default.
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
TRIES="${AETHER_DNS_TRIES:-90}"
DELAY="${AETHER_DNS_DELAY:-1}"
ALLOW_LOOPBACK="${AETHER_DNS_ALLOW_LOOPBACK:-0}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2
  exit 2
fi
for h in "${hosts[@]}"; do
  ok=0
  i=1
  while [ "$i" -le "$TRIES" ]; do
    line="$(podman run --rm --network "$NET" "$ALPINE" getent hosts "$h" 2>/dev/null | head -n1 || true)"
    addr="$(printf '%s' "$line" | awk '{print $1}')"
    if [ -n "$addr" ]; then
      case "$addr" in
        127.*|::1|localhost)
          if [ "$ALLOW_LOOPBACK" = 1 ]; then
            ok=1
          else
            echo "dns-wait: host '$h' resolved to loopback '$addr'; rejecting" >&2
          fi
          ;;
        *)
          ok=1
          ;;
      esac
    fi
    if [ "$ok" -eq 1 ]; then
      break
    fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  if [ "$ok" -ne 1 ]; then
    echo "dns-wait: host '$h' did not resolve to a non-loopback address on network '$NET' after $TRIES tries" >&2
    exit 1
  fi
  echo "dns-wait: resolved $h on $NET"
done
exit 0
SEOF
  if ! bash -n "$TMPD/dns-wait.sh"; then
    halt "updated DNS guard script failed bash -n"
  fi
  install -D -m 755 "$TMPD/dns-wait.sh" "$DNS_SCRIPT" || halt "could not install $DNS_SCRIPT"
  say "[B4] installed loopback-rejecting DNS guard -> $DNS_SCRIPT"
else
  say "[B4] DNS guard already loopback-rejecting -> $DNS_SCRIPT"
fi

# ===================== [B5] server wait script =====================
say "=== [B5] install Woodpecker server wait script ==="
cat > "$TMPD/server-wait.sh" <<'SWEOF'
#!/usr/bin/env bash
# woodpecker-server-wait.sh — wait until woodpecker-server container is running.
set -uo pipefail
NAME="${1:-woodpecker-server}"
TRIES="${2:-90}"
DELAY="${3:-2}"
for i in $(seq 1 "$TRIES"); do
  st="$(podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null || true)"
  if [ "$st" = running ]; then
    exit 0
  fi
  sleep "$DELAY"
done
echo "woodpecker-server-wait: container '$NAME' not running after $TRIES tries" >&2
exit 1
SWEOF
if ! bash -n "$TMPD/server-wait.sh"; then
  halt "server wait script failed bash -n"
fi
install -D -m 755 "$TMPD/server-wait.sh" "$SERVER_WAIT_SCRIPT" || halt "could not install $SERVER_WAIT_SCRIPT"
say "[B5] installed server wait script -> $SERVER_WAIT_SCRIPT"

# ===================== [B6] enable podman socket =====================
say "=== [B6] enable rootless Podman socket ==="
if ! systemctl --user enable --now podman.socket >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if ! systemctl --user enable --now podman.socket >/dev/null 2>&1; then
    halt "could not enable/start user podman.socket"
  fi
fi
SOCK_OK=no
for i in $(seq 1 30); do
  if [ -S "$PODMAN_SOCKET" ]; then
    SOCK_OK=yes
    break
  fi
  sleep 1
done
if [ "$SOCK_OK" != yes ]; then
  halt "podman.socket started but socket file is not present at $PODMAN_SOCKET"
fi
say "[B6] podman.socket active and socket present"

# ===================== [B7] volumes =====================
say "=== [B7] ensure volumes ==="
if ! podman volume exists "$VOL_SERVER" 2>/dev/null; then
  podman volume create "$VOL_SERVER" >/dev/null 2>&1 || halt "could not create volume $VOL_SERVER"
fi
if ! podman volume exists "$VOL_AGENT" 2>/dev/null; then
  podman volume create "$VOL_AGENT" >/dev/null 2>&1 || halt "could not create volume $VOL_AGENT"
fi
say "[B7] volumes present: $VOL_SERVER $VOL_AGENT"

# ===================== [B8] build exec strings =====================
say "=== [B8] build shared-network exec strings ==="

EXE_SERVER="$PODMAN_BIN run --rm --replace --name $CONTAINER_SERVER --network $NET --publish 127.0.0.1:$HOST_PORT:$SERVER_PORT --memory 1024m --user 0:0 --security-opt=no-new-privileges --env-file $WP_ENV -v $VOL_SERVER:/var/lib/woodpecker $IMAGE_SERVER"

EXE_AGENT="$PODMAN_BIN run --rm --replace --name $CONTAINER_AGENT --network container:$CONTAINER_SERVER --memory 768m --user 0:0 --security-opt=no-new-privileges --env-file $WP_ENV -v $PODMAN_SOCKET:/var/run/docker.sock -v $VOL_AGENT:/var/lib/woodpecker $IMAGE_AGENT"

say "[B8] server exec built"
say "[B8] agent exec built with --network container:$CONTAINER_SERVER"

# ===================== [B9] install units =====================
say "=== [B9] install permanent Woodpecker units ==="

{
  printf '# Brick 10A: Woodpecker CI server (BP shared-network agent mode).\n'
  printf '# BP: cached-ref image policy; Postgres-backed; Gitea OAuth configured; loopback-only.\n'
  printf '# Image ref: %s\n' "$IMAGE_SERVER"
  printf '# Frozen digest (%s): %s\n' "$IMAGE_SERVER_DIGEST_SOURCE" "${IMAGE_SERVER_DIGEST:-none}"
  printf '# Host endpoint: http://127.0.0.1:%s\n' "$HOST_PORT"
  printf '# Internal HTTP: http://%s:%s\n' "$CONTAINER_SERVER" "$SERVER_PORT"
  printf '# Internal gRPC: %s\n' "$GRPC_ADDR"
  printf '# Agent mode: --network container:%s\n' "$CONTAINER_SERVER"
  printf '# Volume: %s:/var/lib/woodpecker\n' "$VOL_SERVER"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Woodpecker CI Server (Aether BP shared-net)\n'
  printf 'After=network-online.target postgres.service\n'
  printf 'Wants=network-online.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStartPre=/bin/bash %s postgres\n' "$DNS_SCRIPT"
  printf 'ExecStart=%s\n' "$EXE_SERVER"
  printf 'Restart=always\n'
  printf 'RestartSec=3\n'
  printf 'TimeoutStartSec=240\n'
  printf 'Delegate=yes\n'
  printf '\n'
  printf '[Install]\n'
  printf 'WantedBy=default.target\n'
} > "$TMPD/woodpecker-server.service.desired"

{
  printf '# Brick 10A: Woodpecker CI agent (BP shared-network mode).\n'
  printf '# BP: agent shares woodpecker-server network namespace; connects to 127.0.0.1:9000.\n'
  printf '# Image ref: %s\n' "$IMAGE_AGENT"
  printf '# Frozen digest (%s): %s\n' "$IMAGE_AGENT_DIGEST_SOURCE" "${IMAGE_AGENT_DIGEST:-none}"
  printf '# Server target: %s\n' "$GRPC_ADDR"
  printf '# Backend: docker via rootless Podman socket\n'
  printf '# Socket: %s:/var/run/docker.sock\n' "$PODMAN_SOCKET"
  printf '# Volume: %s:/var/lib/woodpecker\n' "$VOL_AGENT"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Woodpecker CI Agent (Aether BP shared-net)\n'
  printf 'After=network-online.target %s.service\n' "$SERVICE_SERVER"
  printf 'Wants=network-online.target %s.service\n' "$SERVICE_SERVER"
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStartPre=/bin/bash %s %s 90 2\n' "$SERVER_WAIT_SCRIPT" "$CONTAINER_SERVER"
  printf 'ExecStart=%s\n' "$EXE_AGENT"
  printf 'Restart=always\n'
  printf 'RestartSec=3\n'
  printf 'TimeoutStartSec=240\n'
  printf 'Delegate=yes\n'
  printf '\n'
  printf '[Install]\n'
  printf 'WantedBy=default.target\n'
} > "$TMPD/woodpecker-agent.service.desired"

install_unit_if_changed "$TMPD/woodpecker-server.service.desired" "$UNIT_SRC_SERVER" "$UNIT_SRC_SERVER_BAK"
install_unit_if_changed "$UNIT_SRC_SERVER" "$UNIT_INST_SERVER" "$UNIT_INST_SERVER_BAK"
install_unit_if_changed "$TMPD/woodpecker-agent.service.desired" "$UNIT_SRC_AGENT" "$UNIT_SRC_AGENT_BAK"
install_unit_if_changed "$UNIT_SRC_AGENT" "$UNIT_INST_AGENT" "$UNIT_INST_AGENT_BAK"

"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true

if ! systemctl --user daemon-reload; then
  rollback_woodpecker_only
  halt "systemctl --user daemon-reload failed"
fi

# ===================== [B10] start server =====================
say "=== [B10] start Woodpecker server ==="
if ! systemctl --user enable "$SERVICE_SERVER.service"; then
  dump_state
  rollback_woodpecker_only
  halt "could not enable $SERVICE_SERVER.service"
fi
if ! systemctl --user start "$SERVICE_SERVER.service"; then
  dump_state
  rollback_woodpecker_only
  halt "could not start $SERVICE_SERVER.service"
fi

OK=no
for i in $(seq 1 90); do
  if [ "$(active_state "$SERVICE_SERVER.service")" = active ] &&
     [ "$(container_status "$CONTAINER_SERVER")" = running ]; then
    OK=yes
    break
  fi
  sleep 2
done
if [ "$OK" != yes ]; then
  dump_state
  rollback_woodpecker_only
  halt "Woodpecker server did not reach active+running"
fi
say "[B10] server unit_active=active container_status=running"

if ! wait_server_health 150; then
  say "[B10] server endpoint=$SERVER_ENDPOINT code=$SERVER_CODE"
  dump_state
  rollback_woodpecker_only
  halt "P1 failed: Woodpecker server health endpoint never returned 200"
fi
say "[B10] P1 server health ok endpoint=$SERVER_ENDPOINT code=$SERVER_CODE"

# ===================== [B11] start agent =====================
say "=== [B11] start Woodpecker agent ==="
if ! systemctl --user enable "$SERVICE_AGENT.service"; then
  dump_state
  rollback_woodpecker_only
  halt "could not enable $SERVICE_AGENT.service"
fi
if ! systemctl --user start "$SERVICE_AGENT.service"; then
  dump_state
  rollback_woodpecker_only
  halt "could not start $SERVICE_AGENT.service"
fi

OK=no
for i in $(seq 1 90); do
  if [ "$(active_state "$SERVICE_AGENT.service")" = active ] &&
     [ "$(container_status "$CONTAINER_AGENT")" = running ]; then
    OK=yes
    break
  fi
  sleep 2
done
if [ "$OK" != yes ]; then
  dump_state
  rollback_woodpecker_only
  halt "Woodpecker agent did not reach active+running"
fi
say "[B11] agent unit_active=active container_status=running"

sleep 10

AGENT_LOGS="$(podman logs --tail 180 "$CONTAINER_AGENT" 2>&1 || true)"
SERVER_LOGS="$(podman logs --tail 180 "$CONTAINER_SERVER" 2>&1 || true)"
COMBINED_LOGS="$AGENT_LOGS
$SERVER_LOGS"

if logs_have_bad "$COMBINED_LOGS"; then
  printf '%s\n' "$AGENT_LOGS" | sed 's/^/    agent-log: /' || true
  printf '%s\n' "$SERVER_LOGS" | sed 's/^/    server-log: /' || true
  dump_state
  rollback_woodpecker_only
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BP found bad Woodpecker log markers shortly after agent start. Do not proceed to Traefik. Inspect agent-log/server-log/unit dump above. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" >> "$IDX"
  fi
  halt "P2 failed: Woodpecker logs contain bad markers after agent start"
fi
say "[B11] P2 no bad markers after initial 10s settle"

if logs_have_good "$COMBINED_LOGS"; then
  say "[B11] positive agent-connected log marker found"
else
  say "[B11] explicit agent-connected marker not found yet; continuing to 20s stability watch"
fi

# ===================== [B12] final stability watch =====================
say "=== [B12] final 20s stability watch ==="
systemctl --user reset-failed "$SERVICE_SERVER.service" >/dev/null 2>&1 || true
systemctl --user reset-failed "$SERVICE_AGENT.service" >/dev/null 2>&1 || true
sleep 20

NRESTARTS_SERVER_AFTER="$(nrestarts "$SERVICE_SERVER.service")"
NRESTARTS_AGENT_AFTER="$(nrestarts "$SERVICE_AGENT.service")"

if [ "$(active_state "$SERVICE_SERVER.service")" != active ] ||
   [ "$(container_status "$CONTAINER_SERVER")" != running ] ||
   ! server_health_ok; then
  dump_state
  rollback_woodpecker_only
  halt "P3 failed: Woodpecker server unstable after 20s watch"
fi
if [ "$(active_state "$SERVICE_AGENT.service")" != active ] ||
   [ "$(container_status "$CONTAINER_AGENT")" != running ]; then
  dump_state
  rollback_woodpecker_only
  halt "P3 failed: Woodpecker agent unstable after 20s watch"
fi
if [ "$NRESTARTS_SERVER_AFTER" -gt 0 ] || [ "$NRESTARTS_AGENT_AFTER" -gt 0 ]; then
  dump_state
  rollback_woodpecker_only
  halt "P3 failed: restart counter climbed server=$NRESTARTS_SERVER_AFTER agent=$NRESTARTS_AGENT_AFTER"
fi

AGENT_LOGS="$(podman logs --tail 250 "$CONTAINER_AGENT" 2>&1 || true)"
SERVER_LOGS="$(podman logs --tail 250 "$CONTAINER_SERVER" 2>&1 || true)"
COMBINED_LOGS="$AGENT_LOGS
$SERVER_LOGS"

if logs_have_bad "$COMBINED_LOGS"; then
  printf '%s\n' "$AGENT_LOGS" | sed 's/^/    agent-log: /' || true
  printf '%s\n' "$SERVER_LOGS" | sed 's/^/    server-log: /' || true
  dump_state
  rollback_woodpecker_only
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BP 20s stability watch found bad Woodpecker log markers. Do not proceed to Traefik. Inspect logs above. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" >> "$IDX"
  fi
  halt "P4 failed: Woodpecker logs contain bad markers during 20s stability watch"
fi

say "[B12] P3 stable: server NRestarts=$NRESTARTS_SERVER_AFTER agent NRestarts=$NRESTARTS_AGENT_AFTER after 20s"
say "[B12] P4 clean: no connection-refused/fatal/ephemeral-secret/backend/socket markers"

# ===================== [B13] final state =====================
say "=== [B13] final state ==="
say "[B13] server_active=$(active_state "$SERVICE_SERVER.service") server_enabled=$(enabled_state "$SERVICE_SERVER.service") server_container=$(container_status "$CONTAINER_SERVER")"
say "[B13] agent_active=$(active_state "$SERVICE_AGENT.service") agent_enabled=$(enabled_state "$SERVICE_AGENT.service") agent_container=$(container_status "$CONTAINER_AGENT")"
say "[B13] host=http://127.0.0.1:$HOST_PORT internal_server=http://$CONTAINER_SERVER:$SERVER_PORT grpc_addr=$GRPC_ADDR agent_network=container:$CONTAINER_SERVER"
say "[B13] server_endpoint=$SERVER_ENDPOINT server_code=$SERVER_CODE nrestarts_server=$NRESTARTS_SERVER_AFTER nrestarts_agent=$NRESTARTS_AGENT_AFTER"
podman ps --filter "name=$CONTAINER_SERVER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps-server: /' || true
podman ps --filter "name=$CONTAINER_AGENT" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps-agent: /' || true

# ===================== [B14] ledger + replay =====================
say "=== [B14] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BP-woodpecker-shared-network | GATE=PASS | %s: stabilized Woodpecker by running agent in server network namespace; server_image=%s digest=%s(%s); agent_image=%s digest=%s(%s); service_server=%s container_server=%s service_agent=%s container_agent=%s agent_network=container:%s network=%s host=http://127.0.0.1:%s internal_server=http://%s:%s grpc_addr=%s grpc_secret_persisted=yes agent_secret_matched=yes backend=docker podman_socket=%s server_endpoint=%s nrestarts_server=%s nrestarts_agent=%s; no browser login required; no pipeline execution required; no public exposure; no ssh; no ollama/open-webui; no secret echo. |\n' \
    "$(date +%F)" \
    "$TOKEN" \
    "$IMAGE_SERVER" "${IMAGE_SERVER_DIGEST:-none}" "$IMAGE_SERVER_DIGEST_SOURCE" \
    "$IMAGE_AGENT" "${IMAGE_AGENT_DIGEST:-none}" "$IMAGE_AGENT_DIGEST_SOURCE" \
    "$SERVICE_SERVER" "$CONTAINER_SERVER" \
    "$SERVICE_AGENT" "$CONTAINER_AGENT" \
    "$CONTAINER_SERVER" \
    "$NET" "$HOST_PORT" \
    "$CONTAINER_SERVER" "$SERVER_PORT" \
    "$GRPC_ADDR" \
    "$PODMAN_SOCKET" \
    "$SERVER_ENDPOINT" \
    "$NRESTARTS_SERVER_AFTER" "$NRESTARTS_AGENT_AFTER" >> "$IDX"
  say "[B14] ledger row appended."
else
  say "[B14] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[B14] suppression proof: present." || say "[B14] WARNING: missing."

write_replay_bp

say "[RESULT] BP HEALED + WOODPECKER BRICK 10A GREEN — server=http://127.0.0.1:$HOST_PORT agent=shared-network-container grpc=$GRPC_ADDR secret=persisted stability=20s-clean; next: build traefik; still no Ollama/OpenWebUI/chat-model."
exit 0
