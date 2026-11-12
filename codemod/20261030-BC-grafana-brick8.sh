#!/usr/bin/env bash
# 20261030-BC — Grafana brick 8 on aether.
# Proven dependencies:
#   AS/AT: llama-embed + core stack green.
#   AW: litellm green.
#   BB: n8n green, Postgres-backed, stable.
# Goal:
#   Grafana OSS as rootless Podman systemd user service.
#   Host admin: http://127.0.0.1:3000
#   Internal:   http://grafana:3000
#   DB:         dedicated Postgres database grafana owned by role grafana
#   DataSource: Prometheus at http://prometheus:9090
#   Gate:
#     /api/health database=ok
#     provisioned Prometheus datasource exists
#     Grafana proxy query to Prometheus returns success with data
#     provisioned dashboard exists
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
#   - loopback-only publish
#   - candidate proof on temporary ports before permanent promotion
# Hard rules:
#   - multi-line if/then/fi only
#   - bash -n mandatory before run
#   - no heredoc inside $( )
#   - no backticks
set -uo pipefail

TMPD="$(mktemp -d)"
SFX="$$"

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"

SERVICE="grafana"
CONTAINER="grafana"
IMAGE="docker.io/grafana/grafana:latest"
PORT="3000"
NET="aether"
VOL="grafana_data"
HOST_DIR="$A/data/grafana"

PROV_DIR="$A/config/grafana/provisioning"
GRAFANA_ENV="$A/secrets/grafana.env"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/grafana.service"
UNIT_INST="$HOME/.config/systemd/user/grafana.service"
UNIT_SRC_BAK="$UNIT_SRC.pre-BC.bak"
UNIT_INST_BAK="$UNIT_INST.pre-BC.bak"

PG_CONTAINER="postgres"
PG_PORT="5432"

PROM_SERVICE="prometheus"
PROM_CONTAINER="prometheus"

GF_DB_USER="grafana"
GF_DB_NAME="grafana"

DATASOURCE_UID="prometheus-aether"
DASHBOARD_UID="aether-overview"

FAIL_TOKEN="bc-grafana-brick8-candidates-failed-v1"
TOKEN="bc-grafana-brick8-green-v1"
SLUG_REPLAY="20261030-BC-grafana-brick8-replay.sh"

CANDIDATES=(
  keepid_named_sec
  keepid_named
  root_named
  root_bind
)

declare -A CAND_RC
declare -A CAND_NOTE

TEST_UNITS=()
TEST_CONTAINERS=()
TEST_VOLUMES=()
TEST_DIRS=()

SELECTED=""
CAND_SUMMARY=""
DS_OK=no
QUERY_OK=no
DASH_OK=no
HEALTH_OK=no

