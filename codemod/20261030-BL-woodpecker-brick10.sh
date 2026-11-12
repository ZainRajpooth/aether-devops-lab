#!/usr/bin/env bash
# 20261030-BL — Woodpecker CI brick 10A on aether.
# Scope:
#   Install and prove Woodpecker server + agent as rootless Podman systemd user services.
#   Use already-cached images:
#     docker.io/woodpeckerci/woodpecker-server:v3
#     docker.io/woodpeckerci/woodpecker-agent:v3
#   Postgres-backed server.
#   Gitea OAuth app created programmatically.
#   Loopback-only server UI/API:
#     http://127.0.0.1:8000
#   Internal endpoints:
#     http://woodpecker-server:8000
#     woodpecker-server:9000 for agent gRPC
# Gate:
#   P1 Postgres app role can CREATE in public
#   P2 Woodpecker server HTTP health endpoint returns 200
#   P3 Woodpecker agent connects to server
#   P4 Gitea OAuth app exists/created
#   P5 both services stable, NRestarts=0
# Explicit non-goals for this brick:
#   - no browser login required
#   - no repository activation required
#   - no pipeline execution required
#   - no public exposure
#   - no SSH publication
#   - no Ollama/OpenWebUI/chat model
# Safety:
#   - no sudo
#   - no image pull; cached refs required
#   - no model download
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

SERVICE_SERVER="woodpecker-server"
CONTAINER_SERVER="woodpecker-server"
IMAGE_SERVER="docker.io/woodpeckerci/woodpecker-server:v3"

SERVICE_AGENT="woodpecker-agent"
CONTAINER_AGENT="woodpecker-agent"
IMAGE_AGENT="docker.io/woodpeckerci/woodpecker-agent:v3"

HOST_PORT="8000"
SERVER_PORT="8000"
AGENT_GRPC_PORT="9000"
NET="aether"

VOL_SERVER="woodpecker_server_data"
VOL_AGENT="woodpecker_agent_data"

WP_ENV="$A/secrets/woodpecker.env"
GITEA_ENV="$A/secrets/gitea.env"
DNS_SCRIPT="$A/infra/scripts/aether-dns-wait.sh"
ALPINE="docker.io/library/alpine:latest"

PG_CONTAINER="postgres"
PG_PORT="5432"

DB_USER="woodpecker"
DB_NAME="woodpecker"

OAUTH_APP_NAME="woodpecker"
OAUTH_REDIRECT="http://127.0.0.1:$HOST_PORT/authorize"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC_SERVER="$UNIT_SRC_DIR/woodpecker-server.service"
UNIT_INST_SERVER="$HOME/.config/systemd/user/woodpecker-server.service"
UNIT_SRC_AGENT="$UNIT_SRC_DIR/woodpecker-agent.service"
UNIT_INST_AGENT="$HOME/.config/systemd/user/woodpecker-agent.service"

UNIT_SRC_SERVER_BAK="$UNIT_SRC_SERVER.pre-BL.bak"
UNIT_INST_SERVER_BAK="$UNIT_INST_SERVER.pre-BL.bak"
UNIT_SRC_AGENT_BAK="$UNIT_SRC_AGENT.pre-BL.bak"
UNIT_INST_AGENT_BAK="$UNIT_INST_AGENT.pre-BL.bak"

FAIL_TOKEN="bl-woodpecker-brick10-failed-v1"
TOKEN="bl-woodpecker-brick10-green-v1"
SLUG_REPLAY="20261030-BL-woodpecker-brick10-replay.sh"

SU_NAME=""
DB_PASS=""
WP_CLIENT=""
WP_SECRET=""

IMAGE_SERVER_DIGEST=""
IMAGE_AGENT_DIGEST=""
IMAGE_SERVER_DIGEST_SOURCE=""
IMAGE_AGENT_DIGEST_SOURCE=""

