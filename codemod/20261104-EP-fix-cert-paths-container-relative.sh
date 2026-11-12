#!/usr/bin/env bash
# 20261104-EP — fix EO's cert path error: dynamic.yml referenced host path, but Traefik
# container sees /etc/traefik. Rewrite certFile/keyFile to container-relative paths,
# restart Traefik, re-gate. No re-init, no cert regen.
set -uo pipefail
HOME_="$HOME"
TB="$HOME_/DevOps/aether/infra/traefik"
DYN="$TB/dynamic/dynamic.yml"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ep-fix-cert-paths-container-relative-v1"
DOMAIN="id.aether.home"; TPORT="8888"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
code(){ curl -sS -m 6 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || echo 000; }

hr "P0 verify cert files exist at host path"
HOST_CERT="$TB/tls/leaf.pem"
HOST_KEY="$TB/tls/leaf-key.pem"
[ -f "$HOST_CERT" ] && [ -f "$HOST_KEY" ] || { say "[HALT] cert files missing at $HOST_CERT"; exit 1; }
say "cert files present: $HOST_CERT / $HOST_KEY"

hr "P1 rewrite certFile/keyFile in dynamic.yml to container paths"
cp -p "$DYN" "$DYN.pre-EP.bak"
python3 - "$DYN" <<'PYEOF'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
t = p.read_text()
# Replace any host-absolute path ending in /tls/leaf.pem or /tls/leaf-key.pem with /etc/traefik/tls/...
t = re.sub(r'/home/dev/DevOps/aether/infra/traefik/tls/leaf\.pem', '/etc/traefik/tls/leaf.pem', t)
t = re.sub(r'/home/dev/DevOps/aether/infra/traefik/tls/leaf-key\.pem', '/etc/traefik/tls/leaf-key.pem', t)
p.write_text(t)
print("  dynamic.yml cert paths rewritten to /etc/traefik/tls/...")
PYEOF
grep -nE 'certFile:|keyFile:' "$DYN" | sed 's/^/    /'

hr "P2 restart traefik + capture parse errors"
systemctl --user restart traefik.service >/dev/null 2>&1 || true
sleep 5
ERRS="$(journalctl --user -u traefik.service --since '-20s' --no-pager 2>/dev/null | grep -iE 'error while parsing|unable to parse|failed to find' | tail -5 || true)"
[ -n "$ERRS" ] && { say "--- traefik parse errors ---"; printf '%s\n' "$ERRS" | sed 's/^/    /'; } || say "no traefik parse errors (cert loaded)"

hr "P3 gates (trust proof = curl WITHOUT -k)"
G="$(code -H 'Host: gitea.aether.local' http://127.0.0.1:$TPORT/)"
TS="$(code "https://$DOMAIN:$TPORT/.well-known/openid-configuration")"
ISS="$(curl -sS -m 6 "https://$DOMAIN:$TPORT/.well-known/openid-configuration" 2>/dev/null | grep -oE '"issuer":"[^"]+"' | head -1 || true)"
L="$(curl -sS -m 10 -L -o /dev/null -w '%{http_code}|%{content_type}' "https://$DOMAIN:$TPORT/ui/login" 2>/dev/null || echo 000)"
C="$(code "https://$DOMAIN:$TPORT/ui/console/")"
say "gitea plaintext regression=$G (expect 200/302)"
say "discovery TRUSTED(no -k)=$TS  issuer=$ISS"
say "/ui/login final=$L   /ui/console/=$C"
PASS=no; { [ "$TS" = 200 ] && [ "$G" != 404 ] && [ "$G" != 000 ] && printf '%s' "$L" | grep -q '^200|.*text/html' && [ "$C" = 200 ]; } && PASS=yes

hr "P4 ledger + RESULT"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EP: fixed EO cert path error (host->container /etc/traefik/tls/...); trusted discovery=%s login=%s console=%s gitea=%s. |\n' "$(date +%F)" "$TOKEN" "$PASS" "$TS" "$L" "$C" "$G" >> "$IDX"
  say "ledger row appended"
fi
if [ "$PASS" = yes ]; then
  say "[RESULT] EP COMPLETE - HSTS-satisfying trusted TLS live. Open https://$DOMAIN:$TPORT/ui/console/ (no browser changes needed)."
  say "  Admin creds: read LOCALLY $(ls -1t "$HOME_/DevOps/aether/infra/zitadel/setup-el-*.log" 2>/dev/null | head -1)"
else
  say "[RESULT] EP PARTIAL - paste P2+P3."
fi
exit 0
