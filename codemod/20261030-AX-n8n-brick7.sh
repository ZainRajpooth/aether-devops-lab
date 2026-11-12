#!/usr/bin/env bash
# 20261030-AX — n8n brick 7 on aether, Postgres-backed, loopback-only, proven steel thread:
#   n8n container -> http://litellm:4000/v1/embeddings -> local-embed -> llama-embed -> 768-dim vector.
# Lessons encoded: AW flat-array one-line ExecStart (no backslashes); AS clean candidate shape;
# redis/minio preflight pattern (presence-only secret checks, no echo); guarded sentinel-in-payload ledger.
# Safety: no sudo; no image pull (n8n cached); no model download; no ollama/open-webui; no secret echo.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks.
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

SERVICE="n8n"
CONTAINER="n8n"
IMAGE="docker.io/n8nio/n8n:latest"
PORT="5678"
NET="aether"
VOL="n8n_data"
VOLDEST="/home/node/.n8n"

SECRETS="$HOME/.config/aether/secrets.env"
LITELLM_ENV="$A/secrets/litellm.env"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/n8n.service"
UNIT_INST="$HOME/.config/systemd/user/n8n.service"
UNIT_SRC_BAK="$UNIT_SRC.pre-AX.bak"
UNIT_INST_BAK="$UNIT_INST.pre-AX.bak"

TOKEN="n8n brick7 GREEN"
SLUG_REPLAY="20261030-AX-n8n-brick7-replay.sh"

OWNER_EMAIL_DEFAULT="dev@aether.local"

UNIT_CHANGED=no
HOST_DIMS=0
NET_HEALTH=0
OWNER_SETUP="not-attempted"
LOGIN="not-attempted"

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
gen_token(){
  python3 -c 'import secrets,string
alpha=string.ascii_letters+string.digits
p=[secrets.choice(string.ascii_uppercase), secrets.choice(string.ascii_lowercase), secrets.choice(string.digits)]
p+= [secrets.choice(alpha) for _ in range(21)]
secrets.SystemRandom().shuffle(p)
print("".join(p))' 2>/dev/null || true
}
wait_tcp_port_free(){
  local p="$1"
  local tries="${2:-30}"
  local i
  for i in $(seq 1 "$tries"); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}