OAUTH_STATE="not-attempted"
SERVER_ENDPOINT=""
SERVER_CODE="000"
AGENT_CONNECTED=no
NRESTARTS_SERVER_AFTER=0
NRESTARTS_AGENT_AFTER=0

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
valid_ident(){
  local s="${1:-}"
  if printf '%s' "$s" | grep -Eq '^[A-Za-z_][A-Za-z0-9_$]{0,62}$'; then
    return 0
  fi
  return 1
}
valid_uid_like(){
  local s="${1:-}"
  if [ -z "$s" ]; then
    return 1
  fi
  case "$s" in
    *..*)
      return 1
      ;;
  esac
  if printf '%s' "$s" | grep -Eq '^[A-Za-z0-9_.-]{1,190}$'; then
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
read_gitea_value(){
  awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$GITEA_ENV" 2>/dev/null || true
}
append_env(){
  printf '%s=%s\n' "$1" "$2" >> "$WP_ENV"
  chmod 600 "$WP_ENV" 2>/dev/null || true
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
ensure_secret(){
  local key="$1"
  local len="${2:-32}"
  local val=""
  if env_has "$key"; then
    return 0
  fi
  val="$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range($len)))" 2>/dev/null || true)"
  if [ -z "$val" ]; then
    halt "could not generate secret for $key"
  fi
  append_env "$key" "$val"
  say "[L3] appended $key (value not echoed)"
}
container_env_value(){
  local cname="$1"
  local key="$2"
  podman inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' || true
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
known_woodpecker_server_container_exists(){
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_SERVER"
}
classify_port_pid(){
  local pid="$1"
  local cmd cg
  cmd="$(pid_cmdline "$pid")"
  cg="$(pid_cgroup "$pid")"
  if printf '%s' "$cg" | grep -q "$SERVICE_SERVER.service"; then
    printf 'known-service'
    return
  fi
  if printf '%s' "$cg" | grep -q 'libpod'; then
    if known_woodpecker_server_container_exists; then
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
    say "[L0] listener pid=$pid port=$port class=$cls"
    say "[L0] cmd=$(printf '%s' "$(pid_cmdline "$pid")" | cut -c1-180)"
    say "[L0] cgroup=$(printf '%s' "$(pid_cgroup "$pid")" | cut -c1-220)"
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
journal_dump_for(){
  local unit="$1"
  local cname="$2"
  journalctl --user -u "$unit.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 80 "$cname" 2>&1 | sed 's/^/    c: /' || true
}
server_health_ok(){
  local endpoints="/healthz /api/health /version /api/version /"
  local ep code
  SERVER_CODE="000"
  SERVER_ENDPOINT=""
  for ep in $endpoints; do
    : > "$TMPD/server-health.out"
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
agent_connected_ok(){
  local logs
  logs="$(podman logs --tail 250 "$CONTAINER_AGENT" 2>&1 || true)"
  logs="$logs$(podman logs --tail 250 "$CONTAINER_SERVER" 2>&1 || true)"
  printf '%s' "$logs" | grep -Eiq 'agent.{0,60}(connect|register)|(connect|register).{0,60}agent|grpc.{0,60}connect|established connection|connected to server'
}
wait_agent_connected(){
  local tries="${1:-120}"
  local i
  for i in $(seq 1 "$tries"); do
    if agent_connected_ok; then
      AGENT_CONNECTED=yes
      return 0
    fi
    sleep 2
  done
  return 1
}
build_server_exec(){
  local -a args
  local exe="" part
  args=(
    "$PODMAN_BIN" run --rm --replace
    --name "$CONTAINER_SERVER"
    --network "$NET"
    --publish "127.0.0.1:$HOST_PORT:$SERVER_PORT"
    --memory 1024m
    --user 0:0
    --security-opt=no-new-privileges
    --env-file "$WP_ENV"
    -v "$VOL_SERVER:/var/lib/woodpecker"
    "$IMAGE_SERVER"
  )
  for part in "${args[@]}"; do
    exe="$exe$part "
  done
  printf '%s' "${exe% }"
}
build_agent_exec(){
  local -a args
  local exe="" part
  local podman_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
  args=(
    "$PODMAN_BIN" run --rm --replace
    --name "$CONTAINER_AGENT"
    --network "$NET"
    --memory 768m
    --user 0:0
    --security-opt=no-new-privileges
    --env-file "$WP_ENV"
    -e "WOODPECKER_SERVER=$CONTAINER_SERVER:$AGENT_GRPC_PORT"
    -e "WOODPECKER_BACKEND=docker"
    -e "DOCKER_HOST=unix:///var/run/docker.sock"
    -v "$podman_socket:/var/run/docker.sock"
    -v "$VOL_AGENT:/var/lib/woodpecker"
    "$IMAGE_AGENT"
  )
  for part in "${args[@]}"; do
    exe="$exe$part "
  done
  printf '%s' "${exe% }"
}
install_unit_if_changed(){
  local desired="$1"
  local dest="$2"
  local bak="$3"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  if [ ! -f "$dest" ] || ! cmp -s "$desired" "$dest"; then
    if [ -f "$dest" ] && [ ! -f "$bak" ]; then
      cp -p "$dest" "$bak"
      say "[L7] backup -> $bak"
    fi
    install -D -m 644 "$desired" "$dest" || halt "could not install $dest"
    say "[L7] installed -> $dest"
  else
    say "[L7] already desired -> $dest"
  fi
}
run_psql_su(){
  local sqlfile="$1"
  local out="$2"
  local err="$3"
  local db="${4:-postgres}"
  podman exec -i --env-file "$TMPD/su.env" "$PG_CONTAINER" \
    psql -h 127.0.0.1 -p "$PG_PORT" -U "$SU_NAME" -d "$db" \
    -t -A -q -v ON_ERROR_STOP=1 < "$sqlfile" >"$out" 2>"$err"
}
run_psql_app(){
  local sqlfile="$1"
  local out="$2"
  local err="$3"
  podman exec -i --env-file "$TMPD/app.env" "$PG_CONTAINER" \
    psql -h 127.0.0.1 -p "$PG_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -t -A -q -v ON_ERROR_STOP=1 < "$sqlfile" >"$out" 2>"$err"
}
setup_gitea_netrc(){
  local u p
  u="$(read_gitea_value GITEA_ADMIN_USER)"
  p="$(read_gitea_value GITEA_ADMIN_PASSWORD)"
  if [ -z "$u" ] || [ -z "$p" ]; then
    return 1
  fi
  printf 'machine 127.0.0.1 login %s password %s\n' "$u" "$p" > "$TMPD/gitea-netrc"
  chmod 600 "$TMPD/gitea-netrc" 2>/dev/null || true
}
ensure_gitea_oauth_app(){
  if ! setup_gitea_netrc; then
    OAUTH_STATE="missing-gitea-creds"
    return 1
  fi

  local client secret list_base create_base del_code create_code code id ep dep template body done_create
  local -a list_candidates create_candidates delete_templates swagger_ep
  local sw_list sw_create sw_delete

  client="$(read_env_value WOODPECKER_GITEA_CLIENT)"
  secret="$(read_env_value WOODPECKER_GITEA_SECRET)"

  list_candidates=()
  create_candidates=()
  delete_templates=()
  swagger_ep=()

  for ep in /api/swagger/json /api/v1/swagger.json /api/swagger.json /api/v1/openapi.json; do
    : > "$TMPD/oauth-swagger.out"
    code="$(curl -s -o "$TMPD/oauth-swagger.out" -w '%{http_code}' --max-time 15 "http://127.0.0.1:3001$ep" 2>/dev/null || true)"
    code="$(norm "$code")"
    if [ "$code" = 200 ] && python3 -c 'import sys,json; json.load(open(sys.argv[1]))' "$TMPD/oauth-swagger.out" >/dev/null 2>&1; then
      swagger_ep+=("$ep")
      break
    fi
  done

  if [ "${#swagger_ep[@]}" -gt 0 ]; then
    cat > "$TMPD/oauth_discover.py" <<'PYEOF'
import sys, json
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

prefix = data.get("basePath", "")
if not prefix:
    servers = data.get("servers", [])
    if servers and isinstance(servers[0], dict):
        url = servers[0].get("url", "")
        if "://" in url:
            rest = url.split("://", 1)[1]
            if "/" in rest:
                prefix = "/" + rest.split("/", 1)[1]
        elif url.startswith("/"):
            prefix = url

prefix = prefix.rstrip("/")
paths = data.get("paths", {})
cands = []

def full(path):
    if not path:
        return ""
    if prefix and not path.startswith(prefix):
        return prefix + path
    return path

for path, item in paths.items():
    if not isinstance(item, dict):
        continue
    low = path.lower()
    if "oauth2" not in low and "oauth" not in low:
        continue
    if "application" not in low and "applications" not in low and "apps" not in low:
        continue
    methods = set(item.keys())
    score = 0
    if "user" in low:
        score += 20
    if "applications" in low:
        score += 8
    if "oauth2" in low:
        score += 6
    if "get" in methods:
        score += 3
    if "post" in methods:
        score += 4
    if "delete" in methods:
        score += 2
    cands.append((score, path, methods))

cands.sort(reverse=True)

list_path = ""
create_path = ""
delete_template = ""

for score, path, methods in cands:
    if not list_path and "get" in methods:
        list_path = path
    if not create_path and "post" in methods and "{" not in path:
        create_path = path
    if not delete_template and "delete" in methods and "{" in path:
        delete_template = path.replace("{client_id}", "{id}").replace("{application_id}", "{id}").replace("{appId}", "{id}")

if not delete_template and list_path:
    delete_template = list_path.rstrip("/") + "/{id}"

print(full(list_path))
print(full(create_path))
print(full(delete_template))
PYEOF

    python3 "$TMPD/oauth_discover.py" "$TMPD/oauth-swagger.out" > "$TMPD/oauth-discovered.txt" 2>/dev/null || true
    sw_list="$(sed -n '1p' "$TMPD/oauth-discovered.txt" 2>/dev/null || true)"
    sw_create="$(sed -n '2p' "$TMPD/oauth-discovered.txt" 2>/dev/null || true)"
    sw_delete="$(sed -n '3p' "$TMPD/oauth-discovered.txt" 2>/dev/null || true)"
    sw_list="$(norm "$sw_list")"
    sw_create="$(norm "$sw_create")"
    sw_delete="$(norm "$sw_delete")"

    if [ -n "$sw_list" ]; then
      list_candidates+=("$sw_list")
      say "[L4] swagger list path=$sw_list"
    fi
    if [ -n "$sw_create" ]; then
      create_candidates+=("$sw_create")
      say "[L4] swagger create path=$sw_create"
    fi
    if [ -n "$sw_delete" ]; then
      delete_templates+=("$sw_delete")
      say "[L4] swagger delete template=$sw_delete"
    fi
  else
    say "[L4] swagger discovery unavailable; using endpoint variants"
  fi

  list_candidates+=(
    "/api/v1/user/applications/oauth2"
    "/api/v1/user/oauth2/applications"
    "/api/v1/applications/oauth2"
    "/api/v1/oauth2/applications"
    "/api/v1/admin/oauth2/apps"
  )

  create_candidates+=(
    "/api/v1/user/applications/oauth2"
    "/api/v1/user/oauth2/applications"
    "/api/v1/applications/oauth2"
    "/api/v1/oauth2/applications"
    "/api/v1/admin/oauth2/apps"
  )

  delete_templates+=(
    "/api/v1/user/applications/oauth2/{id}"
    "/api/v1/user/oauth2/applications/{id}"
    "/api/v1/applications/oauth2/{id}"
    "/api/v1/oauth2/applications/{id}"
    "/api/v1/admin/oauth2/apps/{id}"
  )

  list_base=""
  for ep in "${list_candidates[@]}"; do
    : > "$TMPD/oauth-list.out"
    code="$(curl -s -o "$TMPD/oauth-list.out" -w '%{http_code}' --max-time 15 --netrc-file "$TMPD/gitea-netrc" "http://127.0.0.1:3001$ep" 2>/dev/null || true)"
    code="$(norm "$code")"
    if [ "$code" = 200 ] && grep -Eq '^[[:space:]]*(\[|\{)' "$TMPD/oauth-list.out" 2>/dev/null; then
      list_base="$ep"
      break
    fi
  done

  if [ -n "$list_base" ]; then
    say "[L4] Gitea OAuth list endpoint=$list_base"

    if [ -n "$client" ] && [ -n "$secret" ]; then
      id="$(python3 "$TMPD/oauth_find.py" client "$client" "$TMPD/oauth-list.out" 2>/dev/null || true)"
      id="$(norm "$id")"
      if [ -n "$id" ]; then
        OAUTH_STATE="existing-valid"
        say "[L4] Gitea OAuth app already exists for client_id (secret not echoed)"
        return 0
      fi
    fi

    id="$(python3 "$TMPD/oauth_find.py" name "$OAUTH_APP_NAME" "$TMPD/oauth-list.out" 2>/dev/null || true)"
    id="$(norm "$id")"

    if [ -n "$id" ]; then
      del_code="000"
      for template in "${delete_templates[@]}"; do
        case "$template" in
          *'{id}'*)
            dep="$(printf '%s' "$template" | sed "s/{id}/$id/g")"
            : > "$TMPD/oauth-del.out"
            code="$(curl -s -o "$TMPD/oauth-del.out" -w '%{http_code}' --max-time 15 --netrc-file "$TMPD/gitea-netrc" -X DELETE "http://127.0.0.1:3001$dep" 2>/dev/null || true)"
            code="$(norm "$code")"
            del_code="$code"
            if [ "$code" = 200 ] || [ "$code" = 204 ]; then
              break
            fi
            ;;
        esac
      done

      if [ "$del_code" != 200 ] && [ "$del_code" != 204 ]; then
        OAUTH_STATE="delete-existing-failed:$del_code"
        head -c 300 "$TMPD/oauth-del.out" 2>/dev/null | sed 's/^/    oauth-delete: /' || true
        return 1
      fi

      say "[L4] deleted stale Gitea OAuth app id=$id"
    fi
  else
    if [ -n "$client" ] && [ -n "$secret" ]; then
      OAUTH_STATE="assumed-existing-list-unavailable"
      say "[L4] Gitea OAuth list unavailable; reusing existing client/secret from env"
      return 0
    fi
    say "[L4] Gitea OAuth list unavailable; attempting create variants"
  fi

  printf '{"name":"%s","uris":["%s"],"confidential_client":true}' "$OAUTH_APP_NAME" "$OAUTH_REDIRECT" > "$TMPD/oauth-body-uris.json"
  printf '{"name":"%s","redirect_uris":["%s"],"confidential_client":true}' "$OAUTH_APP_NAME" "$OAUTH_REDIRECT" > "$TMPD/oauth-body-redirect-uris.json"
  chmod 600 "$TMPD/oauth-body-uris.json" 2>/dev/null || true
  chmod 600 "$TMPD/oauth-body-redirect-uris.json" 2>/dev/null || true

  create_base=""
  create_code="000"
  done_create=no

  for body in "$TMPD/oauth-body-uris.json" "$TMPD/oauth-body-redirect-uris.json"; do
    if [ "$done_create" = yes ]; then
      break
    fi

    for ep in "${create_candidates[@]}"; do
      : > "$TMPD/oauth-create.out"
      code="$(curl -s -o "$TMPD/oauth-create.out" -w '%{http_code}' --max-time 20 --netrc-file "$TMPD/gitea-netrc" -X POST "http://127.0.0.1:3001$ep" -H 'Content-Type: application/json' --data @"$body" 2>/dev/null || true)"
      code="$(norm "$code")"
      create_code="$code"

      if [ "$code" = 200 ] || [ "$code" = 201 ]; then
        create_base="$ep"
        done_create=yes
        break
      fi
    done
  done

  if [ -z "$create_base" ]; then
    OAUTH_STATE="create-failed:$create_code"
    head -c 500 "$TMPD/oauth-create.out" 2>/dev/null | sed 's/^/    oauth-create: /' || true
    return 1
  fi

  cat > "$TMPD/oauth_parse2.py" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

client = d.get("client_id") or d.get("clientId") or ""
secret = d.get("client_secret") or d.get("clientSecret") or ""

print(client)
print(secret)
PYEOF

  python3 "$TMPD/oauth_parse2.py" "$TMPD/oauth-create.out" > "$TMPD/oauth-parsed.txt" 2>/dev/null || true
  chmod 600 "$TMPD/oauth-parsed.txt" 2>/dev/null || true

  client="$(sed -n '1p' "$TMPD/oauth-parsed.txt" 2>/dev/null || true)"
  secret="$(sed -n '2p' "$TMPD/oauth-parsed.txt" 2>/dev/null || true)"
  client="$(norm "$client")"
  secret="$(norm "$secret")"

  if [ -z "$client" ] || [ -z "$secret" ]; then
    OAUTH_STATE="create-parse-failed"
    head -c 500 "$TMPD/oauth-create.out" 2>/dev/null | sed 's/^/    oauth-create: /' || true
    return 1
  fi

  set_env WOODPECKER_GITEA_CLIENT "$client"
  set_env WOODPECKER_GITEA_SECRET "$secret"
  OAUTH_STATE="created"
  say "[L4] created Gitea OAuth app name=$OAUTH_APP_NAME redirect=$OAUTH_REDIRECT base=$create_base (client/secret not echoed)"
  return 0
}
write_replay_bl(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BL: Woodpecker server+agent installed, active, and server health ok.
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
systemctl --user start woodpecker-server.service
systemctl --user start woodpecker-agent.service

HZ=no
for i in $(seq 1 150); do
  for ep in /healthz /api/health /version /api/version /; do
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

SA="$(systemctl --user is-active woodpecker-server.service 2>/dev/null || true)"
AA="$(systemctl --user is-active woodpecker-agent.service 2>/dev/null || true)"

if [ "$HZ" = yes ] && [ "$SA" = active ] && [ "$AA" = active ]; then
  echo "  [GATE PASS] woodpecker server=active agent=active health=ok"
else
  echo "  [GATE FAIL] woodpecker server=$SA agent=$AA health=$HZ"
  exit 1
fi
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[REPLAY] archived -> codemod/$SLUG_REPLAY"
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head tail mv df sort cut; do
  need_cmd "$c"
done
if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
  halt "missing required port diagnostic tool: ss or lsof"
fi
PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

# ===================== [L0] preconditions =====================
say "=== [L0] preconditions ==="

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
  halt "network $NET missing; run AA reconcile first"
fi
if [ "$(container_status "$PG_CONTAINER")" != running ]; then
  halt "postgres container not running"
fi
if [ "$(active_state gitea.service)" != active ] ||
   [ "$(container_status gitea)" != running ]; then
  halt "gitea service/container not active+running"
fi

PORT_OWNER="$(port_owner_report "$HOST_PORT")"
say "[L0] host_port=$HOST_PORT owner=$PORT_OWNER"
if [ "$PORT_OWNER" = unknown ]; then
  halt "port 127.0.0.1:$HOST_PORT is occupied by an unknown process; not killing it blindly"
fi
say "[L0] network present: $NET"
say "[L0] postgres running"
say "[L0] gitea active+running"

if [ "$DRY" = 1 ]; then
  say "[L0] dry-run plan (pure; no secret writes, no OAuth app, no SQL, no unit writes, no start, no ledger):"
  say "    images      -> $IMAGE_SERVER"
  say "                  $IMAGE_AGENT"
  say "    env         -> $WP_ENV (mode 600, contents not echoed)"
  say "    oauth       -> Gitea app name=$OAUTH_APP_NAME redirect=$OAUTH_REDIRECT"
  say "    db          -> postgres role=$DB_USER db=$DB_NAME"
  say "    server      -> http://127.0.0.1:$HOST_PORT internal http://$CONTAINER_SERVER:$SERVER_PORT"
  say "    agent       -> internal $CONTAINER_SERVER:$AGENT_GRPC_PORT, backend=local"
  say "    login       -> NOT required for this brick; later login/pipeline proof should wait for Traefik/hostname"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched."
  exit 0
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user" "$A/secrets" "$A/infra/scripts"
touch "$IDX"

# ===================== [L1] digest freeze =====================
say "=== [L1] image digest freeze ==="
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

say "[L1] server digest($IMAGE_SERVER_DIGEST_SOURCE)=${IMAGE_SERVER_DIGEST:-none}"
say "[L1] agent digest($IMAGE_AGENT_DIGEST_SOURCE)=${IMAGE_AGENT_DIGEST:-none}"

# ===================== [L2] DNS guard =====================
say "=== [L2] ensure shared DNS-wait guard ==="
if [ ! -x "$DNS_SCRIPT" ]; then
  cat > "$TMPD/dns-wait.sh" <<'SEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh — block until aether DNS resolves given hosts.
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
TRIES="${AETHER_DNS_TRIES:-90}"
DELAY="${AETHER_DNS_DELAY:-1}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2
  exit 2
fi
for h in "${hosts[@]}"; do
  ok=0
  i=1
  while [ "$i" -le "$TRIES" ]; do
    if podman run --rm --network "$NET" "$ALPINE" getent hosts "$h" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  if [ "$ok" -ne 1 ]; then
    echo "dns-wait: host '$h' unresolved on '$NET' after $TRIES tries" >&2
    exit 1
  fi
  echo "dns-wait: resolved $h on $NET"
done
exit 0
SEOF
  if ! bash -n "$TMPD/dns-wait.sh"; then
    halt "dns-wait script failed bash -n"
  fi
  install -D -m 755 "$TMPD/dns-wait.sh" "$DNS_SCRIPT" || halt "could not install $DNS_SCRIPT"
  say "[L2] installed shared DNS guard -> $DNS_SCRIPT"
else
  say "[L2] shared DNS guard present -> $DNS_SCRIPT"
fi

# ===================== [L3] Woodpecker env scaffold =====================
say "=== [L3] Woodpecker env file ==="
umask 077
if [ ! -f "$WP_ENV" ]; then
  : > "$WP_ENV"
  chmod 600 "$WP_ENV" 2>/dev/null || true
  say "[L3] created Woodpecker env file -> $WP_ENV"
else
  chmod 600 "$WP_ENV" 2>/dev/null || true
  say "[L3] Woodpecker env file present -> $WP_ENV"
fi

set_env WOODPECKER_HOST "http://127.0.0.1:$HOST_PORT"
set_env WOODPECKER_DATABASE_DRIVER postgres
set_env WOODPECKER_OPEN true
set_env WOODPECKER_AUTHENTICATE_PUBLIC_REPOS false
set_env WOODPECKER_GITEA true
set_env WOODPECKER_GITEA_URL "http://gitea:3000"

ensure_secret WOODPECKER_DATABASE_PASSWORD 32
ensure_secret WOODPECKER_AGENT_SECRET 43

DB_PASS="$(read_env_value WOODPECKER_DATABASE_PASSWORD)"
if [ -z "$DB_PASS" ]; then
  halt "could not read WOODPECKER_DATABASE_PASSWORD"
fi
set_env WOODPECKER_DATABASE_DATASOURCE "postgres://$DB_USER:$DB_PASS@postgres:$PG_PORT/$DB_NAME?sslmode=disable"
say "[L3] WOODPECKER_DATABASE_DATASOURCE set (password not echoed)"

if ! valid_ident "$DB_USER"; then
  halt "unsafe DB_USER identifier"
fi
if ! valid_ident "$DB_NAME"; then
  halt "unsafe DB_NAME identifier"
fi
if ! valid_uid_like "$OAUTH_APP_NAME"; then
  halt "unsafe OAuth app name"
fi

# ===================== [L4] Gitea OAuth app =====================
say "=== [L4] ensure Gitea OAuth app for Woodpecker ==="

cat > "$TMPD/oauth_find.py" <<'PYEOF'
import sys, json
mode = sys.argv[1]
needle = sys.argv[2]
path = sys.argv[3]
try:
    d = json.load(open(path))
    if not isinstance(d, list):
        d = []
except Exception:
    d = []
for x in d:
    if mode == "name" and x.get("name") == needle:
        print(x.get("id", ""))
        break
    if mode == "client" and x.get("client_id") == needle:
        print(x.get("id", ""))
        break
PYEOF

cat > "$TMPD/oauth_parse.py" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("client_id", ""))
    print(d.get("client_secret", ""))
except Exception:
    pass
PYEOF

if ! ensure_gitea_oauth_app; then
  say "[L4] OAuth state=$OAUTH_STATE"
  halt "Gitea OAuth app preparation failed"
fi
say "[L4] OAuth state=$OAUTH_STATE"

WP_CLIENT="$(read_env_value WOODPECKER_GITEA_CLIENT)"
WP_SECRET="$(read_env_value WOODPECKER_GITEA_SECRET)"
if [ -z "$WP_CLIENT" ] || [ -z "$WP_SECRET" ]; then
  halt "Woodpecker Gitea client/secret missing after OAuth preparation"
fi
say "[L4] WOODPECKER_GITEA_CLIENT present length=$(printf '%s' "$WP_CLIENT" | wc -c | tr -d ' ')"
say "[L4] WOODPECKER_GITEA_SECRET present length=$(printf '%s' "$WP_SECRET" | wc -c | tr -d ' ')"

# ===================== [L5] Postgres role/db/grant =====================
say "=== [L5] ensure Woodpecker Postgres role/database/grant ==="
SU_NAME="$(container_env_value "$PG_CONTAINER" POSTGRES_USER)"
if [ -z "$SU_NAME" ]; then
  SU_NAME="postgres"
fi
if ! valid_ident "$SU_NAME"; then
  halt "unsafe superuser identifier from container env"
fi
say "[L5] superuser=$SU_NAME (password not shown)"

SUPW="$(container_env_value "$PG_CONTAINER" POSTGRES_PASSWORD)"
if [ -z "$SUPW" ]; then
  PWFILE="$(container_env_value "$PG_CONTAINER" POSTGRES_PASSWORD_FILE)"
  if [ -n "$PWFILE" ]; then
    SUPW="$(podman exec "$PG_CONTAINER" cat "$PWFILE" 2>/dev/null | tr -d '\n' || true)"
  fi
fi
if [ -z "$SUPW" ]; then
  halt "could not discover postgres superuser password"
fi

printf 'PGPASSWORD=%s\n' "$SUPW" > "$TMPD/su.env"
chmod 600 "$TMPD/su.env" 2>/dev/null || true
unset SUPW
printf 'PGPASSWORD=%s\n' "$DB_PASS" > "$TMPD/app.env"
chmod 600 "$TMPD/app.env" 2>/dev/null || true

cat > "$TMPD/role.sql" <<SQL
\set ON_ERROR_STOP on
\set dbpass ${DB_PASS}
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}')
  THEN format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${DB_USER}', :'dbpass')
  ELSE format('CREATE ROLE %I LOGIN PASSWORD %L', '${DB_USER}', :'dbpass')
END
\gexec
SQL
chmod 600 "$TMPD/role.sql" 2>/dev/null || true
if ! run_psql_su "$TMPD/role.sql" "$TMPD/role.out" "$TMPD/role.err" postgres; then
  tail -n 12 "$TMPD/role.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "ensure Woodpecker Postgres role failed"
fi
say "[L5] ensured Postgres role $DB_USER"

cat > "$TMPD/db-count.sql" <<SQL
\set ON_ERROR_STOP on
SELECT count(*)::text FROM pg_database WHERE datname = '${DB_NAME}';
SQL
chmod 600 "$TMPD/db-count.sql" 2>/dev/null || true
if ! run_psql_su "$TMPD/db-count.sql" "$TMPD/db-count.out" "$TMPD/db-count.err" postgres; then
  tail -n 12 "$TMPD/db-count.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "db count query failed"
fi
DB_COUNT="$(to_int "$(norm "$(head -n1 "$TMPD/db-count.out" | tr -d '\r')")")"

if [ "$DB_COUNT" -eq 0 ]; then
  cat > "$TMPD/create-db.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('CREATE DATABASE %I OWNER %I', '${DB_NAME}', '${DB_USER}')
\gexec
SQL
  chmod 600 "$TMPD/create-db.sql" 2>/dev/null || true
  if ! run_psql_su "$TMPD/create-db.sql" "$TMPD/create-db.out" "$TMPD/create-db.err" postgres; then
    tail -n 12 "$TMPD/create-db.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "CREATE DATABASE woodpecker failed"
  fi
  say "[L5] created Postgres database $DB_NAME owned by $DB_USER"
else
  cat > "$TMPD/db-owner.sql" <<SQL
\set ON_ERROR_STOP on
SELECT COALESCE(pg_get_userbyid(datdba), 'missing') FROM pg_database WHERE datname = '${DB_NAME}';
SQL
  chmod 600 "$TMPD/db-owner.sql" 2>/dev/null || true
  if ! run_psql_su "$TMPD/db-owner.sql" "$TMPD/db-owner.out" "$TMPD/db-owner.err" postgres; then
    tail -n 12 "$TMPD/db-owner.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "db owner query failed"
  fi
  DB_OWNER="$(norm "$(head -n1 "$TMPD/db-owner.out" | tr -d '\r')")"
  if [ "$DB_OWNER" != "$DB_USER" ]; then
    if [ "$DB_OWNER" = "$SU_NAME" ]; then
      cat > "$TMPD/alter-owner.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('ALTER DATABASE %I OWNER TO %I', '${DB_NAME}', '${DB_USER}')
\gexec
SQL
      chmod 600 "$TMPD/alter-owner.sql" 2>/dev/null || true
      if ! run_psql_su "$TMPD/alter-owner.sql" "$TMPD/alter-owner.out" "$TMPD/alter-owner.err" postgres; then
        tail -n 12 "$TMPD/alter-owner.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
        halt "ALTER DATABASE owner failed"
      fi
      say "[L5] changed db owner from $DB_OWNER to $DB_USER"
    else
      halt "db $DB_NAME owned by unexpected role: $DB_OWNER"
    fi
  else
    say "[L5] db $DB_NAME already owned by $DB_USER"
  fi
fi

cat > "$TMPD/grant.sql" <<SQL
\set ON_ERROR_STOP on
GRANT USAGE, CREATE ON SCHEMA public TO "${DB_USER}";
SQL
chmod 600 "$TMPD/grant.sql" 2>/dev/null || true
if ! run_psql_su "$TMPD/grant.sql" "$TMPD/grant.out" "$TMPD/grant.err" "$DB_NAME"; then
  tail -n 12 "$TMPD/grant.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "GRANT schema public failed"
fi

cat > "$TMPD/can-create.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT CASE WHEN has_schema_privilege(current_user, 'public', 'CREATE') THEN 'yes' ELSE 'no' END;
SQL
chmod 600 "$TMPD/can-create.sql" 2>/dev/null || true
if ! run_psql_app "$TMPD/can-create.sql" "$TMPD/can-create.out" "$TMPD/can-create.err"; then
  tail -n 12 "$TMPD/can-create.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "app-role can_create check failed"
fi
CAN_CREATE="$(norm "$(head -n1 "$TMPD/can-create.out" | tr -d '\r')")"
if [ "$CAN_CREATE" != yes ]; then
  halt "P1 failed: app role cannot CREATE in public"
fi
say "[L5] P1 can_create=yes"

# ===================== [L6] stop known state + volumes =====================
say "=== [L6] stop known Woodpecker state; ensure volumes ==="
rollback_woodpecker_only
PORT_OWNER="$(port_owner_report "$HOST_PORT")"
if [ "$PORT_OWNER" = unknown ]; then
  halt "port $HOST_PORT occupied by unknown process after cleanup"
fi
if ! wait_tcp_port_free "$HOST_PORT" 30; then
  halt "port 127.0.0.1:$HOST_PORT still occupied after cleanup"
fi
say "[L6] port 127.0.0.1:$HOST_PORT free"

if ! podman volume exists "$VOL_SERVER" 2>/dev/null; then
  podman volume create "$VOL_SERVER" >/dev/null 2>&1 || halt "could not create volume $VOL_SERVER"
fi
if ! podman volume exists "$VOL_AGENT" 2>/dev/null; then
  podman volume create "$VOL_AGENT" >/dev/null 2>&1 || halt "could not create volume $VOL_AGENT"
fi
say "[L6] volumes present: $VOL_SERVER $VOL_AGENT"

# ===================== [L7] install permanent units =====================
say "=== [L7] install permanent Woodpecker units ==="

EXE_SERVER="$(build_server_exec)"
EXE_AGENT="$(build_agent_exec)"

{
  printf '# Brick 10A: Woodpecker CI server as a rootless Podman container service.\n'
  printf '# BL: cached-ref image policy; Postgres-backed; Gitea OAuth configured; loopback-only.\n'
  printf '# Image ref: %s\n' "$IMAGE_SERVER"
  printf '# Frozen digest (%s): %s\n' "$IMAGE_SERVER_DIGEST_SOURCE" "${IMAGE_SERVER_DIGEST:-none}"
  printf '# Host endpoint: http://127.0.0.1:%s\n' "$HOST_PORT"
  printf '# Internal endpoint: http://%s:%s\n' "$CONTAINER_SERVER" "$SERVER_PORT"
  printf '# Agent gRPC internal: %s:%s\n' "$CONTAINER_SERVER" "$AGENT_GRPC_PORT"
  printf '# DB: postgres role=%s db=%s\n' "$DB_USER" "$DB_NAME"
  printf '# Volume: %s:/var/lib/woodpecker\n' "$VOL_SERVER"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Woodpecker CI Server (Aether)\n'
  printf 'After=network-online.target postgres.service gitea.service\n'
  printf 'Wants=network-online.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStartPre=/bin/bash %s postgres gitea\n' "$DNS_SCRIPT"
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
  printf '# Brick 10A: Woodpecker CI agent as a rootless Podman container service.\n'
  printf '# BO: connects to woodpecker-server:9000; backend=docker via rootless Podman socket.\n'
  printf '# Image ref: %s\n' "$IMAGE_AGENT"
  printf '# Frozen digest (%s): %s\n' "$IMAGE_AGENT_DIGEST_SOURCE" "${IMAGE_AGENT_DIGEST:-none}"
  printf '# Internal server target: %s:%s\n' "$CONTAINER_SERVER" "$AGENT_GRPC_PORT"
  printf '# Volume: %s:/var/lib/woodpecker\n' "$VOL_AGENT"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Woodpecker CI Agent (Aether)\n'
  printf 'After=network-online.target %s.service\n' "$SERVICE_SERVER"
  printf 'Wants=network-online.target %s.service\n' "$SERVICE_SERVER"
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStartPre=/bin/bash %s %s\n' "$DNS_SCRIPT" "$CONTAINER_SERVER"
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

# ===================== [L8] start server =====================
say "=== [L8] start Woodpecker server ==="
if ! systemctl --user enable "$SERVICE_SERVER.service"; then
  journal_dump_for "$SERVICE_SERVER" "$CONTAINER_SERVER"
  rollback_woodpecker_only
  halt "could not enable $SERVICE_SERVER.service"
fi
if ! systemctl --user start "$SERVICE_SERVER.service"; then
  journal_dump_for "$SERVICE_SERVER" "$CONTAINER_SERVER"
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
  journal_dump_for "$SERVICE_SERVER" "$CONTAINER_SERVER"
  rollback_woodpecker_only
  halt "Woodpecker server did not reach active+running"
fi
say "[L8] server unit_active=active container_status=running"

if ! wait_server_health 150; then
  say "[L8] server endpoint=$SERVER_ENDPOINT code=$SERVER_CODE"
  journal_dump_for "$SERVICE_SERVER" "$CONTAINER_SERVER"
  rollback_woodpecker_only
  halt "P2 failed: Woodpecker server health endpoint never returned 200"
fi
say "[L8] P2 server health ok endpoint=$SERVER_ENDPOINT code=$SERVER_CODE"

# ===================== [L9] start agent =====================
say "=== [L9] start Woodpecker agent ==="
if ! systemctl --user enable "$SERVICE_AGENT.service"; then
  journal_dump_for "$SERVICE_AGENT" "$CONTAINER_AGENT"
  rollback_woodpecker_only
  halt "could not enable $SERVICE_AGENT.service"
fi
if ! systemctl --user start "$SERVICE_AGENT.service"; then
  journal_dump_for "$SERVICE_AGENT" "$CONTAINER_AGENT"
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
  journal_dump_for "$SERVICE_AGENT" "$CONTAINER_AGENT"
  rollback_woodpecker_only
  halt "Woodpecker agent did not reach active+running"
fi
say "[L9] agent unit_active=active container_status=running"

if ! wait_agent_connected 120; then
  say "[L9] agent_connected=$AGENT_CONNECTED"
  journal_dump_for "$SERVICE_AGENT" "$CONTAINER_AGENT"
  journal_dump_for "$SERVICE_SERVER" "$CONTAINER_SERVER"
  rollback_woodpecker_only
  halt "P3 failed: Woodpecker agent never appeared connected to server"
fi
say "[L9] P3 agent connected"

# ===================== [L10] stability watch =====================
say "=== [L10] stability watch ==="
systemctl --user reset-failed "$SERVICE_SERVER.service" >/dev/null 2>&1 || true
systemctl --user reset-failed "$SERVICE_AGENT.service" >/dev/null 2>&1 || true
sleep 12

NRESTARTS_SERVER_AFTER="$(nrestarts "$SERVICE_SERVER.service")"
NRESTARTS_AGENT_AFTER="$(nrestarts "$SERVICE_AGENT.service")"

if [ "$(active_state "$SERVICE_SERVER.service")" != active ] ||
   [ "$(container_status "$CONTAINER_SERVER")" != running ] ||
   ! server_health_ok; then
  journal_dump_for "$SERVICE_SERVER" "$CONTAINER_SERVER"
  rollback_woodpecker_only
  halt "P5 failed: Woodpecker server unstable after gate"
fi
if [ "$(active_state "$SERVICE_AGENT.service")" != active ] ||
   [ "$(container_status "$CONTAINER_AGENT")" != running ]; then
  journal_dump_for "$SERVICE_AGENT" "$CONTAINER_AGENT"
  rollback_woodpecker_only
  halt "P5 failed: Woodpecker agent unstable after gate"
fi
if [ "$NRESTARTS_SERVER_AFTER" -gt 0 ] || [ "$NRESTARTS_AGENT_AFTER" -gt 0 ]; then
  journal_dump_for "$SERVICE_SERVER" "$CONTAINER_SERVER"
  journal_dump_for "$SERVICE_AGENT" "$CONTAINER_AGENT"
  rollback_woodpecker_only
  halt "P5 failed: restart counter climbed server=$NRESTARTS_SERVER_AFTER agent=$NRESTARTS_AGENT_AFTER"
fi
say "[L10] P5 stable: server NRestarts=$NRESTARTS_SERVER_AFTER agent NRestarts=$NRESTARTS_AGENT_AFTER after 12s"

# ===================== [L11] final state =====================
say "=== [L11] final state ==="
say "[L11] server_active=$(active_state "$SERVICE_SERVER.service") server_enabled=$(enabled_state "$SERVICE_SERVER.service")"
say "[L11] agent_active=$(active_state "$SERVICE_AGENT.service") agent_enabled=$(enabled_state "$SERVICE_AGENT.service")"
say "[L11] server_container=$(container_status "$CONTAINER_SERVER") agent_container=$(container_status "$CONTAINER_AGENT")"
say "[L11] host=http://127.0.0.1:$HOST_PORT internal_server=http://$CONTAINER_SERVER:$SERVER_PORT agent_target=$CONTAINER_SERVER:$AGENT_GRPC_PORT"
say "[L11] db=$DB_NAME role=$DB_USER oauth_state=$OAUTH_STATE server_endpoint=$SERVER_ENDPOINT agent_connected=$AGENT_CONNECTED"
podman ps --filter "name=$CONTAINER_SERVER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps-server: /' || true
podman ps --filter "name=$CONTAINER_AGENT" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps-agent: /' || true

# ===================== [L12] ledger + replay =====================
say "=== [L12] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BL-woodpecker-brick10 | GATE=PASS | %s: installed Woodpecker server+agent as rootless Podman container services; server_image=%s digest=%s(%s); agent_image=%s digest=%s(%s); service_server=%s container_server=%s service_agent=%s container_agent=%s network=%s host=http://127.0.0.1:%s internal_server=http://%s:%s agent_target=%s:%s db=%s role=%s oauth_state=%s server_endpoint=%s agent_connected=%s nrestarts_server=%s nrestarts_agent=%s; backend=docker via rootless Podman socket; no browser login required; no pipeline execution required; no public exposure; no ssh; no ollama/open-webui; no secret echo. |\n' \
    "$(date +%F)" \
    "$TOKEN" \
    "$IMAGE_SERVER" "${IMAGE_SERVER_DIGEST:-none}" "$IMAGE_SERVER_DIGEST_SOURCE" \
    "$IMAGE_AGENT" "${IMAGE_AGENT_DIGEST:-none}" "$IMAGE_AGENT_DIGEST_SOURCE" \
    "$SERVICE_SERVER" "$CONTAINER_SERVER" \
    "$SERVICE_AGENT" "$CONTAINER_AGENT" \
    "$NET" "$HOST_PORT" \
    "$CONTAINER_SERVER" "$SERVER_PORT" \
    "$CONTAINER_SERVER" "$AGENT_GRPC_PORT" \
    "$DB_NAME" "$DB_USER" \
    "$OAUTH_STATE" "$SERVER_ENDPOINT" "$AGENT_CONNECTED" \
    "$NRESTARTS_SERVER_AFTER" "$NRESTARTS_AGENT_AFTER" >> "$IDX"
  say "[L12] ledger row appended."
else
  say "[L12] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[L12] suppression proof: present." || say "[L12] WARNING: missing."

write_replay_bl

say "[RESULT] WOODPECKER BRICK 10A GREEN — server=http://127.0.0.1:$HOST_PORT internal_server=http://$CONTAINER_SERVER:$SERVER_PORT agent=$CONTAINER_AGENT target=$CONTAINER_SERVER:$AGENT_GRPC_PORT db=$DB_NAME oauth=$OAUTH_STATE agent_connected=$AGENT_CONNECTED; login NOT required yet; next: build traefik, then woodpecker login/pipeline proof; still no Ollama/OpenWebUI/chat-model."
exit 0