cleanup(){
  if [ "${#TEST_UNITS[@]}" -gt 0 ]; then
    for u in "${TEST_UNITS[@]}"; do
      systemctl --user disable --now "$u.service" >/dev/null 2>&1 || true
      rm -f "$HOME/.config/systemd/user/$u.service" 2>/dev/null || true
    done
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi

  if [ "${#TEST_CONTAINERS[@]}" -gt 0 ]; then
    for c in "${TEST_CONTAINERS[@]}"; do
      podman rm -f "$c" >/dev/null 2>&1 || true
    done
  fi

  if [ "${#TEST_VOLUMES[@]}" -gt 0 ]; then
    for v in "${TEST_VOLUMES[@]}"; do
      podman volume rm -f "$v" >/dev/null 2>&1 || true
    done
  fi

  if [ "${#TEST_DIRS[@]}" -gt 0 ]; then
    for d in "${TEST_DIRS[@]}"; do
      rm -rf "$d" 2>/dev/null || true
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
valid_ident(){
  local s="${1:-}"
  if printf '%s' "$s" | grep -Eq '^[A-Za-z_][A-Za-z0-9_$]{0,62}$'; then
    return 0
  fi
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
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true
}
env_has(){
  grep -q "^$1=." "$GRAFANA_ENV" 2>/dev/null
}
read_env_value(){
  awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$GRAFANA_ENV" 2>/dev/null || true
}
append_env(){
  local key="$1"
  local val="$2"
  printf '%s=%s\n' "$key" "$val" >> "$GRAFANA_ENV"
  chmod 600 "$GRAFANA_ENV" 2>/dev/null || true
}
ensure_env(){
  local key="$1"
  local val="$2"
  if ! env_has "$key"; then
    append_env "$key" "$val"
  fi
}
gen_hex_secret(){
  python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || true
}
container_env_value(){
  local cname="$1"
  local key="$2"
  podman inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' || true
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
known_grafana_container_exists(){
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
    if known_grafana_container_exists; then
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
    say "[C0] listener pid=$pid class=$cls"
    say "[C0] cmd=$(printf '%s' "$(pid_cmdline "$pid")" | cut -c1-180)"
    say "[C0] cgroup=$(printf '%s' "$(pid_cgroup "$pid")" | cut -c1-220)"

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
setup_netrc(){
  local user pass
  user="$(read_env_value GF_SECURITY_ADMIN_USER)"
  pass="$(read_env_value GF_SECURITY_ADMIN_PASSWORD)"
  if [ -z "$user" ] || [ -z "$pass" ]; then
    return 1
  fi
  printf 'machine 127.0.0.1 login %s password %s\n' "$user" "$pass" > "$TMPD/netrc"
  chmod 600 "$TMPD/netrc" 2>/dev/null || true
}
grafana_api_get(){
  local port="$1"
  local path="$2"
  local out="$3"
  local code

  if [ ! -f "$TMPD/netrc" ]; then
    if ! setup_netrc; then
      return 1
    fi
  fi

  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 10 --netrc-file "$TMPD/netrc" "http://127.0.0.1:$port$path" 2>/dev/null || true)"
  code="$(norm "$code")"
  if [ "$code" = 200 ]; then
    return 0
  fi
  return 1
}
grafana_health_ok(){
  local port="$1"
  local body code
  code="$(norm "$(http_code "http://127.0.0.1:$port/api/health")")"
  if [ "$code" != 200 ]; then
    return 1
  fi
  body="$(curl -s --max-time 5 "http://127.0.0.1:$port/api/health" 2>/dev/null || true)"
  printf '%s' "$body" | grep -q '"database":"ok"'
}
grafana_datasource_ok(){
  local port="$1"
  local out="$TMPD/ds.out"
  if ! grafana_api_get "$port" "/api/datasources/uid/$DATASOURCE_UID" "$out"; then
    return 1
  fi
  grep -q "\"uid\":\"$DATASOURCE_UID\"" "$out" 2>/dev/null
}
grafana_dashboard_ok(){
  local port="$1"
  local out="$TMPD/dash.out"
  if ! grafana_api_get "$port" "/api/dashboards/uid/$DASHBOARD_UID" "$out"; then
    return 1
  fi
  grep -q "\"uid\":\"$DASHBOARD_UID\"" "$out" 2>/dev/null
}
grafana_prom_query_ok(){
  local port="$1"
  local out="$TMPD/query.out"
  local code

  if [ ! -f "$TMPD/netrc" ]; then
    if ! setup_netrc; then
      return 1
    fi
  fi

  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 15 --netrc-file "$TMPD/netrc" \
    --get "http://127.0.0.1:$port/api/datasources/proxy/uid/$DATASOURCE_UID/api/v1/query" \
    --data-urlencode 'query=count(up)' 2>/dev/null || true)"
  code="$(norm "$code")"
  if [ "$code" != 200 ]; then
    return 1
  fi

  if ! grep -q '"status":"success"' "$out" 2>/dev/null; then
    return 1
  fi

  python3 -c 'import sys,json
try:
    d=json.load(open(sys.argv[1]))
    r=d.get("data",{}).get("result",[])
    sys.exit(0 if len(r)>0 else 1)
except Exception:
    sys.exit(1)' "$out" 2>/dev/null
}
wait_grafana_ready(){
  local port="$1"
  local tries="${2:-90}"
  local i
  for i in $(seq 1 "$tries"); do
    if grafana_health_ok "$port" &&
       grafana_datasource_ok "$port" &&
       grafana_prom_query_ok "$port" &&
       grafana_dashboard_ok "$port"; then
      return 0
    fi
    sleep 2
  done
  return 1
}
journal_dump_for(){
  local unit="$1"
  local cname="$2"
  journalctl --user -u "$unit.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 80 "$cname" 2>&1 | sed 's/^/    c: /' || true
}
rollback_grafana_only(){
  say "[ROLLBACK] stopping/disabling grafana service (data retained)"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
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
    printf 'TimeoutStartSec=240\n'
    printf 'Delegate=yes\n\n'
    printf '[Install]\n'
    printf 'WantedBy=default.target\n'
  } > "$file"
}
build_exec_for_candidate(){
  local cand="$1"
  local cname="$2"
  local port="$3"
  local volref="$4"
  local -a args
  local exe="" part

  args=(
    "$PODMAN_BIN" run --rm --replace
    --name "$cname"
    --network "$NET"
    --publish "127.0.0.1:$port:3000"
    --memory 1536m
    --env-file "$GRAFANA_ENV"
    -v "$PROV_DIR:/etc/grafana/provisioning:ro"
    -v "$volref:/var/lib/grafana"
    -e "GF_SERVER_ROOT_URL=http://127.0.0.1:$port/"
    -e GF_SERVER_HTTP_PORT=3000
    -e GF_AUTH_ANONYMOUS_ENABLED=false
    -e GF_ANALYTICS_REPORTING_ENABLED=false
    -e GF_ANALYTICS_CHECK_FOR_UPDATES=false
  )

  case "$cand" in
    keepid_named_sec)
      args+=(--userns=keep-id --security-opt=no-new-privileges)
      ;;
    keepid_named)
      args+=(--userns=keep-id)
      ;;
    root_named)
      args+=(--user 0:0)
      ;;
    root_bind)
      args+=(--user 0:0)
      ;;
    *)
      halt "unknown candidate: $cand"
      ;;
  esac

  args+=("$IMAGE")

  for part in "${args[@]}"; do
    exe="$exe$part "
  done
  printf '%s' "${exe% }"
}
run_serving_test(){
  local unit="$1"
  local file="$2"
  local cname="$3"
  local port="$4"

  install -D -m 644 "$file" "$HOME/.config/systemd/user/$unit.service" || return 90
  TEST_UNITS+=("$unit")
  TEST_CONTAINERS+=("$cname")

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true

  local start_rc=0
  if ! systemctl --user start "$unit.service" >"$TMPD/$unit.start.out" 2>"$TMPD/$unit.start.err"; then
    start_rc=$?
  fi

  local ok=no
  if wait_grafana_ready "$port" 90; then
    ok=yes
  fi

  journal_dump_for "$unit" "$cname"
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
install_desired_file(){
  local desired="$1"
  local dest="$2"
  local bak="$dest.pre-BC.bak"

  mkdir -p "$(dirname "$dest")" 2>/dev/null || true

  if [ ! -f "$dest" ] || ! cmp -s "$desired" "$dest"; then
    if [ -f "$dest" ] && [ ! -f "$bak" ]; then
      cp -p "$dest" "$bak"
      say "[C2] backup -> $bak"
    fi
    install -D -m 644 "$desired" "$dest" || halt "could not install $dest"
    say "[C2] installed -> $dest"
  else
    say "[C2] already desired -> $dest"
  fi
}
psql_su(){
  local out="$1"
  podman exec -i --env-file "$TMPD/su.env" "$PG_CONTAINER" \
    psql -h 127.0.0.1 -p "$PG_PORT" -U "$SU_NAME" -d postgres \
    -t -A -q -v ON_ERROR_STOP=1 >"$out" 2>"$TMPD/psql-su.err"
}
psql_su_file(){
  local sqlfile="$1"
  local out="$2"
  podman exec -i --env-file "$TMPD/su.env" "$PG_CONTAINER" \
    psql -h 127.0.0.1 -p "$PG_PORT" -U "$SU_NAME" -d postgres \
    -t -A -q -v ON_ERROR_STOP=1 < "$sqlfile" >"$out" 2>"$TMPD/psql-su.err"
}
psql_su_db_file(){
  local sqlfile="$1"
  local out="$2"
  podman exec -i --env-file "$TMPD/su.env" "$PG_CONTAINER" \
    psql -h 127.0.0.1 -p "$PG_PORT" -U "$SU_NAME" -d "$GF_DB_NAME" \
    -t -A -q -v ON_ERROR_STOP=1 < "$sqlfile" >"$out" 2>"$TMPD/psql-su-db.err"
}
write_replay_bc(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BC: ensure Grafana unit is installed, active, and observability gate green.
set -uo pipefail
A="$HOME/DevOps/aether"
ENV="$A/secrets/grafana.env"
UNIT_SRC="$A/infra/systemd/grafana.service"
UNIT_INST="$HOME/.config/systemd/user/grafana.service"

install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable grafana.service >/dev/null 2>&1 || true
systemctl --user start grafana.service

HZ=no
for i in $(seq 1 90); do
  B="$(curl -s --max-time 5 http://127.0.0.1:3000/api/health 2>/dev/null || true)"
  if printf '%s' "$B" | grep -q '"database":"ok"'; then
    HZ=yes
    break
  fi
  sleep 2
done

USER="$(awk -F= '/^GF_SECURITY_ADMIN_USER=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
PASS="$(awk -F= '/^GF_SECURITY_ADMIN_PASSWORD=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
printf 'machine 127.0.0.1 login %s password %s\n' "$USER" "$PASS" > "/tmp/bc-replay.netrc"
chmod 600 "/tmp/bc-replay.netrc"

DS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "/tmp/bc-replay.netrc" http://127.0.0.1:3000/api/datasources/uid/prometheus-aether)"
Q="$(curl -s --max-time 15 --netrc-file "/tmp/bc-replay.netrc" --get http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus-aether/api/v1/query --data-urlencode 'query=count(up)')"
DASH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "/tmp/bc-replay.netrc" http://127.0.0.1:3000/api/dashboards/uid/aether-overview)"

rm -f "/tmp/bc-replay.netrc"

if [ "$HZ" = yes ] && [ "$DS" = 200 ] && [ "$DASH" = 200 ] && printf '%s' "$Q" | grep -q '"status":"success"'; then
  echo "  [GATE PASS] grafana health=ok datasource=ok dashboard=ok query=success"
else
  echo "  [GATE FAIL] grafana health=$HZ datasource=$DS dashboard=$DASH"
  exit 1
fi
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[REPLAY] archived -> codemod/$SLUG_REPLAY"
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head; do
  need_cmd "$c"
done

if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
  halt "missing required port diagnostic tool: ss or lsof"
fi

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user" "$PROV_DIR/datasources" "$PROV_DIR/dashboards/aether" "$A/secrets"
touch "$IDX"

# ===================== [C0] preconditions =====================
say "=== [C0] preconditions ==="

if ! podman image exists "$IMAGE" 2>/dev/null; then
  halt "Grafana image missing: $IMAGE (cached image expected; do not pull ad hoc)"
fi
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing; run AA reconcile first"
fi
if [ "$(container_status "$PG_CONTAINER")" != running ]; then
  halt "postgres container not running"
fi
if [ "$(active_state "$PROM_SERVICE.service")" != active ] ||
   [ "$(container_status "$PROM_CONTAINER")" != running ]; then
  halt "prometheus service/container not active+running"
fi

PORT_OWNER="$(port_owner_report)"
say "[C0] initial_port_owner=$PORT_OWNER"
say "[C0] network present: $NET"
say "[C0] postgres running"
say "[C0] prometheus active+running"

if [ "$DRY" = 1 ]; then
  say "[C0] dry-run plan (pure; no secret writes, no SQL, no unit writes, no start, no ledger):"
  say "    env       -> $GRAFANA_ENV (mode 600, contents not echoed)"
  say "    provisioning -> $PROV_DIR"
  say "    db        -> postgres role=$GF_DB_USER db=$GF_DB_NAME"
  say "    candidates: ${CANDIDATES[*]}"
  say "    service   -> $SERVICE.service"
  say "    container -> $CONTAINER"
  say "    host      -> http://127.0.0.1:$PORT"
  say "    internal  -> http://$CONTAINER:$PORT"
  say "[RESULT] DRY-RUN complete; no writes, no SQL, no start, no ledger row."
  exit 0
fi

# ===================== [C1] secret env file =====================
say "=== [C1] Grafana secret env file ==="
umask 077

if [ ! -f "$GRAFANA_ENV" ]; then
  : > "$GRAFANA_ENV"
  chmod 600 "$GRAFANA_ENV" 2>/dev/null || true
  say "[C1] created Grafana env file -> $GRAFANA_ENV"
else
  chmod 600 "$GRAFANA_ENV" 2>/dev/null || true
  say "[C1] Grafana env file present -> $GRAFANA_ENV"
fi

ensure_env GF_DATABASE_TYPE postgres
ensure_env GF_DATABASE_HOST postgres
ensure_env GF_DATABASE_PORT 5432
ensure_env GF_DATABASE_NAME "$GF_DB_NAME"
ensure_env GF_DATABASE_USER "$GF_DB_USER"
ensure_env GF_DATABASE_SSL_MODE disable
ensure_env GF_SECURITY_ADMIN_USER admin

if ! env_has GF_DATABASE_PASSWORD; then
  SECRET="$(gen_hex_secret)"
  if [ -z "$SECRET" ]; then
    halt "could not generate GF_DATABASE_PASSWORD"
  fi
  append_env GF_DATABASE_PASSWORD "$SECRET"
  say "[C1] appended GF_DATABASE_PASSWORD (value not echoed)"
else
  say "[C1] GF_DATABASE_PASSWORD present"
fi

if ! env_has GF_SECURITY_ADMIN_PASSWORD; then
  SECRET="$(gen_hex_secret)"
  if [ -z "$SECRET" ]; then
    halt "could not generate GF_SECURITY_ADMIN_PASSWORD"
  fi
  append_env GF_SECURITY_ADMIN_PASSWORD "$SECRET"
  say "[C1] appended GF_SECURITY_ADMIN_PASSWORD (value not echoed)"
else
  say "[C1] GF_SECURITY_ADMIN_PASSWORD present"
fi

GF_DB_PASS="$(read_env_value GF_DATABASE_PASSWORD)"
GF_ADMIN_PASS="$(read_env_value GF_SECURITY_ADMIN_PASSWORD)"
if [ -z "$GF_DB_PASS" ] || [ -z "$GF_ADMIN_PASS" ]; then
  halt "could not read required secrets from $GRAFANA_ENV"
fi
say "[C1] db password present=yes length=$(printf '%s' "$GF_DB_PASS" | wc -c | tr -d ' ')"
say "[C1] admin password present=yes length=$(printf '%s' "$GF_ADMIN_PASS" | wc -c | tr -d ' ')"

if ! valid_ident "$GF_DB_USER"; then
  halt "unsafe GF_DB_USER identifier"
fi
if ! valid_ident "$GF_DB_NAME"; then
  halt "unsafe GF_DB_NAME identifier"
fi

# ===================== [C2] provisioning files =====================
say "=== [C2] Grafana provisioning files ==="

cat > "$TMPD/datasources.yaml" <<'YEOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus-aether
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData: {}
    secureJsonData: {}
YEOF

cat > "$TMPD/dashboards-provider.yaml" <<'YEOF'
apiVersion: 1

providers:
  - name: aether
    orgId: 1
    folder: Aether
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards/aether
YEOF

cat > "$TMPD/overview.json" <<'JEOF'
{
  "uid": "aether-overview",
  "title": "Aether Overview",
  "tags": ["aether", "devops"],
  "timezone": "",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "time": {
    "from": "now-1h",
    "to": "now"
  },
  "panels": [
    {
      "id": 1,
      "type": "table",
      "title": "Prometheus up targets",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus-aether"
      },
      "gridPos": {
        "h": 10,
        "w": 24,
        "x": 0,
        "y": 0
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus-aether"
          },
          "expr": "up"
        }
      ]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Node exporter present",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus-aether"
      },
      "gridPos": {
        "h": 6,
        "w": 12,
        "x": 0,
        "y": 10
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus-aether"
          },
          "expr": "count(node_exporter_build_info)"
        }
      ]
    },
    {
      "id": 3,
      "type": "stat",
      "title": "Prometheus targets up",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus-aether"
      },
      "gridPos": {
        "h": 6,
        "w": 12,
        "x": 12,
        "y": 10
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus-aether"
          },
          "expr": "count(up == 1)"
        }
      ]
    }
  ]
}
JEOF

