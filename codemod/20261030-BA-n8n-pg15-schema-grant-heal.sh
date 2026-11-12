#!/usr/bin/env bash
# 20261030-BA — heal n8n "permission denied for schema public" (PostgreSQL 15+ default ACL change).
# Owns AY/AZ result:
#   AZ fixed SFX + N8N_HOST; AY then proved the real blocker is Postgres schema-public CREATE denial
#   for the least-privilege n8n role, NOT a Podman/userns/systemd defect. /healthz raced pre-migration;
#   steel thread + crash journal correctly halted. AY replay heredoc was unquoted (latent bug) -> fixed here.
# Fix (minimal, least-privilege, idempotent):
#   GRANT USAGE, CREATE ON SCHEMA public TO <approle>   (in the n8n database only)
# executed as the bootstrap superuser over the container's own 127.0.0.1, password via 600 temp env-file
# (never echoed, never in argv). Then TRIPLE-PROVE before green:
#   P1 app role has_schema_privilege(public,CREATE)=yes
#   P2 n8n migrations created tables (public table count>0) AND service stable (not crash-looping)
#   P3 steel thread n8n -> litellm -> llama-embed dims>0
# Safety: no sudo; no image pull; no model download; no ollama/open-webui; no secret echo; --check pure.
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
PORT="5678"
NET="aether"

PG_CONTAINER="postgres"
PG_PORT="5432"

SECRETS="$HOME/.config/aether/secrets.env"
LITELLM_ENV="$A/secrets/litellm.env"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/n8n.service"
UNIT_INST="$HOME/.config/systemd/user/n8n.service"

LLAMA_SERVICE="llama-embed-container"
LLAMA_PORT="8081"
LITELLM_SERVICE="litellm"
LITELLM_CONTAINER="litellm"
LITELLM_PORT="4000"

CORRECTION_TOKEN="ay-n8n-pg15-schema-public-create-defect"
FAIL_TOKEN="ba-n8n-pg15-grant-failed-v1"
TOKEN="ba-n8n-pg15-grant-green-v1"
SLUG_REPLAY="20261030-BA-n8n-pg15-grant-heal-replay.sh"

CAN_CREATE=no
TABLES=0
STEEL_DIMS=0
NET_HEALTH=no
OWNER_SETUP="not-attempted"
LOGIN="not-attempted"
SU_NAME=""
APPROLE=""
APPDB=""

cleanup(){
  rm -rf "$TMPD" 2>/dev/null || true
}
trap cleanup EXIT
write_replay_ba(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BA: ensure healed n8n is active and steel thread green (quoted heredoc; AY bug fixed).
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
  if printf "%s" "$B" | grep -q '"status":"ok"'; then
    HZ=yes
    break
  fi
  sleep 2
done
D=$(podman exec n8n node -e 'fetch("http://litellm:4000/v1/embeddings",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+process.env.LITELLM_MASTER_KEY},body:JSON.stringify({model:"local-embed",input:"BA replay"})}).then(r=>r.json()).then(d=>{var e=(d&&d.data&&d.data[0]&&d.data[0].embedding)||[];console.log("DIMS="+e.length)}).catch(()=>{console.log("DIMS=0")})' 2>&1 || true)
D=$(printf "%s" "$D" | sed -n 's/.*DIMS=\([0-9][0-9]*\).*/\1/p' | head -n1)
if [ "$HZ" = yes ] && [ "${D:-0}" -gt 0 ]; then
  echo "  [GATE PASS] n8n healthz=ok dims=$D"
else
  echo "  [GATE FAIL] n8n healthz=$HZ dims=${D:-0}"
  exit 1
fi
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[REPLAY] archived -> codemod/$SLUG_REPLAY"
}

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
secret_present(){
  grep -q "^$1=." "$SECRETS" 2>/dev/null
}
secret_value(){
  awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$SECRETS" 2>/dev/null || true
}
# Read a single env KEY from a container's config env WITHOUT printing any other secret.
container_env_value(){
  local cname="$1"
  local key="$2"
  podman inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' || true
}
healthz_ok(){
  local code body
  code="$(norm "$(http_code "http://127.0.0.1:$PORT/healthz")")"
  if [ "$code" != 200 ]; then
    return 1
  fi
  body="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/healthz" 2>/dev/null || true)"
  printf '%s' "$body" | grep -q '"status":"ok"'
}
wait_healthz(){
  local tries="${1:-120}"
  local i
  for i in $(seq 1 "$tries"); do
    if healthz_ok; then
      return 0
    fi
    sleep 2
  done
  return 1
}
rollback_n8n_only(){
  say "[ROLLBACK] stopping/disabling n8n service (data + grant retained)"
  systemctl --user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}
