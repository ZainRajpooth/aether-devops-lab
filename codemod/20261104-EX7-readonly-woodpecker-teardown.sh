#!/usr/bin/env bash
# 20261104-EX7 — READ-ONLY Brick-12 teardown (§7 after >2 partials). Mutates NOTHING.
# Answers, with evidence, WHY EX6 saw build=none / gitea_status=none:
#   (1) did Gitea actually deliver the hook, and what did WP reply?  (Gitea deliveries API,
#       using the bot creds EX6 already validated -> 200)
#   (2) is the repo / any pipeline actually registered in WP's DB?   (SELECT/count + safe
#       row dumps via RAISE NOTICE; secret columns excluded; users/secrets catalog-only)
#   (3) can we even READ WP's API without a token?                   (GET probes incl swagger)
#   (4) is the agent able to reach the server's gRPC at all?         (network membership +
#       the 127.0.0.1 loopback trap on BOTH sides + 'agent registered' in server log)
# Secrets masked everywhere (mask_env / scrub / gj_mask). Ledger = one INFO row.
set -uo pipefail
HOME_="$HOME"; SEC="$HOME_/DevOps/aether/secrets"; IDX="$CD/INDEX.md"
TOKEN="ex7-readonly-woodpecker-teardown-v1"
REPO="woodpecker-proof"
GT="http://127.0.0.1:3001"            # EX6-confirmed real Gitea host port
WP="http://127.0.0.1:8000"            # EX6-confirmed WP server public API
NET="aether"; PGU="devops"; PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=""; PGPASS=""
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

scrub(){ sed -E -e 's#postgres://[^: @]*:[^: @]*@#postgres://***:***@#g' \
        | awk -v a="$PASS" -v b="$PGPASS" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "[REDACTED]"; else print }'; }
mask_env(){ awk -F= 'NF{k=$1; v=substr($0,length(k)+2); if (k ~ /(SECRET|TOKEN|PASSWORD|PASSWD|KEY|DSN|DATASOURCE|CLIENT_SECRET)/) print k"=***"; else print k"="v}'; }
envval(){ podman inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= -v k="$2" '$1==k{sub(/^[^=]+=/,"");print;exit}'; }

hr "T0 read stored bot creds (tolerate absence)"
[ -s "$BOT_FILE" ] && BOT="$(cat "$BOT_FILE")" || BOT=""
[ -s "$PASS_FILE" ] && PASS="$(cat "$PASS_FILE")" || PASS=""
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
say "bot=${BOT:-<none>} pass_present=$([ -n "$PASS" ] && echo yes || echo no) pgpass_present=$([ -n "$PGPASS" ] && echo yes || echo no)"

hr "T1 did Gitea deliver the hook, and what did WP answer? (decisive for 'repo not activated')"
DELIV_CODE=""; DELIV_STATUS=""
if [ -n "$BOT" ] && [ -n "$PASS" ]; then
  HOOKS="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '[]')"
  HOOK_ID="$(printf '%s' "$HOOKS" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for h in (d if isinstance(d,list) else []):
    u=((h.get("config") or {}).get("url") or "")
    if "woodpecker" in u:
        print(h.get("id","")); break
' 2>/dev/null || true)"
  say "woodpecker hook id = ${HOOK_ID:-none}"
  if [ -n "$HOOK_ID" ]; then
    say "--- hook detail (secret-keys masked) ---"
    curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks/$HOOK_ID" 2>/dev/null \
      | python3 -c '
import sys,json,re
pat=re.compile(r"(secret|token|password|passwd|key|authorization|client_secret)",re.I)
def w(o):
    if isinstance(o,dict): return {k:("***" if pat.search(k) else w(v)) for k,v in o.items()}
    if isinstance(o,list): return [w(x) for x in o]
    return o
try: d=json.load(sys.stdin)
except Exception: d={}
print(json.dumps(w(d))[:600])
' 2>/dev/null | scrub | sed 's/^/    /' || true
    say "--- deliveries (event / status / WP http code / body sniff) ---"
    curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks/$HOOK_ID/deliveries" 2>/dev/null > "$TMP/deliv.json" || echo '[]' > "$TMP/deliv.json"
    python3 -c '