install_desired_file "$TMPD/datasources.yaml" "$PROV_DIR/datasources/aether.yaml"
install_desired_file "$TMPD/dashboards-provider.yaml" "$PROV_DIR/dashboards/dashboards.yaml"
install_desired_file "$TMPD/overview.json" "$PROV_DIR/dashboards/aether/overview.json"

# ===================== [C3] Postgres role/database =====================
say "=== [C3] ensure Grafana Postgres role/database ==="

SU_NAME="$(container_env_value "$PG_CONTAINER" POSTGRES_USER)"
if [ -z "$SU_NAME" ]; then
  SU_NAME="postgres"
fi
if ! valid_ident "$SU_NAME"; then
  halt "unsafe superuser identifier from container env"
fi
say "[C3] superuser=$SU_NAME (password not shown)"

SUPW="$(container_env_value "$PG_CONTAINER" POSTGRES_PASSWORD)"
if [ -z "$SUPW" ]; then
  PWFILE="$(container_env_value "$PG_CONTAINER" POSTGRES_PASSWORD_FILE)"
  if [ -n "$PWFILE" ]; then
    SUPW="$(podman exec "$PG_CONTAINER" cat "$PWFILE" 2>/dev/null | tr -d '\n' || true)"
  fi
fi
if [ -z "$SUPW" ]; then
  halt "could not discover postgres superuser password from container env/password file"
