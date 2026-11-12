#!/usr/bin/env bash
# 20261104-EM — fixes EL's two measurement bugs + one real gap WITHOUT re-init:
# republish 127.0.0.1:8082:8080, set ExternalPort=8888 (real Traefik entry), re-gate
# via the hostname origin. External* are runtime config => restart only. No DB touch.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
SUDIR="$HOME_/.config/systemd/user"
CANON="$HOME_/DevOps/aether/infra/scripts/aether-dns-wait.sh"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="em-republish-externalport-origin-gates-v1"
DOMAIN="id.aether.home"; TPORT="8888"; NET="aether"
CORE_IMAGE="ghcr.io/zitadel/zitadel:latest"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
wait_code(){ local u="$1" w="$2" i c=000; for i in $(seq 1 45); do c="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null || echo 000)"; [ "$c" = "$w" ] && { printf '%s' "$c"; return 0; }; sleep 2; done; printf '%s' "$c"; return 1; }

hr "M0 preflight"
[ -x "$CANON" ] && bash -n "$CANON" || { say "[HALT] guard bad"; exit 1; }
[ "${#MKEY}" -eq 32 ] || { say "[HALT] masterkey bad"; exit 1; }
[ -n "$PGPASS" ] || { say "[HALT] pgpass missing"; exit 1; }

hr "M1 rewrite zitadel quadlet: PublishPort 8082 + ExternalPort $TPORT (runtime config only)"
cp -p "$UDIR/zitadel.container" "$UDIR/zitadel.container.pre-EM.bak" 2>/dev/null || true
cat > "$UDIR/zitadel.container" <<QEOF
[Unit]
Description=Zitadel v4 (Login V1 embedded, single container)
After=local-fs.target network-online.target postgres.service
Wants=postgres.service

[Container]
Image=$CORE_IMAGE
ContainerName=zitadel
Network=$NET
PublishPort=127.0.0.1:8082:8080
User=0
Environment=ZITADEL_PORT=8080
Environment=ZITADEL_EXTERNALDOMAIN=$DOMAIN
Environment=ZITADEL_EXTERNALPORT=$TPORT
Environment=ZITADEL_EXTERNALSECURE=false
Environment=ZITADEL_TLS_ENABLED=false
Environment=ZITADEL_DATABASE_POSTGRES_HOST=postgres
Environment=ZITADEL_DATABASE_POSTGRES_PORT=5432
Environment=ZITADEL_DATABASE_POSTGRES_DATABASE=zitadel
Environment=ZITADEL_DATABASE_POSTGRES_USER_USERNAME=$PGUSER
Environment=ZITADEL_DATABASE_POSTGRES_USER_PASSWORD=$PGPASS
Environment=ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE=disable
Environment=ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME=$PGUSER
Environment=ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD=$PGPASS
Environment=ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE=disable
Environment=ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED=false
Exec=start --masterkey $MKEY --tlsMode disabled

[Service]
ExecStartPre=$CANON postgres
Restart=always
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=default.target
QEOF
chmod 600 "$UDIR/zitadel.container"
say "quadlet rewritten (port 8082 published; ExternalPort=$TPORT)"

hr "M2 restart unit (runtime config reload; NO re-init, NO DB touch)"
systemctl --user daemon-reload
systemctl --user restart zitadel.service
sleep 12
say "unit=$(systemctl --user is-active zitadel.service 2>/dev/null | tr -d '\n') cont=$(podman inspect zitadel --format '{{.State.Status}}' 2>/dev/null || echo absent)"
say "published ports: $(podman port zitadel 2>/dev/null | tr '\n' ' ')"

hr "M3 origin-correct gates"
H_DIRECT="$(wait_code http://127.0.0.1:8082/debug/healthz 200 || true)"
D_CODE="$(curl -sS -m 8 -o /tmp/em-disc.$$ -w '%{http_code}' "http://$DOMAIN:$TPORT/.well-known/openid-configuration" 2>/dev/null || echo 000)"
ISS="$(grep -oE '"issuer"[[:space:]]*:[[:space:]]*"[^"]+"' /tmp/em-disc.$$ 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true),"; ISS="${ISS%,}"
LOGIN_FINAL="$(curl -sS -m 10 -L -o /tmp/em-login.$$ -w '%{http_code}|%{url_effective}|%{content_type}' "http://$DOMAIN:$TPORT/ui/login" 2>/dev/null || echo 000)"
CONS="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://$DOMAIN:$TPORT/ui/console/" 2>/dev/null || echo 000)"
rm -f /tmp/em-disc.$$ /tmp/em-login.$$ 2>/dev/null || true
say "direct healthz(8082)=$H_DIRECT"
say "traefik discovery($TPORT)=$D_CODE issuer='${ISS:-NONE}' expected='http://$DOMAIN:$TPORT'"
say "traefik /ui/login final=$LOGIN_FINAL"
say "traefik /ui/console/=$CONS"
PASS=no
if [ "$H_DIRECT" = 200 ] && [ "$D_CODE" = 200 ] && [ "$ISS" = "http://$DOMAIN:$TPORT" ] && [ "$CONS" = 200 ] && printf '%s' "$LOGIN_FINAL" | grep -q '^200|.*text/html'; then PASS=yes; fi

hr "M4 ledger + RESULT"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EM: republished 8082 + ExternalPort=8888 (runtime config, restart only, no re-init); origin-correct gates direct=%s disc=%s issuer=%s login=%s console=%s. |\n' "$(date +%F)" "$TOKEN" "$PASS" "$H_DIRECT" "$D_CODE" "${ISS:-NONE}" "$LOGIN_FINAL" "$CONS" >> "$IDX"
  say "ledger row appended"
fi
if [ "$PASS" = yes ]; then
  say "[RESULT] EM COMPLETE - Zitadel reachable at http://$DOMAIN:$TPORT/ui/login and /ui/console/"
  say "  Admin creds: read LOCALLY $(ls -1t "$HOME"/DevOps/aether/infra/zitadel/setup-el-*.log 2>/dev/null | head -1) (never paste)"
else
  say "[RESULT] EM PARTIAL - paste M3 lines only."
fi
exit 0