journal_dump(){
  journalctl --user -u "$SERVICE.service" -n 40 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 60 "$CONTAINER" 2>&1 | sed 's/^/    c: /' || true
}
dns_healthz_ok(){
  local out
  out="$(podman exec "$CONTAINER" node -e 'fetch("http://n8n:5678/healthz").then(r=>r.text()).then(t=>console.log(t)).catch(e=>{console.log("ERR:"+e.message);process.exit(1)})' 2>&1 || true)"
  printf '%s' "$out" | grep -q '"status":"ok"'
}
steel_thread_ok(){
  local prog out dims
  prog='fetch("http://litellm:4000/v1/embeddings",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+process.env.LITELLM_MASTER_KEY},body:JSON.stringify({model:"local-embed",input:"n8n BA steel thread"})}).then(function(r){return r.json()}).then(function(d){var e=(d&&d.data&&d.data[0]&&d.data[0].embedding)||[];console.log("DIMS="+e.length)}).catch(function(){console.log("DIMS=0")})'
  out="$(podman exec "$CONTAINER" node -e "$prog" 2>&1 || true)"
  dims="$(to_int "$(printf '%s' "$out" | sed -n 's/.*DIMS=\([0-9][0-9]*\).*/\1/p' | head -n1)")"
  STEEL_DIMS="$dims"
  if [ "$dims" -gt 0 ]; then
    return 0
  fi
  printf '%s\n' "$out" | head -c 500 | sed 's/^/    resp: /' || true
  return 1
}

for c in bash podman systemctl journalctl curl awk sed grep python3 install chmod seq sleep mktemp tr; do
  need_cmd "$c"
done

mkdir -p "$CD" "$UNIT_SRC_DIR" "$HOME/.config/systemd/user"
touch "$IDX"

# ===================== [B0] preconditions + identifier discovery (no secret echo) =====================
say "=== [B0] preconditions + identifier discovery ==="

if [ ! -f "$UNIT_INST" ]; then
  halt "healed n8n unit missing: $UNIT_INST (run AY/AZ first; BA reuses the keepid_named unit)"
fi
if [ ! -f "$SECRETS" ]; then
  halt "secrets spine missing: $SECRETS"
fi
if [ ! -f "$LITELLM_ENV" ]; then
  halt "litellm env missing: $LITELLM_ENV"
fi
if [ "$(container_status "$PG_CONTAINER")" != running ]; then
  halt "postgres container not running; run AA reconcile first"
fi
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing"
fi

APPROLE="$(secret_value DB_POSTGRESDB_USER)"
APPDB="$(secret_value DB_POSTGRESDB_DATABASE)"
if [ -z "$APPROLE" ] || [ -z "$APPDB" ]; then
  halt "spine missing DB_POSTGRESDB_USER / DB_POSTGRESDB_DATABASE"
fi
if ! secret_present DB_POSTGRESDB_PASSWORD; then
  halt "spine missing DB_POSTGRESDB_PASSWORD"
fi

SU_NAME="$(container_env_value "$PG_CONTAINER" POSTGRES_USER)"
if [ -z "$SU_NAME" ]; then
  SU_NAME="postgres"
fi

if ! valid_ident "$APPROLE"; then
  halt "unsafe APPROLE identifier (refusing to interpolate into SQL)"
fi
if ! valid_ident "$APPDB"; then
  halt "unsafe APPDB identifier"
fi
if ! valid_ident "$SU_NAME"; then
  halt "unsafe superuser identifier from container env"
fi

say "[B0] approle=$APPROLE appdb=$APPDB superuser=$SU_NAME (passwords not shown)"

