#!/usr/bin/env bash
# 20261104-ED — READ-ONLY teardown (no writer this turn; §7 after 3 failed heals). Converts
# the HYPOTHESIS "v4 core bundles NO login UI; login is a separate companion app" into
# MEASURED fact, and prices the two architectures: (P1) is there an embedded/v1 login the
# core actually serves? (P2) is a companion login image present/obtainable on THIS box?
# Also reads the live instance login-feature flag (SELECT/catalog only) for completeness.
# Mutates NOTHING but /tmp + one append-only ledger INFO row. Reads NO secret file; prints
# NO secret (log greps are defensively redacted; psql carries no password on the cmdline).
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ed-readonly-loginui-architecture-teardown-v1"
B="http://127.0.0.1:8082"
PGU="devops"; PGDB="zitadel"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
redact(){ awk -v a="$MKEY" -v b="$PGPASS" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "    [REDACTED-LINE]"; else print }'; }
psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }   # no password on cmdline (local socket, as DZ proved)

hr "E0 static login layer: does the core SERVE a login SPA, or only bounce to console?"
for p in "/ui/login" "/ui/login/" "/ui/console/" "/ui/v2/login/login" "/ui/v2/login/login?authRequest=zz-bogus" "/ui/v2/"; do
  HH="$(curl -sS -m 8 -o /dev/null -D - "$B$p" 2>/dev/null | awk 'NR==1{c=$2} tolower($1)=="location:"{l=$2} END{printf "%s|%s", c, (l?l:"-")}' | tr -d '\r')"
  FG="$(curl -sS -m 8 -L -o /tmp/ed-b.$$ -w '%{http_code}|%{url_effective}|%{content_type}' "$B$p" 2>/dev/null || echo '000|-|-')"
  PREV="$(head -c 120 /tmp/ed-b.$$ 2>/dev/null | tr -d '\n\r' || true)"
  printf '  %-34s head=%-12s final=%s\n' "$p" "$HH" "$FG"
  [ -n "$PREV" ] && printf '      body: %s\n' "$PREV"
done
rm -f /tmp/ed-b.$$ 2>/dev/null || true
say "READ: if /ui/login/ final != a login SPA (no <title>..Login.. / no login asset chunks)"
say "      and /ui/v2/* is 404, the core serves NO embedded login -> HYPOTHESIS supported."

hr "E1 live instance login-feature flag (SELECT/catalog only; reveals the column for next turn)"
say "--- (a) feature/setting-ish tables and their columns (scoped catalog, read-only) ---"
psqlq "SELECT table_schema||'.'||table_name FROM information_schema.columns WHERE table_name ILIKE '%feature%' OR (table_schema IN ('settings','instance') AND table_name ILIKE '%setting%') GROUP BY 1 ORDER BY 1 LIMIT 20" | sed 's/^/    tbl: /' || true
while read -r t; do
  [ -z "$t" ] && continue
  sch="${t%%.*}"; tb="${t#*.}"
  say "    columns of $t:"
  psqlq "SELECT '      '||column_name||' '||data_type FROM information_schema.columns WHERE table_schema='$sch' AND table_name='$tb' ORDER BY ordinal_position LIMIT 40" || true
done < <(psqlq "SELECT table_schema||'.'||table_name FROM information_schema.columns WHERE table_name ILIKE '%feature%' GROUP BY 1 ORDER BY 1 LIMIT 8")
say "--- (b) value probe on any login/v2/feature/legacy column (bounded, SELECT-only) ---"
N=0
while IFS='|' read -r t c; do
  [ -z "$t" ] || [ -z "$c" ] && continue
  N=$((N+1)); [ "$N" -gt 12 ] && break
  sch="${t%%.*}"; tb="${t#*.}"
  vals="$(psqlq "SELECT \"$c\" FROM \"$sch\".\"$tb\" LIMIT 3" | tr '\n' ' ')"
  say "    $t.$c = ${vals:-(no rows)}"
done < <(psqlq "SELECT table_schema||'.'||table_name||'|'||column_name FROM information_schema.columns WHERE (column_name ILIKE '%login%' OR column_name ILIKE '%v2%' OR column_name ILIKE '%feature%' OR column_name ILIKE '%legac%') AND (table_schema IN ('settings','instance','projections','auth') OR table_name ILIKE '%feature%') ORDER BY 1,2 LIMIT 40")
[ "$N" -eq 0 ] && say "    (no login/v2/feature column matched the scoped filter -> flag likely JSON in a generic column; (a) above names the table for next turn)"

hr "E2 Path-2 feasibility: is a companion LOGIN image present/obtainable on THIS box?"
say "--- cached images matching login/zitadel ---"
podman images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null | grep -iE 'login|zitadel' | sed 's/^/    /' || say "    (none)"
say "--- core image tag in use (confirms v4) ---"
podman inspect zitadel --format '{{.Config.Image}}' 2>/dev/null | sed 's/^/    /' || say "    (inspect failed)"
say "READ: if NO login image is cached, Path-2 needs a network pull (exact ref to be confirmed"
say "      from the compose/KB docs next turn, NOT guessed). If pull is unacceptable here, the"
say "      honest fallback is 'Zitadel = API/console-backend only' + proceed to Brick 12."

hr "E3 core route registry, FRESH (post-EC restart): does the core serve ANY /ui/v2 or login route?"
say "registered-route count = $(podman logs zitadel 2>&1 | grep -c 'registered route' || true)"
podman logs zitadel 2>&1 | grep -i 'registered route' | grep -iE '/ui/|login|v2' | head -10 | redact | sed 's/^/    /' || say "    (none -> core mounts no login UI route)"
say "--- any startup warning mentioning login / companion / v2 ? ---"
podman logs zitadel 2>&1 | grep -iE 'login|companion|v2|not configured|unavailable' | grep -viE 'registered route' | tail -12 | redact | sed 's/^/    /' || say "    (none)"

hr "E4 synthesis (read-only; nothing changed)"
say "E0 tells us whether the core serves an embedded login SPA (P1 possible) or only bounces (P1 dead on this image)."
say "E1 tells us the LIVE login-feature flag value + the exact column name (so next turn's writer is exact, B13)."
say "E2 tells us whether the companion login image is obtainable here (P2 feasible offline) or needs a pull."
say "E3 re-confirms, post-restart, that the core mounts no /ui/v2 route (the 404 source)."
say "[RESULT] ED COMPLETE - paste E0-E4; the path (P1 vs P2 vs API-only fallback) is decided by these numbers, not by recall."

hr "E5 ledger (INFO, append-only)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=INFO | ED read-only teardown: HYPOTHESIS = v4 core bundles NO login UI (login is a separate companion app; "old times" was a v3 bundled core); curl-vs-browser divergence explained by console-JS OIDC redirect to /ui/v2 (core serves 0 /ui/v2 routes). Measuring E0 embedded-SPA?, E1 live flag+column, E2 companion-image availability, E3 fresh route registry. No mutations; fleet untouched. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended (INFO)"
fi
exit 0
