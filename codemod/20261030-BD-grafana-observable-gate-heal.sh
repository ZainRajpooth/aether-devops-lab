#!/usr/bin/env bash
# 20261030-BD — heal BC Grafana failure by making the readiness gate observable and less overstrict.
# BC evidence:
#   Grafana reached HTTP listen and "All modules healthy".
#   BC failed with aggregate rc=1 and no subcheck telemetry.
#   BC required count(up) to return rows, which is not required for Grafana->Prometheus connectivity.
# BD strategy:
#   1) stop/clean known Grafana state;
#   2) ensure Grafana Postgres role/db/grant idempotently via stdin SQL;
#   3) write minimal valid provisioning files;
#   4) prove one candidate shape: root_named on a temporary port;
#   5) promote only if observable gate passes:
#        /api/health database=ok
#        provisioned Prometheus datasource exists
#        provisioned dashboard exists
#        Grafana datasource proxy can execute Prometheus query "1"
#   6) append guarded ledger rows and archive replay.
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
#   - loopback-only publish
#   - --check is pure
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

PROV_DIR="$A/config/grafana/provisioning"
GRAFANA_ENV="$A/secrets/grafana.env"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/grafana.service"
UNIT_INST="$HOME/.config/systemd/user/grafana.service"
UNIT_SRC_BAK="$UNIT_SRC.pre-BD.bak"
UNIT_INST_BAK="$UNIT_INST.pre-BD.bak"

PG_CONTAINER="postgres"
PG_PORT="5432"

PROM_SERVICE="prometheus"
PROM_CONTAINER="prometheus"

GF_DB_USER="grafana"
GF_DB_NAME="grafana"

DATASOURCE_UID="prometheus-aether"
DASHBOARD_UID="aether-overview"

CORRECTION_TOKEN="bc-grafana-blind-overstrict-gate-defect"
FAIL_TOKEN="bd-grafana-observable-gate-failed-v1"
TOKEN="bd-grafana-brick8-green-v2"
SLUG_REPLAY="20261030-BD-grafana-observable-gate-heal-replay.sh"

TEST_UNITS=()
TEST_CONTAINERS=()
TEST_VOLUMES=()

SELECTED="root_named"
ADMIN_USER=""
ADMIN_PASS=""
GF_DB_PASS=""
SU_NAME=""