import sys,json
try: d=json.load(open(sys.argv[1]))
except Exception: print("    (deliveries unparseable)"); sys.exit(0)
items = d if isinstance(d,list) else (d.get("deliveries") or d.get("data") or [])
if not items: print("    (deliveries: EMPTY -> Gitea never POSTed, or hook disabled)"); sys.exit(0)
for x in items[:6]:
    if not isinstance(x,dict): continue
    rb=str(x.get("response_body") or x.get("request_body") or "")[:140].replace("\n"," ").replace("\r"," ")
    print("    delivery id=%s event=%s status=%s wp_http_code=%s" % (x.get("id"),x.get("event"),x.get("status"),x.get("status_code")))
    print("       body140: %s" % rb)
' "$TMP/deliv.json" 2>/dev/null | scrub | sed 's/^/  /' || true
    DELIV_CODE="$(python3 -c '
import sys,json
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
items = d if isinstance(d,list) else (d.get("deliveries") or [])
if items and isinstance(items[0],dict): print(items[0].get("status_code",""))
' "$TMP/deliv.json" 2>/dev/null || true)"
    DELIV_STATUS="$(python3 -c '
import sys,json
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
items = d if isinstance(d,list) else (d.get("deliveries") or [])
if items and isinstance(items[0],dict): print(items[0].get("status",""))
' "$TMP/deliv.json" 2>/dev/null || true)"
  fi
else
  say "skip (no stored bot creds); re-run EPW3/EX6 first or paste T1 after creating a bot"
fi
say "CAPTURED wp_http_code(first delivery)=${DELIV_CODE:-none} status=${DELIV_STATUS:-none}"

hr "T2 WP DB truth (read-only): every table count + safe row dumps + schema catalog"
say "--- table counts & (for repo/pipeline/build/agent-like tables) CSV row dumps via NOTICE ---"
podman exec -i postgres psql -U "$PGU" -d "$PGDB" -v ON_ERROR_STOP=0 2>&1 <<'SQL' | scrub | sed 's/^/    /'
DO $$
DECLARE t RECORD; c TEXT; n BIGINT; r RECORD;
BEGIN
  FOR t IN
    SELECT table_schema s, table_name tb,
           (table_name ~* '(repo|pipe|build|workflow|task|conf|agent|cron|registr|redirect)') dump,
           (table_name ~* '(user|secret)') cat
    FROM information_schema.tables
    WHERE table_schema NOT IN ('pg_catalog','information_schema') AND table_type='BASE TABLE'
    ORDER BY 1,2
  LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM %I.%I', t.s, t.tb) INTO n;
      RAISE NOTICE 'COUNT %.% = %', t.s, t.tb, n;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'COUNT %.% = ERR:%', t.s, t.tb, SQLERRM;
    END;
    IF t.dump OR t.cat THEN
      FOR c IN SELECT column_name||' '||data_type FROM information_schema.columns
               WHERE table_schema=t.s AND table_name=t.tb ORDER BY ordinal_position
      LOOP RAISE NOTICE 'COL %.%. %', t.s, t.tb, c; END LOOP;
    END IF;
    IF t.dump THEN
      BEGIN
        SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) INTO c
        FROM information_schema.columns
        WHERE table_schema=t.s AND table_name=t.tb
          AND column_name !~* '(secret|token|password|passwd|hash|key)';
        IF c IS NULL OR c='' THEN
          RAISE NOTICE 'DUMP %.% = (no non-secret columns)', t.s, t.tb;
        ELSE
          RAISE NOTICE 'SAFE_COLS %.% = %', t.s, t.tb, c;
          FOR r IN EXECUTE format('SELECT %s FROM %I.%I LIMIT 5', c, t.s, t.tb)
          LOOP RAISE NOTICE 'ROW %.%: %', t.s, t.tb, r; END LOOP;
        END IF;
      EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'DUMP %.% = ERR:%', t.s, t.tb, SQLERRM;
      END;
    END IF;
  END LOOP;