LLAMA_HEALTH="$(norm "$(http_code "http://127.0.0.1:$LLAMA_PORT/health")")"
if [ "$LLAMA_HEALTH" != 200 ]; then
  halt "llama-embed health != 200 (got $LLAMA_HEALTH)"
fi
if [ "$(active_state "$LITELLM_SERVICE.service")" != active ] ||
   [ "$(container_status "$LITELLM_CONTAINER")" != running ]; then
  halt "litellm not active+running"
fi
LITELLM_HEALTH="$(norm "$(http_code "http://127.0.0.1:$LITELLM_PORT/health/liveliness")")"
if [ "$LITELLM_HEALTH" != 200 ]; then
  halt "litellm liveliness != 200 (got $LITELLM_HEALTH)"
fi
say "[B0] llama-embed=200 litellm=200 postgres=running"

CUR_ACTIVE="$(active_state "$SERVICE.service")"
CUR_CONT="$(container_status "$CONTAINER")"
say "[B0] current n8n service=$CUR_ACTIVE container=$CUR_CONT"

if [ "$DRY" = 1 ]; then
  say "[B0] dry-run plan (pure; no SQL, no env-files with secrets, no start, no ledger):"
  say "    1) stop n8n if not already green"
  say "    2) GRANT USAGE, CREATE ON SCHEMA public TO $APPROLE  (in db $APPDB, as $SU_NAME via 127.0.0.1)"
  say "    3) prove app role can_create=yes"
  say "    4) start n8n, prove migrations created tables + service stable"
  say "    5) prove in-network healthz + steel thread n8n->litellm->llama-embed"
  say "    6) best-effort owner setup + login; guarded ledger; quoted replay"
  say "[RESULT] DRY-RUN complete; no grant, no start, no ledger row."
  exit 0
fi

# ===================== [B1] correction ledger =====================
say "=== [B1] correction ledger row ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AY/AZ cleared Podman defects; the residual n8n failure was PostgreSQL 15+ default ACL: schema public no longer grants CREATE to non-owner roles, so the least-privilege n8n role got "permission denied for schema public" during TypeORM migrations. /healthz raced pre-migration and passed, but steel-thread correctly halted. BA grants USAGE,CREATE on public to the n8n role in its own DB (least privilege, idempotent) and triple-proves (can_create, tables>0+stable, steel-thread). Also fixes AY unquoted replay heredoc. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" >> "$IDX"
  say "[B1] PG15 schema-public correction row appended."
else
  say "[B1] PG15 schema-public correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[B1] suppression proof: correction sentinel present." || say "[B1] WARNING: correction sentinel missing."

# ===================== [B2] fast path: already fully green? =====================
say "=== [B2] already-green fast path (read-only probes) ==="
FAST=no
if [ "$CUR_ACTIVE" = active ] && [ "$CUR_CONT" = running ] && healthz_ok; then
  # need app-role probes; build temp env-file (600) for the check only
  umask 077
  APPPW="$(secret_value DB_POSTGRESDB_PASSWORD)"
  printf 'PGPASSWORD=%s\n' "$APPPW" > "$TMPD/app.env"
  chmod 600 "$TMPD/app.env" 2>/dev/null || true
  unset APPPW

  cat > "$TMPD/app_check.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT CASE WHEN has_schema_privilege(current_user, 'public', 'CREATE') THEN 'CAN_CREATE=yes' ELSE 'CAN_CREATE=no' END;
SQL
  cat > "$TMPD/app_tables.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT 'TABLES=' || count(*)::text FROM information_schema.tables WHERE table_schema = 'public';
SQL

  CHK="$(podman exec --env-file "$TMPD/app.env" "$PG_CONTAINER" psql -h 127.0.0.1 -p "$PG_PORT" -U "$APPROLE" -d "$APPDB" -f "$TMPD/app_check.sql" 2>"$TMPD/chk.err" || true)"
  TBLS="$(podman exec --env-file "$TMPD/app.env" "$PG_CONTAINER" psql -h 127.0.0.1 -p "$PG_PORT" -U "$APPROLE" -d "$APPDB" -f "$TMPD/app_tables.sql" 2>"$TMPD/tbl.err" || true)"
  if printf '%s' "$CHK" | grep -q 'CAN_CREATE=yes' &&
     [ "$(to_int "$(printf '%s' "$TBLS" | sed -n 's/.*TABLES=\([0-9][0-9]*\).*/\1/p' | head -n1)")" -gt 0 ] &&
     steel_thread_ok; then
    FAST=yes
  fi
