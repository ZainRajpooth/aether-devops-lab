#!/usr/bin/env bash
# 20261103-DW — READ-ONLY, corrected. Fixes DV's `local`-same-statement crash (one local
# per line) and DU's filename-mismatch extract bug (deterministic body names; no sanitizer,
# no redundant cp). Confirms trailing-slash entrypoints serve 200+HTML, extracts the issuer
# correctly, and HEADs the SPA's referenced assets to discriminate cache-vs-build for a
# blank render. Mutates NOTHING; reads NO secret; prints NO secret (public UI + discovery).
set -uo pipefail
BASE="http://127.0.0.1:8082"
EXP_ISSUER="http://127.0.0.1:8082"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

probe(){                       # $1=path  $2=savename -> sets P_CODE P_CT P_LOC P_PREV
  local p="$1"
  local sn="$2"
  local hdr="$TMP/h.$sn"
  local bd="$TMP/$sn"
  P_CODE="$(curl -sS -m 8 -D "$hdr" -o "$bd" -w '%{http_code}' "$BASE$p" 2>/dev/null || echo 000)"
  P_CT="$(awk 'tolower($1)=="content-type:"{sub(/^[^:]*:[[:space:]]*/,"");sub(/\r$/,"");print;exit}' "$hdr" 2>/dev/null || true)"
  P_LOC="$(awk 'tolower($1)=="location:"{sub(/^[^:]*:[[:space:]]*/,"");sub(/\r$/,"");print;exit}' "$hdr" 2>/dev/null || true)"
  P_PREV="$(head -c 200 "$bd" 2>/dev/null | tr -d '\n\r' || true)"
  printf '  %-34s code=%-3s ct=%-26s loc=%s\n' "$p" "$P_CODE" "${P_CT:--}" "${P_LOC:--}"
  [ -n "$P_PREV" ] && printf '      body: %s\n' "$P_PREV"
}

head_asset(){                  # $1=absolute url -> prints code
  local u="$1"
  printf '      asset %-58s ' "$u"
  curl -sS -m 8 -o /dev/null -w '%{http_code}\n' -I "$u" 2>/dev/null || echo 000
}

assets_of(){                   # $1=htmlfile $2=default-base -> resolved absolute asset urls (cap 12)
  local f="$1"
  local defbase="$2"
  local bh
  local n=0
  bh="$(grep -oiE '<base[[:space:]]+href="[^"]+"' "$f" 2>/dev/null | head -1 | sed -E 's/.*href="([^"]+)".*/\1/')"
  [ -z "$bh" ] && bh="$defbase"
  case "$bh" in */) : ;; /*) bh="$bh/" ;; *) bh="/$bh/" ;; esac
  local r
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

hr "W0 corrected issuer extract (deterministic filename; no sanitizer mismatch)"
probe /debug/healthz health.txt; H="$P_CODE"
probe /.well-known/openid-configuration disc.json; D="$P_CODE"
ISSUER="$(grep -oE '"issuer"[[:space:]]*:[[:space:]]*"[^"]+"' "$TMP/disc.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$ISSUER" ] && ISSUER=NONE
IOK=no; [ "$ISSUER" = "$EXP_ISSUER" ] && IOK=yes
say "issuer_in_discovery='$ISSUER'  expected='$EXP_ISSUER'  ISSUER_OK=$IOK  (health=$H discovery=$D)"

hr "W1 canonical entrypoints (trailing slash) + v2 siblings"
probe /ui/console/ con_slash.html; CS="$P_CODE"
probe /ui/login/ log_slash.html;  LS="$P_CODE"
probe /ui/v2/login/ v2a.html;     V2A="$P_CODE"
probe /ui/v2/ v2b.html;           V2B="$P_CODE"

hr "W2 SPA asset HEADs (blank-page discriminator: cache vs broken-build)"
say "--- console assets (base from its own <base href>) ---"
while read -r u; do [ -n "$u" ] && head_asset "$u"; done < <(assets_of "$TMP/con_slash.html" "/ui/console/")
say "--- login assets ---"
while read -r u; do [ -n "$u" ] && head_asset "$u"; done < <(assets_of "$TMP/log_slash.html" "/ui/login/")

hr "W3 verdict (read-only; changes nothing)"
say "codes: health=$H discovery=$D issuer_ok=$IOK console/=$CS login/=$LS v2login/=$V2A v2/=$V2B"
if [ "$H" != 200 ] || [ "$D" != 200 ]; then
  say "=> SERVER DOWN on public paths (contradicts your 200). Paste W0-W2."
elif [ "$IOK" != yes ]; then
  say "=> GENUINE issuer mismatch now that extract is fixed ('$ISSUER' != '$EXP_ISSUER'). STOP; I measure the instance-domain record read-only next (no writer, B13)."
elif [ "$CS" = 200 ] && { [ "$LS" = 200 ] || [ "$V2A" = 200 ] || [ "$V2B" = 200 ]; }; then
  say "=> ENTRYPOINTS CONFIRMED SERVED. Use http://127.0.0.1:8082/ui/console/ (and /ui/login/ or the 200 v2 form above)."
  say "   If your browser STILL shows blank at the correct slashed URL, read the W2 asset codes:"
  say "     all 200  -> pure client state: open INCOGNITO -> /ui/console/ ; then permanently DevTools>Application>Service Workers>Unregister + Storage>Clear site data for 127.0.0.1:8082."
  say "     any 404  -> server serves the shell but an asset is missing (build/serve issue): paste the W2 404 lines; I localize, no guess."
else
  say "=> Login/console UI not served at the measured slashed paths (console/=$CS login/=$LS v2=$V2A/$V2B). Paste W0-W2 verbatim; I localize from literal codes (no writer)."
fi
say "[RESULT] DW COMPLETE - read-only; see W3."
exit 0
