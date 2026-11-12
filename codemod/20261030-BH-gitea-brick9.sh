#!/usr/bin/env bash
# 20261030-BH — Gitea brick 9 on aether.
# Goal:
#   Professional local Git server for DevOps control plane.
#   Postgres-backed, rootless Podman, systemd user service, loopback-only.
#   Host admin/UI/API: http://127.0.0.1:3001
#   Internal endpoint: http://gitea:3000
# Gate:
#   P1 Postgres role/db/grant proven.
#   P2 Gitea /api/healthz status=pass.
#   P3 Admin user exists/created.
#   P4 Smoke repository created via API.
#   P5 Smoke repository retrieved via API.
#   P6 Service stable after promotion.
# Safety:
#   - no sudo
#   - no paid service
#   - no ollama/open-webui/chat model
#   - no secret echo
#   - no SSH published
#   - registration disabled
#   - pinned image; pull only if missing, with disk guard
#   - probe on temporary port before permanent promotion
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

SERVICE="gitea"
CONTAINER="gitea"
IMAGE="${GITEA_IMAGE_OVERRIDE:-docker.io/gitea/gitea:1.22}"
HOST_PORT="3001"
CONTAINER_PORT="3000"
NET="aether"
VOL="gitea_data"
VOLDEST="/data"

GITEA_ENV="$A/secrets/gitea.env"

PG_CONTAINER="postgres"
PG_PORT="5432"

DB_USER="gitea"
DB_NAME="gitea"

ADMIN_USER_DEFAULT="aether-admin"
ADMIN_EMAIL_DEFAULT="dev@aether.local"
SMOKE_REPO="aether-smoke"
SMOKE_DESC="Aether Gitea brick 9 smoke repository"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/gitea.service"
UNIT_INST="$HOME/.config/systemd/user/gitea.service"
UNIT_SRC_BAK="$UNIT_SRC.pre-BH.bak"
UNIT_INST_BAK="$UNIT_INST.pre-BH.bak"

FAIL_TOKEN="bh-gitea-brick9-failed-v1"
TOKEN="bh-gitea-brick9-green-v1"
SLUG_REPLAY="20261030-BH-gitea-brick9-replay.sh"

TEST_UNITS=()
TEST_CONTAINERS=()

SU_NAME=""
DB_PASS=""
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_EMAIL=""