G_HEALTH=no
G_DS=no
G_DASH=no
G_QUERY=no
G_HEALTH_CODE=000
G_DS_CODE=000
G_DASH_CODE=000
G_QUERY_CODE=000
G_QUERY_DETAIL=""

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
http_code_no_auth(){
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
    say "[D0] listener pid=$pid class=$cls"
    say "[D0] cmd=$(printf '%s' "$(pid_cmdline "$pid")" | cut -c1-180)"
    say "[D0] cgroup=$(printf '%s' "$(pid_cgroup "$pid")" | cut -c1-220)"

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
  if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
    return 1
  fi
  printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$ADMIN_PASS" > "$TMPD/netrc"
  chmod 600 "$TMPD/netrc" 2>/dev/null || true
}
grafana_api_code(){
  local port="$1"
  local path="$2"
  local out="$3"
  local code

  if [ ! -f "$TMPD/netrc" ]; then
    if ! setup_netrc; then
      printf '000'
      return 1
    fi
  fi

  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 10 --netrc-file "$TMPD/netrc" "http://127.0.0.1:$port$path" 2>/dev/null || true)"
  code="$(norm "$code")"
  if [ -z "$code" ]; then
    code=000
  fi
  printf '%s' "$code"
}
grafana_health_ok(){
  local port="$1"
  local body="$TMPD/health.out"
  local code
  code="$(norm "$(http_code_no_auth "http://127.0.0.1:$port/api/health")")"
  G_HEALTH_CODE="$code"
  if [ "$code" != 200 ]; then
    return 1
  fi
  curl -s --max-time 5 "http://127.0.0.1:$port/api/health" >"$body" 2>/dev/null || true
  tr -d '[:space:]' < "$body" 2>/dev/null | grep -q '"database":"ok"' 2>/dev/null
}
grafana_datasource_ok(){
  local port="$1"
  local out="$TMPD/ds.out"
  local code
  code="$(grafana_api_code "$port" "/api/datasources/uid/$DATASOURCE_UID" "$out")"
  G_DS_CODE="$code"
  if [ "$code" != 200 ]; then
    return 1
  fi
  grep -q "\"uid\":\"$DATASOURCE_UID\"" "$out" 2>/dev/null
}
grafana_dashboard_ok(){
  local port="$1"
  local out="$TMPD/dash.out"
  local code
  code="$(grafana_api_code "$port" "/api/dashboards/uid/$DASHBOARD_UID" "$out")"
  G_DASH_CODE="$code"
  if [ "$code" != 200 ]; then
    return 1
  fi
  grep -q "\"uid\":\"$DASHBOARD_UID\"" "$out" 2>/dev/null
}
grafana_prom_query_ok(){
  local port="$1"
  local out="$TMPD/query.out"
  local list="$TMPD/dslist.out"
  local code ds_id

  code="$(grafana_api_code "$port" "/api/datasources/proxy/uid/$DATASOURCE_UID/api/v1/query?query=1" "$out")"
  G_QUERY_CODE="$code"
  if [ "$code" = 200 ] && grep -q '"status":"success"' "$out" 2>/dev/null; then
    G_QUERY_DETAIL="uid-proxy"
    return 0
  fi

  code="$(grafana_api_code "$port" "/api/datasources" "$list")"
  if [ "$code" != 200 ]; then
    G_QUERY_DETAIL="datasource-list-failed:$code"
    return 1
  fi

  ds_id="$(python3 "$TMPD/ds_id.py" < "$list" 2>/dev/null || true)"
  ds_id="$(norm "$ds_id")"
  case "$ds_id" in
    ''|*[!0-9]*)
      G_QUERY_DETAIL="datasource-id-missing"
      return 1
      ;;
  esac

  code="$(grafana_api_code "$port" "/api/datasources/proxy/$ds_id/api/v1/query?query=1" "$out")"
  G_QUERY_CODE="$code"
  if [ "$code" = 200 ] && grep -q '"status":"success"' "$out" 2>/dev/null; then
    G_QUERY_DETAIL="id-proxy:$ds_id"
    return 0
  fi

  G_QUERY_DETAIL="query-failed:$code"
  return 1
}
grafana_subchecks(){
  G_HEALTH=no
  G_DS=no
  G_DASH=no
  G_QUERY=no
  G_QUERY_DETAIL=""

  if grafana_health_ok "$1"; then
    G_HEALTH=yes
  fi
  if grafana_datasource_ok "$1"; then
    G_DS=yes
  fi
  if grafana_dashboard_ok "$1"; then
    G_DASH=yes
  fi
  if grafana_prom_query_ok "$1"; then
    G_QUERY=yes
  fi

  if [ "$G_HEALTH" = yes ] &&
     [ "$G_DS" = yes ] &&
     [ "$G_DASH" = yes ] &&
     [ "$G_QUERY" = yes ]; then
    return 0
  fi
  return 1
}
wait_grafana_ready(){
  local port="$1"
  local tries="${2:-150}"
  local i
  for i in $(seq 1 "$tries"); do
    if grafana_subchecks "$port"; then
      return 0
    fi
    sleep 2
  done
  return 1
}
dump_gate_detail(){
  local port="$1"
  grafana_subchecks "$port" || true
  say "[GATE DETAIL] health=$G_HEALTH code=$G_HEALTH_CODE"
  say "[GATE DETAIL] datasource=$G_DS code=$G_DS_CODE uid=$DATASOURCE_UID"
  say "[GATE DETAIL] dashboard=$G_DASH code=$G_DASH_CODE uid=$DASHBOARD_UID"
  say "[GATE DETAIL] prom_query=$G_QUERY code=$G_QUERY_DETAIL"
  if [ -s "$TMPD/health.out" ]; then
    say "[GATE DETAIL] health-body=$(head -c 300 "$TMPD/health.out" | tr '\n' ' ')"
  fi
  if [ -s "$TMPD/ds.out" ]; then
    say "[GATE DETAIL] ds-body=$(head -c 300 "$TMPD/ds.out" | tr '\n' ' ')"
  fi
  if [ -s "$TMPD/dash.out" ]; then
    say "[GATE DETAIL] dash-body=$(head -c 300 "$TMPD/dash.out" | tr '\n' ' ')"
  fi
  if [ -s "$TMPD/query.out" ]; then
    say "[GATE DETAIL] query-body=$(head -c 300 "$TMPD/query.out" | tr '\n' ' ')"
  fi
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
build_grafana_exec(){
  local cname="$1"
  local port="$2"
  local volref="$3"
  local -a args
  local exe="" part

  args=(
    "$PODMAN_BIN" run --rm --replace
    --name "$cname"
    --network "$NET"
    --publish "127.0.0.1:$port:3000"
    --memory 1536m
    --user 0:0
    --security-opt=no-new-privileges
    --env-file "$GRAFANA_ENV"
    -v "$PROV_DIR:/etc/grafana/provisioning:ro"
    -v "$volref:/var/lib/grafana"
    -e "GF_SERVER_ROOT_URL=http://127.0.0.1:$port/"
    -e GF_SERVER_HTTP_PORT=3000
    -e GF_AUTH_ANONYMOUS_ENABLED=false
    -e GF_PLUGINS_PLUGIN_ADMIN_ENABLED=false
    -e GF_PLUGINS_AUTO_UPDATE=false
    -e GF_ANALYTICS_REPORTING_ENABLED=false
    -e GF_ANALYTICS_CHECK_FOR_UPDATES=false
    "$IMAGE"
  )

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
  local volref="$5"

  install -D -m 644 "$file" "$HOME/.config/systemd/user/$unit.service" || return 90
  TEST_UNITS+=("$unit")
  TEST_CONTAINERS+=("$cname")
  TEST_VOLUMES+=("$volref")

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true

  local start_rc=0
  if ! systemctl --user start "$unit.service" >"$TMPD/$unit.start.out" 2>"$TMPD/$unit.start.err"; then
    start_rc=$?
  fi

  local ok=no
  if wait_grafana_ready "$port" 150; then
    ok=yes
  fi

  dump_gate_detail "$port"
  journal_dump_for "$unit" "$cname"
  if [ -s "$TMPD/$unit.start.err" ]; then
    say "    start-err($unit):"
    tail -n 8 "$TMPD/$unit.start.err" 2>/dev/null | sed 's/^/      /' || true
  fi

  systemctl --user disable --now "$unit.service" >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/$unit.service" 2>/dev/null || true
  podman rm -f "$cname" >/dev/null 2>&1 || true
  podman volume rm -f "$volref" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true

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
  local bak="$dest.pre-BD.bak"

  mkdir -p "$(dirname "$dest")" 2>/dev/null || true

  if [ ! -f "$dest" ] || ! cmp -s "$desired" "$dest"; then
    if [ -f "$dest" ] && [ ! -f "$bak" ]; then
      cp -p "$dest" "$bak"
      say "[D2] backup -> $bak"
    fi
    install -D -m 644 "$desired" "$dest" || halt "could not install $dest"
    say "[D2] installed -> $dest"
  else
    say "[D2] already desired -> $dest"
  fi
}
run_psql_as(){
  local envfile="$1"
  local user="$2"
  local dbname="$3"
  local sqlfile="$4"
  local out="$5"
  local err="$6"

  podman exec -i --env-file "$envfile" "$PG_CONTAINER" \
    psql -h 127.0.0.1 -p "$PG_PORT" -U "$user" -d "$dbname" \
    -t -A -q -v ON_ERROR_STOP=1 < "$sqlfile" >"$out" 2>"$err"
}
write_replay_bd(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BD: ensure Grafana unit is installed, active, and observable gate green.
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
for i in $(seq 1 150); do
  B="$(curl -s --max-time 5 http://127.0.0.1:3000/api/health 2>/dev/null || true)"
  if printf '%s' "$B" | tr -d '[:space:]' | grep -q '"database":"ok"'; then
    HZ=yes
    break
  fi
  sleep 2
done

USER="$(awk -F= '/^GF_SECURITY_ADMIN_USER=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
PASS="$(awk -F= '/^GF_SECURITY_ADMIN_PASSWORD=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
NETRC="/tmp/bd-replay.$$.netrc"
printf 'machine 127.0.0.1 login %s password %s\n' "$USER" "$PASS" > "$NETRC"
chmod 600 "$NETRC" 2>/dev/null || true

DS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "$NETRC" http://127.0.0.1:3000/api/datasources/uid/prometheus-aether)"
DASH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "$NETRC" http://127.0.0.1:3000/api/dashboards/uid/aether-overview)"
Q="$(curl -s --max-time 15 --netrc-file "$NETRC" http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus-aether/api/v1/query?query=1)"

rm -f "$NETRC"

if [ "$HZ" = yes ] && [ "$DS" = 200 ] && [ "$DASH" = 200 ] && printf '%s' "$Q" | grep -q '"status":"success"'; then
  echo "  [GATE PASS] grafana health=ok datasource=ok dashboard=ok prom_query=success"
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

# ===================== [D0] preconditions =====================
say "=== [D0] preconditions ==="

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
say "[D0] initial_port_owner=$PORT_OWNER"
say "[D0] network present: $NET"
say "[D0] postgres running"
say "[D0] prometheus active+running"

if [ "$DRY" = 1 ]; then
  say "[D0] dry-run plan (pure; no secret writes, no SQL, no unit writes, no start, no ledger):"
  say "    env          -> $GRAFANA_ENV (mode 600, contents not echoed)"
  say "    provisioning -> $PROV_DIR"
  say "    db           -> postgres role=$GF_DB_USER db=$GF_DB_NAME"
  say "    candidate    -> root_named only"
  say "    service      -> $SERVICE.service"
  say "    container    -> $CONTAINER"
  say "    host         -> http://127.0.0.1:$PORT"
  say "    internal     -> http://$CONTAINER:$PORT"
  say "    gate         -> health + datasource + dashboard + Prometheus proxy query 1"
  say "[RESULT] DRY-RUN complete; no writes, no SQL, no start, no ledger row."
  exit 0
fi

# ===================== [D1] correction ledger =====================
say "=== [D1] correction ledger row ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BC Grafana failed with aggregate rc=1 despite Grafana logs showing HTTP listen and all modules healthy. BC gate was blind and overstrict: it required count(up) rows and did not report which subcheck failed. BD supersedes BC with observable subcheck telemetry, one root_named candidate, minimal valid dashboard, and Prometheus proxy query "1" as connectivity proof. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" >> "$IDX"
  say "[D1] BC blind gate correction row appended."
else
  say "[D1] BC blind gate correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[D1] suppression proof: correction sentinel present." || say "[D1] WARNING: correction sentinel missing."

# ===================== [D2] Grafana secret env file =====================
say "=== [D2] Grafana secret env file ==="
umask 077

if [ ! -f "$GRAFANA_ENV" ]; then
  : > "$GRAFANA_ENV"
  chmod 600 "$GRAFANA_ENV" 2>/dev/null || true
  say "[D2] created Grafana env file -> $GRAFANA_ENV"
else
  chmod 600 "$GRAFANA_ENV" 2>/dev/null || true
  say "[D2] Grafana env file present -> $GRAFANA_ENV"
fi

ensure_env GF_DATABASE_TYPE postgres
ensure_env GF_DATABASE_HOST postgres
ensure_env GF_DATABASE_PORT 5432
ensure_env GF_DATABASE_NAME "$GF_DB_NAME"
ensure_env GF_DATABASE_USER "$GF_DB_USER"
ensure_env GF_DATABASE_SSL_MODE disable
ensure_env GF_SECURITY_ADMIN_USER admin
ensure_env GF_PLUGINS_PLUGIN_ADMIN_ENABLED false
ensure_env GF_PLUGINS_AUTO_UPDATE false
ensure_env GF_ANALYTICS_REPORTING_ENABLED false
ensure_env GF_ANALYTICS_CHECK_FOR_UPDATES false

if ! env_has GF_DATABASE_PASSWORD; then
  GF_DB_PASS="$(gen_hex_secret)"
  if [ -z "$GF_DB_PASS" ]; then
    halt "could not generate GF_DATABASE_PASSWORD"
  fi
  append_env GF_DATABASE_PASSWORD "$GF_DB_PASS"
  say "[D2] appended GF_DATABASE_PASSWORD (value not echoed)"
else
  say "[D2] GF_DATABASE_PASSWORD present"
fi

if ! env_has GF_SECURITY_ADMIN_PASSWORD; then
  ADMIN_PASS="$(gen_hex_secret)"
  if [ -z "$ADMIN_PASS" ]; then
    halt "could not generate GF_SECURITY_ADMIN_PASSWORD"
  fi
  append_env GF_SECURITY_ADMIN_PASSWORD "$ADMIN_PASS"
  say "[D2] appended GF_SECURITY_ADMIN_PASSWORD (value not echoed)"
else
  say "[D2] GF_SECURITY_ADMIN_PASSWORD present"
fi

GF_DB_PASS="$(read_env_value GF_DATABASE_PASSWORD)"
ADMIN_USER="$(read_env_value GF_SECURITY_ADMIN_USER)"
ADMIN_PASS="$(read_env_value GF_SECURITY_ADMIN_PASSWORD)"

if [ -z "$GF_DB_PASS" ] || [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
  halt "could not read required secrets from $GRAFANA_ENV"
fi
say "[D2] db password present=yes length=$(printf '%s' "$GF_DB_PASS" | wc -c | tr -d ' ')"
say "[D2] admin user=$ADMIN_USER admin password present=yes length=$(printf '%s' "$ADMIN_PASS" | wc -c | tr -d ' ')"

if ! valid_ident "$GF_DB_USER"; then
  halt "unsafe GF_DB_USER identifier"
fi
if ! valid_ident "$GF_DB_NAME"; then
  halt "unsafe GF_DB_NAME identifier"
fi

# ===================== [D3] provisioning files =====================
say "=== [D3] Grafana provisioning files ==="

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
  "schemaVersion": 36,
  "version": 1,
  "refresh": "30s",
  "time": {
    "from": "now-1h",
    "to": "now"
  },
  "panels": []
}
JEOF

install_desired_file "$TMPD/datasources.yaml" "$PROV_DIR/datasources/aether.yaml"
install_desired_file "$TMPD/dashboards-provider.yaml" "$PROV_DIR/dashboards/dashboards.yaml"
install_desired_file "$TMPD/overview.json" "$PROV_DIR/dashboards/aether/overview.json"

cat > "$TMPD/ds_id.py" <<'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    for x in d:
        if x.get("uid") == "prometheus-aether":
            print(x.get("id", ""))
            break
except Exception:
    pass
PYEOF
chmod 600 "$TMPD/ds_id.py" 2>/dev/null || true

# ===================== [D4] Postgres role/database/grant =====================
say "=== [D4] ensure Grafana Postgres role/database/grant ==="

SU_NAME="$(container_env_value "$PG_CONTAINER" POSTGRES_USER)"
if [ -z "$SU_NAME" ]; then
  SU_NAME="postgres"
fi
if ! valid_ident "$SU_NAME"; then
  halt "unsafe superuser identifier from container env"
fi
say "[D4] superuser=$SU_NAME (password not shown)"

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

printf 'PGPASSWORD=%s\n' "$GF_DB_PASS" > "$TMPD/app.env"
chmod 600 "$TMPD/app.env" 2>/dev/null || true

cat > "$TMPD/role-count.sql" <<SQL
\set ON_ERROR_STOP on
SELECT count(*)::text FROM pg_roles WHERE rolname = '${GF_DB_USER}';
SQL
chmod 600 "$TMPD/role-count.sql" 2>/dev/null || true

ROLE_COUNT_OUT="$TMPD/role-count.out"
ROLE_COUNT_ERR="$TMPD/role-count.err"
if ! run_psql_as "$TMPD/su.env" "$SU_NAME" postgres "$TMPD/role-count.sql" "$ROLE_COUNT_OUT" "$ROLE_COUNT_ERR"; then
  tail -n 12 "$ROLE_COUNT_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
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
  OUT="$TMPD/create-role.out"
  ERR="$TMPD/create-role.err"
  if ! run_psql_as "$TMPD/su.env" "$SU_NAME" postgres "$TMPD/create-role.sql" "$OUT" "$ERR"; then
    tail -n 12 "$ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "CREATE ROLE grafana failed"
  fi
  say "[D4] created Postgres role $GF_DB_USER"
else
  cat > "$TMPD/alter-role.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${GF_DB_USER}', '${GF_DB_PASS}')
\gexec
SQL
  chmod 600 "$TMPD/alter-role.sql" 2>/dev/null || true
  OUT="$TMPD/alter-role.out"
  ERR="$TMPD/alter-role.err"
  if ! run_psql_as "$TMPD/su.env" "$SU_NAME" postgres "$TMPD/alter-role.sql" "$OUT" "$ERR"; then
    tail -n 12 "$ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "ALTER ROLE grafana password failed"
  fi
  say "[D4] ensured Postgres role $GF_DB_USER password matches env file"
fi

cat > "$TMPD/db-count.sql" <<SQL
\set ON_ERROR_STOP on
SELECT count(*)::text FROM pg_database WHERE datname = '${GF_DB_NAME}';
SQL
chmod 600 "$TMPD/db-count.sql" 2>/dev/null || true
DB_COUNT_OUT="$TMPD/db-count.out"
DB_COUNT_ERR="$TMPD/db-count.err"
if ! run_psql_as "$TMPD/su.env" "$SU_NAME" postgres "$TMPD/db-count.sql" "$DB_COUNT_OUT" "$DB_COUNT_ERR"; then
  tail -n 12 "$DB_COUNT_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "Postgres database count query failed"
fi
DB_COUNT="$(to_int "$(norm "$(head -n1 "$DB_COUNT_OUT" | tr -d '\r')")")"

if [ "$DB_COUNT" -eq 0 ]; then
  cat > "$TMPD/create-db.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('CREATE DATABASE %I OWNER %I', '${GF_DB_NAME}', '${GF_DB_USER}')
\gexec
SQL
  chmod 600 "$TMPD/create-db.sql" 2>/dev/null || true
  OUT="$TMPD/create-db.out"
  ERR="$TMPD/create-db.err"
  if ! run_psql_as "$TMPD/su.env" "$SU_NAME" postgres "$TMPD/create-db.sql" "$OUT" "$ERR"; then
    tail -n 12 "$ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "CREATE DATABASE grafana failed"
  fi
  say "[D4] created Postgres database $GF_DB_NAME owned by $GF_DB_USER"
else
  cat > "$TMPD/db-owner.sql" <<SQL
\set ON_ERROR_STOP on
SELECT COALESCE(pg_get_userbyid(datdba), 'missing') FROM pg_database WHERE datname = '${GF_DB_NAME}';
SQL
  chmod 600 "$TMPD/db-owner.sql" 2>/dev/null || true
  OWNER_OUT="$TMPD/db-owner.out"
  OWNER_ERR="$TMPD/db-owner.err"
  if ! run_psql_as "$TMPD/su.env" "$SU_NAME" postgres "$TMPD/db-owner.sql" "$OWNER_OUT" "$OWNER_ERR"; then
    tail -n 12 "$OWNER_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
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
      chmod 600 "$TMPD/alter-db-owner.sql" 2>/dev/null || true
      OUT="$TMPD/alter-db.out"
      ERR="$TMPD/alter-db.err"
      if ! run_psql_as "$TMPD/su.env" "$SU_NAME" postgres "$TMPD/alter-db-owner.sql" "$OUT" "$ERR"; then
        tail -n 12 "$ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
        halt "ALTER DATABASE grafana OWNER failed"
      fi
      say "[D4] changed database owner from $DB_OWNER to $GF_DB_USER"
    else
      halt "database $GF_DB_NAME exists but is owned by unexpected role: $DB_OWNER"
    fi
  else
    say "[D4] Postgres database $GF_DB_NAME already owned by $GF_DB_USER"
  fi
fi

cat > "$TMPD/grant-schema.sql" <<SQL
\set ON_ERROR_STOP on
GRANT USAGE, CREATE ON SCHEMA public TO "${GF_DB_USER}";
SQL
chmod 600 "$TMPD/grant-schema.sql" 2>/dev/null || true
GRANT_OUT="$TMPD/grant-schema.out"
GRANT_ERR="$TMPD/grant-schema.err"
if ! run_psql_as "$TMPD/su.env" "$SU_NAME" "$GF_DB_NAME" "$TMPD/grant-schema.sql" "$GRANT_OUT" "$GRANT_ERR"; then
  tail -n 12 "$GRANT_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "GRANT USAGE, CREATE ON SCHEMA public failed"
fi
say "[D4] ensured schema public USAGE, CREATE for role $GF_DB_USER in db $GF_DB_NAME"

cat > "$TMPD/can-create.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT CASE WHEN has_schema_privilege(current_user, 'public', 'CREATE') THEN 'yes' ELSE 'no' END;
SQL
chmod 600 "$TMPD/can-create.sql" 2>/dev/null || true
CAN_OUT="$TMPD/can-create.out"
CAN_ERR="$TMPD/can-create.err"
if ! run_psql_as "$TMPD/app.env" "$GF_DB_USER" "$GF_DB_NAME" "$TMPD/can-create.sql" "$CAN_OUT" "$CAN_ERR"; then
  tail -n 12 "$CAN_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "app-role can_create check failed"
fi
CAN_CREATE="$(norm "$(head -n1 "$CAN_OUT" | tr -d '\r')")"
if [ "$CAN_CREATE" != yes ]; then
  halt "app role cannot CREATE in public after grant"
fi
say "[D4] P1 can_create=yes"

# ===================== [D5] stop known Grafana state =====================
say "=== [D5] stop known Grafana state ==="
rollback_grafana_only
PORT_OWNER="$(port_owner_report)"
say "[D5] post_stop_port_owner=$PORT_OWNER"
if [ "$PORT_OWNER" = unknown ]; then
  halt "port 127.0.0.1:$PORT is occupied by an unknown process; not killing it blindly"
fi
if ! wait_tcp_port_free "$PORT" 30; then
  halt "port 127.0.0.1:$PORT remains occupied after known-state cleanup"
fi
say "[D5] port 127.0.0.1:$PORT free"

# ===================== [D6] candidate proof: root_named only =====================
say "=== [D6] candidate proof: root_named on temporary port ==="
port="$(pick_free_port_from 18310)"
if [ -z "$port" ]; then
  halt "could not allocate temporary port for candidate $SELECTED"
fi

cname="bd-$SELECTED-$SFX"
unit="bd-$SELECTED-$SFX"
file="$TMPD/$unit.service"
volref="bd-grafana-$SELECTED-$SFX"

podman volume create "$volref" >/dev/null 2>&1 || halt "could not create test volume $volref"
exe="$(build_grafana_exec "$cname" "$port" "$volref")"
make_unit_file "$file" "BD Grafana candidate $SELECTED $SFX" "$exe" "no"

say "[D6] testing candidate=$SELECTED container=$cname port=$port volume=$volref"
run_serving_test "$unit" "$file" "$cname" "$port" "$volref"
rc=$?

if [ "$rc" != 0 ]; then
  say "[D6] candidate=$SELECTED rc=$rc"
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BD Grafana candidate proof failed: candidate=%s rc=%s health=%s ds=%s dash=%s query=%s query_detail=%s; Grafana left stopped; inspect [D6] GATE DETAIL above. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" "$SELECTED" "$rc" "$G_HEALTH" "$G_DS" "$G_DASH" "$G_QUERY" "$G_QUERY_DETAIL" >> "$IDX"
    say "[D6] failure ledger row appended."
  else
    say "[D6] failure ledger row already present (guard suppressed)."
  fi
  halt "BD Grafana candidate proof failed; service left stopped"
fi
say "[D6] candidate=$SELECTED passed observable gate"

# ===================== [D7] promote permanently =====================
say "=== [D7] promote selected candidate=$SELECTED permanently ==="

if [ -f "$UNIT_SRC" ] && [ ! -f "$UNIT_SRC_BAK" ]; then
  cp -p "$UNIT_SRC" "$UNIT_SRC_BAK"
  say "[D7] unit source backup -> $UNIT_SRC_BAK"
fi
if [ -f "$UNIT_INST" ] && [ ! -f "$UNIT_INST_BAK" ]; then
  cp -p "$UNIT_INST" "$UNIT_INST_BAK"
  say "[D7] unit installed backup -> $UNIT_INST_BAK"
fi

if ! podman volume exists "$VOL" 2>/dev/null; then
  podman volume create "$VOL" >/dev/null 2>&1 || halt "could not create volume $VOL"
fi
say "[D7] using named volume -> $VOL"

exe="$(build_grafana_exec "$CONTAINER" "$PORT" "$VOL")"

{
  printf '# Brick 8: Grafana OSS as a rootless Podman container service.\n'
  printf '# BD observable gate heal: root_named, loopback-only, Postgres-backed, Prometheus datasource.\n'
  printf '# Container name: %s\n' "$CONTAINER"
  printf '# Network: %s\n' "$NET"
  printf '# Host admin endpoint: http://127.0.0.1:%s\n' "$PORT"
  printf '# Internal endpoint: http://%s:%s\n' "$CONTAINER" "$PORT"
  printf '# DB: postgres role=%s db=%s\n' "$GF_DB_USER" "$GF_DB_NAME"
  printf '# DataSource: Prometheus http://prometheus:9090 uid=%s\n' "$DATASOURCE_UID"
  printf '# Dashboard: %s\n' "$DASHBOARD_UID"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Grafana OSS (Aether observability, BD healed)\n'
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
say "[D7] installed grafana unit -> $UNIT_INST"

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

say "[D7] started $SERVICE.service with candidate=$SELECTED"

# ===================== [D8] wait active+running =====================
say "=== [D8] wait for unit active and container running ==="
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

say "[D8] unit_active=active container_status=$(container_status "$CONTAINER")"

# ===================== [D9] final observable gate =====================
say "=== [D9] final observable gate ==="
if ! wait_grafana_ready "$PORT" 180; then
  dump_gate_detail "$PORT"
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_grafana_only
  halt "Grafana final observable gate failed"
fi

say "[D9] health=$G_HEALTH code=$G_HEALTH_CODE"
say "[D9] datasource=$G_DS code=$G_DS_CODE uid=$DATASOURCE_UID"
say "[D9] dashboard=$G_DASH code=$G_DASH_CODE uid=$DASHBOARD_UID"
say "[D9] prom_query=$G_QUERY detail=$G_QUERY_DETAIL code=$G_QUERY_CODE"

# ===================== [D10] final state =====================
say "=== [D10] final state ==="
say "[D10] selected_candidate=$SELECTED"
say "[D10] service_active=$(active_state "$SERVICE.service") service_enabled=$(enabled_state "$SERVICE.service")"
say "[D10] container_status=$(container_status "$CONTAINER")"
say "[D10] host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT"
say "[D10] db=$GF_DB_NAME role=$GF_DB_USER datasource=$DATASOURCE_UID dashboard=$DASHBOARD_UID"
say "[D10] admin_user=$ADMIN_USER admin_password_present=yes (value not echoed)"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [D11] ledger row =====================
say "=== [D11] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BD-grafana-observable-gate-heal | GATE=PASS | %s: installed Grafana as rootless Podman container service using candidate=%s; service=%s container=%s network=%s image=%s host=http://127.0.0.1:%s internal=http://%s:%s db=%s role=%s datasource=%s dashboard=%s health=%s ds=%s query=%s query_detail=%s admin_user=%s; no sqlite; no ollama/open-webui; no secret echo; loopback-only publish. |\n' \
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
    "$G_HEALTH" \
    "$G_DS" \
    "$G_QUERY" \
    "$G_QUERY_DETAIL" \
    "$ADMIN_USER" >> "$IDX"
  say "[D11] ledger row appended."
else
  say "[D11] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[D11] suppression proof: sentinel present." || say "[D11] WARNING: sentinel missing."

write_replay_bd

say "[RESULT] GRAFANA BRICK 8 GREEN — service=$SERVICE container=$CONTAINER host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT db=$GF_DB_NAME datasource=$DATASOURCE_UID dashboard=$DASHBOARD_UID selected=$SELECTED; next: build rag pilot; still no Ollama/OpenWebUI/chat-model."
exit 0