fi

printf 'PGPASSWORD=%s\n' "$SUPW" > "$TMPD/su.env"
chmod 600 "$TMPD/su.env" 2>/dev/null || true
unset SUPW

ROLE_COUNT_OUT="$TMPD/role-count.out"
if ! psql_su "$ROLE_COUNT_OUT" <<SQL
\set ON_ERROR_STOP on
SELECT count(*)::text FROM pg_roles WHERE rolname = '${GF_DB_USER}';
SQL
then
  tail -n 12 "$TMPD/psql-su.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "Postgres role count query failed"
fi

ROLE_COUNT="$(to_int "$(norm "$(head -n1 "$ROLE_COUNT_OUT" | tr -d '\r')")")"
if [ "$ROLE_COUNT" -eq 0 ]; then
  cat > "$TMPD/create-role.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', '${GF_DB_USER}', '${GF_DB_PASS}')
\gexec
SQL
  chmod 600 "$TMPD/create-role.sql" 2>/dev/null || true

  CREATE_ROLE_OUT="$TMPD/create-role.out"
  if ! psql_su_file "$TMPD/create-role.sql" "$CREATE_ROLE_OUT"; then
    tail -n 12 "$TMPD/psql-su.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "CREATE ROLE grafana failed"
  fi
  say "[C3] created Postgres role $GF_DB_USER"