IMAGE_PRESENT=no
PORT_OWNER="unknown"
HEALTH=no
ADMIN_STATE="not-attempted"
REPO_STATE="not-attempted"
NRESTARTS_AFTER=0
PROBE_PORT=""
PROBE_CONTAINER=""
PROBE_UNIT=""

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
  grep -q "^$1=." "$GITEA_ENV" 2>/dev/null
}
read_env_value(){
  awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$GITEA_ENV" 2>/dev/null || true
}
append_env(){
  local key="$1"
  local val="$2"
  printf '%s=%s\n' "$key" "$val" >> "$GITEA_ENV"
  chmod 600 "$GITEA_ENV" 2>/dev/null || true
}
set_env(){
  local key="$1"
  local val="$2"
  local tmp="$TMPD/setenv.tmp"

  if [ -f "$GITEA_ENV" ]; then
    grep -v "^${key}=" "$GITEA_ENV" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp"
  fi

  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$GITEA_ENV"
  chmod 600 "$GITEA_ENV" 2>/dev/null || true
}
ensure_secret(){
  local key="$1"
  local len="${2:-24}"
  local val=""

  if env_has "$key"; then
    return 0
  fi

  val="$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range($len)))" 2>/dev/null || true)"
  if [ -z "$val" ]; then
    halt "could not generate secret for $key"
  fi

  append_env "$key" "$val"
  say "[H3] appended $key (value not echoed)"
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
known_gitea_container_exists(){
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
    if known_gitea_container_exists; then
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
    say "[H0] listener pid=$pid port=$port class=$cls"
    say "[H0] cmd=$(printf '%s' "$(pid_cmdline "$pid")" | cut -c1-180)"
    say "[H0] cgroup=$(printf '%s' "$(pid_cgroup "$pid")" | cut -c1-220)"

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
pick_free_port_from(){
  local start="$1"
  local p
  for p in $(seq "$start" $((start + 59))); do
    if port_free "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf ''
}
rollback_gitea_only(){
  say "[ROLLBACK] stopping/disabling gitea service (data retained)"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}
journal_dump_for(){
  local unit="$1"
  local cname="$2"
  journalctl --user -u "$unit.service" -n 45 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 80 "$cname" 2>&1 | sed 's/^/    c: /' || true
}
healthz_ok_port(){
  local port="$1"
  local code body
  code="$(norm "$(http_code "http://127.0.0.1:$port/api/healthz")")"
  if [ "$code" != 200 ]; then
    return 1
  fi
  body="$(curl -s --max-time 5 "http://127.0.0.1:$port/api/healthz" 2>/dev/null || true)"
  printf '%s' "$body" | tr -d '[:space:]' | grep -q '"status":"pass"'
}
wait_healthz_port(){
  local port="$1"
  local tries="${2:-150}"
  local i
  for i in $(seq 1 "$tries"); do
    if healthz_ok_port "$port"; then
      HEALTH=yes
      return 0
    fi
    sleep 2
  done
  return 1
}
build_exec(){
  local cname="$1"
  local port="$2"
  local volref="$3"
  local -a args
  local exe="" part

  args=(
    "$PODMAN_BIN" run --rm --replace
    --name "$cname"
    --network "$NET"
    --publish "127.0.0.1:$port:$CONTAINER_PORT"
    --memory 1536m
    --user 0:0
    --security-opt=no-new-privileges
    --env-file "$GITEA_ENV"
    -v "$volref:$VOLDEST"
    "$IMAGE"
  )

  for part in "${args[@]}"; do
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
    printf 'TimeoutStartSec=240\n'
    printf 'Delegate=yes\n\n'
    printf '[Install]\n'
    printf 'WantedBy=default.target\n'
  } > "$file"
}
install_unit_if_changed(){
  local desired="$1"
  local dest="$2"
  local bak="$3"

  mkdir -p "$(dirname "$dest")" 2>/dev/null || true

  if [ ! -f "$dest" ] || ! cmp -s "$desired" "$dest"; then
    if [ -f "$dest" ] && [ ! -f "$bak" ]; then
      cp -p "$dest" "$bak"
      say "[H8] backup -> $bak"
    fi
    install -D -m 644 "$desired" "$dest" || halt "could not install $dest"
    say "[H8] installed -> $dest"
  else
    say "[H8] already desired -> $dest"
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
setup_netrc(){
  ADMIN_USER="$(read_env_value GITEA_ADMIN_USER)"
  ADMIN_PASS="$(read_env_value GITEA_ADMIN_PASSWORD)"
  ADMIN_EMAIL="$(read_env_value GITEA_ADMIN_EMAIL)"

  if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ] || [ -z "$ADMIN_EMAIL" ]; then
    return 1
  fi

  printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$ADMIN_PASS" > "$TMPD/netrc"
  chmod 600 "$TMPD/netrc" 2>/dev/null || true
}
ensure_admin_in_container(){
  local cname="$1"
  local out="$TMPD/admin.out"
  local err="$TMPD/admin.err"
  local adminenv="$TMPD/admin.env"

  if ! setup_netrc; then
    ADMIN_STATE="missing-env"
    return 1
  fi

  printf 'GITEA_ADMIN_USER=%s\nGITEA_ADMIN_EMAIL=%s\nGITEA_ADMIN_PASSWORD=%s\n' \
    "$ADMIN_USER" "$ADMIN_EMAIL" "$ADMIN_PASS" > "$adminenv"
  chmod 600 "$adminenv" 2>/dev/null || true

  if podman exec -i --env-file "$adminenv" "$cname" sh -c 'gitea admin user create --admin --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASSWORD" --email "$GITEA_ADMIN_EMAIL" --must-change-password=false' >"$out" 2>"$err"; then
    ADMIN_STATE=created
    say "[admin] created admin user=$ADMIN_USER"
    return 0
  fi

  if grep -qi 'already exist\|username.*taken\|user already\|is already' "$out" "$err" 2>/dev/null; then
    ADMIN_STATE=exists
    say "[admin] admin user already exists"
    return 0
  fi

  ADMIN_STATE=failed
  say "[admin] admin creation failed"
  tail -n 10 "$err" 2>/dev/null | sed 's/^/    admin-err: /' || true
  tail -n 10 "$out" 2>/dev/null | sed 's/^/    admin-out: /' || true
  return 1
}
smoke_repo_port(){
  local port="$1"
  local create_out="$TMPD/repo-create.out"
  local get_out="$TMPD/repo-get.out"
  local body="$TMPD/repo.json"
  local code

  if ! setup_netrc; then
    REPO_STATE="missing-env"
    return 1
  fi

  printf '{"name":"%s","private":true,"auto_init":true,"description":"%s"}' \
    "$SMOKE_REPO" "$SMOKE_DESC" > "$body"
  chmod 600 "$body" 2>/dev/null || true

  code="$(curl -s -o "$create_out" -w '%{http_code}' --max-time 25 --netrc-file "$TMPD/netrc" \
    -X POST "http://127.0.0.1:$port/api/v1/user/repos" \
    -H 'Content-Type: application/json' \
    --data @"$body" 2>/dev/null || true)"
  code="$(norm "$code")"

  if [ "$code" = 201 ]; then
    REPO_STATE=created
  elif [ "$code" = 409 ] || [ "$code" = 422 ]; then
    if tr -d '[:space:]' < "$create_out" 2>/dev/null | grep -qi 'already\|exist'; then
      REPO_STATE=exists
    else
      REPO_STATE="create-failed:$code"
      head -c 400 "$create_out" 2>/dev/null | sed 's/^/    repo-create: /' || true
      return 1
    fi
  else
    REPO_STATE="create-failed:$code"
    head -c 400 "$create_out" 2>/dev/null | sed 's/^/    repo-create: /' || true
    return 1
  fi

  code="$(curl -s -o "$get_out" -w '%{http_code}' --max-time 15 --netrc-file "$TMPD/netrc" \
    "http://127.0.0.1:$port/api/v1/repos/${ADMIN_USER}/${SMOKE_REPO}" 2>/dev/null || true)"
  code="$(norm "$code")"

  if [ "$code" != 200 ]; then
    REPO_STATE="get-failed:$code"
    head -c 400 "$get_out" 2>/dev/null | sed 's/^/    repo-get: /' || true
    return 1
  fi

  if ! tr -d '[:space:]' < "$get_out" 2>/dev/null | grep -q "\"name\":\"$SMOKE_REPO\""; then
    REPO_STATE="get-body-mismatch"
    head -c 400 "$get_out" 2>/dev/null | sed 's/^/    repo-get: /' || true
    return 1
  fi

  say "[repo] smoke repo ok state=$REPO_REPO_STATE repo=$SMOKE_REPO owner=$ADMIN_USER"
  return 0
}
write_replay_bh(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BH: ensure Gitea unit is installed, active, healthy, and smoke repo exists.
set -uo pipefail
A="$HOME/DevOps/aether"
ENV="$A/secrets/gitea.env"
UNIT_SRC="$A/infra/systemd/gitea.service"
UNIT_INST="$HOME/.config/systemd/user/gitea.service"

install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable gitea.service >/dev/null 2>&1 || true
systemctl --user start gitea.service

HZ=no
for i in $(seq 1 150); do
  B="$(curl -s --max-time 5 http://127.0.0.1:3001/api/healthz 2>/dev/null || true)"
  if printf '%s' "$B" | tr -d '[:space:]' | grep -q '"status":"pass"'; then
    HZ=yes
    break
  fi
  sleep 2
done

U="$(awk -F= '/^GITEA_ADMIN_USER=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
P="$(awk -F= '/^GITEA_ADMIN_PASSWORD=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
N="/tmp/bh-replay.$$.netrc"
printf 'machine 127.0.0.1 login %s password %s\n' "$U" "$P" > "$N"
chmod 600 "$N" 2>/dev/null || true

R="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --netrc-file "$N" http://127.0.0.1:3001/api/v1/repos/$U/aether-smoke)"
rm -f "$N"

if [ "$HZ" = yes ] && [ "$R" = 200 ]; then
  echo "  [GATE PASS] gitea healthz=pass smoke_repo=ok"
else
  echo "  [GATE FAIL] gitea healthz=$HZ smoke_repo=$R"
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

# ===================== [H0] read-only preconditions =====================
say "=== [H0] preconditions ==="

if podman image exists "$IMAGE" 2>/dev/null; then
  IMAGE_PRESENT=yes
  say "[H0] image present: $IMAGE"
else
  say "[H0] image missing: $IMAGE (will pull if applying; pinned tag, no latest)"
fi

if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing; run AA reconcile first"
fi
say "[H0] network present: $NET"

if [ "$(container_status "$PG_CONTAINER")" != running ]; then
  halt "postgres container not running"
fi
say "[H0] postgres running"

PORT_OWNER="$(port_owner_report "$HOST_PORT")"
say "[H0] host_port=$HOST_PORT owner=$PORT_OWNER"

if [ "$PORT_OWNER" = unknown ]; then
  halt "port 127.0.0.1:$HOST_PORT is occupied by an unknown process; not killing it blindly"
fi

if [ "$DRY" = 1 ]; then
  say "[H0] dry-run plan (pure; no image pull, no secret writes, no SQL, no unit writes, no start, no ledger):"
  say "    image       -> $IMAGE present=$IMAGE_PRESENT"
  say "    env         -> $GITEA_ENV (mode 600, contents not echoed)"
  say "    db          -> postgres role=$DB_USER db=$DB_NAME"
  say "    host        -> http://127.0.0.1:$HOST_PORT"
  say "    internal    -> http://$CONTAINER:$CONTAINER_PORT"
  say "    volume      -> $VOL:$VOLDEST"
  say "    probe       -> temporary loopback port before permanent promotion"
  say "    gate        -> healthz + admin + smoke repo create/get + stability"
  say "[RESULT] DRY-RUN complete; nothing written, no image pull, no service touched."
  exit 0
fi

# ===================== [H1] filesystem + ledger scaffold =====================
say "=== [H1] filesystem scaffold ==="
mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user" "$A/secrets"
touch "$IDX"
say "[H1] directories ready"

# ===================== [H2] image pull if missing =====================
say "=== [H2] image gate ==="
if [ "$IMAGE_PRESENT" = yes ]; then
  say "[H2] image already cached: $IMAGE"
else
  AVAIL_KB="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  AVAIL_KB="$(to_int "$AVAIL_KB")"
  if [ "$AVAIL_KB" -lt 1048576 ]; then
    halt "insufficient disk space for Gitea image pull; need at least 1 GiB free under \$HOME"
  fi
  say "[H2] pulling pinned image: $IMAGE"
  if ! podman image pull "$IMAGE"; then
    halt "could not pull $IMAGE"
  fi
  say "[H2] pulled image: $IMAGE"
fi

# ===================== [H3] Gitea env/secrets/config =====================
say "=== [H3] Gitea env file ==="
umask 077

if [ ! -f "$GITEA_ENV" ]; then
  : > "$GITEA_ENV"
  chmod 600 "$GITEA_ENV" 2>/dev/null || true
  say "[H3] created Gitea env file -> $GITEA_ENV"
else
  chmod 600 "$GITEA_ENV" 2>/dev/null || true
  say "[H3] Gitea env file present -> $GITEA_ENV"
fi

set_env GITEA_DB_USER "$DB_USER"
set_env GITEA_DB_NAME "$DB_NAME"
set_env GITEA_ADMIN_USER "$ADMIN_USER_DEFAULT"
set_env GITEA_ADMIN_EMAIL "$ADMIN_EMAIL_DEFAULT"

set_env GITEA__database__DB_TYPE postgres
set_env GITEA__database__HOST "postgres:$PG_PORT"
set_env GITEA__database__NAME "$DB_NAME"
set_env GITEA__database__USER "$DB_USER"
set_env GITEA__database__SSL_MODE disable

set_env GITEA__server__PROTOCOL http
set_env GITEA__server__DOMAIN 127.0.0.1
set_env GITEA__server__ROOT_URL "http://127.0.0.1:$HOST_PORT/"
set_env GITEA__server__HTTP_PORT "$CONTAINER_PORT"
set_env GITEA__server__START_SSH_SERVER false
set_env GITEA__server__SSH_PORT 22
set_env GITEA__server__SSH_LISTEN_PORT 22

set_env GITEA__security__INSTALL_LOCK true
set_env GITEA__service__DISABLE_REGISTRATION true
set_env GITEA__service__REQUIRE_SIGNIN_VIEW true
set_env GITEA__openid__ENABLE_OPENID_SIGNIN false
set_env GITEA__openid__ENABLE_OPENID_SIGNUP false
set_env GITEA__mailer__ENABLED false
set_env GITEA__repository__DEFAULT_BRANCH main
set_env GITEA__repository__DEFAULT_PRIVATE private
set_env GITEA__session__COOKIE_SECURE false
set_env GITEA__actions__ENABLED false
set_env GITEA__packages__ENABLED false
set_env GITEA__metrics__ENABLED true
set_env GITEA__log__LEVEL Info

ensure_secret GITEA_DB_PASSWORD 32
ensure_secret GITEA_ADMIN_PASSWORD 24

DB_PASS="$(read_env_value GITEA_DB_PASSWORD)"
ADMIN_USER="$(read_env_value GITEA_ADMIN_USER)"
ADMIN_PASS="$(read_env_value GITEA_ADMIN_PASSWORD)"
ADMIN_EMAIL="$(read_env_value GITEA_ADMIN_EMAIL)"

if [ -z "$DB_PASS" ] || [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ] || [ -z "$ADMIN_EMAIL" ]; then
  halt "could not read required values from $GITEA_ENV"
fi

if ! valid_ident "$DB_USER"; then
  halt "unsafe DB_USER identifier"
fi
if ! valid_ident "$DB_NAME"; then
  halt "unsafe DB_NAME identifier"
fi
if ! valid_uid_like "$ADMIN_USER"; then
  halt "unsafe ADMIN_USER value"
fi
if ! valid_uid_like "$SMOKE_REPO"; then
  halt "unsafe SMOKE_REPO value"
fi

say "[H3] db user=$DB_USER db=$DB_NAME admin_user=$ADMIN_USER (passwords not shown)"

# ===================== [H4] Postgres role/db/grant =====================
say "=== [H4] ensure Gitea Postgres role/database/grant ==="

SU_NAME="$(container_env_value "$PG_CONTAINER" POSTGRES_USER)"
if [ -z "$SU_NAME" ]; then
  SU_NAME="postgres"
fi
if ! valid_ident "$SU_NAME"; then
  halt "unsafe superuser identifier from container env"
fi
say "[H4] superuser=$SU_NAME (password not shown)"

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

printf 'PGPASSWORD=%s\n' "$DB_PASS" > "$TMPD/app.env"
chmod 600 "$TMPD/app.env" 2>/dev/null || true

cat > "$TMPD/role.sql" <<SQL
\set ON_ERROR_STOP on
\set dbpass ${DB_PASS}
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}')
  THEN format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${DB_USER}', :dbpass)
  ELSE format('CREATE ROLE %I LOGIN PASSWORD %L', '${DB_USER}', :dbpass)