END $$;
SQL
# best-effort scalars (tolerate wrong guessed column names -> unknown; T2 dump is authoritative)
REPO_ROWS="unknown"; PIPE_ROWS="unknown"
if [ -n "$BOT" ]; then
  REPO_ROWS="$(podman exec -i postgres psql -U "$PGU" -d "$PGDB" -tA -v bot="$BOT" -v repo="$REPO" \
    -c "SELECT count(*) FROM repos WHERE lower(repo_owner)=lower(:bot) AND lower(repo_name)=lower(:repo)" 2>/dev/null | tr -d ' \n' || true)"
  [ -z "$REPO_ROWS" ] && REPO_ROWS=unknown
  PIPE_ROWS="$(podman exec -i postgres psql -U "$PGU" -d "$PGDB" -tA \
    -c "SELECT count(*) FROM pipelines" 2>/dev/null | tr -d ' \n' || true)"
  [ -z "$PIPE_ROWS" ] && PIPE_ROWS=unknown
fi
say "CAPTURED repos_row_match(guess)=${REPO_ROWS} pipelines_count(guess)=${PIPE_ROWS}  (trust the T2 dump over these)"

hr "T3 can WP's API be read WITHOUT a token? (maps the blindness; discovers routes via swagger)"
for u in \
  "$WP/" "$WP/api" "$WP/api/version" "$WP/api/user" "$WP/api/repos" \
  "$WP/api/repos/$BOT/$REPO" "$WP/api/repos/$BOT/$REPO/builds" "$WP/api/agents" \
  "$WP/swagger/doc.json" "$WP/openapi.json" "$WP/api/swagger.json" ; do
  hf="$TMP/h"; bf="$TMP/b"
  code="$(curl -sS -m 8 -D "$hf" -o "$bf" -w '%{http_code}' "$u" 2>/dev/null || echo 000)"
  ct="$(awk 'tolower($1)=="content-type:"{sub(/^[^:]*:[[:space:]]*/,"");sub(/\r$/,"");print;exit}' "$hf" 2>/dev/null)"
  printf '  %-52s code=%-3s ctype=%s\n' "$u" "$code" "${ct:-?}"
  printf '      body140: %s\n' "$(head -c 140 "$bf" 2>/dev/null | tr -d '\n\r' | scrub)"
done
say "READ: HTML body on /api/... => SPA fallback => those endpoints need a token (we are blind, not broken)."
say "      swagger/openapi 200+json => I can read the EXACT activation/token endpoints next turn (no guess)."

hr "T4 agent<->server topology & the 127.0.0.1 gRPC trap"
MEMBERS="$(podman network inspect "$NET" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)"
say "aether net members: ${MEMBERS:-<inspect failed>}"
HAS_SRV=no; HAS_AG=no
printf '%s' "$MEMBERS" | grep -qw woodpecker-server && HAS_SRV=yes
printf '%s' "$MEMBERS" | grep -qw woodpecker-agent && HAS_AG=yes
say "server-on-net=$HAS_SRV agent-on-net=$HAS_AG  (both must be yes for name-DNS to work)"
SRV_GRPC="$(envval woodpecker-server WOODPECKER_GRPC_ADDR)"
SRV_HOST="$(envval woodpecker-server WOODPECKER_HOST)"
AG_SRV="$(envval woodpecker-agent WOODPECKER_SERVER)"
AG_GRPC="$(envval woodpecker-agent WOODPECKER_GRPC_ADDR)"
say "server WOODPECKER_GRPC_ADDR='${SRV_GRPC:-unset}'  WOODPECKER_HOST='${SRV_HOST:-unset}'"
say "agent  WOODPECKER_SERVER='${AG_SRV:-unset}'  WOODPECKER_GRPC_ADDR='${AG_GRPC:-unset}'"
say "--- server non-secret env (masked) ---"; podman inspect woodpecker-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | mask_env | grep -iE 'WOODPECKER_(SERVER|GRPC|HOST|OPEN|AUTHENTICATE|BACKEND|PLATFORM|GITEA|DATABASE_DRIVER|AGENT)' | sed 's/^/    /' || true
say "--- agent non-secret env (masked) ---";  podman inspect woodpecker-agent  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | mask_env | grep -iE 'WOODPECKER_(SERVER|GRPC|HOST|BACKEND|PLATFORM|DOCKER_HOST)' | sed 's/^/    /' || true
AGENT_REG="$(podman logs --since 30m woodpecker-server 2>&1 | grep -ciE 'agent registered|registered agent|stream opened|new agent|agent connected' || true)"
say "server-log 'agent registered/connected' hits (30m) = ${AGENT_REG:-0}"
say "--- server log: grpc/listen/agent/hook/activate/repo/404/401 (30m) ---"
podman logs --since 30m woodpecker-server 2>&1 | grep -iE 'grpc|listen|agent|register|stream|dial|refused|hook|activate|repo|pipeline|404|401|error|warn' | tail -40 | scrub | sed 's/^/    /' || say "    (no matching lines)"
say "--- agent log: connect/register/dial/refused/error (30m) ---"
podman logs --since 30m woodpecker-agent 2>&1 | grep -iE 'connect|register|dial|refused|error|warn|grpc|server|backend|docker|podman' | tail -30 | scrub | sed 's/^/    /' || say "    (no matching lines)"