fi

if [ "$FAST" = yes ]; then
  say "[B2] n8n already fully green (can_create + tables>0 + steel-thread); ensuring enabled"
  systemctl --user enable "$SERVICE.service" >/dev/null 2>&1 || true
  TABLES="$(to_int "$(printf '%s' "$TBLS" | sed -n 's/.*TABLES=\([0-9][0-9]*\).*/\1/p' | head -n1)")"
  CAN_CREATE=yes
  NET_HEALTH=yes
  if dns_healthz_ok; then NET_HEALTH=yes; else NET_HEALTH=no; fi
  if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | B | 20261030-BA-n8n-pg15-grant-heal | GATE=PASS | %s: already-green fast path; n8n role=%s db=%s can_create=%s tables=%s steel_dims=%s dns_health=%s; grant idempotent no-op; no secret echo. |\n' \
      "$(date +%F)" "$TOKEN" "$APPROLE" "$APPDB" "$CAN_CREATE" "$TABLES" "$STEEL_DIMS" "$NET_HEALTH" >> "$IDX"
    say "[B2] ledger row appended (fast path)."
  else
    say "[B2] ledger row already present (guard suppressed)."
  fi
  grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[B2] suppression proof: sentinel present." || say "[B2] WARNING: sentinel missing."
  write_replay_ba
  say "[RESULT] N8N BRICK 7 GREEN (PG15 GRANT ALREADY IN PLACE) — service=$SERVICE host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT steel_dims=$STEEL_DIMS; next: build grafana; still no Ollama/OpenWebUI/chat-model."
  exit 0
fi
say "[B2] not fully green; proceeding to grant + (re)start"

# ===================== [B3] stop n8n to break any crash loop =====================
say "=== [B3] stop n8n (break crash loop before grant) ==="
rollback_n8n_only
say "[B3] n8n stopped; service=$SERVICE container=$(container_status "$CONTAINER")"

# ===================== [B4] grant USAGE,CREATE on public (as superuser, 127.0.0.1, no echo) =====================
say "=== [B4] apply least-privilege schema grant ==="
umask 077

SUPW="$(container_env_value "$PG_CONTAINER" POSTGRES_PASSWORD)"
printf 'PGPASSWORD=%s\n' "$SUPW" > "$TMPD/su.env"
chmod 600 "$TMPD/su.env" 2>/dev/null || true
unset SUPW

APPPW="$(secret_value DB_POSTGRESDB_PASSWORD)"
printf 'PGPASSWORD=%s\n' "$APPPW" > "$TMPD/app.env"
chmod 600 "$TMPD/app.env" 2>/dev/null || true
unset APPPW

cat > "$TMPD/grant.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT format('GRANT USAGE, CREATE ON SCHEMA public TO %I', :'approle') \gexec
SQL

GRANT_OUT="$TMPD/grant.out"
GRANT_ERR="$TMPD/grant.err"
GRANT_RC=0
if ! podman exec --env-file "$TMPD/su.env" "$PG_CONTAINER" psql \
      -h 127.0.0.1 -p "$PG_PORT" -U "$SU_NAME" -d "$APPDB" \
      -v approle="$APPROLE" -f "$TMPD/grant.sql" >"$GRANT_OUT" 2>"$GRANT_ERR"; then
  GRANT_RC=$?
fi

if [ "$GRANT_RC" != 0 ]; then
  say "[B4] grant psql rc=$GRANT_RC"
  tail -n 12 "$GRANT_ERR" 2>/dev/null | sed 's/^/    pg-err: /' || true
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BA schema grant failed: superuser=%s approle=%s appdb=%s rc=%s; n8n left stopped; inspect [B4] pg-err (likely local-socket/auth or db-name mismatch). |\n' \
      "$(date +%F)" "$FAIL_TOKEN" "$SU_NAME" "$APPROLE" "$APPDB" "$GRANT_RC" >> "$IDX"
    say "[B4] failure ledger row appended."
  fi
  halt "schema grant failed; n8n left stopped to avoid restart loop"