END
\gexec
SQL
chmod 600 "$TMPD/role.sql" 2>/dev/null || true

ROLE_OUT="$TMPD/role.out"
ROLE_ERR="$TMPD/role.err"
if ! run_psql_su "$TMPD/role.sql" "$ROLE_OUT" "$ROLE_ERR" postgres; then
  tail -n 12 "$ROLE_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "ensure Gitea Postgres role failed"
fi
say "[H4] ensured Postgres role $DB_USER"

cat > "$TMPD/db-count.sql" <<SQL
\set ON_ERROR_STOP on
SELECT count(*)::text FROM pg_database WHERE datname = '${DB_NAME}';
SQL
chmod 600 "$TMPD/db-count.sql" 2>/dev/null || true

DBC_OUT="$TMPD/db-count.out"
DBC_ERR="$TMPD/db-count.err"
if ! run_psql_su "$TMPD/db-count.sql" "$DBC_OUT" "$DBC_ERR" postgres; then
  tail -n 12 "$DBC_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "Postgres database count query failed"
fi
DB_COUNT="$(to_int "$(norm "$(head -n1 "$DBC_OUT" | tr -d '\r')")")"

if [ "$DB_COUNT" -eq 0 ]; then
  cat > "$TMPD/create-db.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('CREATE DATABASE %I OWNER %I', '${DB_NAME}', '${DB_USER}')