else
  cat > "$TMPD/alter-role.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${GF_DB_USER}', '${GF_DB_PASS}')
\gexec
SQL
  chmod 600 "$TMPD/alter-role.sql" 2>/dev/null || true

  ALTER_ROLE_OUT="$TMPD/alter-role.out"
  if ! psql_su_file "$TMPD/alter-role.sql" "$ALTER_ROLE_OUT"; then
    tail -n 12 "$TMPD/psql-su.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "ALTER ROLE grafana password failed"
  fi
  say "[C3] ensured Postgres role $GF_DB_USER password matches env file"
fi

DB_COUNT_OUT="$TMPD/db-count.out"
if ! psql_su "$DB_COUNT_OUT" <<SQL
\set ON_ERROR_STOP on
SELECT count(*)::text FROM pg_database WHERE datname = '${GF_DB_NAME}';
SQL
then
  tail -n 12 "$TMPD/psql-su.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "Postgres database count query failed"
fi

DB_COUNT="$(to_int "$(norm "$(head -n1 "$DB_COUNT_OUT" | tr -d '\r')")")"
if [ "$DB_COUNT" -eq 0 ]; then
  cat > "$TMPD/create-db.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('CREATE DATABASE %I OWNER %I', '${GF_DB_NAME}', '${GF_DB_USER}')
