#!/usr/bin/env bash
# 20261030-BI — Gitea brick 9, cached-ref-first. Supersedes BH.
# Owns BH defects:
#   1) BH pinned docker.io/gitea/gitea:1.22 while session-approved + cached ref is :latest
#      (X/Y/Z image-cache). Pulling 1.22 would downgrade and waste ~180MiB.
#   2) BH referenced undefined $REPO_REPO_STATE (set -u crash after probe repo create).
#   3) BH lacked the DNS cold-start ExecStartPre guard (BF lesson from Grafana 97-loop).
# Policy:
#   image = ${GITEA_IMAGE_OVERRIDE} -> cached :latest -> cached :1.22 -> pull :latest (disk-gated).
#   Freeze chosen image RepoDigests (fallback image id) into unit header + ledger for reproducibility.
# Gates: P1 pg can_create; P2 /api/healthz status=pass; P3 admin created/exists;
#        P4 smoke repo create; P5 smoke repo get; P6 stability NRestarts=0.
# Safety: no sudo; no paid svc; no ollama/open-webui/chat; no secret echo; no SSH published;
#         registration disabled; loopback-only; probe on temp port before promotion.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks.
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
NET="aether"
VOL="gitea_data"
VOLDEST="/data"
HOST_PORT="3001"
CONTAINER_PORT="3000"

REF_LATEST="docker.io/gitea/gitea:latest"
REF_LEGACY="docker.io/gitea/gitea:1.22"
IMAGE_REF=""
IMAGE_DIGEST=""
IMAGE_DIGEST_SOURCE=""

GITEA_ENV="$A/secrets/gitea.env"
DNS_SCRIPT="$A/infra/scripts/aether-dns-wait.sh"
ALPINE="docker.io/library/alpine:latest"

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
UNIT_SRC_BAK="$UNIT_SRC.pre-BI.bak"
UNIT_INST_BAK="$UNIT_INST.pre-BI.bak"

CORRECTION_TOKEN="bi-bh-image-ref-typo-dns-defects"
FAIL_TOKEN="bi-gitea-brick9-failed-v1"
TOKEN="bi-gitea-brick9-green-v1"
SLUG_REPLAY="20261030-BI-gitea-brick9-replay.sh"

TEST_UNITS=()
TEST_CONTAINERS=()