\gexec
SQL
  chmod 600 "$TMPD/create-db.sql" 2>/dev/null || true
  CDB_OUT="$TMPD/create-db.out"
  CDB_ERR="$TMPD/create-db.err"
  if ! run_psql_su "$TMPD/create-db.sql" "$CDB_OUT" "$CDB_ERR" postgres; then
    tail -n 12 "$CDB_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "CREATE DATABASE gitea failed"
  fi
  say "[H4] created Postgres database $DB_NAME owned by $DB_USER"
else
  cat > "$TMPD/db-owner.sql" <<SQL
\set ON_ERROR_STOP on
SELECT COALESCE(pg_get_userbyid(datdba), 'missing') FROM pg_database WHERE datname = '${DB_NAME}';
SQL
  chmod 600 "$TMPD/db-owner.sql" 2>/dev/null || true
  OWN_OUT="$TMPD/db-owner.out"
  OWN_ERR="$TMPD/db-owner.err"
  if ! run_psql_su "$TMPD/db-owner.sql" "$OWN_OUT" "$OWN_ERR" postgres; then
    tail -n 12 "$OWN_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
    halt "Postgres database owner query failed"
  fi
  DB_OWNER="$(norm "$(head -n1 "$OWN_OUT" | tr -d '\r')")"
  if [ "$DB_OWNER" != "$DB_USER" ]; then
    if [ "$DB_OWNER" = "$SU_NAME" ]; then
      cat > "$TMPD/alter-db-owner.sql" <<SQL
