#!/usr/bin/env bash
# 20261104-EX7B — READ-ONLY Brick-12 teardown, fixed.
# Mutates nothing except /tmp and one append-only codemod/INDEX.md INFO row.
#
# Purpose:
# Determine why EX6 saw:
#   woodpecker build number=none
#   woodpecker final status=unknown
#   gitea commit status=none
#
# Hypotheses measured:
# A) Gitea webhook delivered, but Woodpecker returned 404 because repo is not activated in WP.
# B) WP API is unreadable without token, so scripted polling is blind.
# C) WP agent cannot reach WP server because gRPC address is loopback inside containers.
# D) WP DB has no repo/pipeline rows.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
TOKEN="ex7b-readonly-woodpecker-teardown-fixed-v1"

REPO="woodpecker-proof"
GT="http://127.0.0.1:3001"
WP="http://127.0.0.1:8000"
NET="aether"
PGU="devops"
PGDB="woodpecker"

BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=""
PGPASS=""
BOT=""

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

scrub(){
  sed -E -e 's#postgres://[^: @]*:[^: @]*@#postgres://***:***@#g' |
  awk -v a="$PASS" -v b="$PGPASS" '
    {
      if ((a != "" && index($0, a)) || (b != "" && index($0, b)))
        print "[REDACTED]"
      else
        print
    }
  '
}

mask_env(){
  awk -F= '
    NF {
      k=$1
      v=substr($0, length(k)+2)
      if (k ~ /(SECRET|TOKEN|PASSWORD|PASSWD|KEY|DSN|DATASOURCE|CLIENT_SECRET)/)
        print k "=***"
      else
        print k "=" v
    }
  '
}

envval(){
  local container="$1" key="$2"
  podman inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    awk -F= -v k="$key" '$1==k { sub(/^[^=]+=/, ""); print; exit }'
}

hr "T0 preflight"
for c in python3 curl podman awk sed grep; do
  command -v "$c" >/dev/null 2>&1 || { say "[HALT] missing command: $c"; exit 1; }
done

for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || { say "[HALT] container not present/running: $c"; exit 1; }
done

mkdir -p "$CD" "$SEC"
touch "$IDX"

[ -s "$BOT_FILE" ] && BOT="$(cat "$BOT_FILE")" || BOT=""
[ -s "$PASS_FILE" ] && PASS="$(cat "$PASS_FILE")" || PASS=""
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"

say "bot=${BOT:-<none>}"
say "bot_pass_present=$([ -n "$PASS" ] && echo yes || echo no)"
say "pgpass_present=$([ -n "$PGPASS" ] && echo yes || echo no)"

hr "T1 Gitea hook delivery evidence"
DELIV_CODE=""
DELIV_STATUS=""
HOOK_ID=""

if [ -n "$BOT" ] && [ -n "$PASS" ]; then
  HOOKS="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '[]')"

  HOOK_ID="$(printf '%s' "$HOOKS" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

items = d if isinstance(d, list) else []
for h in items:
    if not isinstance(h, dict):
        continue
    cfg = h.get("config") or {}
    url = cfg.get("url") or ""
    if "woodpecker" in url:
        print(h.get("id", ""))
        break
' 2>/dev/null || true)"

  say "woodpecker hook id = ${HOOK_ID:-none}"

  if [ -n "$HOOK_ID" ]; then
    say "--- hook detail, secret fields masked ---"
    curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks/$HOOK_ID" 2>/dev/null |
      python3 -c '
import sys, json, re
pat = re.compile(r"(secret|token|password|passwd|key|authorization|client_secret)", re.I)