\gexec
SQL
  CREATE_DB_OUT="$TMPD/create-db.out"
  if ! psql_su_file "$TMPD/create-db.sql" "$CREATE_DB_OUT"; then
    tail -n 12 "$TMPD/psql-su.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "CREATE DATABASE grafana failed"
  fi
  say "[C3] created Postgres database $GF_DB_NAME owned by $GF_DB_USER"
else
  OWNER_OUT="$TMPD/db-owner.out"
  if ! psql_su "$OWNER_OUT" <<SQL
\set ON_ERROR_STOP on
SELECT COALESCE(pg_get_userbyid(datdba), 'missing') FROM pg_database WHERE datname = '${GF_DB_NAME}';
SQL
  then
    tail -n 12 "$TMPD/psql-su.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "Postgres database owner query failed"
  fi

  DB_OWNER="$(norm "$(head -n1 "$OWNER_OUT" | tr -d '\r')")"
  if [ "$DB_OWNER" != "$GF_DB_USER" ]; then
    if [ "$DB_OWNER" = "$SU_NAME" ]; then
      cat > "$TMPD/alter-db-owner.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('ALTER DATABASE %I OWNER TO %I', '${GF_DB_NAME}', '${GF_DB_USER}')
\gexec
SQL
      ALTER_DB_OUT="$TMPD/alter-db.out"
      if ! psql_su_file "$TMPD/alter-db-owner.sql" "$ALTER_DB_OUT"; then
        tail -n 12 "$TMPD/psql-su.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
        halt "ALTER DATABASE grafana OWNER failed"
      fi
      say "[C3] changed database owner from $DB_OWNER to $GF_DB_USER"
    else
      halt "database $GF_DB_NAME exists but is owned by unexpected role: $DB_OWNER"
    fi
  else
    say "[C3] Postgres database $GF_DB_NAME already owned by $GF_DB_USER"
  fi
fi

cat > "$TMPD/grant-schema.sql" <<SQL
\set ON_ERROR_STOP on
GRANT USAGE, CREATE ON SCHEMA public TO ${GF_DB_USER};
SQL
GRANT_OUT="$TMPD/grant-schema.out"
if ! psql_su_db_file "$TMPD/grant-schema.sql" "$GRANT_OUT"; then
  tail -n 12 "$TMPD/psql-su-db.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "GRANT USAGE, CREATE ON SCHEMA public failed"
fi
say "[C3] ensured schema public USAGE, CREATE for role $GF_DB_USER in db $GF_DB_NAME"

# ===================== [C4] candidate proof =====================
say "=== [C4] Grafana candidate proof under throwaway systemd user services ==="
idx=0
for cand in "${CANDIDATES[@]}"; do
  idx=$((idx + 1))
  port="$(pick_free_port_from $((18300 + idx * 10)))"
  if [ -z "$port" ]; then
    halt "could not allocate temporary port for candidate $cand"
  fi

  cname="bc-$cand-$SFX"
  unit="bc-$cand-$SFX"
  file="$TMPD/$unit.service"

  if [ "$cand" = root_bind ]; then
    volref="$TMPD/bind-$cand-$SFX"
    mkdir -p "$volref" 2>/dev/null || true
    chmod 700 "$volref" 2>/dev/null || true
    TEST_DIRS+=("$volref")
  else
    volref="bc-grafana-$cand-$SFX"
    podman volume create "$volref" >/dev/null 2>&1 || halt "could not create test volume $volref"
    TEST_VOLUMES+=("$volref")
  fi

  exe="$(build_exec_for_candidate "$cand" "$cname" "$port" "$volref")"
  make_unit_file "$file" "BC Grafana candidate $cand $SFX" "$exe" "no"

  say "[C4] testing candidate=$cand container=$cname port=$port volume=$volref"
  run_serving_test "$unit" "$file" "$cname" "$port"
  rc=$?

  if [ "$cand" != root_bind ]; then
    podman volume rm -f "$volref" >/dev/null 2>&1 || true
  else
    rm -rf "$volref" 2>/dev/null || true
  fi

  CAND_RC["$cand"]="$rc"
  if [ "$rc" = 0 ]; then
    CAND_NOTE["$cand"]="ready"
    SELECTED="$cand"
    say "[C4] selected candidate=$SELECTED"
    break
  else
    CAND_NOTE["$cand"]="failed"
    say "[C4] candidate=$cand rc=$rc"
  fi
