#!/usr/bin/env bash
# 20261103-DV — READ-ONLY. Corrects DU's self-inflicted issuer-extract bug (deterministic
# body filenames, no path-sanitizer mismatch), confirms the trailing-slash entrypoints
# serve 200+HTML, HEADs the SPA's referenced assets (blank-page = cache vs broken-build),
# and probes the two v2 siblings the /ui/login 301 taught us to check. Mutates NOTHING;
# reads NO secret; prints NO secret (public UI + public discovery only).
set -uo pipefail
BASE="http://127.0.0.1:8082"
EXP_ISSUER="http://127.0.0.1:8082"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
probe(){ # $1=path $2=savename  -> globals P_CODE P_CT P_LOC P_PREV ; body -> $TMP/$2
  local p="$1" sn="$2" hdr="$TMP/h.$sn" bd="$TMP/$sn"
  P_CODE="$(curl -sS -m 8 -D "$hdr" -o "$bd" -w '%{http_code}' "$BASE$p" 2>/dev/null || echo 000)"
  P_CT="$(awk 'tolower($1)=="content-type:"{sub(/^[^:]*:[[:space:]]*/,"");sub(/\r$/,"");print;exit}' "$hdr" 2>/dev/null || true)"
  P_LOC="$(awk 'tolower($1)=="location:"{sub(/^[^:]*:[[:space:]]*/,"");sub(/\r$/,"");print;exit}' "$hdr" 2>/dev/null || true)"
  P_PREV="$(head -c 200 "$bd" 2>/dev/null | tr -d '\n\r' || true)"
  printf '  %-34s code=%-3s ct=%-26s loc=%s\n' "$p" "$P_CODE" "${P_CT:--}" "${P_LOC:--}"
  [ -n "$P_PREV" ] && printf '      body: %s\n' "$P_PREV"
}
head_asset(){ # $1=url -> prints code
  printf '      asset %-58s ' "$1"; curl -sS -m 8 -o /dev/null -w '%{http_code}\n' -I "$1" 2>/dev/null || echo 000
}
assets_of(){ # $1=htmlfile $2=default-base  -> resolved absolute asset URLs (cap 12)
  local f="$1" defbase="$2" bh n=0
  bh="$(grep -oiE '<base[[:space:]]+href="[^"]+"' "$f" 2>/dev/null | head -1 | sed -E 's/.*href="([^"]+)".*/\1/')"
  [ -z "$bh" ] && bh="$defbase"
  case "$bh" in */) : ;; /*) bh="$bh/" ;; *) bh="/$bh/" ;; esac
  while read -r r; do
    [ -z "$r" ] && continue
    n=$((n+1)); [ "$n" -gt 12 ] && break
    case "$r" in
      http*) printf '%s\n' "$r" ;;
      /*)    printf '%s%s\n' "$BASE" "$r" ;;
      ./*)   printf '%s%s%s\n' "$BASE" "$bh" "${r#./}" ;;
      *)     printf '%s%s%s\n' "$BASE" "$bh" "$r" ;;
    esac
  done < <(grep -oiE '(src|href)="[^"]+\.(js|css|mjs)"' "$f" 2>/dev/null | sed -E 's/.*="([^"]+)".*/\1/' | sort -u)
}

hr "V0 corrected issuer extract (deterministic filename; no sanitizer mismatch)"
probe /debug/healthz health.txt; H="$P_CODE"
probe /.well-known/openid-configuration disc.json; D="$P_CODE"
ISSUER="$(grep -oE '"issuer"[[:space:]]*:[[:space:]]*"[^"]+"' "$TMP/disc.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$ISSUER" ] && ISSUER=NONE
IOK=no; [ "$ISSUER" = "$EXP_ISSUER" ] && IOK=yes
say "issuer_in_discovery='$ISSUER'  expected='$EXP_ISSUER'  ISSUER_OK=$IOK  (health=$H discovery=$D)"

hr "V1 canonical entrypoints (trailing slash) + v2 siblings"
probe /ui/console/ con_slash.html; CS="$P_CODE"
probe /ui/login/ log_slash.html;  LS="$P_CODE"
probe /ui/v2/login/ v2a.html;     V2A="$P_CODE"
probe /ui/v2/ v2b.html;           V2B="$P_CODE"

hr "V2 SPA asset HEADs (blank-page discriminator: cache vs broken-build)"
say "--- console assets (base from its own <base href>) ---"
while read -r u; do [ -n "$u" ] && head_asset "$u"; done < <(assets_of "$TMP/con_slash.html" "/ui/console/")
say "--- login assets ---"
while read -r u; do [ -n "$u" ] && head_asset "$u"; done < <(assets_of "$TMP/log_slash.html" "/ui/login/")

hr "V3 verdict (read-only; changes nothing)"
say "codes: health=$H discovery=$D issuer_ok=$IOK console/=$CS login/=$LS v2login/=$V2A v2/=$V2B"
if [ "$H" != 200 ] || [ "$D" != 200 ]; then
  say "=> SERVER DOWN on public paths (contradicts your 200). Paste V0-V2."
elif [ "$IOK" != yes ]; then
  say "=> GENUINE issuer mismatch now that extract is fixed ('$ISSUER' != '$EXP_ISSUER'). STOP; I measure the instance-domain record read-only next (no writer, B13)."
elif [ "$CS" = 200 ] && { [ "$LS" = 200 ] || [ "$V2A" = 200 ] || [ "$V2B" = 200 ]; }; then
  say "=> ENTRYPOINTS CONFIRMED SERVED. Use http://127.0.0.1:8082/ui/console/ (and /ui/login/ or the 200 v2 form above)."
  say "   If your browser STILL shows blank at the correct slashed URL, check the V2 asset codes:"
  say "     all 200  -> pure client state: open INCOGNITO -> /ui/console/ ; then permanently DevTools>Application>Service Workers>Unregister + Storage>Clear site data for 127.0.0.1:8082."
  say "     any 404  -> server serves the shell but an asset is missing (build/serve issue): paste the V2 404 lines; I localize, no guess."
else
  say "=> Login/console UI not served at the measured slashed paths (console/=$CS login/=$LS v2=$V2A/$V2B). Paste V0-V2 verbatim; I localize from literal codes (no writer)."
fi
say "[RESULT] DV COMPLETE - read-only; see V3."
exit 0
