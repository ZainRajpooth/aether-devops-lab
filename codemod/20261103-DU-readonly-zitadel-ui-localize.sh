#!/usr/bin/env bash
# 20261103-DU — READ-ONLY. Separates "browser replayed a stale authRequest (SW/cache)"
# from "server does not serve the /ui/v2 route (v4.20 login-UI build/config)".
# Hits each path with -D(headers) -o(body) -w(code|ctype), NO -L (so we SEE 302 Location),
# --max-time 8. Prints code/ctype/location + 240-char body preview; saves full bodies to
# /tmp for local inspection. Reads NO secret file; prints NO secret (UI/OIDC/health only).
set -uo pipefail
BASE="http://127.0.0.1:8082"
EXP_ISSUER="http://127.0.0.1:8082"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
san(){ printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
probe(){ # $1=path  -> sets globals P_CODE P_CT P_LOC P_PREV ; saves body to $TMP/body-<san>.txt
  local p="$1" hdr="$TMP/h" bd="$TMP/b"
  P_CODE="$(curl -sS -m 8 -D "$hdr" -o "$bd" -w '%{http_code}' "$BASE$p" 2>/dev/null || echo 000)"
  P_CT="$(curl -sS -m 8 -o /dev/null -D "$hdr" -w '%{content_type}' "$BASE$p" 2>/dev/null | head -1 | tr -d '\r' || true)"
  # re-derive ctype from the saved header dump (single request, no double-hit)
  P_CT="$(awk 'tolower($1)=="content-type:"{sub(/^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Tt][Yy][Pp][Ee]:[[:space:]]*/,"");sub(/\r$/,"");print;exit}' "$hdr" 2>/dev/null || true)"
  P_LOC="$(awk 'tolower($1)=="location:"{sub(/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*/,"");sub(/\r$/,"");print;exit}' "$hdr" 2>/dev/null || true)"
  P_PREV="$(head -c 240 "$bd" 2>/dev/null | tr -d '\n\r' || true)"
  cp -f "$bd" "$TMP/body-$(san "$p").txt" 2>/dev/null || true
  printf '  %-44s code=%-3s ct=%-28s loc=%s\n' "$p" "$P_CODE" "${P_CT:--}" "${P_LOC:--}"
  [ -n "$P_PREV" ] && printf '      body: %s\n' "$P_PREV"
}

hr "U0 health + public discovery (server liveness + issuer truth)"
probe /debug/healthz
H_CODE="$P_CODE"
probe /.well-known/openid-configuration
D_CODE="$P_CODE"
ISSUER="$(grep -oE '"issuer"[[:space:]]*:[[:space:]]*"[^"]+"' "$TMP/body-_well_known_openid_configuration.txt" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/' || true)"
say "issuer_in_discovery='${ISSUER:-NONE}'  expected='$EXP_ISSUER'"
ISSUER_OK=no; [ "$ISSUER" = "$EXP_ISSUER" ] && ISSUER_OK=yes
say "ISSUER_OK=$ISSUER_OK  (discovery code=$D_CODE ; health code=$H_CODE)"

hr "U1 UI routes WITHOUT a stale id (server-level route existence)"
probe /ui/
probe /ui/console
C_CODE="$P_CODE"
probe /ui/login
L_CODE="$P_CODE"
probe /ui/v2/login/login
V2_NOAUTH_CODE="$P_CODE"

hr "U2 control: same v2 route WITH a known-BOGUS id (id-lookup behavior)"
probe "/ui/v2/login/login?authRequest=zz-bogus-control-id"
V2_BOGUS_CODE="$P_CODE"; V2_BOGUS_PREV="$P_PREV"
say "bogus-id preview: ${V2_BOGUS_PREV:-(empty)}"

hr "U3 verdict (server-vs-browser; this brick changes nothing)"
say "codes: health=$H_CODE discovery=$D_CODE issuer_ok=$ISSUER_OK console=$C_CODE login=$L_CODE v2_noauth=$V2_NOAUTH_CODE v2_bogus=$V2_BOGUS_CODE"
if [ "$H_CODE" != 200 ] || [ "$D_CODE" != 200 ]; then
  say "=> SERVER NOT HEALTHY on public paths (unexpected vs your 200). Paste U0-U2; do NOT proceed."
elif [ "$ISSUER_OK" != yes ]; then
  say "=> ISSUER MISMATCH in discovery ('${ISSUER:-NONE}' != '$EXP_ISSUER'): deeper instance-domain/ExternalDomain divergence. STOP; I will measure, not guess (B13)."
elif [ "$V2_NOAUTH_CODE" = 404 ]; then
  say "=> SERVER-SIDE: the /ui/v2 route 404s even with NO id => v4.20 build/config does not serve the v2 Login UI at this path."
  say "   This is NOT a browser cache issue. Next turn = read-only login-UI-version/settings probe (needs a token; we unblock login first) — I will NOT ship a writer guessing the API (B13/§7)."
  say "   Meanwhile: try the v1 console path your browser may still have cached working, and confirm incognito ALSO 404s (it should, if this branch is true)."
elif [ "$V2_BOGUS_CODE" = 404 ] || printf '%s' "$V2_BOGUS_PREV" | grep -q '"code":5'; then
  say "=> BROWSER-LOCAL (high confidence): v2 route is ALIVE (no-auth != 404) but ANY unknown/stale authRequest id returns NOT_FOUND(code 5) — exactly your screenshot."
  say "   Your browser replayed a STALE authRequest id (service worker / cache / history). A reboot cannot clear that; incognito can."
  say "   FIX NOW: open incognito -> http://127.0.0.1:8082/ui/console . If it loads, permanently clear: DevTools>Application>Service Workers>Unregister + Storage>Clear site data for 127.0.0.1:8082."
else
  say "=> MIXED/UNEXPECTED: v2 no-auth=$V2_NOAUTH_CODE and bogus=$V2_BOGUS_CODE don't fit either clean branch. Paste U0-U3 verbatim; I localize from the literal codes, no guess."
fi
say "[RESULT] DU COMPLETE - read-only; see U3. Full bodies saved under $TMP (auto-removed); re-run with a kept dir if you want them on disk."
exit 0