journal_dump(){
  journalctl --user -u "$SERVICE.service" -n 40 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 60 "$CONTAINER" 2>&1 | sed 's/^/    c: /' || true
}
rollback_n8n_only(){
  say "[ROLLBACK] stopping/disabling n8n service (volume retained)"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp; do
  need_cmd "$c"
done

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user"
touch "$IDX"

# ===================== [X0] preconditions + presence-only secret checks =====================
say "=== [X0] preconditions ==="
if ! podman image exists "$IMAGE" 2>/dev/null; then
  halt "n8n image missing: $IMAGE (cached image expected; do not pull ad hoc)"
fi
if [ ! -f "$SECRETS" ]; then
  halt "secrets spine missing: $SECRETS"
fi
if [ ! -f "$LITELLM_ENV" ]; then
  halt "litellm env missing: $LITELLM_ENV (run AW first)"
fi
if podman network exists "$NET" 2>/dev/null; then
  say "[X0] network present: $NET"
else
  halt "network $NET missing; run AA reconcile first"
fi

MISSING_KEYS=""
for k in DB_POSTGRESDB_DATABASE DB_POSTGRESDB_USER DB_POSTGRESDB_PASSWORD; do
  if ! secret_present "$k"; then
    MISSING_KEYS="$MISSING_KEYS $k"
  fi
done
if [ -n "$MISSING_KEYS" ]; then
  halt "secrets.env missing required keys:$MISSING_KEYS — add them deliberately (single-source), then rerun"
fi
say "[X0] postgres creds present in spine (values not echoed)"

umask 077
if ! secret_present N8N_ENCRYPTION_KEY; then
  ENC="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || true)"
  if [ -z "$ENC" ]; then
    halt "could not generate N8N_ENCRYPTION_KEY"
  fi
  append_secret N8N_ENCRYPTION_KEY "$ENC"
  say "[X0] appended N8N_ENCRYPTION_KEY to spine (value not echoed)"
else
  say "[X0] N8N_ENCRYPTION_KEY present"
fi

if ! secret_present N8N_OWNER_EMAIL; then
  append_secret N8N_OWNER_EMAIL "$OWNER_EMAIL_DEFAULT"
  say "[X0] appended N8N_OWNER_EMAIL=$OWNER_EMAIL_DEFAULT"
else
  say "[X0] N8N_OWNER_EMAIL present"
fi

if ! secret_present N8N_OWNER_PASSWORD; then
  OPW="$(gen_token)"
  if [ -z "$OPW" ]; then
    halt "could not generate N8N_OWNER_PASSWORD"
  fi
  append_secret N8N_OWNER_PASSWORD "$OPW"
  say "[X0] appended N8N_OWNER_PASSWORD to spine (value not echoed)"
else
  say "[X0] N8N_OWNER_PASSWORD present"
fi

if [ "$DRY" = 1 ]; then
  say "[X0] dry-run plan:"
  say "    service   -> $SERVICE.service"
  say "    container -> $CONTAINER on $NET, publish 127.0.0.1:$PORT"
  say "    volume    -> $VOL:$VOLDEST"
  say "    db        -> postgresdb via spine keys"
  say "    steel     -> n8n container node fetch http://litellm:4000/v1/embeddings (local-embed)"
  say "[RESULT] DRY-RUN complete; no unit write, no start, no owner setup, no ledger row."
  exit 0
fi

# ===================== [X1] desired unit (flat-array one-line ExecStart) =====================
say "=== [X1] desired n8n.service ==="

N8N_ARGS=(
  run --rm --replace
  --name "$CONTAINER"
  --network "$NET"
  --publish "127.0.0.1:$PORT:5678"
  --memory 1024m
  --security-opt=no-new-privileges
  --env-file "$SECRETS"
  --env-file "$LITELLM_ENV"
  -v "$VOL:$VOLDEST"
  -e DB_TYPE=postgresdb
  -e DB_POSTGRESDB_HOST=postgres
  -e DB_POSTGRESDB_PORT=5432
  -e N8N_EDITOR_BASE_URL="http://127.0.0.1:$PORT/"
  -e GENERIC_TIMEZONE=UTC
  -e N8N_DIAGNOSTICS_ENABLED=false
  "$IMAGE"
)

EXEC="$PODMAN_BIN $(printf '%s ' "${N8N_ARGS[@]}")"
EXEC="${EXEC% }"

{
  printf '# Brick 7: n8n workflow automation as a rootless Podman container service.\n'
  printf '# AX flat-array one-line ExecStart (AW lesson: no backslash continuations).\n'
  printf '# DB: postgres on aether (spine creds); state: named volume %s at %s.\n' "$VOL" "$VOLDEST"
  printf '# Host admin: http://127.0.0.1:%s ; internal: http://%s:%s\n' "$PORT" "$CONTAINER" "$PORT"
  printf '\n'
  printf '[Unit]\n'
  printf 'Description=n8n workflow automation (Postgres-backed)\n'
  printf 'After=network-online.target postgres.service litellm.service\n'
  printf 'Wants=network-online.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=simple\n'
  printf 'ExecStart=%s\n' "$EXEC"
  printf 'Restart=always\n'
  printf 'RestartSec=3\n'
  printf 'TimeoutStartSec=240\n'
  printf 'Delegate=yes\n'
  printf '\n'
  printf '[Install]\n'
  printf 'WantedBy=default.target\n'
} > "$TMPD/n8n.service.desired"

if [ ! -f "$UNIT_SRC" ] || ! cmp -s "$TMPD/n8n.service.desired" "$UNIT_SRC"; then
  if [ -f "$UNIT_SRC" ] && [ ! -f "$UNIT_SRC_BAK" ]; then
    cp -p "$UNIT_SRC" "$UNIT_SRC_BAK"
    say "[X1] unit source backup -> $UNIT_SRC_BAK"
  fi
  install -D -m 644 "$TMPD/n8n.service.desired" "$UNIT_SRC" || halt "could not write n8n unit source"
  UNIT_CHANGED=yes
  say "[X1] installed n8n unit source -> $UNIT_SRC"
else
  say "[X1] n8n unit source already desired -> $UNIT_SRC"
fi

if [ ! -f "$UNIT_INST" ] || ! cmp -s "$UNIT_SRC" "$UNIT_INST"; then
  if [ -f "$UNIT_INST" ] && [ ! -f "$UNIT_INST_BAK" ]; then
    cp -p "$UNIT_INST" "$UNIT_INST_BAK"
    say "[X1] unit installed backup -> $UNIT_INST_BAK"
  fi
  install -D -m 644 "$UNIT_SRC" "$UNIT_INST" || halt "could not install n8n unit"
  UNIT_CHANGED=yes
  say "[X1] installed n8n unit -> $UNIT_INST"
else
  say "[X1] n8n installed unit already desired -> $UNIT_INST"
fi

# ===================== [X2] clean known stale state =====================
say "=== [X2] clean known n8n state ==="
systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
systemctl --user daemon-reload >/dev/null 2>&1 || true

if ! wait_tcp_port_free "$PORT" 30; then
  halt "port 127.0.0.1:$PORT remains occupied by an unknown listener; inspect before promotion"
fi
say "[X2] port 127.0.0.1:$PORT free"

podman volume exists "$VOL" 2>/dev/null || podman volume create "$VOL" >/dev/null 2>&1 || true
say "[X2] volume $VOL present"

# ===================== [X3] start service =====================
say "=== [X3] start n8n.service ==="
if ! systemctl --user enable "$SERVICE.service"; then
  journal_dump
  rollback_n8n_only
  halt "could not enable $SERVICE.service"
fi
if ! systemctl --user start "$SERVICE.service"; then
  journal_dump
  rollback_n8n_only
  halt "could not start $SERVICE.service"
fi
say "[X3] started $SERVICE.service"

# ===================== [X4] wait active+running =====================
say "=== [X4] wait for unit active and container running ==="
WAIT_OK=no
for i in $(seq 1 60); do
  if [ "$(active_state "$SERVICE.service")" = active ] &&
     [ "$(container_status "$CONTAINER")" = running ]; then
    WAIT_OK=yes
    break
  fi
  sleep 2
done
if [ "$WAIT_OK" != yes ]; then
  journal_dump
  rollback_n8n_only
  halt "n8n did not reach active+running"
fi
say "[X4] unit_active=active container_status=running"

# ===================== [X5] host healthz gate (DB-backed) =====================
say "=== [X5] host healthz gate (n8n /healthz reflects DB readiness) ==="
HZ=no
for i in $(seq 1 90); do
  CODE="$(norm "$(http_code "http://127.0.0.1:$PORT/healthz")")"
  if [ "$CODE" = 200 ]; then
    BODY="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/healthz" 2>/dev/null || true)"
    if printf '%s' "$BODY" | grep -q '"status":"ok"'; then
      HZ=yes
      break
    fi
  fi
  sleep 2
