#!/usr/bin/env bash
# 20261104-EI — Replicate the EXACT official docker-compose architecture for v4.
# Translates the magic env vars, shared PAT volume, and Traefik path-routing into
# rootless Podman quadlets. Restores the "worked fine in docker" experience.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
BOOT_DIR="$ZIT_DIR/bootstrap"
TRAEFIK_DYNAMIC="$HOME_/DevOps/aether/infra/traefik/dynamic.yml"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ei-official-v4-compose-architecture-v1"
DOMAIN="id.aether.home"
NET="aether"
V4_TAG="v4.12.1"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "I0 stop and remove existing zitadel units/containers"
systemctl --user stop zitadel.service zitadel-login.service 2>/dev/null || true
systemctl --user disable zitadel.service zitadel-login.service 2>/dev/null || true
rm -f "$UDIR/zitadel.container" "$UDIR/zitadel-login.container" 2>/dev/null || true
podman rm -f zitadel zitadel-login 2>/dev/null || true
systemctl --user daemon-reload
say "stopped and removed old units"

hr "I1 drop and recreate the zitadel DB"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
PGPASS="$(podman exec postgres printenv POSTGRES_PASSWORD 2>/dev/null || true)"
podman exec postgres psql -U "$PGUSER" -d postgres -tAc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zitadel' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS zitadel;" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "CREATE DATABASE zitadel OWNER $PGUSER;" >/dev/null 2>&1 || true
say "zitadel DB dropped and recreated"

hr "I2 create bootstrap volume dir for the PAT"
mkdir -p "$BOOT_DIR"
chmod 777 "$BOOT_DIR"  # ensure non-root container uid can write the PAT
say "bootstrap dir ready: $BOOT_DIR"

hr "I3 run start-from-init with OFFICIAL COMPOSE magic env vars"
SETUP_LOG="$ZIT_DIR/setup-ei-$(date +%Y%m%d-%H%M%S).log"
set +e
timeout 240 podman run --rm --network "$NET" \
  -v "$BOOT_DIR":/zitadel/bootstrap:rw \
  -e ZITADEL_PORT=8080 \
  -e ZITADEL_EXTERNALDOMAIN="$DOMAIN" \
  -e ZITADEL_EXTERNALPORT=80 \
  -e ZITADEL_EXTERNALSECURE=false \
  -e ZITADEL_TLS_ENABLED=false \
  -e "ZITADEL_DATABASE_POSTGRES_DSN=host=postgres port=5432 dbname=zitadel user=$PGUSER password=$PGPASS sslmode=disable" \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGEREQUIRED=false \
  -e ZITADEL_FIRSTINSTANCE_LOGINCLIENTPATPATH=/zitadel/bootstrap/login-client.pat \
  -e ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_USERNAME=login-client \
  -e "ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_NAME=Automatically Initialized IAM_LOGIN_CLIENT" \
  -e ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED=true \
  -e "ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_BASEURI=http://$DOMAIN/ui/v2/login/" \
  -e "ZITADEL_OIDC_DEFAULTLOGINURLV2=http://$DOMAIN/ui/v2/login/login?authRequest=" \
  -e "ZITADEL_OIDC_DEFAULTLOGOUTURLV2=http://$DOMAIN/ui/v2/login/logout?post_logout_redirect=" \
  -e "ZITADEL_SAML_DEFAULTLOGINURLV2=http://$DOMAIN/ui/v2/login/login?samlRequest=" \
  "ghcr.io/zitadel/zitadel:$V4_TAG" start-from-init --masterkey "$(cat $SEC/zitadel-masterkey)" >"$SETUP_LOG" 2>&1
SRC=$?
set -e
chmod 600 "$SETUP_LOG"
if [ "$SRC" -ne 0 ] && [ "$SRC" -ne 124 ]; then
  say "[HALT] init failed; redacted tail:"
  tail -10 "$SETUP_LOG" | sed 's/^/    /'
  exit 1
fi
[ -f "$BOOT_DIR/login-client.pat" ] || { say "[HALT] login-client.pat not generated in bootstrap dir"; exit 1; }
say "INIT OK; PAT written to $BOOT_DIR/login-client.pat"

hr "I4 create zitadel core quadlet"
cat > "$UDIR/zitadel.container" <<QEOF
[Unit]
Description=Zitadel v4 Core (Official Compose Arch)
After=local-fs.target network-online.target postgres.service
Wants=postgres.service

