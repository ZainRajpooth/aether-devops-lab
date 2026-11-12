#!/usr/bin/env bash
# 20261030-AY — heal n8n brick 7 restart loop caused by EACCES mkdir '/.n8n'.
# Owns AX defects:
#   1) AX did not force n8n to use the mounted user folder.
#   2) AX --check mutated owner secrets before the dry-run gate.
# Strategy:
#   1) stop the failing n8n restart loop;
#   2) prove clean candidates under throwaway systemd user services;
#   3) promote only the first candidate that reaches n8n /healthz status=ok;
#   4) verify in-network DNS health and n8n -> LiteLLM -> llama-embed steel thread;
#   5) best-effort owner provisioning without echoing secrets;
#   6) append guarded ledger rows and archive replay.
# Candidates:
#   keepid_named : --userns=keep-id, HOME=/home/node, named volume
#   root_named   : --user 0:0, HOME=/root, named volume
#   root_bind    : --user 0:0, HOME=/root, host bind mount under aether/data/n8n
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

SERVICE="n8n"
CONTAINER="n8n"
IMAGE="docker.io/n8nio/n8n:latest"
PORT="5678"
NET="aether"
VOL="n8n_data"
VOLDEST="/home/node/.n8n"
HOST_DIR="$A/data/n8n"

SECRETS="$HOME/.config/aether/secrets.env"
LITELLM_ENV="$A/secrets/litellm.env"

LLAMA_SERVICE="llama-embed-container"
LLAMA_CONTAINER="llama-embed"
LLAMA_PORT="8081"
LITELLM_SERVICE="litellm"
LITELLM_CONTAINER="litellm"
LITELLM_PORT="4000"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/n8n.service"
UNIT_INST="$HOME/.config/systemd/user/n8n.service"
UNIT_SRC_BAK="$UNIT_SRC.pre-AY.bak"
UNIT_INST_BAK="$UNIT_INST.pre-AY.bak"

CORRECTION_TOKEN="ax-n8n-userfolder-eacces-defect"
FAIL_TOKEN="ay-n8n-userfolder-heal-failed-v1"
TOKEN="ay-n8n-userfolder-heal-green-v2"
SLUG_REPLAY="20261030-AY-n8n-userfolder-heal-replay.sh"

CANDIDATES=(
  keepid_named
  root_named
  root_bind
)

declare -A CAND_RC
declare -A CAND_NOTE

TEST_UNITS=()
TEST_CONTAINERS=()