done

CAND_SUMMARY=""
for cand in "${CANDIDATES[@]}"; do
  CAND_SUMMARY="${CAND_SUMMARY}${cand}=${CAND_RC[$cand]:-skipped}/${CAND_NOTE[$cand]:-?} "
done
CAND_SUMMARY="$(norm "$CAND_SUMMARY")"

if [ -z "$SELECTED" ]; then
  say "[C4] all Grafana candidates failed."
  say "[C4] candidates=$CAND_SUMMARY"
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BC Grafana candidate proof failed: candidates=%s; Grafana left stopped; inspect [C4] journals above. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" "$CAND_SUMMARY" >> "$IDX"
    say "[C4] failure ledger row appended."
  else
    say "[C4] failure ledger row already present (guard suppressed)."
  fi
  halt "no Grafana candidate passed; service left stopped"
fi

# ===================== [C5] clean permanent port state =====================
say "=== [C5] clean known Grafana state on port $PORT ==="
PORT_OWNER="$(port_owner_report)"
say "[C5] pre_cleanup_port_owner=$PORT_OWNER"

if [ "$PORT_OWNER" = unknown ]; then
  halt "port 127.0.0.1:$PORT is occupied by an unknown process; not killing it blindly"
fi

if [ "$PORT_OWNER" = known ]; then
  say "[C5] stopping known grafana state"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

if ! wait_tcp_port_free "$PORT" 30; then
  PORT_OWNER="$(port_owner_report)"
  say "[C5] post_cleanup_port_owner=$PORT_OWNER"
  halt "port 127.0.0.1:$PORT remains occupied after known-state cleanup"
fi
say "[C5] port 127.0.0.1:$PORT is free"

# ===================== [C6] promote selected candidate permanently =====================
say "=== [C6] promote selected candidate=$SELECTED ==="

if [ -f "$UNIT_SRC" ] && [ ! -f "$UNIT_SRC_BAK" ]; then
  cp -p "$UNIT_SRC" "$UNIT_SRC_BAK"
  say "[C6] unit source backup -> $UNIT_SRC_BAK"
fi
if [ -f "$UNIT_INST" ] && [ ! -f "$UNIT_INST_BAK" ]; then
  cp -p "$UNIT_INST" "$UNIT_INST_BAK"
  say "[C6] unit installed backup -> $UNIT_INST_BAK"
fi

if [ "$SELECTED" = root_bind ]; then
  VOLREF="$HOST_DIR"
  mkdir -p "$VOLREF" 2>/dev/null || true
  chmod 700 "$VOLREF" 2>/dev/null || true
  say "[C6] using host bind volume -> $VOLREF"
else
  VOLREF="$VOL"
  if ! podman volume exists "$VOLREF" 2>/dev/null; then
    podman volume create "$VOLREF" >/dev/null 2>&1 || halt "could not create volume $VOLREF"
  fi
  say "[C6] using named volume -> $VOLREF"
fi

exe="$(build_exec_for_candidate "$SELECTED" "$CONTAINER" "$PORT" "$VOLREF")"

{
  printf '# Brick 8: Grafana OSS as a rootless Podman container service.\n'
  printf '# BC candidate: %s\n' "$SELECTED"
  printf '# Container name: %s\n' "$CONTAINER"
  printf '# Network: %s\n' "$NET"
  printf '# Host admin endpoint: http://127.0.0.1:%s\n' "$PORT"
  printf '# Internal endpoint: http://%s:%s\n' "$CONTAINER" "$PORT"
  printf '# DB: postgres role=%s db=%s\n' "$GF_DB_USER" "$GF_DB_NAME"
  printf '# DataSource: Prometheus http://prometheus:9090 uid=%s\n' "$DATASOURCE_UID"
  printf '# Dashboard: %s\n' "$DASHBOARD_UID"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Grafana OSS (Aether observability)\n'
  printf 'After=network-online.target postgres.service %s.service\n' "$PROM_SERVICE"
  printf 'Wants=network-online.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStart=%s\n' "$exe"
  printf 'Restart=always\n'
  printf 'RestartSec=3\n'
  printf 'TimeoutStartSec=240\n'
  printf 'Delegate=yes\n'
  printf '\n'
  printf '[Install]\n'
  printf 'WantedBy=default.target\n'
} > "$TMPD/grafana.service.desired"

