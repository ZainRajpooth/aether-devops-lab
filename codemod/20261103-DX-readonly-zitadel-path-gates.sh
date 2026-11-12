#!/usr/bin/env bash
# 20261103-DX — READ-ONLY fact-gatherer for the Path1-vs-Path2 decision + the no-slash
# blank hypothesis. Mutates NOTHING (only /tmp + an append-only ledger INFO row). Reads
# NO secret file; prints NO secret (public discovery, public UI, /etc/hosts READ, traefik
# dashboard API, traefik config files). Every D-block is an independent measured fact.
set -uo pipefail
HOME_="$HOME"
BASE="http://127.0.0.1:8082"
EXP_ISSUER="http://127.0.0.1:8082"
TRAF_API="http://127.0.0.1:8888"
TRAF_HOST="traefik.aether.local"
TRAF_DIR="$HOME_/DevOps/aether/infra/traefik"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="dx-readonly-zitadel-path-gates-v1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
code(){ curl -sS -m 8 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || echo 000; }
body(){ curl -sS -m 8 -o "$1" -w '' "$2" 2>/dev/null || true; }

hr "D1 loopback issuer sanity (expect $EXP_ISSUER)"
body "$TMP/disc.json" "$BASE/.well-known/openid-configuration"
ISS="$(grep -oE '"issuer"[[:space:]]*:[[:space:]]*"[^"]+"' "$TMP/disc.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$ISS" ] && ISS=NONE
say "issuer='$ISS'  match=$([ "$ISS" = "$EXP_ISSUER" ] && echo yes || echo NO)  health=$(code "$BASE/debug/healthz")"

hr "D2 does the INSTANCE answer to other Hosts? (=> is that domain already stored?)"
for h in 127.0.0.1 localhost id.aether.home; do
  c="$(code -H "Host: $h" "$BASE/.well-known/openid-configuration")"
  say "Host: $h  ->  openid-configuration = $c   $([ "$c" = 200 ] && echo '(stored domain)' || echo '(NOT a stored domain -> Path2 must ADD it)')"
done

hr "D3 does id.aether.home RESOLVE on this host? (=> is Path2 sudo-free?)"
G="$(getent hosts id.aether.home 2>/dev/null | head -1 || true)"
say "getent id.aether.home: ${G:-<empty>}"
HIT="$(grep -nE 'id\.aether\.home' /etc/hosts 2>/dev/null | head -3 || true)"
if [ -n "$HIT" ]; then say "/etc/hosts HAS it (read-only): $HIT  => Path2 needs NO sudo";
elif [ -n "$G" ]; then say "resolves via DNS/other (not /etc/hosts)  => Path2 likely needs NO sudo";
else say "does NOT resolve  => Path2 needs ONE sudo line you run: echo '127.0.0.1 id.aether.home' | sudo tee -a /etc/hosts"; fi

hr "D4 Traefik routers for id.aether.home / zitadel? (read-only api, fallback to file)"
RC="$(code -H "Host: $TRAF_HOST" "$TRAF_API/api/http/routers")"
say "traefik api /api/http/routers = $RC"
if [ "$RC" = 200 ]; then
  body "$TMP/routers.json" -H "Host: $TRAF_HOST" "$TRAF_API/api/http/routers" 2>/dev/null || true
  # routers.json body via body() takes (file,url) but we need the header; redo with curl:
  curl -sS -m 8 -H "Host: $TRAF_HOST" "$TRAF_API/api/http/routers" -o "$TMP/routers.json" 2>/dev/null || true
  MATCH="$(grep -oiE '"name":"[^"]*(id\.aether|zitadel)[^"]*"' "$TMP/routers.json" 2>/dev/null | sort -u | head -5 || true)"
  say "matching routers: ${MATCH:-<none>}"
  [ -z "$MATCH" ] && say "=> no Traefik router for id.aether.home/zitadel -> Path2 must ADD one"
else
  say "api not reachable; scanning dynamic/static files instead (see D5)"
fi

hr "D5 Traefik TLS/cert/resolver for aether.home? (read-only file scan)"
if [ -d "$TRAF_DIR" ]; then
  say "files: $(find "$TRAF_DIR" -maxdepth 2 -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.toml' \) 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')"
  TLSH="$(grep -rniE 'aether|tls|certificat|resolver|store' "$TRAF_DIR" 2>/dev/null | grep -viE 'password|secret|token|key:' | head -12 || true)"
  if [ -n "$TLSH" ]; then printf '  %s\n' "$TLSH"; else say "  (no tls/cert/resolver/aether lines found -> Path2 must configure TLS for id.aether.home)"; fi
else say "traefik dir not found at $TRAF_DIR"; fi

hr "D6 no-slash vs slash console: <base> + asset codes (tests the blank-page cause)"
# slash page (known-good) -> grab one js chunk name
body "$TMP/con_slash.html" "$BASE/ui/console/"
CHUNK="$(grep -oiE '(chunk|main)-[A-Z0-9]+\.(js|mjs)' "$TMP/con_slash.html" 2>/dev/null | head -1 || true)"
BSLASH="$(grep -oiE '<base[[:space:]]+href="[^"]+"' "$TMP/con_slash.html" 2>/dev/null | head -1 | sed -E 's/.*href="([^"]+)".*/\1/')"
say "slash page  /ui/console/ : base='${BSLASH:-<none>}'"
[ -n "$CHUNK" ] && say "  asset /ui/console/$CHUNK = $(code "$BASE/ui/console/$CHUNK")   (expect 200)"
# no-slash page -> its OWN base + same chunk resolved against BOTH bases
body "$TMP/con_noslash.html" "$BASE/ui/console"
BNOS="$(grep -oiE '<base[[:space:]]+href="[^"]+"' "$TMP/con_noslash.html" 2>/dev/null | head -1 | sed -E 's/.*href="([^"]+)".*/\1/')"
say "no-slash    /ui/console  : http=$(code "$BASE/ui/console")  base='${BNOS:-<none>}'"
if [ -n "$CHUNK" ]; then
  say "  same chunk at /ui/console/$CHUNK = $(code "$BASE/ui/console/$CHUNK")   at /ui/$CHUNK = $(code "$BASE/ui/$CHUNK")"
  case "$BNOS" in
    /ui/console/|"") say "  => base ok/empty: if browser still blanks here, cause is CLIENT state (incognito), not URL" ;;
    *) say "  => no-slash base='$BNOS' differs from '/ui/console/': relative assets may 404 -> BLANK. Use the SLASH url." ;;
  esac