\set ON_ERROR_STOP on
SELECT format('ALTER DATABASE %I OWNER TO %I', '${DB_NAME}', '${DB_USER}')
\gexec
SQL
      chmod 600 "$TMPD/alter-db-owner.sql" 2>/dev/null || true
      ADB_OUT="$TMPD/alter-db.out"
      ADB_ERR="$TMPD/alter-db.err"
      if ! run_psql_su "$TMPD/alter-db-owner.sql" "$ADB_OUT" "$ADB_ERR" postgres; then
        tail -n 12 "$ADB_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
        halt "ALTER DATABASE gitea OWNER failed"
      fi
      say "[H4] changed database owner from $DB_OWNER to $DB_USER"
    else
      halt "database $DB_NAME exists but is owned by unexpected role: $DB_OWNER"
    fi
  else
    say "[H4] Postgres database $DB_NAME already owned by $DB_USER"
  fi
fi

cat > "$TMPD/grant-schema.sql" <<SQL
\set ON_ERROR_STOP on
GRANT USAGE, CREATE ON SCHEMA public TO "${DB_USER}";
SQL
chmod 600 "$TMPD/grant-schema.sql" 2>/dev/null || true
GR_OUT="$TMPD/grant-schema.out"
GR_ERR="$TMPD/grant-schema.err"
if ! run_psql_su "$TMPD/grant-schema.sql" "$GR_OUT" "$GR_ERR" "$DB_NAME"; then
  tail -n 12 "$GR_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "GRANT USAGE, CREATE ON SCHEMA public failed"
