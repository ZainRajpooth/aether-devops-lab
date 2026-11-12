#!/usr/bin/env bash
# 20261030-BQ — Traefik brick 11: loopback-only edge router in front of the proven stack.
# Additive: does NOT remove or alter any existing direct publish (gitea:3001, woodpecker:8000,
# grafana:3000, n8n:5678 all keep working; Woodpecker OAuth redirect stays valid).
# Identity of routing is proven STRUCTURALLY via Traefik's own control-plane API
# (/api/http/services + /api/http/routers), NOT by sniffing backend bodies — this is the
# deliberate fix for this session's recurring "guessed-body / false-green" class.
# A second liveness-through-proxy layer probes each backend on a path already observed 200
# this session, with the correct Host header.
# Decisions recorded in a DECISION ledger row: 8888 loopback-only (80/443+TLS deferred; 8080=weaviate);
# file provider watch:false (restart to apply edits); cached-ref-first + digest freeze;
# /etc/hosts is a one-time MANUAL user step (script never sudo, never edits /etc/hosts).
# Safety: no sudo; no image pull; no model download; no ollama/open-webui; no secret echo;
#         --check pure/read-only.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( );
#             no backticks as shell substitution (backticks appear ONLY as literal Traefik rule
#             syntax inside QUOTED heredocs, where the shell does not process them).
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

SERVICE="traefik"
CONTAINER="traefik"
IMAGE="docker.io/library/traefik:latest"
HOST_PORT="8888"
INNER_PORT="8888"
NET="aether"

CFG_DIR="$A/infra/traefik"
STATIC_CFG="$CFG_DIR/traefik.yml"
DYN_DIR="$CFG_DIR/dynamic"
DYN_CFG="$DYN_DIR/dynamic.yml"
STATIC_BAK="$STATIC_CFG.pre-BQ.bak"
DYN_BAK="$DYN_CFG.pre-BQ.bak"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/traefik.service"
UNIT_INST="$HOME/.config/systemd/user/traefik.service"
UNIT_SRC_BAK="$UNIT_SRC.pre-BQ.bak"
UNIT_INST_BAK="$UNIT_INST.pre-BQ.bak"

DNS_SCRIPT="$A/infra/scripts/aether-dns-wait.sh"
ALPINE="docker.io/library/alpine:latest"

BACKEND_CONTAINERS="gitea grafana woodpecker-server n8n"

DECISION_TOKEN="bq-traefik-design-decisions-v1"
FAIL_TOKEN="bq-traefik-brick11-failed-v1"
TOKEN="bq-traefik-brick11-green-v1"
SLUG_REPLAY="20261030-BQ-traefik-brick11-replay.sh"

IMAGE_DIGEST=""
IMAGE_DIGEST_SOURCE=""
ENTRY_CODE="000"
NRESTARTS_AFTER=0

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
known_traefik_container_exists(){
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}
listener_pids_on_port(){
  local port="$1"
  local out=""
  local pat="127\.0\.0\.1:$port|\[::1\]:$port|\*:$port|0\.0\.0\.0:$port"
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltnp 2>/dev/null | grep -E "$pat" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
  fi
  if [ -z "$out" ] && command -v lsof >/dev/null 2>&1; then
    out="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>2 {print $2}' | sort -u || true)"
  fi
  printf '%s\n' "$out" | grep -E '^[0-9]+$' || true
}
pid_cgroup(){
  local pid="$1"
  if [ -r "/proc/$pid/cgroup" ]; then
    tr '\n' ' ' < "/proc/$pid/cgroup" 2>/dev/null || true
  fi
}
classify_port_pid(){
  local pid="$1"
  local cg
  cg="$(pid_cgroup "$pid")"
  if printf '%s' "$cg" | grep -q "$SERVICE.service"; then
    printf 'known-service'
    return
  fi
  if printf '%s' "$cg" | grep -q 'libpod'; then
    if known_traefik_container_exists; then
      printf 'known-container'
      return
    fi
  fi
  printf 'unknown'
}
port_owner_report(){
  local port="$1"
  local pids pid cls
  pids="$(listener_pids_on_port "$port")"
  if [ -z "$pids" ]; then
    printf 'free'
    return
  fi
  while IFS= read -r pid; do
    if [ -z "$pid" ]; then
      continue
    fi
    cls="$(classify_port_pid "$pid")"
    say "[Q0] listener pid=$pid port=$port class=$cls"
    if [ "$cls" = unknown ]; then
      printf 'unknown'
      return
    fi
  done <<< "$pids"
  printf 'known'
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
# Host-header probe: writes body to $2, prints HTTP code. No body assumptions by callers.
probe_host(){
  local hdr="$1"
  local out="$2"
  local path="${3:-/}"
  local code
  : > "$out"
  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 10 -H "Host: $hdr" "http://127.0.0.1:$HOST_PORT$path" 2>/dev/null || true)"
  code="$(norm "$code")"
  if [ -z "$code" ]; then
    code=000
  fi
  printf '%s' "$code"
}
rollback_traefik_only(){
  say "[ROLLBACK] stopping/disabling traefik service (config retained)"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}
