#!/usr/bin/env bash
# 20261104-DZ — READ-ONLY. Discriminates A (login routes never registered) vs
# B (routes exist, auth-request lookup/storage broken) vs C (server ok, browser
# delta) for the /ui/v2/login 404 that the clean-room test isolated. GETs + log
# greps + SELECT-only SQL only; writes nothing but /tmp captures + ledger INFO row.
set -uo pipefail
SEC="$HOME/DevOps/aether/secrets"
IDX="$HOME/DevOps/aether/codemod/INDEX.md"
TOKEN="dz-readonly-loginui-route-diagnose-v1"
B="http://127.0.0.1:8082"
JAR="/tmp/dz-jar.$$"
LBODY="/tmp/dz-login-body.$$"
MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
redact(){ awk -v a="$MKEY" -v b="$PGPASS" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "    [REDACTED-LINE]"; else print }'; }
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
logs(){ podman logs zitadel 2>&1 || journalctl --user -u zitadel.service --no-pager 2>/dev/null || true; }

hr "Z0 container liveness / restart churn (rules crash-churn in/out)"
podman inspect zitadel --format 'name={{.Name}} status={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}}' 2>/dev/null | sed 's/^/  /' || say "  inspect failed"
say "unit NRestarts=$(systemctl --user show zitadel.service -p NRestarts --value 2>/dev/null | tr -d '\n')"

hr "Z1 startup route registrations: is ANY login/ui route registered? (discriminates A)"
say "--- 'registered route' lines mentioning login or /ui/ ---"
logs | grep -i 'registered route' | grep -iE 'login|/ui/' | head -20 | redact | sed 's/^/  /' || say "  (none)"
say "--- counts: total / login-ish / ui-ish / any 'login ui|loginv2|legacy login' mentions ---"
say "  total=$(logs | grep -c 'registered route' || true)  login=$(logs | grep -i 'registered route' | grep -ci login || true)  ui=$(logs | grep -i 'registered route' | grep -ci '/ui/' || true)  loginui_mentions=$(logs | grep -ciE 'login.?ui|loginv2|legacy login' || true)"

hr "Z2 scripted server-side flow: authorize -> fresh authRequest -> immediate GET (curl+jar)"
AZ="$B/oauth/v2/authorize?client_id=console&redirect_uri=http%3A%2F%2F127.0.0.1%3A8082%2Fui%2Fconsole%2Fauth%2Fcallback&response_type=code&scope=openid%20profile%20email&prompt=login"
LOC="$(curl -sS -m 8 -c "$JAR" -o /dev/null -D - "$AZ" 2>/dev/null | awk 'tolower($1)=="location:"{sub(/^[^:]*:[[:space:]]*/,"");sub(/\r$/,"");print;exit}')"
say "authorize -> Location: ${LOC:-(none)}"
ID=""
case "$LOC" in *authRequest=*) ID="${LOC##*authRequest=}"; ID="${ID%%&*}";; esac
say "fresh authRequest id: ${ID:-(none)}"
if [ -n "$ID" ]; then
  CODE="$(curl -sS -m 8 -b "$JAR" -c "$JAR" -o "$LBODY" -w '%{http_code}' "$B/ui/v2/login/login?authRequest=$ID" 2>/dev/null || echo 000)"
  say "GET /ui/v2/login/login?authRequest=<FRESH> via curl = $CODE   (200 => C-branch; 404 => A or B)"
  head -c 200 "$LBODY" 2>/dev/null | tr -d '\n\r' | sed 's/^/    body: /' || true
else
  say "authorize gave no login redirect (dummy client possibly rejected); its body:"
  curl -sS -m 8 -c "$JAR" "$AZ" 2>/dev/null | head -c 300 | redact | sed 's/^/    /' || true
fi
rm -f "$JAR" "$LBODY" 2>/dev/null || true

hr "Z3 server log, last 3 min (what zitadel said about login/auth-request traffic)"
podman logs --since 3m zitadel 2>&1 | grep -iE 'login|auth.?request|not found|level=(error|warn)' | tail -25 | redact | sed 's/^/  /' || say "  (no matching lines; container stdout may live in journal -> next turn fallback)"

hr "Z4 read-only auth-request storage census (SELECT only)"
TBL="$(podman exec postgres psql -U devops -d zitadel -tAc "SELECT table_schema||'.'||table_name FROM information_schema.tables WHERE table_name ILIKE '%auth_request%' ORDER BY 1" 2>/dev/null || true)"
say "auth_request-ish tables: ${TBL:-(none => likely in-memory/cache store)}"
for t in $TBL; do
  n="$(podman exec postgres psql -U devops -d zitadel -tAc "SELECT count(*) FROM $t" 2>/dev/null || echo err)"
  say "  count($t) = $n"
done

hr "Z5 branch map (read-only; nothing changed)"
say "A) Z1 login/ui registrations = 0          -> login UI never registered (config/build). Next brick: read the exact enable-key from the binary's own help/defaults, then gate-enable."
say "B) Z1 registrations > 0 AND Z2 = 404       -> auth-request lookup/storage broken; Z3/Z4 say where. Next brick repairs that path only."
say "C) Z2 = 200 while browser fails            -> header/cookie delta; next turn replays curl with browser headers."
say "[RESULT] DZ COMPLETE - paste Z0-Z5 verbatim; the branch line chosen is the only thing I need."

hr "Z6 ledger (INFO, append-only)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=INFO | DZ read-only: clean-room test falsified client-cache hypothesis (fresh authRequest redirect from console 404s server-side); discriminating A(login routes unregistered) vs B(auth-request lookup/storage) vs C(browser delta) via Z1 route registrations, Z2 scripted curl authorize->fresh-id->GET, Z3 logs, Z4 SELECT-only census, Z0 churn. No mutations. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended (INFO)"
fi
exit 0