fi
say "[H4] ensured schema public USAGE, CREATE for role $DB_USER in db $DB_NAME"

cat > "$TMPD/can-create.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT CASE WHEN has_schema_privilege(current_user, 'public', 'CREATE') THEN 'yes' ELSE 'no' END;
SQL
chmod 600 "$TMPD/can-create.sql" 2>/dev/null || true
CAN_OUT="$TMPD/can-create.out"
CAN_ERR="$TMPD/can-create.err"
if ! run_psql_app "$TMPD/can-create.sql" "$CAN_OUT" "$CAN_ERR"; then
  tail -n 12 "$CAN_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "app-role can_create check failed"
fi
CAN_CREATE="$(norm "$(head -n1 "$CAN_OUT" | tr -d '\r')")"
if [ "$CAN_CREATE" != yes ]; then
  halt "app role cannot CREATE in public after grant"
fi
say "[H4] P1 can_create=yes"

# ===================== [H5] stop known permanent state =====================
say "=== [H5] stop known Gitea state ==="
rollback_gitea_only
PORT_OWNER="$(port_owner_report "$HOST_PORT")"
say "[H5] post_stop_port_owner=$PORT_OWNER"
if [ "$PORT_OWNER" = unknown ]; then
  halt "port 127.0.0.1:$HOST_PORT is occupied by an unknown process after cleanup"
