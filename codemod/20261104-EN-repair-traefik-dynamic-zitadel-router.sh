#!/usr/bin/env bash
# 20261104-EN — repair EL's duplicate-key Traefik dynamic config and re-add the
# id.aether.home router in the structurally correct place (provider-mode aware).
# Regression-gated: gitea route must stay 200 or we roll back automatically.
set -uo pipefail
HOME_="$HOME"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="en-repair-traefik-dynamic-zitadel-router-v1"
TB="$HOME_/DevOps/aether/infra/traefik"
STATIC="$TB/traefik.yml"
DDIR="$TB/dynamic"
DYN="$DDIR/dynamic.yml"
DOMAIN="id.aether.home"; TPORT="8888"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
code(){ curl -sS -m 6 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || echo 000; }

hr "N0 locate dynamic config + provider mode"
[ -f "$DYN" ] || { say "[HALT] $DYN missing"; exit 1; }
MODE="filename"
grep -qE '^[[:space:]]*directory:' "$STATIC" 2>/dev/null && [ -d "$DDIR" ] && MODE="directory"
say "static=$STATIC mode=$MODE dynamic=$DYN"
BAK="$DYN.pre-EL.bak"
[ -f "$BAK" ] || { say "[HALT] $BAK missing; paste tail -30 $DYN instead of guessing"; exit 1; }
say "duplicate-key check: routers-blocks=$(grep -cE '^  routers:' "$DYN") services-blocks=$(grep -cE '^  services:' "$DYN") (2/2 = EL corruption confirmed)"

hr "N1 restore clean dynamic config from EL backup"
cp -p "$DYN" "$DYN.pre-EN.bak" 2>/dev/null || true
cp -p "$BAK" "$DYN"
say "restored; now routers-blocks=$(grep -cE '^  routers:' "$DYN") services-blocks=$(grep -cE '^  services:' "$DYN") (expect 1/1)"

hr "N2 re-add zitadel routing (mode-aware, idempotent)"
if grep -q 'zitadel-single' "$DYN" 2>/dev/null || { [ "$MODE" = directory ] && grep -q 'zitadel-single' "$DDIR/zitadel.yml" 2>/dev/null; }; then
  say "zitadel router already present; skipping add"
elif [ "$MODE" = directory ]; then
  cat > "$DDIR/zitadel.yml" <<YEOF
http:
  routers:
    zitadel-single:
      rule: "Host(\`$DOMAIN\`)"
      entryPoints: [web]
      service: zitadel-single
  services:
    zitadel-single:
      loadBalancer:
        servers:
          - url: "http://zitadel:8080"
YEOF
  say "wrote $DDIR/zitadel.yml (separate file = no duplicate keys)"
else
  awk -v d="$DOMAIN" '
    /^  routers:$/ && !r { print; print "    zitadel-single:"; print "      rule: \"Host(`" d ")\"\""; r=1; next }
    { print }
  ' "$DYN" > /dev/null 2>&1 || true   # placeholder guard (never used)
  python3 - "$DYN" "$DOMAIN" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); d = sys.argv[2]; t = p.read_text()
router = (f'    zitadel-single:\n'
          f'      rule: "Host(`{d})"\n'
          f'      entryPoints: [web]\n'
          f'      service: zitadel-single\n')
service = ('    zitadel-single:\n'
           '      loadBalancer:\n'
           '        servers:\n'
           '          - url: "http://zitadel:8080"\n')
lines = t.splitlines(keepends=True); out = []; ir = is_ = False
for ln in lines:
    out.append(ln)
    if ln.rstrip() == '  routers:' and not ir:
        out.append(router); ir = True
    if ln.rstrip() == '  services:' and not is_:
        out.append(service); is_ = True
p.write_text(''.join(out))
print('  merged router+service into existing maps (python, indent-safe)')
PYEOF
fi

hr "N3 reload traefik + capture config errors"
systemctl --user restart traefik.service >/dev/null 2>&1 || true
sleep 6
ERRS="$(journalctl --user -u traefik.service --since '-40s' --no-pager 2>/dev/null | grep -iE 'error|yaml|parse|unable' | tail -8 || true)"
[ -n "$ERRS" ] && { say "--- traefik config errors ---"; printf '%s\n' "$ERRS" | sed 's/^/    /'; } || say "no traefik config errors in last 40s"

hr "N4 gates (regression FIRST: gitea must stay green)"
G="$(code -H 'Host: gitea.aether.local' http://127.0.0.1:$TPORT/)"
say "gitea via traefik = $G (expect 200/302; if 404 => config still bad -> auto-rollback)"
if [ "$G" = 404 ] || [ "$G" = 000 ]; then
  cp -p "$DYN.pre-EN.bak" "$DYN" 2>/dev/null || true
  [ "$MODE" = directory ] && rm -f "$DDIR/zitadel.yml" 2>/dev/null || true
  systemctl --user restart traefik.service >/dev/null 2>&1 || true
  say "[HALT] regression failed; rolled back dynamic config; paste N3 errors"
  exit 1
fi
D="$(code "http://$DOMAIN:$TPORT/.well-known/openid-configuration")"
L="$(curl -sS -m 10 -L -o /tmp/en-login.$$ -w '%{http_code}|%{content_type}' "http://$DOMAIN:$TPORT/ui/login" 2>/dev/null || echo 000)"
C="$(code "http://$DOMAIN:$TPORT/ui/console/")"
H="$(code http://127.0.0.1:8082/debug/healthz)"
ISS="$(curl -sS -m 6 "http://$DOMAIN:$TPORT/.well-known/openid-configuration" 2>/dev/null | grep -oE '"issuer":"[^"]+"' | head -1 || true)"
rm -f /tmp/en-login.$$ 2>/dev/null || true
say "discovery=$D issuer=$ISS"
say "/ui/login final=$L (expect 200|text/html)"
say "/ui/console/=$C  direct-healthz=$H"

hr "N5 browser-side HSTS clear (manual, 60s, no sudo) + ledger"
say "Brave: open  brave://net-internals/#hsts  ->  'Delete domain security policies'  ->  type  id.aether.home  ->  Delete."
say "Then (same tab)  brave://settings/security  ->  turn OFF 'Upgrade connections to HTTPS' (or add exception)."
say "Finally open EXACTLY:  http://id.aether.home:$TPORT/ui/console/   (http, not https; port $TPORT)"
say "Stale bookmarks to delete: localhost:8082/... and any /ui/v2/login/login?authRequest=... link."
touch "$IDX"
PASS=no; { [ "$D" = 200 ] && printf '%s' "$L" | grep -q '^200|.*text/html' && [ "$C" = 200 ] && [ "$H" = 200 ]; } && PASS=yes
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EN: restored dynamic.yml from .pre-EL.bak (duplicate routers/services keys removed), re-added zitadel router mode=%s with gitea regression gate; discovery=%s login=%s console=%s; HSTS clear instructions given (browser-local). |\n' "$(date +%F)" "$TOKEN" "$PASS" "$MODE" "$D" "$L" "$C" >> "$IDX"
  say "ledger row appended"
fi
[ "$PASS" = yes ] && say "[RESULT] EN COMPLETE - server side green; do the 60s Brave HSTS clear, then login at http://$DOMAIN:$TPORT/ui/console/" \
                  || say "[RESULT] EN PARTIAL - paste N3+N4."
exit 0
