#!/usr/bin/env bash
# 20261104-EO — (1) fix EN's broken router literal; (2) restore docker-era edge TLS for
# id.aether.home from ON-DISK cert/CA material (discovery-first, HALT if absent); (3) switch
# zitadel to --tlsMode external + ExternalSecure=true:8888 + h2c backend (KB tls_modes).
# No sudo, no browser surgery, no re-init. Rollback = two .pre-EO.bak restores.
set -uo pipefail
HOME_="$HOME"
TB="$HOME_/DevOps/aether/infra/traefik"
DYN="$TB/dynamic/dynamic.yml"
TLS_DIR="$TB/tls"
UDIR="$HOME_/.config/containers/systemd"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="eo-edge-tls-from-past-material-v1"
DOMAIN="id.aether.home"; TPORT="8888"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
code(){ curl -sS -m 6 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || echo 000; }

hr "O0 discovery: past TLS material + traefik mounts + entrypoints (read-only)"
say "--- mkcert / CA / cert artifacts on disk ---"
command -v mkcert >/dev/null 2>&1 && say "  mkcert binary: $(command -v mkcert)" || say "  mkcert binary: none"
ls -la "$HOME_/.local/share/mkcert" 2>/dev/null | sed 's/^/    /' || say "    ~/.local/share/mkcert: absent"
ls /usr/local/share/ca-certificates/ 2>/dev/null | sed 's/^/    sysCA: /' || say "    /usr/local/share/ca-certificates: empty/absent"
find "$HOME_/DevOps" "$HOME_/docker" "$HOME_/.config" "$HOME_/.local/share" -maxdepth 5 \
  \( -name '*.pem' -o -name '*.crt' -o -name '*.key' -o -name 'rootCA*' \) -type f 2>/dev/null | head -25 | sed 's/^/    cert: /' || say "    no cert files found"
say "--- old configs mentioning id.aether.home + tls/cert ---"
grep -rl "$DOMAIN" "$HOME_/DevOps" "$HOME_/docker" "$HOME_/.config" 2>/dev/null | head -10 | sed 's/^/    hit: /' || say "    none"
for h in $(grep -rl "$DOMAIN" "$HOME_/DevOps" "$HOME_/docker" 2>/dev/null | head -6); do
  grep -HnE 'certFile|keyFile|rootCA|mkcert|tls|443' "$h" 2>/dev/null | head -6 | sed 's/^/      /' || true
done
say "--- traefik container mounts + entrypoints ---"
podman inspect traefik --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}
{{end}}' 2>/dev/null | sed 's/^/    mount: /' || say "    inspect failed"
grep -nE 'address:|entryPoints:' "$TB/traefik.yml" 2>/dev/null | head -8 | sed 's/^/    static: /' || true
say "--- current dynamic.yml tls presence + zitadel rule literal ---"
grep -nE '^tls:|certFile|zitadel-single|Host\(' "$DYN" 2>/dev/null | head -12 | sed 's/^/    dyn: /' || true

hr "O1 choose cert material (evidence-based; HALT if none)"
CERT=""; KEY=""
# preference 1: existing leaf cert+key for the domain
CAND_C="$(find "$HOME_/DevOps" "$HOME_/.config" -maxdepth 6 -type f \( -name "*$DOMAIN*cert*" -o -name "*$DOMAIN*.pem" -o -name "*$DOMAIN*.crt" \) 2>/dev/null | head -1)"
if [ -n "$CAND_C" ]; then
  CAND_K="$(printf '%s' "$CAND_C" | sed -E 's/(cert|crt|pem)$/key/; s/\.crt$/.key/')"
  [ -f "$CAND_K" ] && { CERT="$CAND_C"; KEY="$CAND_K"; say "  found existing leaf: $CERT + $KEY"; }