done
if [ "$HZ" != yes ]; then
  journal_dump
  rollback_n8n_only
  halt "n8n /healthz never returned 200 status ok (DB migration or connectivity problem)"
fi
say "[X5] host /healthz=200 status=ok (Postgres-backed readiness proven)"

# ===================== [X6] in-network DNS gate =====================
say "=== [X6] in-network DNS gate ==="
NET_OUT="$TMPD/net.out"
NET_ERR="$TMPD/net.err"
if podman run --rm --network "$NET" docker.io/library/alpine:latest \
  /bin/sh -c 'wget -q -O - --timeout=10 "http://n8n:5678/healthz"' >"$NET_OUT" 2>"$NET_ERR"; then
  if grep -q '"status":"ok"' "$NET_OUT" 2>/dev/null; then
    NET_HEALTH=200
  fi
else
  tail -n 5 "$NET_ERR" 2>/dev/null | sed 's/^/    net-err: /' || true
fi
if [ "$NET_HEALTH" != 200 ]; then
  journal_dump
  rollback_n8n_only
  halt "containers on $NET cannot reach http://n8n:5678/healthz"
fi
say "[X6] in-network http://n8n:5678/healthz = ok"

# ===================== [X7] steel thread: n8n container -> LiteLLM embeddings =====================
say "=== [X7] steel thread: n8n container -> LiteLLM -> llama-embed ==="
NODE_PROG='fetch("http://litellm:4000/v1/embeddings",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+process.env.LITELLM_MASTER_KEY},body:JSON.stringify({model:"local-embed",input:"n8n steel thread"})}).then(function(r){return r.json()}).then(function(d){var e=(d&&d.data&&d.data[0]&&d.data[0].embedding)||[];console.log("DIMS="+e.length)}).catch(function(){console.log("DIMS=0")})'
DIMS_OUT="$(podman exec "$CONTAINER" node -e "$NODE_PROG" 2>&1 || true)"
HOST_DIMS="$(to_int "$(printf '%s' "$DIMS_OUT" | sed -n 's/.*DIMS=\([0-9][0-9]*\).*/\1/p' | head -n1)")"
say "[X7] n8n->litellm embeddings dims=$HOST_DIMS"
if [ "$HOST_DIMS" -lt 1 ]; then
  printf '%s\n' "$DIMS_OUT" | head -c 500 | sed 's/^/    resp: /' || true
  journal_dump
  rollback_n8n_only
  halt "n8n container could not obtain embeddings through LiteLLM"
fi

# ===================== [X8] best-effort owner provisioning =====================
say "=== [X8] best-effort owner provisioning (no secret echo) ==="
OWNER_EMAIL="$(secret_value N8N_OWNER_EMAIL)"
OWNER_PW="$(secret_value N8N_OWNER_PASSWORD)"