else say "  (no chunk name scraped; rely on D1-D5 + incognito test)"; fi

hr "D7 synthesis (independent facts; no fragile global verdict)"
say "D1 issuer match: $([ "$ISS" = "$EXP_ISSUER" ] && echo yes || echo NO)"
say "D2 id.aether.home stored? $( [ "$(code -H 'Host: id.aether.home' "$BASE/.well-known/openid-configuration")" = 200 ] && echo yes || echo no )"
say "D3 resolves? $( [ -n "$G" ] || [ -n "$HIT" ] && echo yes || echo no )   (sudo needed for Path2? $( [ -n "$G" ] || [ -n "$HIT" ] && echo NO || echo YES-one-line ))"
say "D6 if you ONLY ever use /ui/console/ (slash) + incognito, the blank should not reproduce; if it does in incognito, paste D1-D7."
say "[RESULT] DX COMPLETE - read-only; paste D1-D7 to choose Path1 (now) vs Path2 (I build DY from these)."

hr "D8 ledger (INFO, append-only)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=INFO | DX read-only path-gates: issuer_match=%s; id.aether.home_stored=%s; resolves=%s(sudo_needed=%s); traefik_router=%s; no-slash base=%s. No mutations. DW W3 was a tooling mis-verdict; server proven healthy (console/ 200 + 12 assets 200). |\n' \
    "$(date +%F)" "$TOKEN" "$([ "$ISS" = "$EXP_ISSUER" ] && echo yes || echo no)" \
    "$( [ "$(code -H 'Host: id.aether.home' "$BASE/.well-known/openid-configuration")" = 200 ] && echo yes || echo no )" \
    "$( [ -n "$G" ] || [ -n "$HIT" ] && echo yes || echo no )" \
    "$( [ -n "$G" ] || [ -n "$HIT" ] && echo no || echo yes )" \
    "$( [ "$RC" = 200 ] && echo 'api-checked' || echo 'file-scan' )" \
    "${BNOS:-none}" >> "$IDX"
  say "ledger row appended (INFO)"
fi
exit 0