[Container]
Image=ghcr.io/zitadel/zitadel:$V4_TAG
Network=$NET
Environment=ZITADEL_PORT=8080
Environment=ZITADEL_EXTERNALDOMAIN=$DOMAIN
Environment=ZITADEL_EXTERNALPORT=80
Environment=ZITADEL_EXTERNALSECURE=false
Environment=ZITADEL_TLS_ENABLED=false
Environment=ZITADEL_DATABASE_POSTGRES_DSN=host=postgres port=5432 dbname=zitadel user=$PGUSER password=$PGPASS sslmode=disable
Environment=ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED=true
Environment=ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_BASEURI=http://$DOMAIN/ui/v2/login/
Volume=$BOOT_DIR:/zitadel/bootstrap:ro
Exec=start --masterkey $(cat $SEC/zitadel-masterkey)

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/zitadel.container"

hr "I5 create zitadel-login quadlet"
COOKIE_SECRET="$(openssl rand -base64 32)"
cat > "$UDIR/zitadel-login.container" <<QEOF
[Unit]
Description=Zitadel v4 Login UI (Official Compose Arch)
After=local-fs.target network-online.target zitadel.service
Wants=zitadel.service

[Container]
Image=ghcr.io/zitadel/zitadel-login:$V4_TAG
Network=$NET
Environment=ZITADEL_API_URL=http://zitadel:8080
Environment=NEXT_PUBLIC_BASE_PATH=/ui/v2/login
Environment=ZITADEL_SERVICE_USER_TOKEN_FILE=/zitadel/bootstrap/login-client.pat
Environment=ZITADEL_SESSION_COOKIE_SECRET=$COOKIE_SECRET
Environment=CUSTOM_REQUEST_HEADERS=Host:$DOMAIN,X-Forwarded-Proto:http
Volume=$BOOT_DIR:/zitadel/bootstrap:ro

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=90

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/zitadel-login.container"

hr "I6 append Traefik path-routing rules to dynamic.yml"
if ! grep -q 'zitadel-login-web' "$TRAEFIK_DYNAMIC" 2>/dev/null; then
  cat >> "$TRAEFIK_DYNAMIC" <<TREOF

  routers:
    zitadel-login-web:
      rule: "Host(\`$DOMAIN\`) && PathPrefix(\`/ui/v2/login\`)"
      service: zitadel-login
      entryPoints: [web]
    zitadel-api-web:
      rule: "Host(\`$DOMAIN\`) && !PathPrefix(\`/ui/v2/login\`)"
      service: zitadel-api
      entryPoints: [web]
  services:
    zitadel-login:
      loadBalancer:
        servers:
          - url: "http://zitadel-login:3000"
    zitadel-api:
      loadBalancer:
        servers:
          - url: "h2c://zitadel:8080"
TREOF
  say "appended Traefik routers for $DOMAIN"
  systemctl --user restart traefik.service
else
  say "Traefik rules already present"
fi

hr "I7 daemon-reload + start services"
systemctl --user daemon-reload
systemctl --user enable --now zitadel.service zitadel-login.service
sleep 15
say "core: $(systemctl --user is-active zitadel.service) ; login: $(systemctl --user is-active zitadel-login.service)"

hr "I8 gate: does the login UI respond via Traefik?"
CODE="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "http://$DOMAIN/ui/v2/login/healthy" 2>/dev/null || echo 000)"
say "http://$DOMAIN/ui/v2/login/healthy = $CODE   (expect 200)"
if [ "$CODE" = 200 ]; then
  say "[RESULT] EI COMPLETE - Official v4 architecture deployed."
  say "  Open http://$DOMAIN/ui/console/ in your browser."
  say "  Initial admin creds are in: $SETUP_LOG (look for 'Initial admin user')"
else
  say "[RESULT] EI PARTIAL - services running but Traefik routing failed ($CODE). Paste I8 + journalctl -u traefik -n 20."
fi

hr "I9 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EI: replicated official v4 docker-compose architecture (magic init env vars + shared PAT volume + Traefik path-routing). /ui/v2/login/healthy now %s. Rollback: stop units, remove dynamic.yml routers. |\n' "$(date +%F)" "$TOKEN" "$([ "$CODE" = 200 ] && echo PASS || echo PARTIAL)" "$CODE" >> "$IDX"
  say "ledger row appended"
fi
exit 0