fi
say "[B4] GRANT USAGE, CREATE ON SCHEMA public TO $APPROLE applied in db $APPDB (idempotent)"

# ===================== [B5] prove P1: app role can_create =====================
say "=== [B5] P1 proof: app role has_schema_privilege(public,CREATE) ==="
cat > "$TMPD/app_check.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT CASE WHEN has_schema_privilege(current_user, 'public', 'CREATE') THEN 'CAN_CREATE=yes' ELSE 'CAN_CREATE=no' END;
SQL
CHK="$(podman exec --env-file "$TMPD/app.env" "$PG_CONTAINER" psql -h 127.0.0.1 -p "$PG_PORT" -U "$APPROLE" -d "$APPDB" -f "$TMPD/app_check.sql" 2>"$TMPD/chk.err" || true)"
if printf '%s' "$CHK" | grep -q 'CAN_CREATE=yes'; then
  CAN_CREATE=yes
else
  tail -n 8 "$TMPD/chk.err" 2>/dev/null | sed 's/^/    pg-err: /' || true
  halt "P1 failed: app role still cannot CREATE in public after grant"
fi
say "[B5] P1 can_create=yes"

# ===================== [B6] start n8n + prove P2 (migrations created tables + stable) =====================
say "=== [B6] start n8n and prove migrations + stability ==="
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
say "[B6] started $SERVICE.service"

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
  journal_dump
  rollback_n8n_only
  halt "n8n did not reach active+running after grant"
fi
say "[B6] unit_active=active container_status=running"

if ! wait_healthz 120; then
  journal_dump
  rollback_n8n_only
  halt "n8n /healthz never ok after grant"
fi
say "[B6] host /healthz=200 status=ok"

cat > "$TMPD/app_tables.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT 'TABLES=' || count(*)::text FROM information_schema.tables WHERE table_schema = 'public';
SQL

TABLES=0
for i in $(seq 1 60); do
  TBLS="$(podman exec --env-file "$TMPD/app.env" "$PG_CONTAINER" psql -h 127.0.0.1 -p "$PG_PORT" -U "$APPROLE" -d "$APPDB" -f "$TMPD/app_tables.sql" 2>/dev/null || true)"
  TABLES="$(to_int "$(printf '%s' "$TBLS" | sed -n 's/.*TABLES=\([0-9][0-9]*\).*/\1/p' | head -n1)")"
  if [ "$TABLES" -gt 0 ]; then
    break
  fi
  sleep 2
done
if [ "$TABLES" -lt 1 ]; then
  journal_dump
  rollback_n8n_only
  halt "P2 failed: n8n migrations created no tables in public (grant not effective or db mismatch)"
fi
say "[B6] P2 migrations created tables in public: count=$TABLES"

# stability re-check (catch crash-loop that briefly passed healthz)
sleep 8
if [ "$(active_state "$SERVICE.service")" != active ] ||
   [ "$(container_status "$CONTAINER")" != running ] || ! healthz_ok; then
  journal_dump
  rollback_n8n_only
  halt "P2 failed: n8n not stable after initial healthz (still crash-looping)"
fi
say "[B6] P2 stability re-check ok (active+running+healthz after 8s)"

# ===================== [B7] prove in-network DNS =====================
say "=== [B7] in-network DNS gate ==="
if dns_healthz_ok; then
  NET_HEALTH=yes
else
  journal_dump
  rollback_n8n_only
  halt "n8n container cannot reach http://n8n:5678/healthz internally"
fi
say "[B7] in-network http://n8n:5678/healthz = ok"

# ===================== [B8] prove P3 steel thread =====================
say "=== [B8] P3 steel thread: n8n -> LiteLLM -> llama-embed ==="
if ! steel_thread_ok; then
  journal_dump
  rollback_n8n_only
  halt "P3 failed: n8n could not obtain embeddings through LiteLLM"