dump_state(){
  systemctl --user status --no-pager "$SERVICE.service" 2>/dev/null | sed 's/^/    unit: /' || true
  journalctl --user -u "$SERVICE.service" -n 60 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 120 "$CONTAINER" 2>&1 | sed 's/^/    c: /' || true
}
install_if_changed(){
  local desired="$1"
  local dest="$2"
  local bak="$3"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  if [ ! -f "$dest" ] || ! cmp -s "$desired" "$dest"; then
    if [ -f "$dest" ] && [ ! -f "$bak" ]; then
      cp -p "$dest" "$bak"
      say "[Q] backup -> $bak"
    fi
    install -D -m 644 "$desired" "$dest" || halt "could not install $dest"
    say "[Q] installed -> $dest"
  else
    say "[Q] already desired -> $dest"
  fi
}
write_replay_bq(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BQ: Traefik unit installed+active; structural mapping + liveness-through-proxy green.
set -uo pipefail
A="$HOME/DevOps/aether"
UNIT_SRC="$A/infra/systemd/traefik.service"
UNIT_INST="$HOME/.config/systemd/user/traefik.service"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable traefik.service >/dev/null 2>&1 || true
systemctl --user restart traefik.service
HZ=no
for i in $(seq 1 90); do
  C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: traefik.aether.local' "http://127.0.0.1:8888/api/version" 2>/dev/null || true)"
  if [ "$C" = 200 ]; then
    HZ=yes
    break
  fi
  sleep 2
done
SVC="$(curl -s --max-time 8 -H 'Host: traefik.aether.local' "http://127.0.0.1:8888/api/http/services" 2>/dev/null || true)"
RTS="$(curl -s --max-time 8 -H 'Host: traefik.aether.local' "http://127.0.0.1:8888/api/http/routers" 2>/dev/null || true)"
MAP_OK=no
if printf '%s' "$SVC" | grep -q 'gitea:3000' && \
   printf '%s' "$SVC" | grep -q 'woodpecker-server:8000' && \
   printf '%s' "$SVC" | grep -q 'grafana:3000' && \
   printf '%s' "$SVC" | grep -q 'n8n:5678' && \
   printf '%s' "$RTS" | grep -q 'gitea.aether.local' && \
   printf '%s' "$RTS" | grep -q 'woodpecker.aether.local' && \
   printf '%s' "$RTS" | grep -q 'grafana.aether.local' && \
   printf '%s' "$RTS" | grep -q 'n8n.aether.local'; then
  MAP_OK=yes
fi
P1="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: gitea.aether.local' "http://127.0.0.1:8888/api/healthz" 2>/dev/null || true)"
P2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: grafana.aether.local' "http://127.0.0.1:8888/api/health" 2>/dev/null || true)"
P3="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: woodpecker.aether.local' "http://127.0.0.1:8888/api/health" 2>/dev/null || true)"
P4="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: n8n.aether.local' "http://127.0.0.1:8888/healthz" 2>/dev/null || true)"
if [ "$HZ" = yes ] && [ "$MAP_OK" = yes ] && [ "$P1" = 200 ] && [ "$P2" = 200 ] && [ "$P3" = 200 ] && [ "$P4" = 200 ]; then
  echo "  [GATE PASS] traefik api=ok mapping=ok gitea=200 grafana=200 woodpecker=200 n8n=200"
else
  echo "  [GATE FAIL] traefik api=$HZ mapping=$MAP_OK gitea=$P1 grafana=$P2 woodpecker=$P3 n8n=$P4"
  exit 1
fi
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[REPLAY] archived -> codemod/$SLUG_REPLAY"
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head id; do
  need_cmd "$c"
done
if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
  halt "missing required port diagnostic tool: ss or lsof"
fi
PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

# ===================== [Q0] read-only preconditions =====================
say "=== [Q0] preconditions ==="
if ! podman image exists "$IMAGE" 2>/dev/null; then
  halt "traefik image missing: $IMAGE (cached image required; do not pull ad hoc)"
fi
if ! podman image exists "$ALPINE" 2>/dev/null; then
  halt "alpine image missing (DNS guard needs it cached)"
fi
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing"
fi
MISSING_BACKENDS=""
for b in $BACKEND_CONTAINERS; do
  if [ "$(container_status "$b")" != running ]; then
    MISSING_BACKENDS="$MISSING_BACKENDS $b"
  fi
done
if [ -n "$MISSING_BACKENDS" ]; then
  halt "backend container(s) not running:$MISSING_BACKENDS (fix those first; do not proxy to a dead upstream)"
fi
PORT_OWNER="$(port_owner_report "$HOST_PORT")"
say "[Q0] host_port=$HOST_PORT owner=$PORT_OWNER"
if [ "$PORT_OWNER" = unknown ]; then
  halt "port 127.0.0.1:$HOST_PORT occupied by unknown process; not killing blindly"
fi
IMAGE_DIGEST="$(norm "$(podman image inspect "$IMAGE" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | awk '{print $1}' || true)")"
if [ -n "$IMAGE_DIGEST" ]; then
  IMAGE_DIGEST_SOURCE="repodigest"
else
  IMAGE_DIGEST="$(norm "$(podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)")"
  IMAGE_DIGEST_SOURCE="image-id"
fi
say "[Q0] image=$IMAGE digest(${IMAGE_DIGEST_SOURCE})=${IMAGE_DIGEST:-none}"
say "[Q0] backends running: $BACKEND_CONTAINERS"
say "[Q0] entrypoint=127.0.0.1:$HOST_PORT (loopback-only; 80/443+TLS deferred)"

if [ "$DRY" = 1 ]; then
  say "[Q0] dry-run plan (pure/read-only; no config write, no unit write, no start, no ledger):"
  say "    static cfg  -> $STATIC_CFG"
  say "    dynamic cfg -> $DYN_CFG"
  say "    unit        -> $UNIT_SRC / $UNIT_INST"
  say "    gate layer1 -> Traefik API /api/http/services + /api/http/routers structural mapping"
  say "    gate layer2 -> Host-header liveness: gitea /api/healthz, grafana /api/health, woodpecker /api/health, n8n /healthz, traefik /dashboard/ + /api/version"
  say "    hosts file  -> NOT touched (one-time MANUAL user step printed at end)"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched."
  exit 0
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user" "$CFG_DIR" "$DYN_DIR"
touch "$IDX"

# ===================== [Q1] DECISION ledger row =====================
say "=== [Q1] decision ledger row ==="
if ! grep -qF "$DECISION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | DECISION | %s | APPEND-ONLY | Traefik brick 11 design: (1) routing identity proven STRUCTURALLY via Traefik control-plane API (/api/http/services + /api/http/routers) instead of backend-body sniffing, to close this session'"'"'s recurring guessed-body/false-green class; (2) entrypoint 127.0.0.1:8888 loopback-only — port 80/443 and TLS deferred (8080 already used by Weaviate; low-port bind rootless would need a sudo/sysctl gamble we refuse); (3) file provider with watch:false — config edits require systemctl --user restart traefik, removing inotify/bind-mount uncertainty; (4) cached-ref-first traefik:latest with RepoDigest freeze; (5) /etc/hosts is a one-time MANUAL user step (script never sudo, never edits /etc/hosts); automated gate uses explicit Host headers which equal the runtime routing key; (6) additive — existing direct publishes and the Woodpecker OAuth redirect (127.0.0.1:8000) remain valid. |\n' \
    "$(date +%F)" "$DECISION_TOKEN" >> "$IDX"
  say "[Q1] decision row appended."
else
  say "[Q1] decision row already present (guard suppressed)."
fi
grep -qF "$DECISION_TOKEN" "$IDX" 2>/dev/null && say "[Q1] suppression proof: present." || say "[Q1] WARNING: missing."

# ===================== [Q2] static config =====================
say "=== [Q2] write Traefik static config ==="
cat > "$TMPD/traefik.yml" <<'YEOF'
# Brick 11: Traefik static config (BQ). Loopback-only edge router.
# Backticks below are literal Traefik rule syntax inside this quoted heredoc;
# they are NOT shell command substitution.
global:
  checkNewVersion: false
  sendAnonymousUsage: false
entryPoints:
  web:
    address: ":8888"
api:
  dashboard: true
providers:
  file:
    filename: "/etc/traefik/dynamic/dynamic.yml"
    watch: false
log:
  level: INFO
accessLog: {}
YEOF
if ! cmp -s "$TMPD/traefik.yml" "$STATIC_CFG"; then
  if [ -f "$STATIC_CFG" ] && [ ! -f "$STATIC_BAK" ]; then
    cp -p "$STATIC_CFG" "$STATIC_BAK"
    say "[Q2] static backup -> $STATIC_BAK"
  fi
  install -D -m 644 "$TMPD/traefik.yml" "$STATIC_CFG" || halt "could not write $STATIC_CFG"
  say "[Q2] static config -> $STATIC_CFG"
else
  say "[Q2] static config already desired"
fi

# ===================== [Q3] dynamic config =====================
say "=== [Q3] write Traefik dynamic config ==="
cat > "$TMPD/dynamic.yml" <<'YEOF'
# Brick 11: Traefik dynamic config (BQ). Host-based routers on the aether network.
# Backticks are literal Traefik rule syntax inside this quoted heredoc, not shell substitution.
http:
  routers:
    gitea-router:
      rule: "Host(`gitea.aether.local`)"
      entryPoints: ["web"]
      service: gitea-svc
    woodpecker-router:
      rule: "Host(`woodpecker.aether.local`)"
      entryPoints: ["web"]
      service: woodpecker-svc
    grafana-router:
      rule: "Host(`grafana.aether.local`)"
      entryPoints: ["web"]
      service: grafana-svc
    n8n-router:
      rule: "Host(`n8n.aether.local`)"
      entryPoints: ["web"]
      service: n8n-svc
    traefik-dashboard-router:
      rule: "Host(`traefik.aether.local`) && PathPrefix(`/dashboard`)"
      entryPoints: ["web"]
      service: api@internal
    traefik-api-router:
      rule: "Host(`traefik.aether.local`) && PathPrefix(`/api`)"
      entryPoints: ["web"]
      service: api@internal
  services:
    gitea-svc:
      loadBalancer:
        servers:
          - url: "http://gitea:3000"
    woodpecker-svc:
      loadBalancer:
        servers:
          - url: "http://woodpecker-server:8000"
    grafana-svc:
      loadBalancer:
        servers:
          - url: "http://grafana:3000"
    n8n-svc:
      loadBalancer:
        servers:
          - url: "http://n8n:5678"
YEOF
if ! cmp -s "$TMPD/dynamic.yml" "$DYN_CFG"; then
  if [ -f "$DYN_CFG" ] && [ ! -f "$DYN_BAK" ]; then
    cp -p "$DYN_CFG" "$DYN_BAK"
    say "[Q3] dynamic backup -> $DYN_BAK"
  fi
  install -D -m 644 "$TMPD/dynamic.yml" "$DYN_CFG" || halt "could not write $DYN_CFG"
  say "[Q3] dynamic config -> $DYN_CFG"
else
  say "[Q3] dynamic config already desired"
fi

# ===================== [Q4] DNS guard present =====================
say "=== [Q4] ensure shared DNS guard ==="
if [ ! -x "$DNS_SCRIPT" ]; then
  halt "shared DNS guard missing/not executable: $DNS_SCRIPT (run BP/BI first)"
fi
say "[Q4] DNS guard present -> $DNS_SCRIPT"

# ===================== [Q5] stop known state + port =====================
say "=== [Q5] stop known Traefik state ==="
rollback_traefik_only
PORT_OWNER="$(port_owner_report "$HOST_PORT")"
if [ "$PORT_OWNER" = unknown ]; then
  halt "port $HOST_PORT occupied by unknown process after cleanup"
fi
if ! wait_tcp_port_free "$HOST_PORT" 30; then
  halt "port 127.0.0.1:$HOST_PORT still occupied after cleanup"
fi
say "[Q5] port 127.0.0.1:$HOST_PORT free"

# ===================== [Q6] build exec + unit =====================
say "=== [Q6] install permanent Traefik unit ==="
EXE="$PODMAN_BIN run --rm --replace --name $CONTAINER --network $NET --publish 127.0.0.1:$HOST_PORT:$INNER_PORT --memory 320m --user 0:0 --security-opt=no-new-privileges -v $CFG_DIR:/etc/traefik:ro $IMAGE --configfile=/etc/traefik/traefik.yml"

{
  printf '# Brick 11: Traefik edge router (BQ). Loopback-only; additive to direct publishes.\n'
  printf '# Image ref: %s\n' "$IMAGE"
  printf '# Frozen digest (%s): %s\n' "$IMAGE_DIGEST_SOURCE" "${IMAGE_DIGEST:-none}"
  printf '# Entrypoint: http://127.0.0.1:%s  (80/443+TLS deferred)\n' "$HOST_PORT"
  printf '# Config (ro bind): %s -> /etc/traefik\n' "$CFG_DIR"
  printf '# Routing identity proven via Traefik API, not body sniffing (see DECISION row).\n'
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Traefik Edge Router (Aether)\n'
  printf 'After=network-online.target gitea.service grafana.service woodpecker-server.service n8n.service\n'
  printf 'Wants=network-online.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStartPre=/bin/bash %s gitea grafana woodpecker-server n8n\n' "$DNS_SCRIPT"
  printf 'ExecStart=%s\n' "$EXE"
  printf 'Restart=always\n'
  printf 'RestartSec=3\n'
  printf 'TimeoutStartSec=180\n'
  printf 'Delegate=yes\n'
  printf '\n'
  printf '[Install]\n'
  printf 'WantedBy=default.target\n'
} > "$TMPD/traefik.service.desired"

install_if_changed "$TMPD/traefik.service.desired" "$UNIT_SRC" "$UNIT_SRC_BAK"
install_if_changed "$UNIT_SRC" "$UNIT_INST" "$UNIT_INST_BAK"
"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true
if ! systemctl --user daemon-reload; then
  rollback_traefik_only
  halt "daemon-reload failed"
fi

# ===================== [Q7] start =====================
say "=== [Q7] start Traefik ==="
if ! systemctl --user enable "$SERVICE.service"; then
  dump_state
  rollback_traefik_only
  halt "could not enable $SERVICE.service"
fi
if ! systemctl --user start "$SERVICE.service"; then
  dump_state
  rollback_traefik_only
  halt "could not start $SERVICE.service"
fi
OK=no
for i in $(seq 1 90); do
  if [ "$(active_state "$SERVICE.service")" = active ] &&
     [ "$(container_status "$CONTAINER")" = running ]; then
    OK=yes
    break
  fi
  sleep 2
done
if [ "$OK" != yes ]; then
  dump_state
  rollback_traefik_only
  halt "Traefik did not reach active+running"
fi
say "[Q7] unit_active=active container_status=running"

# ===================== [Q8] gate layer 1: Traefik alive + structural mapping =====================
say "=== [Q8] gate L1: Traefik API alive + structural router/service mapping ==="
READY=no
for i in $(seq 1 90); do
  ENTRY_CODE="$(probe_host "traefik.aether.local" "$TMPD/q-version.out" "/api/version")"
  if [ "$ENTRY_CODE" = 200 ]; then
    READY=yes
    break
  fi
  sleep 2
done
if [ "$READY" != yes ]; then
  say "[Q8] traefik /api/version code=$ENTRY_CODE"
  dump_state
  rollback_traefik_only
  halt "L1 failed: Traefik API never returned 200"
fi
say "[Q8] Traefik API alive (/api/version=200)"

curl -s --max-time 10 -H 'Host: traefik.aether.local' "http://127.0.0.1:$HOST_PORT/api/http/services" > "$TMPD/q-services.json" 2>/dev/null || true
curl -s --max-time 10 -H 'Host: traefik.aether.local' "http://127.0.0.1:$HOST_PORT/api/http/routers" > "$TMPD/q-routers.json" 2>/dev/null || true

cat > "$TMPD/q-expected.json" <<'EEOF'
{
  "services": {
    "gitea-svc": "http://gitea:3000",
    "woodpecker-svc": "http://woodpecker-server:8000",
    "grafana-svc": "http://grafana:3000",
    "n8n-svc": "http://n8n:5678"
  },
  "routers": {
    "gitea-router": {"host": "gitea.aether.local", "service": "gitea-svc"},
    "woodpecker-router": {"host": "woodpecker.aether.local", "service": "woodpecker-svc"},
    "grafana-router": {"host": "grafana.aether.local", "service": "grafana-svc"},
    "n8n-router": {"host": "n8n.aether.local", "service": "n8n-svc"},
    "traefik-dashboard-router": {"host": "traefik.aether.local", "service": "api@internal"},
    "traefik-api-router": {"host": "traefik.aether.local", "service": "api@internal"}
  }
}
EEOF

cat > "$TMPD/q-validate.py" <<'VEOF'
import sys, json

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception as e:
        sys.stderr.write("load-fail %s: %s\n" % (p, e))
        return None

svc = load(sys.argv[1])
rts = load(sys.argv[2])
exp = load(sys.argv[3])
if svc is None or rts is None or exp is None:
    sys.exit(3)

svc_by = {s.get("name"): s for s in svc if isinstance(s, dict)}
rts_by = {r.get("name"): r for r in rts if isinstance(r, dict)}

fails = 0

def strip_slash(u):
    return u[:-1] if isinstance(u, str) and u.endswith("/") else u

for name, want_url in exp["services"].items():
    s = svc_by.get(name)
    if not s:
        print("    SVC FAIL %s: missing from /api/http/services" % name)
        fails += 1
        continue
    servers = (s.get("loadBalancer") or {}).get("servers") or []
    if len(servers) != 1:
        print("    SVC FAIL %s: expected 1 server, got %d" % (name, len(servers)))
        fails += 1
        continue
    got = strip_slash(servers[0].get("url", ""))
    want = strip_slash(want_url)
    if got != want:
        print("    SVC FAIL %s: url=%s want=%s" % (name, got, want))
        fails += 1
    else:
        print("    SVC OK   %s -> %s" % (name, got))

for name, spec in exp["routers"].items():
    r = rts_by.get(name)
    if not r:
        print("    RTU FAIL %s: missing from /api/http/routers" % name)
        fails += 1
        continue
    rule = r.get("rule", "")
    svc_name = r.get("service", "")
    host_ok = spec["host"] in rule
    svc_ok = (svc_name == spec["service"])
    if not host_ok or not svc_ok:
        print("    RTU FAIL %s: rule=%s service=%s (want host~%s service=%s)" % (name, rule, svc_name, spec["host"], spec["service"]))
        fails += 1
    else:
        print("    RTU OK   %s: host~%s service=%s" % (name, spec["host"], svc_name))

if fails:
    print("    MAPPING: %d failure(s)" % fails)
    sys.exit(1)
print("    MAPPING: all services + routers structurally correct")
sys.exit(0)
VEOF

if ! python3 "$TMPD/q-validate.py" "$TMPD/q-services.json" "$TMPD/q-routers.json" "$TMPD/q-expected.json"; then
  VAL_RC=$?
  say "[Q8] structural validation rc=$VAL_RC"
  head -c 600 "$TMPD/q-services.json" 2>/dev/null | sed 's/^/    svc-head: /' || true
  head -c 600 "$TMPD/q-routers.json" 2>/dev/null | sed 's/^/    rtu-head: /' || true
  dump_state
  rollback_traefik_only
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BQ L1 structural mapping failed: Traefik API service/router mapping did not match expected map. This is the anti-typo/anti-false-green proof; inspect SVC/RTU lines + svc-head/rtu-head above. Do not proceed. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" >> "$IDX"
  fi
  halt "L1 failed: structural router/service mapping mismatch"
fi
say "[Q8] L1 PASS: structural mapping correct"

# ===================== [Q9] gate layer 2: liveness-through-proxy =====================
say "=== [Q9] gate L2: liveness-through-proxy (Host headers) ==="
declare -a L2_HOST L2_PATH L2_LABEL
L2_HOST=("gitea.aether.local" "grafana.aether.local" "woodpecker.aether.local" "n8n.aether.local" "traefik.aether.local")
L2_PATH=("/api/healthz" "/api/health" "/api/health" "/healthz" "/dashboard/")
L2_LABEL=("gitea" "grafana" "woodpecker" "n8n" "dashboard")
L2_FAIL=""
idx=0
while [ "$idx" -lt "${#L2_HOST[@]}" ]; do
  h="${L2_HOST[$idx]}"
  p="${L2_PATH[$idx]}"
  lbl="${L2_LABEL[$idx]}"
  code="$(probe_host "$h" "$TMPD/q-l2-$lbl.out" "$p")"
  body_head="$(head -c 160 "$TMPD/q-l2-$lbl.out" 2>/dev/null | tr '\n' ' ')"
  bad=no
  if printf '%s' "$body_head" | grep -Eiq '404 page not found|502 Bad Gateway|503 Service Unavailable|no such host|dial tcp'; then
    bad=yes
  fi
  if [ "$code" != 200 ] || [ "$bad" = yes ]; then
    L2_FAIL="$L2_FAIL $lbl($code)"
    say "[Q9] L2 FAIL $lbl host=$h path=$p code=$code body=$body_head"
  else
    say "[Q9] L2 OK   $lbl host=$h path=$p code=$code"
  fi
  idx=$((idx + 1))
done
if [ -n "$L2_FAIL" ]; then
  dump_state
  rollback_traefik_only
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BQ L2 liveness-through-proxy failed for:%s. Mapping was structurally correct (L1 passed), so this is a true backend-liveness or path signal, not a routing typo. Inspect L2 FAIL lines + dumps. Do not proceed. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" "$L2_FAIL" >> "$IDX"
  fi
  halt "L2 failed: liveness-through-proxy$L2_FAIL"
fi
say "[Q9] L2 PASS: all backends reachable + healthy through the proxy"

# ===================== [Q10] stability watch =====================
say "=== [Q10] stability watch ==="
systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
sleep 12
NRESTARTS_AFTER="$(nrestarts "$SERVICE.service")"
if [ "$(active_state "$SERVICE.service")" != active ] ||
   [ "$(container_status "$CONTAINER")" != running ]; then
  dump_state
  rollback_traefik_only
  halt "P-stable failed: Traefik unstable after 12s"
fi
ENTRY_CODE="$(probe_host "traefik.aether.local" "$TMPD/q-version2.out" "/api/version")"
if [ "$ENTRY_CODE" != 200 ]; then
  dump_state
  rollback_traefik_only
  halt "P-stable failed: Traefik API not 200 after watch (code=$ENTRY_CODE)"
fi
if [ "$NRESTARTS_AFTER" -gt 0 ]; then
  dump_state
  rollback_traefik_only
  halt "P-stable failed: NRestarts climbed to $NRESTARTS_AFTER"
fi
say "[Q10] stable: active+running+api200, NRestarts=$NRESTARTS_AFTER after 12s"

# ===================== [Q11] final state =====================
say "=== [Q11] final state ==="
say "[Q11] service_active=$(active_state "$SERVICE.service") enabled=$(enabled_state "$SERVICE.service") container=$(container_status "$CONTAINER")"
say "[Q11] image=$IMAGE digest_source=$IMAGE_DIGEST_SOURCE digest=${IMAGE_DIGEST:-none}"
say "[Q11] entrypoint=http://127.0.0.1:$HOST_PORT hostnames=gitea/woodpecker/grafana/n8n/traefik.aether.local"
say "[Q11] config_static=$STATIC_CFG config_dynamic=$DYN_CFG (watch:false -> restart to apply edits)"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [Q12] green ledger + replay =====================
say "=== [Q12] green ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BQ-traefik-brick11 | GATE=PASS | %s: installed Traefik loopback edge router; image=%s digest=%s(%s); service=%s container=%s network=%s entrypoint=http://127.0.0.1:%s hostnames=gitea/woodpecker/grafana/n8n/traefik.aether.local; static=%s dynamic=%s watch=false; gate-L1=structural-traefik-api-mapping; gate-L2=liveness-through-proxy(gitea/grafana/woodpecker/n8n/dashboard all 200); nrestarts=%s; additive-direct-publishes-preserved; no-sudo; no-etc-hosts-edit; no-80/443/TLS-yet; no-pull; no-ollama/open-webui; no-secret-echo. |\n' \
    "$(date +%F)" "$TOKEN" "$IMAGE" "${IMAGE_DIGEST:-none}" "$IMAGE_DIGEST_SOURCE" \
    "$SERVICE" "$CONTAINER" "$NET" "$HOST_PORT" "$STATIC_CFG" "$DYN_CFG" "$NRESTARTS_AFTER" >> "$IDX"
  say "[Q12] green row appended."
else
  say "[Q12] green row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[Q12] suppression proof: present." || say "[Q12] WARNING: missing."

write_replay_bq

say "[Q12] OPTIONAL one-time MANUAL host resolution (YOU run this with your own sudo; the script never does):"
say "    printf '%s\\n' '127.0.0.1 gitea.aether.local woodpecker.aether.local grafana.aether.local n8n.aether.local traefik.aether.local' | sudo tee -a /etc/hosts"
say "    (skip if you prefer the direct ports; the green gate above did NOT need it)"
say "[RESULT] TRAEFIK BRICK 11 GREEN — entrypoint=http://127.0.0.1:$HOST_PORT hostnames=gitea/woodpecker/grafana/n8n/traefik.aether.local mapping=structural-api liveness=all-200 nrestarts=$NRESTARTS_AFTER; additive (direct ports + Woodpecker OAuth redirect intact); next: build woodpecker pipeline proof; still no Ollama/OpenWebUI/chat-model; TLS/80-443 deferred."
exit 0