fi
# preference 2: mkcert CA present -> mint fresh trusted leaf (no sudo)
if [ -z "$CERT" ] && command -v mkcert >/dev/null 2>&1 && [ -f "$HOME_/.local/share/mkcert/rootCA.pem" ]; then
  mkdir -p "$TLS_DIR"
  ( cd "$TLS_DIR" && mkcert -cert-file "$DOMAIN.pem" -key-file "$DOMAIN-key.pem" "$DOMAIN" >/dev/null 2>&1 ) \
    && CERT="$TLS_DIR/$DOMAIN.pem" && KEY="$TLS_DIR/$DOMAIN-key.pem" && say "  minted via mkcert (CA already trusted): $CERT"
fi
# preference 3: docker-era CA key on disk -> openssl-sign fresh leaf (CA already in trust store)
if [ -z "$CERT" ]; then
  CA_KEY="$(find "$HOME_/DevOps" "$HOME_/.local/share" -maxdepth 6 -type f \( -name 'rootCA-key.pem' -o -name '*ca*.key' -o -name '*ca-key.pem' \) 2>/dev/null | head -1)"
  CA_CRT="$(find "$HOME_/DevOps" "$HOME_/.local/share" -maxdepth 6 -type f \( -name 'rootCA.pem' -o -name '*ca*.pem' -o -name '*ca*.crt' \) 2>/dev/null | head -1)"
  if [ -n "$CA_KEY" ] && [ -n "$CA_CRT" ]; then
    mkdir -p "$TLS_DIR"
    openssl req -new -newkey rsa:2048 -nodes -keyout "$TLS_DIR/$DOMAIN-key.pem" -subj "/CN=$DOMAIN" -out "$TLS_DIR/$DOMAIN.csr" >/dev/null 2>&1 \
    && openssl x509 -req -in "$TLS_DIR/$DOMAIN.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial -days 825 -sha256 -extfile <(printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' "$DOMAIN") -out "$TLS_DIR/$DOMAIN.pem" >/dev/null 2>&1 \
    && CERT="$TLS_DIR/$DOMAIN.pem" && KEY="$TLS_DIR/$DOMAIN-key.pem" && say "  signed fresh leaf with docker-era CA: $CERT"
  fi
fi
if [ -z "$CERT" ] || [ -z "$KEY" ]; then
  say "[HALT-B13] No trusted cert/CA material found on disk. Paste the O0 discovery block and tell me"
  say "  where the docker-era cert/CA lived (path or tool, e.g. mkcert/minica/step-ca). I will not guess"
  say "  and I will not propose browser-policy deletion (you correctly rejected that)."
  exit 1
fi
# trust proof WITHOUT -k (system store => Brave will trust too)
mkdir -p "$TLS_DIR"
cp -p "$CERT" "$TLS_DIR/leaf.pem" 2>/dev/null || true; cp -p "$KEY" "$TLS_DIR/leaf-key.pem" 2>/dev/null || true
CERT="$TLS_DIR/leaf.pem"; KEY="$TLS_DIR/leaf-key.pem"
chmod 644 "$CERT"; chmod 600 "$KEY"
say "  cert staged inside traefik mount dir: $CERT / $KEY"

hr "O2 fix router literal + add router tls + top-level tls block (python, anchored, idempotent)"
cp -p "$DYN" "$DYN.pre-EO.bak"
python3 - "$DYN" "$DOMAIN" "$CERT" "$KEY" <<'PYEOF'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); dom, cert, key = sys.argv[2], sys.argv[3], sys.argv[4]
t = p.read_text()
# 1) repair ANY malformed zitadel-single rule literal (broken backtick from EN)
t = re.sub(r'rule:\s*"Host\(`?%s\)?`?"?' % re.escape(dom), 'rule: "Host(`%s`)"' % dom, t)
# 2) ensure router has tls: {} (insert after its entryPoints line if missing)
if ('zitadel-single:' in t) and not re.search(r'zitadel-single:[\s\S]{0,200}?tls:', t):
    t = re.sub(r'(zitadel-single:[\s\S]*?entryPoints: \[web\]\n)', r'\1      tls: {}\n', t, count=1)
# 3) top-level tls certificates block (sibling of http:), idempotent
if 'certFile:' not in t:
    t += ("\ntls:\n  certificates:\n    - certFile: %s\n      keyFile: %s\n" % (cert, key))