fi
say "[B8] P3 n8n->litellm->llama-embed dims=$STEEL_DIMS"

# ===================== [B9] best-effort owner provisioning (no secret echo) =====================
say "=== [B9] best-effort owner provisioning ==="
OWNER_EMAIL="$(secret_value N8N_OWNER_EMAIL)"
OWNER_PW="$(secret_value N8N_OWNER_PASSWORD)"
if [ -z "$OWNER_EMAIL" ]; then OWNER_EMAIL="dev@aether.local"; fi

if [ -n "$OWNER_PW" ]; then
  SETUP_BODY="$TMPD/owner.json"
  chmod 600 "$SETUP_BODY" 2>/dev/null || true
  printf '{"email":"%s","firstName":"Aether","lastName":"Ops","password":"%s"}' "$OWNER_EMAIL" "$OWNER_PW" > "$SETUP_BODY"
  SETUP_CODE="$(curl -s -o "$TMPD/owner.out" -w '%{http_code}' --max-time 20 -X POST "http://127.0.0.1:$PORT/rest/owner-setup" -H 'Content-Type: application/json' --data @"$SETUP_BODY" 2>/dev/null || true)"
  SETUP_CODE="$(norm "$SETUP_CODE")"
  if [ "$SETUP_CODE" = 200 ] || [ "$SETUP_CODE" = 201 ]; then
    OWNER_SETUP=ok
    say "[B9] owner created via REST"
  else
    if grep -qi 'exist\|already' "$TMPD/owner.out" 2>/dev/null; then
      OWNER_SETUP=exists
      say "[B9] owner already exists"
    else
      OWNER_SETUP=manual-needed
      say "[B9] owner-setup returned $SETUP_CODE; finish once in UI at http://127.0.0.1:$PORT (creds in spine)"
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
      say "[B9] REST login ok (cookie jar discarded with temp dir)"
    else
      LOGIN=failed
      say "[B9] REST login returned $LOGIN_CODE"
    fi
  fi
else
  OWNER_SETUP=manual-needed
  say "[B9] no N8N_OWNER_PASSWORD in spine; complete setup once in UI at http://127.0.0.1:$PORT"
fi

# ===================== [B10] final state + ledger + quoted replay =====================
say "=== [B10] final state ==="
say "[B10] service_active=$(active_state "$SERVICE.service") service_enabled=$(enabled_state "$SERVICE.service") container=$(container_status "$CONTAINER")"
say "[B10] host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT db=$APPDB role=$APPROLE"
say "[B10] can_create=$CAN_CREATE tables=$TABLES dns_health=$NET_HEALTH steel_dims=$STEEL_DIMS owner_setup=$OWNER_SETUP login=$LOGIN"
podman ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BA-n8n-pg15-grant-heal | GATE=PASS | %s: healed n8n PG15 schema-public CREATE denial via least-privilege GRANT USAGE,CREATE on public to role=%s in db=%s (idempotent, superuser via 127.0.0.1, no echo); service=%s host=http://127.0.0.1:%s internal=http://%s:%s can_create=%s tables=%s dns_health=%s steel_dims=%s owner_setup=%s login=%s; no sqlite; no ollama/open-webui; AY unquoted-replay bug fixed. |\n' \
    "$(date +%F)" "$TOKEN" "$APPROLE" "$APPDB" "$SERVICE" "$PORT" "$CONTAINER" "$PORT" "$CAN_CREATE" "$TABLES" "$NET_HEALTH" "$STEEL_DIMS" "$OWNER_SETUP" "$LOGIN" >> "$IDX"
  say "[B10] ledger row appended."
else
  say "[B10] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[B10] suppression proof: sentinel present." || say "[B10] WARNING: sentinel missing."

write_replay_ba

say "[RESULT] N8N BRICK 7 GREEN AFTER PG15 SCHEMA GRANT — service=$SERVICE container=$CONTAINER host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT role=$APPROLE db=$APPDB can_create=$CAN_CREATE tables=$TABLES steel_dims=$STEEL_DIMS owner_setup=$OWNER_SETUP; next: build grafana; still no Ollama/OpenWebUI/chat-model."
exit 0