def mask(o):
    if isinstance(o, dict):
        return {k: ("***" if pat.search(k) else mask(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [mask(x) for x in o]
    return o

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

print(json.dumps(mask(d))[:800])
' 2>/dev/null | scrub | sed 's/^/    /' || true

    say "--- deliveries: event / status / WP http code / body sniff ---"
    curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks/$HOOK_ID/deliveries" 2>/dev/null > "$TMP/deliv.json" || echo '[]' > "$TMP/deliv.json"

    python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("    (deliveries unparseable)")
    sys.exit(0)

items = d if isinstance(d, list) else (d.get("deliveries") or d.get("data") or [])
if not items:
    print("    (deliveries EMPTY: Gitea never posted, or hook disabled, or endpoint unsupported)")
    sys.exit(0)

for x in items[:8]:
    if not isinstance(x, dict):
        continue
    body = str(x.get("response_body") or x.get("request_body") or "")[:160]
    body = body.replace("\n", " ").replace("\r", " ")
    print("    delivery id=%s event=%s status=%s wp_http_code=%s" % (
        x.get("id"),
        x.get("event"),
        x.get("status"),
        x.get("status_code")
    ))
    print("       body160: %s" % body)
' "$TMP/deliv.json" 2>/dev/null | scrub | sed 's/^/  /' || true

    DELIV_CODE="$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

items = d if isinstance(d, list) else (d.get("deliveries") or [])
if items and isinstance(items[0], dict):
    v = items[0].get("status_code", "")
    if v is not None:
        print(v)
' "$TMP/deliv.json" 2>/dev/null || true)"

    DELIV_STATUS="$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

items = d if isinstance(d, list) else (d.get("deliveries") or [])
if items and isinstance(items[0], dict):
    v = items[0].get("status", "")
    if v is not None:
        print(v)
' "$TMP/deliv.json" 2>/dev/null || true)"
  fi
else
  say "skip: no stored Gitea bot credentials"
fi

say "CAPTURED first_delivery_wp_http_code=${DELIV_CODE:-none}"
say "CAPTURED first_delivery_status=${DELIV_STATUS:-none}"

hr "T2 Woodpecker DB truth, read-only"
say "--- table counts + safe row dumps for repo/pipeline/build/agent-like tables ---"
podman exec -i postgres psql -U "$PGU" -d "$PGDB" -v ON_ERROR_STOP=0 2>&1 <<'SQL' | scrub | sed 's/^/    /'
DO $$
DECLARE
  t RECORD;
  c TEXT;
  n BIGINT;
  r RECORD;
BEGIN
  FOR t IN
    SELECT
      table_schema AS s,
      table_name AS tb,
      (table_name ~* '(repo|pipe|build|workflow|task|conf|agent|cron|registr|redirect)') AS is_dump,
      (table_name ~* '(user|secret)') AS is_cat
    FROM information_schema.tables
    WHERE table_schema NOT IN ('pg_catalog','information_schema','toast')
      AND table_type = 'BASE TABLE'
    ORDER BY 1, 2
  LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM %I.%I', t.s, t.tb) INTO n;
      RAISE NOTICE 'COUNT %.% = %', t.s, t.tb, n;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'COUNT %.% = ERR:%', t.s, t.tb, SQLERRM;
    END;

    IF t.is_dump OR t.is_cat THEN
      FOR c IN
        SELECT column_name || ' ' || data_type
        FROM information_schema.columns
        WHERE table_schema = t.s AND table_name = t.tb
        ORDER BY ordinal_position
      LOOP
        RAISE NOTICE 'COL %.%. %', t.s, t.tb, c;
      END LOOP;
    END IF;

    IF t.is_dump THEN
      BEGIN
        SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
        INTO c
        FROM information_schema.columns
        WHERE table_schema = t.s
          AND table_name = t.tb
          AND column_name !~* '(secret|token|password|passwd|hash|key)';

        IF c IS NULL OR c = '' THEN
          RAISE NOTICE 'DUMP %.% = (no non-secret columns)', t.s, t.tb;
        ELSE
          RAISE NOTICE 'SAFE_COLS %.% = %', t.s, t.tb, c;
          FOR r IN EXECUTE format('SELECT %s FROM %I.%I LIMIT 5', c, t.s, t.tb)
          LOOP
            RAISE NOTICE 'ROW %.%: %', t.s, t.tb, r;
          END LOOP;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'DUMP %.% = ERR:%', t.s, t.tb, SQLERRM;
      END;
    END IF;
  END LOOP;
END $$;
SQL

REPO_ROWS="unknown"
PIPE_ROWS="unknown"

if [ -n "$BOT" ]; then
  REPO_ROWS="$(
    podman exec -i postgres psql -U "$PGU" -d "$PGDB" -tA \
      -v bot="$BOT" -v repo="$REPO" \
      -c "SELECT count(*) FROM repos WHERE lower(repo_owner)=lower(:bot) AND lower(repo_name)=lower(:repo)" \
      2>/dev/null | tr -d ' \n' || true
  )"
  [ -z "$REPO_ROWS" ] && REPO_ROWS="unknown"

  PIPE_ROWS="$(
    podman exec -i postgres psql -U "$PGU" -d "$PGDB" -tA \
      -c "SELECT count(*) FROM pipelines" \
      2>/dev/null | tr -d ' \n' || true
  )"
  [ -z "$PIPE_ROWS" ] && PIPE_ROWS="unknown"
fi

say "CAPTURED repos_row_match_guess=${REPO_ROWS}"
say "CAPTURED pipelines_count_guess=${PIPE_ROWS}"
say "NOTE: T2 dump is authoritative; guesses may fail if column names differ."

hr "T3 Woodpecker API observability without token"
for u in \
  "$WP/" \
  "$WP/api" \
  "$WP/api/version" \
  "$WP/api/user" \
  "$WP/api/repos" \
  "$WP/api/repos/$BOT/$REPO" \
  "$WP/api/repos/$BOT/$REPO/builds" \
  "$WP/api/agents" \
  "$WP/swagger/doc.json" \
  "$WP/openapi.json" \
  "$WP/api/swagger.json"
do
  hf="$TMP/h"
  bf="$TMP/b"
  code="$(curl -sS -m 8 -D "$hf" -o "$bf" -w '%{http_code}' "$u" 2>/dev/null || echo 000)"
  ct="$(awk 'tolower($1)=="content-type:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$hf" 2>/dev/null || true)"
  printf '  %-58s code=%-3s ctype=%s\n' "$u" "$code" "${ct:-?}"
  printf '      body140: %s\n' "$(head -c 140 "$bf" 2>/dev/null | tr -d '\n\r' | scrub || true)"
done

say "READ: HTML on /api/... means SPA fallback; those endpoints need auth/token."
say "READ: swagger/openapi JSON gives exact REST routes for activation/token work next turn."

hr "T4 network and gRPC addressing trap"
MEMBERS="$(podman ps --filter network="$NET" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || true)"
say "aether net members: ${MEMBERS:-<none>}"

HAS_SRV=no
HAS_AG=no
printf '%s' "$MEMBERS" | grep -qw woodpecker-server && HAS_SRV=yes
printf '%s' "$MEMBERS" | grep -qw woodpecker-agent && HAS_AG=yes
say "server_on_net=$HAS_SRV agent_on_net=$HAS_AG"

SRV_GRPC="$(envval woodpecker-server WOODPECKER_GRPC_ADDR)"
SRV_HOST="$(envval woodpecker-server WOODPECKER_HOST)"
AG_SRV="$(envval woodpecker-agent WOODPECKER_SERVER)"
AG_GRPC="$(envval woodpecker-agent WOODPECKER_GRPC_ADDR)"

say "server WOODPECKER_GRPC_ADDR='${SRV_GRPC:-unset}'"
say "server WOODPECKER_HOST='${SRV_HOST:-unset}'"
say "agent  WOODPECKER_SERVER='${AG_SRV:-unset}'"
say "agent  WOODPECKER_GRPC_ADDR='${AG_GRPC:-unset}'"

say "--- server non-secret env, masked ---"
podman inspect woodpecker-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
  mask_env |
  grep -iE 'WOODPECKER_(SERVER|GRPC|HOST|OPEN|AUTHENTICATE|BACKEND|PLATFORM|GITEA|DATABASE_DRIVER|AGENT)' |
  sed 's/^/    /' || true

say "--- agent non-secret env, masked ---"
podman inspect woodpecker-agent --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
  mask_env |
  grep -iE 'WOODPECKER_(SERVER|GRPC|HOST|BACKEND|PLATFORM|DOCKER_HOST)' |
  sed 's/^/    /' || true

AGENT_REG="$(podman logs --since 30m woodpecker-server 2>&1 | grep -ciE 'agent registered|registered agent|stream opened|new agent|agent connected' || true)"
say "server log agent-registration hits last 30m = ${AGENT_REG:-0}"

say "--- server log: grpc/listen/agent/hook/activate/repo/404/401/error ---"
podman logs --since 30m woodpecker-server 2>&1 |
  grep -iE 'grpc|listen|agent|register|stream|dial|refused|hook|activate|repo|pipeline|404|401|error|warn' |
  tail -40 |
  scrub |
  sed 's/^/    /' || say "    (no matching lines)"

say "--- agent log: connect/register/dial/refused/error/backend/docker/podman ---"
podman logs --since 30m woodpecker-agent 2>&1 |
  grep -iE 'connect|register|dial|refused|error|warn|grpc|server|backend|docker|podman' |
  tail -30 |
  scrub |
  sed 's/^/    /' || say "    (no matching lines)"

hr "T5 decision"
say "A) Hook delivery: wp_http_code=${DELIV_CODE:-none} status=${DELIV_STATUS:-none}"
case "${DELIV_CODE:-}" in
  404)
    say "   => Gitea posted, Woodpecker replied 404."
    say "   => Strong evidence: repo is not activated inside Woodpecker."
    say "   => A Gitea-side webhook alone is insufficient."
    ;;
  200|201|202|204)
    say "   => Hook accepted by Woodpecker."
    say "   => If T2 shows no pipeline/build, block is downstream: agent/gRPC or config."
    ;;
  ""|none)
    say "   => No delivery record."
    say "   => Either Gitea never posted, hook disabled, wrong hook URL, or deliveries endpoint unsupported."
    ;;
  *)
    say "   => Delivery code ${DELIV_CODE}; inspect body above."
    ;;