p.write_text(t)
print("  dynamic.yml patched (rule literal fixed, router tls added, tls store added)")
PYEOF
grep -n 'Host(`' "$DYN" | sed 's/^/    rule: /'

hr "O3 zitadel: tlsMode external + ExternalSecure=true + h2c backend (runtime config, no re-init)"
cp -p "$UDIR/zitadel.container" "$UDIR/zitadel.container.pre-EO.bak"
python3 - "$UDIR/zitadel.container" "$DOMAIN" "$TPORT" <<'PYEOF'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); dom, tp = sys.argv[2], sys.argv[3]
t = p.read_text()
t = t.replace('Environment=ZITADEL_EXTERNALSECURE=false', 'Environment=ZITADEL_EXTERNALSECURE=true')
t = re.sub(r'Environment=ZITADEL_EXTERNALPORT=\d+', 'Environment=ZITADEL_EXTERNALPORT=%s' % tp, t)
t = t.replace('--tlsMode disabled', '--tlsMode external')
p.write_text(t)
print("  zitadel.container: ExternalSecure=true, ExternalPort=%s, tlsMode external" % tp)
PYEOF
python3 - "$DYN" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t = t.replace('url: "http://zitadel:8080"', 'url: "h2c://zitadel:8080"')
p.write_text(t); print("  backend scheme -> h2c (KB tls_modes + official compose)")
PYEOF

hr "O4 restart traefik + zitadel; capture parse errors"
systemctl --user restart traefik.service >/dev/null 2>&1 || true
sleep 4
systemctl --user restart zitadel.service >/dev/null 2>&1 || true
sleep 12
ERRS="$(journalctl --user -u traefik.service --since '-30s' --no-pager 2>/dev/null | grep -iE 'error while parsing|raw string|unable' | tail -5 || true)"
[ -n "$ERRS" ] && { say "--- traefik parse errors ---"; printf '%s\n' "$ERRS" | sed 's/^/    /'; } || say "no traefik parse errors"

hr "O5 gates (trust proof = curl WITHOUT -k)"
G="$(code -H 'Host: gitea.aether.local' http://127.0.0.1:$TPORT/)"
TS="$(code "https://$DOMAIN:$TPORT/.well-known/openid-configuration")"
TK="$(code -k "https://$DOMAIN:$TPORT/.well-known/openid-configuration")"
ISS="$(curl -sS -m 6 "https://$DOMAIN:$TPORT/.well-known/openid-configuration" 2>/dev/null | grep -oE '"issuer":"[^"]+"' | head -1 || true)"
L="$(curl -sS -m 10 -L -o /dev/null -w '%{http_code}|%{content_type}' "https://$DOMAIN:$TPORT/ui/login" 2>/dev/null || echo 000)"
C="$(code "https://$DOMAIN:$TPORT/ui/console/")"
say "gitea plaintext regression=$G (expect 200/302)"
say "discovery TRUSTED(no -k)=$TS  discovery(-k)=$TK  issuer=$ISS"
say "/ui/login final=$L   /ui/console/=$C"
PASS=no; { [ "$TS" = 200 ] && [ "$G" != 404 ] && [ "$G" != 000 ] && printf '%s' "$L" | grep -q '^200|.*text/html' && [ "$C" = 200 ]; } && PASS=yes

hr "O6 ledger + RESULT"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EO: fixed EN broken rule literal; restored docker-era edge TLS from on-disk cert/CA (no sudo, no browser surgery); zitadel tlsMode external + ExternalSecure=true:8888 + h2c backend (KB tls_modes); trusted discovery=%s login=%s console=%s gitea=%s. |\n' "$(date +%F)" "$TOKEN" "$PASS" "$TS" "$L" "$C" "$G" >> "$IDX"
  say "ledger row appended"
fi
if [ "$PASS" = yes ]; then
  say "[RESULT] EO COMPLETE - HSTS-satisfying trusted TLS live. Open https://$DOMAIN:$TPORT/ui/console/ (no browser changes needed)."
else
  say "[RESULT] EO PARTIAL - paste O4+O5; if TS=000 but TK=200 the cert is not system-trusted -> paste O0 discovery."
fi
exit 0