hr "T5 decision (independent evidence lines; no brittle single verdict)"
say "A) hook delivery: wp_http_code=${DELIV_CODE:-none} status=${DELIV_STATUS:-none}"
case "${DELIV_CODE:-}" in
  404) say "   => Gitea DID post, WP replied 404 => repo NOT activated in WP. A Gitea-side-only webhook is insufficient; WP must register the repo (its UI 'Activate Repository', or a fetched REST call). THIS is why EX6 saw no build." ;;
  200|201|202|204) say "   => hook ACCEPTED by WP. If T2 shows no pipeline/build row, the block is downstream (agent) — see C)." ;;
  ""|none) say "   => no delivery record => Gitea never posted (hook disabled? wrong URL? push predates hook?). Re-push after confirming hook active." ;;
  *) say "   => delivery code ${DELIV_CODE} (see body above) — interpret with T2/T4." ;;
esac
say "B) WP observability: if T3 /api/* returned HTML, ALL scripted reads/writes need a Woodpecker API token (none stored). The build may exist and be invisible to us."
say "C) agent<->server gRPC:"
if printf '%s' "${SRV_GRPC:-}" | grep -qE '^(127\.0\.0\.1|localhost)(:|$)'; then say "   => SERVER binds gRPC to loopback (${SRV_GRPC}) => unreachable from the agent container. Heal: WOODPECKER_GRPC_ADDR=0.0.0.0:9000 (or :9000)." ; fi
if printf '%s' "${AG_SRV:-}" | grep -qE '^(127\.0\.0\.1|localhost)(:|$)'; then say "   => AGENT dials its OWN loopback (${AG_SRV}) => can never reach server. Heal: WOODPECKER_SERVER=woodpecker-server:9000." ; fi
[ "$HAS_SRV" = yes ] && [ "$HAS_AG" = yes ] || say "   => containers NOT both on '$NET' => name DNS fails between them. Heal: attach both to '$NET'."
[ "${AGENT_REG:-0}" -ge 1 ] && say "   => server log DOES show an agent registered => gRPC path is actually OK; ignore the loopback heuristic." \
                             || say "   => server log shows NO registered agent (30m) => consistent with the loopback/membership trap above."
say "D) DB truth (T2): repos_row_match(guess)=${REPO_ROWS} pipelines_count(guess)=${PIPE_ROWS}; the T2 COUNT/ROW dump is authoritative for 'is the repo + any pipeline present?'"
say "[RESULT] EX7 COMPLETE - read-only; paste T1-T5. Next turn = ONE two-part heal (activate repo + fix gRPC addressing), built from this evidence + (if needed) the swagger endpoints T3 discovered — never guessed (B13/§7)."

hr "T6 ledger (INFO, append-only)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=INFO | EX7 read-only Brick-12 teardown: owns EX6 design-miss (Gitea-side webhook without WP activation) + missing WP token (SPA-HTML blindness) + suspected 127.0.0.1 gRPC trap on server&agent. Captured delivery code=%s status=%s; repos_match=%s pipes=%s; srv_grpc=%s ag_srv=%s; agent_reg_hits=%s; net srv/ag=%s/%s. No mutations. |\n' \
    "$(date +%F)" "$TOKEN" "${DELIV_CODE:-none}" "${DELIV_STATUS:-none}" "$REPO_ROWS" "$PIPE_ROWS" "${SRV_GRPC:-unset}" "${AG_SRV:-unset}" "${AGENT_REG:-0}" "$HAS_SRV" "$HAS_AG" >> "$IDX"
  say "ledger row appended (INFO)"
fi
exit 0