esac

say "B) WP API observability:"
say "   If T3 /api/* returned HTML, scripted reads/writes need a Woodpecker API token."
say "   The build may exist but be invisible to anonymous API calls."

say "C) Agent/server gRPC:"
if printf '%s' "${SRV_GRPC:-}" | grep -qE '^(127\.0\.0\.1|localhost)(:|$)'; then
  say "   => SERVER binds gRPC to loopback: ${SRV_GRPC}"
  say "   => Agent container cannot reach it. Heal target: WOODPECKER_GRPC_ADDR=0.0.0.0:9000 or :9000."
fi

if printf '%s' "${AG_SRV:-}" | grep -qE '^(127\.0\.0\.1|localhost)(:|$)'; then
  say "   => AGENT dials its own loopback: ${AG_SRV}"
  say "   => It can never reach server. Heal target: WOODPECKER_SERVER=woodpecker-server:9000."
fi

if [ "$HAS_SRV" != yes ] || [ "$HAS_AG" != yes ]; then
  say "   => Both WP containers are not confirmed on network '$NET'."
  say "   => Name DNS between them will fail. Heal target: attach both to '$NET'."
fi

if [ "${AGENT_REG:-0}" -ge 1 ]; then
  say "   => Server log DOES show agent registration/connection."
  say "   => gRPC path may already be OK despite loopback heuristic."