install -D -m 644 "$TMPD/grafana.service.desired" "$UNIT_SRC" || halt "could not write grafana unit source"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST" || halt "could not install grafana unit"
say "[C6] installed grafana unit -> $UNIT_INST"

"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true

if ! systemctl --user daemon-reload; then
  rollback_grafana_only
  halt "systemctl --user daemon-reload failed"
fi

if ! systemctl --user enable "$SERVICE.service"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_grafana_only
  halt "could not enable $SERVICE.service"
fi

if ! systemctl --user start "$SERVICE.service"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_grafana_only
  halt "could not start $SERVICE.service"
fi

say "[C6] started $SERVICE.service with candidate=$SELECTED"

# ===================== [C7] wait active+running =====================
say "=== [C7] wait for unit active and container running ==="
WAIT_OK=no
for i in $(seq 1 90); do
  if [ "$(active_state "$SERVICE.service")" = active ] &&
     [ "$(container_status "$CONTAINER")" = running ]; then
    WAIT_OK=yes
    break
  fi
  sleep 2
done

if [ "$WAIT_OK" != yes ]; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_grafana_only
  halt "Grafana did not reach active+running"
fi

say "[C7] unit_active=active container_status=$(container_status "$CONTAINER")"

# ===================== [C8] full observability gate =====================
say "=== [C8] Grafana functional observability gate ==="
if ! wait_grafana_ready "$PORT" 120; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_grafana_only
  halt "Grafana health/datasource/query/dashboard gate failed"
fi

if grafana_health_ok "$PORT"; then HEALTH_OK=yes; fi
if grafana_datasource_ok "$PORT"; then DS_OK=yes; fi
if grafana_prom_query_ok "$PORT"; then QUERY_OK=yes; fi
if grafana_dashboard_ok "$PORT"; then DASH_OK=yes; fi

say "[C8] health=$HEALTH_OK datasource=$DS_OK prom_query=$QUERY_OK dashboard=$DASH_OK"

if [ "$HEALTH_OK" != yes ] || [ "$DS_OK" != yes ] || [ "$QUERY_OK" != yes ] || [ "$DASH_OK" != yes ]; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_grafana_only
  halt "Grafana gate incomplete"
fi

# ===================== [C9] final state =====================
say "=== [C9] final state ==="
say "[C9] selected_candidate=$SELECTED"
say "[C9] service_active=$(active_state "$SERVICE.service") service_enabled=$(enabled_state "$SERVICE.service")"
say "[C9] container_status=$(container_status "$CONTAINER")"
say "[C9] host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT"
say "[C9] db=$GF_DB_NAME role=$GF_DB_USER datasource=$DATASOURCE_UID dashboard=$DASHBOARD_UID"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [C10] ledger row =====================
say "=== [C10] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BC-grafana-brick8 | GATE=PASS | %s: installed Grafana as rootless Podman container service using candidate=%s; service=%s container=%s network=%s image=%s host=http://127.0.0.1:%s internal=http://%s:%s db=%s role=%s datasource=%s dashboard=%s health=%s ds=%s query=%s dash=%s candidates=%s; no ollama/open-webui; no secret echo; loopback-only publish. |\n' \
    "$(date +%F)" \
    "$TOKEN" \
    "$SELECTED" \
    "$SERVICE" \
    "$CONTAINER" \
    "$NET" \
    "$IMAGE" \
    "$PORT" \
    "$CONTAINER" \
    "$PORT" \
    "$GF_DB_NAME" \
    "$GF_DB_USER" \
    "$DATASOURCE_UID" \
    "$DASHBOARD_UID" \
    "$HEALTH_OK" \
    "$DS_OK" \
    "$QUERY_OK" \
    "$DASH_OK" \
    "$CAND_SUMMARY" >> "$IDX"
  say "[C10] ledger row appended."
else
  say "[C10] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[C10] suppression proof: sentinel present." || say "[C10] WARNING: sentinel missing."

write_replay_bc

say "[RESULT] GRAFANA BRICK 8 GREEN — service=$SERVICE container=$CONTAINER host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT db=$GF_DB_NAME datasource=$DATASOURCE_UID dashboard=$DASHBOARD_UID selected=$SELECTED; next: build rag pilot; still no Ollama/OpenWebUI/chat-model."
exit 0