fi
if ! wait_tcp_port_free "$HOST_PORT" 30; then
  halt "port 127.0.0.1:$HOST_PORT remains occupied after known-state cleanup"
fi
say "[H5] port 127.0.0.1:$HOST_PORT free"

# ===================== [H6] volume =====================
say "=== [H6] ensure named volume ==="
if ! podman volume exists "$VOL" 2>/dev/null; then
  podman volume create "$VOL" >/dev/null 2>&1 || halt "could not create volume $VOL"
fi
say "[H6] volume present: $VOL"

# ===================== [H7] probe on temporary port =====================
say "=== [H7] probe Gitea on temporary loopback port ==="
PROBE_PORT="$(pick_free_port_from 18410)"
if [ -z "$PROBE_PORT" ]; then
  halt "could not allocate temporary probe port"
fi

PROBE_CONTAINER="bh-gitea-probe-$SFX"
PROBE_UNIT="bh-gitea-probe-$SFX"
PROBE_UNIT_FILE="$TMPD/$PROBE_UNIT.service"

EXE="$(build_exec "$PROBE_CONTAINER" "$PROBE_PORT" "$VOL")"
make_unit_file "$PROBE_UNIT_FILE" "BH Gitea probe $SFX" "$EXE" "no"

install -D -m 644 "$PROBE_UNIT_FILE" "$HOME/.config/systemd/user/$PROBE_UNIT.service" || halt "could not install probe unit"
TEST_UNITS+=("$PROBE_UNIT")
TEST_CONTAINERS+=("$PROBE_CONTAINER")

systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user reset-failed "$PROBE_UNIT.service" >/dev/null 2>&1 || true

say "[H7] starting probe container=$PROBE_CONTAINER port=$PROBE_PORT"
if ! systemctl --user start "$PROBE_UNIT.service"; then
  journal_dump_for "$PROBE_UNIT" "$PROBE_CONTAINER"
  halt "Gitea probe failed to start"
fi

if ! wait_healthz_port "$PROBE_PORT" 150; then
  journal_dump_for "$PROBE_UNIT" "$PROBE_CONTAINER"
  halt "Gitea probe /api/healthz never returned status=pass"
fi
say "[H7] probe healthz=pass"

if ! ensure_admin_in_container "$PROBE_CONTAINER"; then
  journal_dump_for "$PROBE_UNIT" "$PROBE_CONTAINER"
  halt "Gitea probe admin ensure failed"
fi

if ! smoke_repo_port "$PROBE_PORT"; then
  journal_dump_for "$PROBE_UNIT" "$PROBE_CONTAINER"
  halt "Gitea probe smoke repo failed"
fi
say "[H7] probe smoke repo ok"

systemctl --user disable --now "$PROBE_UNIT.service" >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/$PROBE_UNIT.service" 2>/dev/null || true
podman rm -f "$PROBE_CONTAINER" >/dev/null 2>&1 || true
systemctl --user daemon-reload >/dev/null 2>&1 || true
say "[H7] probe stopped; promoting permanent service"

# ===================== [H8] permanent unit =====================
say "=== [H8] install permanent Gitea unit ==="

EXE="$(build_exec "$CONTAINER" "$HOST_PORT" "$VOL")"

{
  printf '# Brick 9: Gitea as a rootless Podman container service.\n'
  printf '# BH: Postgres-backed, loopback-only, no SSH published, registration disabled.\n'
  printf '# Host endpoint: http://127.0.0.1:%s\n' "$HOST_PORT"
  printf '# Internal endpoint: http://%s:%s\n' "$CONTAINER" "$CONTAINER_PORT"
  printf '# DB: postgres role=%s db=%s\n' "$DB_USER" "$DB_NAME"
  printf '# Volume: %s:%s\n' "$VOL" "$VOLDEST"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Gitea (Aether Git server)\n'
  printf 'After=network-online.target postgres.service\n'
  printf 'Wants=network-online.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStart=%s\n' "$EXE"
  printf 'Restart=always\n'
  printf 'RestartSec=3\n'
  printf 'TimeoutStartSec=240\n'
  printf 'Delegate=yes\n'
  printf '\n'
  printf '[Install]\n'
  printf 'WantedBy=default.target\n'
} > "$TMPD/gitea.service.desired"