else
  say "   => Server log shows NO agent registration/connection in last 30m."
  say "   => Consistent with loopback/membership trap."
fi

say "D) DB truth:"
say "   repos_row_match_guess=${REPO_ROWS}"
say "   pipelines_count_guess=${PIPE_ROWS}"
say "   Use T2 COUNT/ROW dump as authoritative."

say "[RESULT] EX7B COMPLETE - read-only; paste T1-T5."
say "Next turn: one coherent heal based on evidence:"
say "  - activate repo in Woodpecker if T1=404 or T2 lacks repo/pipeline"
say "  - fix gRPC addressing if T4 shows loopback/no agent registration"
say "  - capture WP token if T3 shows SPA HTML on /api"

hr "T6 ledger, append-only INFO"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=INFO | EX7B read-only Brick-12 teardown fixed unbound CD. Captured delivery code=%s status=%s; repos_match=%s pipes=%s; srv_grpc=%s ag_srv=%s; agent_reg_hits=%s; net srv/ag=%s/%s. No mutations except /tmp and this INDEX row. |\n' \
    "$(date +%F)" "$TOKEN" "${DELIV_CODE:-none}" "${DELIV_STATUS:-none}" "$REPO_ROWS" "$PIPE_ROWS" "${SRV_GRPC:-unset}" "${AG_SRV:-unset}" "${AGENT_REG:-0}" "$HAS_SRV" "$HAS_AG" >> "$IDX"
  say "ledger row appended"
else
  say "ledger row already exists"
fi

exit 0