SETUP_BODY="$TMPD/owner.json"
chmod 600 "$SETUP_BODY" 2>/dev/null || true
printf '{"email":"%s","firstName":"Aether","lastName":"Ops","password":"%s"}' "$OWNER_EMAIL" "$OWNER_PW" > "$SETUP_BODY"

SETUP_CODE="$(curl -s -o "$TMPD/owner.out" -w '%{http_code}' --max-time 20 -X POST "http://127.0.0.1:$PORT/rest/owner-setup" -H 'Content-Type: application/json' --data @"$SETUP_BODY" 2>/dev/null || true)"
SETUP_CODE="$(norm "$SETUP_CODE")"

if [ "$SETUP_CODE" = 200 ] || [ "$SETUP_CODE" = 201 ]; then
  OWNER_SETUP=ok
  say "[X8] owner created via REST"
else
  if grep -qi 'owner' "$TMPD/owner.out" 2>/dev/null && grep -qi 'exist\|already' "$TMPD/owner.out" 2>/dev/null; then
    OWNER_SETUP=exists
    say "[X8] owner already exists"
  else
    OWNER_SETUP=manual-needed
    say "[X8] owner-setup REST returned $SETUP_CODE; complete setup once in UI at http://127.0.0.1:$PORT (credentials are in the spine)"
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
    say "[X8] REST login ok (cookie jar discarded with temp dir)"
  else
    LOGIN=failed
    say "[X8] REST login returned $LOGIN_CODE; owner provisioning needs manual verification"
  fi
fi

# ===================== [X9] final state + ledger + replay =====================
say "=== [X9] final state ==="
say "[X9] service_active=$(active_state "$SERVICE.service") container=$(container_status "$CONTAINER")"
say "[X9] host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT db=postgresdb volume=$VOL"
say "[X9] owner_setup=$OWNER_SETUP login=$LOGIN steel_dims=$HOST_DIMS"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-AX-n8n-brick7 | GATE=PASS | %s: n8n on %s publish 127.0.0.1:%s; db=postgresdb via spine; volume=%s; healthz=200(status ok); in-network healthz=%s; steel thread n8n->litellm->llama-embed dims=%s; owner_setup=%s login=%s; no sqlite; no ollama/open-webui; no secret echo. |\n' \
    "$(date +%F)" "$TOKEN" "$NET" "$PORT" "$VOL" "$NET_HEALTH" "$HOST_DIMS" "$OWNER_SETUP" "$LOGIN" >> "$IDX"
  say "[X9] ledger row appended."
else
  say "[X9] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[X9] suppression proof: sentinel present." || say "[X9] WARNING: sentinel missing."

cat > "$CD/$SLUG_REPLAY" <<REPLAY
#!/usr/bin/env bash
# Replay/verify for AX: ensure n8n unit installed+active and steel thread green.
set -uo pipefail
A="$HOME/DevOps/aether"
UNIT_SRC="$A/infra/systemd/n8n.service"
UNIT_INST="$HOME/.config/systemd/user/n8n.service"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable n8n.service >/dev/null 2>&1 || true
systemctl --user start n8n.service
HZ=no
for i in $(seq 1 90); do
  B=$(curl -s --max-time 5 http://127.0.0.1:5678/healthz 2>/dev/null || true)
  if printf '%s' "$B" | grep -q '"status":"ok"'; then
    HZ=yes
    break
  fi
  sleep 2
done
D=$(podman exec n8n node -e 'fetch("http://litellm:4000/v1/embeddings",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+process.env.LITELLM_MASTER_KEY},body:JSON.stringify({model:"local-embed",input:"replay"})}).then(r=>r.json()).then(d=>{var e=(d&&d.data&&d.data[0]&&d.data[0].embedding)||[];console.log("DIMS="+e.length)}).catch(()=>{console.log("DIMS=0")})' 2>&1 || true)
D=$(printf '%s' "$D" | sed -n 's/.*DIMS=\([0-9][0-9]*\).*/\1/p' | head -n1)
if [ "$HZ" = yes ] && [ "${D:-0}" -gt 0 ]; then
  echo "  [GATE PASS] n8n healthz=ok dims=$D"
else
  echo "  [GATE FAIL] n8n healthz=$HZ dims=${D:-0}"
  exit 1
fi
REPLAY
chmod +x "$CD/$SLUG_REPLAY"
say "[X9] replay archived -> codemod/$SLUG_REPLAY"

say "[RESULT] N8N BRICK 7 GREEN — service=$SERVICE container=$CONTAINER db=postgresdb host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT steel_dims=$HOST_DIMS owner_setup=$OWNER_SETUP; next: grafana, then gitea/woodpecker/portainer, edge (traefik+zitadel) last; still no Ollama/OpenWebUI/chat-model."
exit 0