SELECTED=""
CAND_SUMMARY=""
NET_HEALTH=no
STEEL_DIMS=0
OWNER_SETUP="not-attempted"
LOGIN="not-attempted"

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
secret_present(){
  grep -q "^$1=." "$SECRETS" 2>/dev/null
}
secret_value(){
  awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$SECRETS" 2>/dev/null || true
}
append_secret(){
  local key="$1"
  local val="$2"
  printf '%s=%s\n' "$key" "$val" >> "$SECRETS"
  chmod 600 "$SECRETS" 2>/dev/null || true
}
gen_password(){
  python3 -c 'import secrets,string
alpha=string.ascii_letters+string.digits
p=[secrets.choice(string.ascii_uppercase), secrets.choice(string.ascii_lowercase), secrets.choice(string.digits)]
p+=[secrets.choice(alpha) for _ in range(21)]
secrets.SystemRandom().shuffle(p)
print("".join(p))' 2>/dev/null || true
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
healthz_ok(){
  local port="$1"
  local code body
  code="$(norm "$(http_code "http://127.0.0.1:$port/healthz")")"
  if [ "$code" != 200 ]; then
    return 1
  fi
  body="$(curl -s --max-time 5 "http://127.0.0.1:$port/healthz" 2>/dev/null || true)"
  printf '%s' "$body" | grep -q '"status":"ok"'
}
wait_healthz(){
  local port="$1"
  local tries="${2:-120}"
  local i st
  for i in $(seq 1 "$tries"); do
    if healthz_ok "$port"; then
      return 0
    fi
    st="$(active_state "n8n-probe-does-not-exist.service")"
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
rollback_n8n_only(){
  say "[ROLLBACK] stopping/disabling n8n service (data retained)"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}
build_exec_for_candidate(){
  local cand="$1"
  local cname="$2"
  local port="$3"
  local -a cmd
  local exe="" part

  cmd=(
    "$PODMAN_BIN" run --rm --replace
    --name "$cname"
    --network "$NET"
    --publish "127.0.0.1:$port:5678"
    --memory 1536m
    --security-opt=no-new-privileges
    --env-file "$SECRETS"
    --env-file "$LITELLM_ENV"
    -e DB_TYPE=postgresdb
    -e DB_POSTGRESDB_HOST=postgres
    -e DB_POSTGRESDB_PORT=5432
    -e "N8N_USER_FOLDER=$VOLDEST"
    -e N8N_HOST=0.0.0.0
    -e N8N_PROTOCOL=http
    -e N8N_PORT=5678
    -e "WEBHOOK_URL=http://127.0.0.1:$port/"
    -e "N8N_EDITOR_BASE_URL=http://127.0.0.1:$port/"
    -e GENERIC_TIMEZONE=UTC
    -e N8N_DIAGNOSTICS_ENABLED=false
  )

  case "$cand" in
    keepid_named)
      cmd+=(--userns=keep-id -e HOME=/home/node -v "$VOL:$VOLDEST" "$IMAGE")
      ;;
    root_named)
      cmd+=(--user 0:0 -e HOME=/root -v "$VOL:$VOLDEST" "$IMAGE")
      ;;
    root_bind)
      cmd+=(--user 0:0 -e HOME=/root -v "$HOST_DIR:$VOLDEST" "$IMAGE")
      ;;
    *)
      halt "unknown candidate: $cand"
      ;;
  esac

  for part in "${cmd[@]}"; do
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
  local i
  for i in $(seq 1 120); do
    if healthz_ok "$port"; then
      ok=yes
      break
    fi
    sleep 2
  done

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
dns_healthz_ok(){
  local out
  out="$(podman exec "$CONTAINER" node -e 'fetch("http://n8n:5678/healthz").then(r=>r.text()).then(t=>console.log(t)).catch(e=>{console.log("ERR:"+e.message);process.exit(1)})' 2>&1 || true)"
  printf '%s' "$out" | grep -q '"status":"ok"'
}
steel_thread_ok(){
  local prog out dims
  prog='fetch("http://litellm:4000/v1/embeddings",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+process.env.LITELLM_MASTER_KEY},body:JSON.stringify({model:"local-embed",input:"n8n AY steel thread"})}).then(function(r){return r.json()}).then(function(d){var e=(d&&d.data&&d.data[0]&&d.data[0].embedding)||[];console.log("DIMS="+e.length)}).catch(function(){console.log("DIMS=0")})'
  out="$(podman exec "$CONTAINER" node -e "$prog" 2>&1 || true)"
  dims="$(to_int "$(printf '%s' "$out" | sed -n 's/.*DIMS=\([0-9][0-9]*\).*/\1/p' | head -n1)")"
  STEEL_DIMS="$dims"
  if [ "$dims" -gt 0 ]; then
    return 0
  fi
  printf '%s\n' "$out" | head -c 700 | sed 's/^/    resp: /' || true
  return 1
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr; do
  need_cmd "$c"
done

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user" "$HOST_DIR"
chmod 700 "$HOST_DIR" 2>/dev/null || true
touch "$IDX"

# ===================== [Y0] preconditions, pure dry-run =====================
say "=== [Y0] preconditions ==="

if ! podman image exists "$IMAGE" 2>/dev/null; then
  halt "n8n image missing: $IMAGE"
fi
if [ ! -f "$SECRETS" ]; then
  halt "secrets spine missing: $SECRETS"
fi
if [ ! -f "$LITELLM_ENV" ]; then
  halt "litellm env missing: $LITELLM_ENV"
fi
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing; run AA reconcile first"
fi

MISSING_KEYS=""
for k in DB_POSTGRESDB_DATABASE DB_POSTGRESDB_USER DB_POSTGRESDB_PASSWORD; do
  if ! secret_present "$k"; then
    MISSING_KEYS="$MISSING_KEYS $k"
  fi
done
if [ -n "$MISSING_KEYS" ]; then
  halt "secrets.env missing required keys:$MISSING_KEYS"
fi
say "[Y0] postgres creds present in spine (values not echoed)"

NEED_ENC=no
NEED_EMAIL=no
NEED_PW=no
if ! secret_present N8N_ENCRYPTION_KEY; then
  NEED_ENC=yes
fi
if ! secret_present N8N_OWNER_EMAIL; then
  NEED_EMAIL=yes
fi
if ! secret_present N8N_OWNER_PASSWORD; then
  NEED_PW=yes
fi

LLAMA_HEALTH="$(norm "$(http_code "http://127.0.0.1:$LLAMA_PORT/health")")"
if [ "$LLAMA_HEALTH" != 200 ]; then
  halt "llama-embed health is not 200 on 127.0.0.1:$LLAMA_PORT; got $LLAMA_HEALTH"
fi
say "[Y0] llama-embed healthy health=$LLAMA_HEALTH"

if [ "$(active_state "$LITELLM_SERVICE.service")" != active ]; then
  halt "litellm service is not active"
fi
if [ "$(container_status "$LITELLM_CONTAINER")" != running ]; then
  halt "litellm container is not running"
fi
LITELLM_HEALTH="$(norm "$(http_code "http://127.0.0.1:$LITELLM_PORT/health/liveliness")")"
if [ "$LITELLM_HEALTH" != 200 ]; then
  halt "litellm liveliness is not 200 on 127.0.0.1:$LITELLM_PORT; got $LITELLM_HEALTH"
fi
say "[Y0] litellm healthy liveliness=$LITELLM_HEALTH"

if [ "$DRY" = 1 ]; then
  say "[Y0] dry-run plan:"
  say "    stop failing n8n restart loop"
  say "    candidates: ${CANDIDATES[*]}"
  say "    promote first candidate reaching /healthz status=ok"
  say "    verify n8n -> litellm -> llama-embed embeddings"
  if [ "$NEED_ENC" = yes ]; then
    say "    would append N8N_ENCRYPTION_KEY if missing"
  fi
  if [ "$NEED_EMAIL" = yes ]; then
    say "    would append N8N_OWNER_EMAIL if missing"
  fi
  if [ "$NEED_PW" = yes ]; then
    say "    would append N8N_OWNER_PASSWORD if missing"
  fi
  say "[RESULT] DRY-RUN complete; no secret writes, no unit writes, no candidate services, no ledger row."
  exit 0
fi

umask 077
if [ "$NEED_ENC" = yes ]; then
  ENC="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || true)"
  if [ -z "$ENC" ]; then
    halt "could not generate N8N_ENCRYPTION_KEY"
  fi
  append_secret N8N_ENCRYPTION_KEY "$ENC"
  say "[Y0] appended N8N_ENCRYPTION_KEY to spine (value not echoed)"
else
  say "[Y0] N8N_ENCRYPTION_KEY present"
fi

if [ "$NEED_EMAIL" = yes ]; then
  append_secret N8N_OWNER_EMAIL "dev@aether.local"
  say "[Y0] appended N8N_OWNER_EMAIL=dev@aether.local"
else
  say "[Y0] N8N_OWNER_EMAIL present"
fi

if [ "$NEED_PW" = yes ]; then
  OPW="$(gen_password)"
  if [ -z "$OPW" ]; then
    halt "could not generate N8N_OWNER_PASSWORD"
  fi
  append_secret N8N_OWNER_PASSWORD "$OPW"
  say "[Y0] appended N8N_OWNER_PASSWORD to spine (value not echoed)"
else
  say "[Y0] N8N_OWNER_PASSWORD present"
fi

# ===================== [Y1] correction ledger =====================
say "=== [Y1] correction ledger row ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AX n8n failed because rootless Podman/n8n resolved user folder as /.n8n and hit EACCES mkdir /.n8n. AX also mutated owner secrets during --check. AY supersedes AX by forcing N8N_USER_FOLDER/HOME, proving clean candidates on temporary ports, and keeping --check pure. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" >> "$IDX"
  say "[Y1] AX n8n correction row appended."
else
  say "[Y1] AX n8n correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[Y1] suppression proof: correction sentinel present." || say "[Y1] WARNING: correction sentinel missing."

# ===================== [Y2] stop failing restart loop =====================
say "=== [Y2] stop failing n8n restart loop ==="
rollback_n8n_only
if ! wait_tcp_port_free "$PORT" 30; then
  halt "port 127.0.0.1:$PORT remains occupied after stopping known n8n state; inspect listener before candidate proof"
fi
say "[Y2] port 127.0.0.1:$PORT free"

podman volume exists "$VOL" 2>/dev/null || podman volume create "$VOL" >/dev/null 2>&1 || true
say "[Y2] named volume $VOL present"
say "[Y2] host bind candidate dir ready -> $HOST_DIR"

# ===================== [Y3] candidate proof =====================
say "=== [Y3] n8n candidate proof under throwaway systemd user services ==="
idx=0
for cand in "${CANDIDATES[@]}"; do
  idx=$((idx + 1))
  port="$(pick_free_port_from $((18200 + idx * 10)))"
  if [ -z "$port" ]; then
    halt "could not allocate temporary port for candidate $cand"
  fi

  cname="ay-$cand-$SFX"
  unit="ay-$cand-$SFX"
  file="$TMPD/$unit.service"

  exe="$(build_exec_for_candidate "$cand" "$cname" "$port")"
  make_unit_file "$file" "AY n8n candidate $cand $SFX" "$exe" "no"

  say "[Y3] testing candidate=$cand container=$cname port=$port"
  run_serving_test "$unit" "$file" "$cname" "$port"
  rc=$?
  CAND_RC["$cand"]="$rc"

  if [ "$rc" = 0 ]; then
    CAND_NOTE["$cand"]="healthz-ok"
    SELECTED="$cand"
    say "[Y3] selected candidate=$SELECTED"
    break
  else
    CAND_NOTE["$cand"]="failed"
    say "[Y3] candidate=$cand rc=$rc"
  fi
done

CAND_SUMMARY=""
for cand in "${CANDIDATES[@]}"; do
  CAND_SUMMARY="${CAND_SUMMARY}${cand}=${CAND_RC[$cand]:-skipped}/${CAND_NOTE[$cand]:-?} "
done
CAND_SUMMARY="$(norm "$CAND_SUMMARY")"

if [ -z "$SELECTED" ]; then
  say "[Y3] all n8n candidates failed."
  say "[Y3] candidates=$CAND_SUMMARY"
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | AY n8n candidate proof failed: candidates=%s; native n8n remains stopped to avoid restart loop; inspect [Y3] journals above. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" "$CAND_SUMMARY" >> "$IDX"
    say "[Y3] failure ledger row appended."
  else
    say "[Y3] failure ledger row already present (guard suppressed)."
  fi
  halt "no n8n candidate passed; service left stopped to prevent restart loop"
fi

# ===================== [Y4] promote selected candidate permanently =====================
say "=== [Y4] promote selected candidate=$SELECTED ==="

if [ -f "$UNIT_SRC" ] && [ ! -f "$UNIT_SRC_BAK" ]; then
  cp -p "$UNIT_SRC" "$UNIT_SRC_BAK"
  say "[Y4] unit source backup -> $UNIT_SRC_BAK"
fi
if [ -f "$UNIT_INST" ] && [ ! -f "$UNIT_INST_BAK" ]; then
  cp -p "$UNIT_INST" "$UNIT_INST_BAK"
  say "[Y4] unit installed backup -> $UNIT_INST_BAK"
fi

exe="$(build_exec_for_candidate "$SELECTED" "$CONTAINER" "$PORT")"

{
  printf '# Brick 7 healed: n8n workflow automation as a rootless Podman container service.\n'
  printf '# AY forces N8N_USER_FOLDER and HOME to avoid EACCES mkdir /.n8n.\n'
  printf '# Selected candidate: %s\n' "$SELECTED"
  printf '# Container name: %s\n' "$CONTAINER"
  printf '# Network: %s\n' "$NET"
  printf '# Host admin endpoint: http://127.0.0.1:%s\n' "$PORT"
  printf '# Internal endpoint: http://%s:%s\n' "$CONTAINER" "$PORT"
  printf '# DB: postgresdb via secrets spine; no SQLite.\n'
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=n8n workflow automation (Postgres-backed, AY healed)\n'
  printf 'After=network-online.target postgres.service litellm.service %s.service\n' "$LLAMA_SERVICE"
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
} > "$TMPD/n8n.service.desired"

install -D -m 644 "$TMPD/n8n.service.desired" "$UNIT_SRC" || halt "could not write n8n unit source"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST" || halt "could not install n8n unit"
say "[Y4] installed healed n8n unit -> $UNIT_INST"

"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true

if ! systemctl --user daemon-reload; then
  rollback_n8n_only
  halt "systemctl --user daemon-reload failed"
fi

if ! systemctl --user enable "$SERVICE.service"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_n8n_only
  halt "could not enable $SERVICE.service"
fi

if ! systemctl --user start "$SERVICE.service"; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_n8n_only
  halt "could not start $SERVICE.service"
fi

say "[Y4] started $SERVICE.service with candidate=$SELECTED"

# ===================== [Y5] wait active+running =====================
say "=== [Y5] wait for unit active and container running ==="
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
  rollback_n8n_only
  halt "healed n8n did not reach active+running"
fi

say "[Y5] unit_active=active container_status=$(container_status "$CONTAINER")"

# ===================== [Y6] host healthz gate =====================
say "=== [Y6] host healthz gate ==="
HZ=no
for i in $(seq 1 120); do
  if healthz_ok "$PORT"; then
    HZ=yes
    break
  fi
  sleep 2
done

if [ "$HZ" != yes ]; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_n8n_only
  halt "healed n8n /healthz never returned 200 status=ok"
fi

say "[Y6] host /healthz=200 status=ok"

# ===================== [Y7] in-network DNS gate =====================
say "=== [Y7] in-network DNS gate ==="
if dns_healthz_ok; then
  NET_HEALTH=yes
else
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_n8n_only
  halt "n8n container cannot reach http://n8n:5678/healthz internally"
fi
say "[Y7] in-network http://n8n:5678/healthz = ok"

# ===================== [Y8] steel thread =====================
say "=== [Y8] steel thread: n8n -> LiteLLM -> llama-embed ==="
if ! steel_thread_ok; then
  journal_dump_for "$SERVICE" "$CONTAINER"
  rollback_n8n_only
  halt "n8n steel thread failed: could not obtain embeddings through LiteLLM"
fi
say "[Y8] n8n->litellm->llama-embed dims=$STEEL_DIMS"

# ===================== [Y9] best-effort owner provisioning =====================
say "=== [Y9] best-effort owner provisioning (no secret echo) ==="
OWNER_EMAIL="$(secret_value N8N_OWNER_EMAIL)"
OWNER_PW="$(secret_value N8N_OWNER_PASSWORD)"

SETUP_BODY="$TMPD/owner.json"
chmod 600 "$SETUP_BODY" 2>/dev/null || true
printf '{"email":"%s","firstName":"Aether","lastName":"Ops","password":"%s"}' "$OWNER_EMAIL" "$OWNER_PW" > "$SETUP_BODY"

SETUP_CODE="$(curl -s -o "$TMPD/owner.out" -w '%{http_code}' --max-time 20 -X POST "http://127.0.0.1:$PORT/rest/owner-setup" -H 'Content-Type: application/json' --data @"$SETUP_BODY" 2>/dev/null || true)"
SETUP_CODE="$(norm "$SETUP_CODE")"

if [ "$SETUP_CODE" = 200 ] || [ "$SETUP_CODE" = 201 ]; then
  OWNER_SETUP=ok
  say "[Y9] owner created via REST"
else
  if grep -qi 'owner' "$TMPD/owner.out" 2>/dev/null && grep -qi 'exist\|already' "$TMPD/owner.out" 2>/dev/null; then
    OWNER_SETUP=exists
    say "[Y9] owner already exists"
  else
    OWNER_SETUP=manual-needed
    say "[Y9] owner-setup REST returned $SETUP_CODE; complete setup once in UI at http://127.0.0.1:$PORT (credentials are in the spine)"
  fi
fi

if [ "$OWNER_SETUP" = ok ] || [ "$OWNER_SETUP" = exists ]; then
  LOGIN_BODY="$TMPD/login.json"
  chmod 600 "$LOGIN_BODY" 2>/dev/null || true
  printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$OWNER_EMAIL" "$OWNER_PW" > "$LOGIN_BODY"
  LOGIN_CODE="$(curl -s -o "$TMPD/login.out" -w '%{http_code}' --max-time 20 -c "$TMPD/cookies.txt" -X POST "http://127.0.0.1:$PORT/rest/login" -H 'Content-Type: application/json' --data @"$LOGIN_BODY" 2>/dev/null || true)"
  LOGIN_CODE="$(norm "$LOGIN_CODE")"
  if [ "$LOGIN_CODE" = 200 ]; then
    LOGIN=ok
    say "[Y9] REST login ok (cookie jar discarded with temp dir)"
  else
    LOGIN=failed
    say "[Y9] REST login returned $LOGIN_CODE; owner provisioning needs manual verification"
  fi
fi

# ===================== [Y10] final state =====================
say "=== [Y10] final state ==="
say "[Y10] selected_candidate=$SELECTED"
say "[Y10] service_active=$(active_state "$SERVICE.service") service_enabled=$(enabled_state "$SERVICE.service")"
say "[Y10] container_status=$(container_status "$CONTAINER")"
say "[Y10] host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT db=postgresdb"
say "[Y10] healthz=$HZ dns_health=$NET_HEALTH steel_dims=$STEEL_DIMS owner_setup=$OWNER_SETUP login=$LOGIN"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

# ===================== [Y11] ledger row =====================
say "=== [Y11] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-AY-n8n-userfolder-heal | GATE=PASS | %s: healed n8n EACCES mkdir /.n8n by forcing N8N_USER_FOLDER/HOME and selecting clean candidate=%s; service=%s container=%s network=%s host=http://127.0.0.1:%s internal=http://%s:%s db=postgresdb healthz=ok dns_health=%s steel_dims=%s owner_setup=%s login=%s candidates=%s; no sqlite; no ollama/open-webui; no secret echo. |\n' \
    "$(date +%F)" \
    "$TOKEN" \
    "$SELECTED" \
    "$SERVICE" \
    "$CONTAINER" \
    "$NET" \
    "$PORT" \
    "$CONTAINER" \
    "$PORT" \
    "$NET_HEALTH" \
    "$STEEL_DIMS" \
    "$OWNER_SETUP" \
    "$LOGIN" \
    "$CAND_SUMMARY" >> "$IDX"
  say "[Y11] ledger row appended."
else
  say "[Y11] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[Y11] suppression proof: sentinel present." || say "[Y11] WARNING: sentinel missing."

# ===================== [Y12] replay =====================
cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AY: ensure healed n8n unit is installed, active, and steel thread green.
set -uo pipefail
A="$HOME/DevOps/aether"
UNIT_SRC="$A/infra/systemd/n8n.service"
UNIT_INST="$HOME/.config/systemd/user/n8n.service"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable n8n.service >/dev/null 2>&1 || true
systemctl --user start n8n.service
HZ=no
for i in $(seq 1 120); do
  B=$(curl -s --max-time 5 http://127.0.0.1:5678/healthz 2>/dev/null || true)
  if printf '%s' "$B" | grep -q '"status":"ok"'; then
    HZ=yes
    break
  fi
  sleep 2
done
D=$(podman exec n8n node -e 'fetch("http://litellm:4000/v1/embeddings",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+process.env.LITELLM_MASTER_KEY},body:JSON.stringify({model:"local-embed",input:"AY replay"})}).then(r=>r.json()).then(d=>{var e=(d&&d.data&&d.data[0]&&d.data[0].embedding)||[];console.log("DIMS="+e.length)}).catch(()=>{console.log("DIMS=0")})' 2>&1 || true)
D=$(printf '%s' "$D" | sed -n 's/.*DIMS=\([0-9][0-9]*\).*/\1/p' | head -n1)
if [ "$HZ" = yes ] && [ "${D:-0}" -gt 0 ]; then
  echo "  [GATE PASS] n8n healthz=ok dims=$D"
else
  echo "  [GATE FAIL] n8n healthz=$HZ dims=${D:-0}"
  exit 1
fi
REPLAY
chmod +x "$CD/$SLUG_REPLAY"
say "[Y12] replay archived -> codemod/$SLUG_REPLAY"

say "[RESULT] N8N BRICK 7 GREEN AFTER USERFOLDER HEAL — selected=$SELECTED service=$SERVICE container=$CONTAINER host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT steel_dims=$STEEL_DIMS owner_setup=$OWNER_SETUP; next: grafana, then gitea/woodpecker/portainer, edge last; still no Ollama/OpenWebUI/chat-model."
exit 0