SU_NAME=""
DB_PASS=""
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_EMAIL=""
HEALTH=no
ADMIN_STATE="not-attempted"
REPO_STATE="not-attempted"
NRESTARTS_AFTER=0

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
  printf '%s=%s\n' "$1" "$2" >> "$GITEA_ENV"
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
  say "[I3] appended $key (value not echoed)"
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
    say "[I0] listener pid=$pid port=$port class=$cls"
    say "[I0] cmd=$(printf '%s' "$(pid_cmdline "$pid")" | cut -c1-180)"
    say "[I0] cgroup=$(printf '%s' "$(pid_cgroup "$pid")" | cut -c1-220)"
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
    "$IMAGE_REF"
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
    printf '# BI hardening: block start until aether DNS resolves backing hosts (BF lesson).\n'
    printf 'ExecStartPre=/bin/bash %s postgres\n' "$DNS_SCRIPT"
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
      say "[I8] backup -> $bak"
    fi
    install -D -m 644 "$desired" "$dest" || halt "could not install $dest"
    say "[I8] installed -> $dest"
  else
    say "[I8] already desired -> $dest"
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
  local exec_user="1000:1000"
  local git_uid git_gid
  git_uid="$(podman exec "$cname" sh -c 'id -u git 2>/dev/null || true' 2>/dev/null || true)"
  git_gid="$(podman exec "$cname" sh -c 'id -g git 2>/dev/null || true' 2>/dev/null || true)"
  git_uid="$(norm "$git_uid")"
  git_gid="$(norm "$git_gid")"
  case "$git_uid" in
    ''|*[!0-9]*)
      git_uid=1000
      ;;
  esac
  case "$git_gid" in
    ''|*[!0-9]*)
      git_gid=1000
      ;;
  esac
  exec_user="$git_uid:$git_gid"
  say "[admin] using exec user=$exec_user (non-root service user)"
  podman exec "$cname" sh -c "chown -R $exec_user /data >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  if podman exec -i --user "$exec_user" --env-file "$adminenv" "$cname" sh -c 'gitea admin user create --admin --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASSWORD" --email "$GITEA_ADMIN_EMAIL" --must-change-password=false' >"$out" 2>"$err"; then
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
  say "[repo] smoke repo ok state=$REPO_STATE repo=$SMOKE_REPO owner=$ADMIN_USER"
  return 0
}
write_replay_bi(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BI: Gitea unit installed+active, healthz pass, smoke repo retrievable.
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
N="/tmp/bi-replay.$$.netrc"
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

# ===================== [I0] preconditions =====================
say "=== [I0] preconditions ==="
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing; run AA reconcile first"
fi
say "[I0] network present: $NET"
if [ "$(container_status "$PG_CONTAINER")" != running ]; then
  halt "postgres container not running"
fi
say "[I0] postgres running"
PORT_OWNER="$(port_owner_report "$HOST_PORT")"
say "[I0] host_port=$HOST_PORT owner=$PORT_OWNER"
if [ "$PORT_OWNER" = unknown ]; then
  halt "port 127.0.0.1:$HOST_PORT occupied by unknown process; not killing blindly"
fi

# ===================== [I1] image resolution: cached-ref-first =====================
say "=== [I1] image resolution (cached-ref-first; digest freeze) ==="
if [ -n "${GITEA_IMAGE_OVERRIDE:-}" ]; then
  IMAGE_REF="$GITEA_IMAGE_OVERRIDE"
  say "[I1] override honored: $IMAGE_REF"
  if ! podman image exists "$IMAGE_REF" 2>/dev/null; then
    halt "override image not cached: $IMAGE_REF (pull deliberately, not implicitly)"
  fi
elif podman image exists "$REF_LATEST" 2>/dev/null; then
  IMAGE_REF="$REF_LATEST"
  say "[I1] using CACHED session-approved ref: $IMAGE_REF (no pull)"
elif podman image exists "$REF_LEGACY" 2>/dev/null; then
  IMAGE_REF="$REF_LEGACY"
  say "[I1] using CACHED legacy ref: $IMAGE_REF (no pull)"
else
  IMAGE_REF="$REF_LATEST"
  say "[I1] no cached gitea ref; will pull $IMAGE_REF behind disk guard"
fi

IMAGE_DIGEST="$(podman image inspect "$IMAGE_REF" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | awk '{print $1}')"
IMAGE_DIGEST="$(norm "$IMAGE_DIGEST")"
if [ -n "$IMAGE_DIGEST" ]; then
  IMAGE_DIGEST_SOURCE="repodigest"
else
  IMAGE_DIGEST="$(norm "$(podman image inspect "$IMAGE_REF" --format '{{.Id}}' 2>/dev/null || true)")"
  IMAGE_DIGEST_SOURCE="image-id"
fi
say "[I1] frozen digest($IMAGE_DIGEST_SOURCE)=${IMAGE_DIGEST:-none}"

if [ "$DRY" = 1 ]; then
  say "[I1] dry-run plan (pure; no pull, no secret writes, no SQL, no unit writes, no start, no ledger):"
  say "    image       -> $IMAGE_REF (digest ${IMAGE_DIGEST:-none} via $IMAGE_DIGEST_SOURCE)"
  say "    env         -> $GITEA_ENV (mode 600, contents not echoed)"
  say "    db          -> postgres role=$DB_USER db=$DB_NAME"
  say "    dns guard   -> $DNS_SCRIPT (ExecStartPre)"
  say "    host        -> http://127.0.0.1:$HOST_PORT ; internal http://$CONTAINER:$CONTAINER_PORT"
  say "    gate        -> P1 can_create, P2 healthz, P3 admin, P4/P5 smoke repo, P6 stability"
  say "[RESULT] DRY-RUN complete; nothing written, no pull, no service touched."
  exit 0
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user" "$A/secrets" "$A/infra/scripts"
touch "$IDX"

if [ ! -s "$IMAGE_DIGEST" ] && [ "$IMAGE_DIGEST_SOURCE" = repodigest ]; then
  :
fi

if ! podman image exists "$IMAGE_REF" 2>/dev/null; then
  AVAIL_KB="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  AVAIL_KB="$(to_int "$AVAIL_KB")"
  if [ "$AVAIL_KB" -lt 1048576 ]; then
    halt "insufficient disk for gitea pull; need >=1GiB free under \$HOME"
  fi
  say "[I1] pulling $IMAGE_REF"
  if ! podman image pull "$IMAGE_REF"; then
    halt "could not pull $IMAGE_REF"
  fi
  IMAGE_DIGEST="$(podman image inspect "$IMAGE_REF" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | awk '{print $1}')"
  IMAGE_DIGEST="$(norm "$IMAGE_DIGEST")"
  if [ -z "$IMAGE_DIGEST" ]; then
    IMAGE_DIGEST="$(norm "$(podman image inspect "$IMAGE_REF" --format '{{.Id}}' 2>/dev/null || true)")"
    IMAGE_DIGEST_SOURCE="image-id"
  else
    IMAGE_DIGEST_SOURCE="repodigest"
  fi
  say "[I1] pulled; frozen digest($IMAGE_DIGEST_SOURCE)=${IMAGE_DIGEST:-none}"
fi

# ===================== [I2] shared DNS-wait guard =====================
say "=== [I2] ensure shared DNS-wait guard ==="
if [ ! -x "$DNS_SCRIPT" ]; then
  cat > "$TMPD/dns-wait.sh" <<'SEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh — block until aether DNS resolves given hosts (BF lesson, shared).
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
  say "[I2] installed shared DNS guard -> $DNS_SCRIPT"
else
  say "[I2] shared DNS guard present -> $DNS_SCRIPT"
fi
if ! podman image exists "$ALPINE" 2>/dev/null; then
  halt "alpine image missing (DNS guard needs it cached)"
fi

# ===================== [I3] env/secrets =====================
say "=== [I3] Gitea env file ==="
umask 077
if [ ! -f "$GITEA_ENV" ]; then
  : > "$GITEA_ENV"
  chmod 600 "$GITEA_ENV" 2>/dev/null || true
  say "[I3] created Gitea env file -> $GITEA_ENV"
else
  chmod 600 "$GITEA_ENV" 2>/dev/null || true
  say "[I3] Gitea env file present -> $GITEA_ENV"
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
set_env GITEA__database__PASSWD "$DB_PASS"
say "[I3] mapped DB password to GITEA__database__PASSWD (value not echoed)"
if ! valid_ident "$DB_USER" || ! valid_ident "$DB_NAME"; then
  halt "unsafe DB identifier"
fi
if ! valid_uid_like "$ADMIN_USER" || ! valid_uid_like "$SMOKE_REPO"; then
  halt "unsafe admin/repo identifier"
fi
say "[I3] db user=$DB_USER db=$DB_NAME admin_user=$ADMIN_USER (passwords not shown)"

# ===================== [I4] correction ledger =====================
say "=== [I4] correction ledger row ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BH defects owned: (1) pinned gitea:1.22 though session-approved cached ref is gitea:latest (X/Y/Z image-cache) — would downgrade + waste ~180MiB; (2) undefined REPO_REPO_STATE would crash under set -u after probe repo create; (3) no DNS cold-start ExecStartPre guard (BF lesson). BI supersedes BH: cached-ref-first image policy with RepoDigest freeze, typo fixed, shared aether-dns-wait.sh ExecStartPre. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" >> "$IDX"
  say "[I4] correction row appended."
else
  say "[I4] correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[I4] suppression proof: present." || say "[I4] WARNING: missing."

# ===================== [I5] Postgres role/db/grant =====================
say "=== [I5] ensure Gitea Postgres role/database/grant ==="
SU_NAME="$(container_env_value "$PG_CONTAINER" POSTGRES_USER)"
if [ -z "$SU_NAME" ]; then
  SU_NAME="postgres"
fi
if ! valid_ident "$SU_NAME"; then
  halt "unsafe superuser identifier from container env"
fi
say "[I5] superuser=$SU_NAME (password not shown)"
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
  halt "ensure Gitea Postgres role failed"
fi
say "[I5] ensured Postgres role $DB_USER"

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
    halt "CREATE DATABASE gitea failed"
  fi
  say "[I5] created Postgres database $DB_NAME owned by $DB_USER"
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
      say "[I5] changed db owner from $DB_OWNER to $DB_USER"
    else
      halt "db $DB_NAME owned by unexpected role: $DB_OWNER"
    fi
  else
    say "[I5] db $DB_NAME already owned by $DB_USER"
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
say "[I5] P1 can_create=yes"

# ===================== [I6] stop known state + volume =====================
say "=== [I6] stop known Gitea state; ensure volume ==="
rollback_gitea_only
PORT_OWNER="$(port_owner_report "$HOST_PORT")"
if [ "$PORT_OWNER" = unknown ]; then
  halt "port $HOST_PORT occupied by unknown process after cleanup"
fi
if ! wait_tcp_port_free "$HOST_PORT" 30; then
  halt "port 127.0.0.1:$HOST_PORT still occupied after cleanup"
fi
say "[I6] port 127.0.0.1:$HOST_PORT free"
if ! podman volume exists "$VOL" 2>/dev/null; then
  podman volume create "$VOL" >/dev/null 2>&1 || halt "could not create volume $VOL"
fi
say "[I6] volume present: $VOL"

# ===================== [I7] probe on temporary port =====================
say "=== [I7] probe Gitea on temporary loopback port ==="
PROBE_PORT="$(pick_free_port_from 18410)"
if [ -z "$PROBE_PORT" ]; then
  halt "could not allocate temporary probe port"
fi
PROBE_CONTAINER="bi-gitea-probe-$SFX"
PROBE_UNIT="bi-gitea-probe-$SFX"
EXE="$(build_exec "$PROBE_CONTAINER" "$PROBE_PORT" "$VOL")"
make_unit_file "$TMPD/$PROBE_UNIT.service" "BI Gitea probe $SFX" "$EXE" "no"
install -D -m 644 "$TMPD/$PROBE_UNIT.service" "$HOME/.config/systemd/user/$PROBE_UNIT.service" || halt "could not install probe unit"
TEST_UNITS+=("$PROBE_UNIT")
TEST_CONTAINERS+=("$PROBE_CONTAINER")
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user reset-failed "$PROBE_UNIT.service" >/dev/null 2>&1 || true
say "[I7] starting probe container=$PROBE_CONTAINER port=$PROBE_PORT image=$IMAGE_REF"
if ! systemctl --user start "$PROBE_UNIT.service"; then
  journal_dump_for "$PROBE_UNIT" "$PROBE_CONTAINER"
  halt "probe failed to start"
fi
if ! wait_healthz_port "$PROBE_PORT" 150; then
  journal_dump_for "$PROBE_UNIT" "$PROBE_CONTAINER"
  halt "probe /api/healthz never pass"
fi
say "[I7] P2 probe healthz=pass"
if ! ensure_admin_in_container "$PROBE_CONTAINER"; then
  journal_dump_for "$PROBE_UNIT" "$PROBE_CONTAINER"
  halt "probe admin ensure failed"
fi
say "[I7] P3 probe admin_state=$ADMIN_STATE"
if ! smoke_repo_port "$PROBE_PORT"; then
  journal_dump_for "$PROBE_UNIT" "$PROBE_CONTAINER"
  halt "probe smoke repo failed"
fi
say "[I7] P4/P5 probe repo_state=$REPO_STATE"
systemctl --user disable --now "$PROBE_UNIT.service" >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/$PROBE_UNIT.service" 2>/dev/null || true
podman rm -f "$PROBE_CONTAINER" >/dev/null 2>&1 || true
systemctl --user daemon-reload >/dev/null 2>&1 || true
say "[I7] probe stopped; promoting permanent service"

# ===================== [I8] permanent unit =====================
say "=== [I8] install permanent Gitea unit (digest frozen in header) ==="
EXE="$(build_exec "$CONTAINER" "$HOST_PORT" "$VOL")"
{
  printf '# Brick 9: Gitea as a rootless Podman container service.\n'
  printf '# BI: cached-ref-first image policy; Postgres-backed; loopback-only; no SSH published.\n'
  printf '# Image ref: %s\n' "$IMAGE_REF"
  printf '# Frozen digest (%s): %s\n' "$IMAGE_DIGEST_SOURCE" "${IMAGE_DIGEST:-none}"
  printf '# Host endpoint: http://127.0.0.1:%s ; internal: http://%s:%s\n' "$HOST_PORT" "$CONTAINER" "$CONTAINER_PORT"
  printf '# DB: postgres role=%s db=%s ; volume %s:%s\n' "$DB_USER" "$DB_NAME" "$VOL" "$VOLDEST"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=Gitea (Aether Git server)\n'
  printf 'After=network-online.target postgres.service\n'
  printf 'Wants=network-online.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStartPre=/bin/bash %s postgres\n' "$DNS_SCRIPT"
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
  halt "daemon-reload failed"
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
say "[I8] started $SERVICE.service"

# ===================== [I9] final gate =====================
say "=== [I9] final Gitea gate ==="
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
say "[I9] unit_active=active container_status=running"
if ! wait_healthz_port "$HOST_PORT" 150; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "P2 failed: /api/healthz never pass on permanent service"
fi
say "[I9] P2 healthz=pass"
if ! ensure_admin_in_container "$CONTAINER"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "P3 failed: admin ensure on permanent service"
fi
say "[I9] P3 admin_state=$ADMIN_STATE"
if ! smoke_repo_port "$HOST_PORT"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "P4/P5 failed: smoke repo on permanent service"
fi
say "[I9] P4/P5 repo_state=$REPO_STATE"
systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
sleep 10
NRESTARTS_AFTER="$(nrestarts "$SERVICE.service")"
if [ "$(active_state "$SERVICE.service")" != active ] ||
   [ "$(container_status "$CONTAINER")" != running ] ||
   ! healthz_ok_port "$HOST_PORT"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "P6 failed: unstable after final gate"
fi
if [ "$NRESTARTS_AFTER" -gt 0 ]; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_gitea_only
  halt "P6 failed: NRestarts climbed to $NRESTARTS_AFTER"
fi
say "[I9] P6 stable: NRestarts=$NRESTARTS_AFTER after 10s"

# ===================== [I10] final state + ledger + replay =====================
say "=== [I10] final state ==="
say "[I10] service_active=$(active_state "$SERVICE.service") enabled=$(enabled_state "$SERVICE.service") container=$(container_status "$CONTAINER")"
say "[I10] image=$IMAGE_REF digest_source=$IMAGE_DIGEST_SOURCE digest=${IMAGE_DIGEST:-none}"
say "[I10] host=http://127.0.0.1:$HOST_PORT internal=http://$CONTAINER:$CONTAINER_PORT db=$DB_NAME admin=$ADMIN_USER repo=$SMOKE_REPO"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BI-gitea-brick9 | GATE=PASS | %s: Gitea on cached ref %s (digest %s via %s); service=%s container=%s host=http://127.0.0.1:%s internal=http://%s:%s db=%s role=%s volume=%s admin=%s smoke_repo=%s healthz=%s admin_state=%s repo_state=%s nrestarts=%s; no ssh published; registration disabled; dns-guard ExecStartPre; no sqlite; no ollama/open-webui; no secret echo. |\n' \
    "$(date +%F)" "$TOKEN" "$IMAGE_REF" "${IMAGE_DIGEST:-none}" "$IMAGE_DIGEST_SOURCE" \
    "$SERVICE" "$CONTAINER" "$HOST_PORT" "$CONTAINER" "$CONTAINER_PORT" "$DB_NAME" "$DB_USER" "$VOL" \
    "$ADMIN_USER" "$SMOKE_REPO" "$HEALTH" "$ADMIN_STATE" "$REPO_STATE" "$NRESTARTS_AFTER" >> "$IDX"
  say "[I10] ledger row appended."
else
  say "[I10] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[I10] suppression proof: present." || say "[I10] WARNING: missing."
write_replay_bi

say "[RESULT] GITEA BRICK 9 GREEN — image=$IMAGE_REF (cached, digest frozen) host=http://127.0.0.1:$HOST_PORT internal=http://$CONTAINER:$CONTAINER_PORT admin=$ADMIN_USER smoke_repo=$SMOKE_REPO; next: build woodpecker (cached v3 images); still no Ollama/OpenWebUI/chat-model."
exit 0