install_unit_if_changed "$TMPD/gitea.service.desired" "$UNIT_SRC" "$UNIT_SRC_BAK"
install_unit_if_changed "$UNIT_SRC" "$UNIT_INST" "$UNIT_INST_BAK"

"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true

if ! systemctl --user daemon-reload; then
  rollback_gitea_only
  halt "systemctl --user daemon-reload failed"
fi

if ! systemctl --user enable "$SERVICE.service"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "could not enable $SERVICE.service"
fi

if ! systemctl --user start "$SERVICE.service"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "could not start $SERVICE.service"
fi

say "[H8] started $SERVICE.service"

# ===================== [H9] final gate =====================
say "=== [H9] final Gitea gate ==="
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
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "Gitea did not reach active+running"
fi
say "[H9] unit_active=active container_status=running"

if ! wait_healthz_port "$HOST_PORT" 150; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "Gitea /api/healthz never returned status=pass"
fi
say "[H9] P2 healthz=pass"

if ! ensure_admin_in_container "$CONTAINER"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "Gitea admin ensure failed on permanent service"
fi
say "[H9] P3 admin_state=$ADMIN_STATE"

if ! smoke_repo_port "$HOST_PORT"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "Gitea smoke repo failed on permanent service"
fi
say "[H9] P4/P5 repo_state=$REPO_STATE"

systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
sleep 10
NRESTARTS_AFTER="$(nrestarts "$SERVICE.service")"

if [ "$(active_state "$SERVICE.service")" != active ] ||
   [ "$(container_status "$CONTAINER")" != running ] ||
   ! healthz_ok_port "$HOST_PORT"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "Gitea unstable after final gate"
fi

if [ "$NRESTARTS_AFTER" -gt 0 ]; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "Gitea auto-restart counter climbed to $NRESTARTS_AFTER during stability watch"
fi
say "[H9] P6 stable: active+running+healthz ok, NRestarts=$NRESTARTS_AFTER after 10s"

# ===================== [H10] final state =====================
say "=== [H10] final state ==="
say "[H10] service_active=$(active_state "$SERVICE.service") service_enabled=$(enabled_state "$SERVICE.service")"
say "[H10] container_status=$(container_status "$CONTAINER")"
say "[H10] host=http://127.0.0.1:$HOST_PORT internal=http://$CONTAINER:$CONTAINER_PORT"
say "[H10] db=$DB_NAME role=$DB_USER volume=$VOL admin_user=$ADMIN_USER repo=$SMOKE_REPO"
say "[H10] health=$HEALTH admin_state=$ADMIN_STATE repo_state=$REPO_STATE nrestarts_after=$NRESTARTS_AFTER"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [H11] ledger row =====================
say "=== [H11] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BH-gitea-brick9 | GATE=PASS | %s: installed Gitea as rootless Podman container service; service=%s container=%s network=%s image=%s host=http://127.0.0.1:%s internal=http://%s:%s db=%s role=%s volume=%s admin_user=%s smoke_repo=%s healthz=%s admin_state=%s repo_state=%s nrestarts_after=%s; no ssh published; registration disabled; no sqlite; no ollama/open-webui; no secret echo; loopback-only publish. |\n' \
    "$(date +%F)" \
    "$TOKEN" \
    "$SERVICE" \
    "$CONTAINER" \
    "$NET" \
    "$IMAGE" \
    "$HOST_PORT" \
    "$CONTAINER" \
    "$CONTAINER_PORT" \
    "$DB_NAME" \
    "$DB_USER" \
    "$VOL" \
    "$ADMIN_USER" \
    "$SMOKE_REPO" \
    "$HEALTH" \
    "$ADMIN_STATE" \
    "$REPO_STATE" \
    "$NRESTARTS_AFTER" >> "$IDX"
  say "[H11] ledger row appended."
else
  say "[H11] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[H11] suppression proof: sentinel present." || say "[H11] WARNING: sentinel missing."

write_replay_bh

say "[RESULT] GITEA BRICK 9 GREEN — service=$SERVICE container=$CONTAINER host=http://127.0.0.1:$HOST_PORT internal=http://$CONTAINER:$CONTAINER_PORT db=$DB_NAME admin_user=$ADMIN_USER smoke_repo=$SMOKE_REPO; next: build woodpecker; still no Ollama/OpenWebUI/chat-model."
exit 0
