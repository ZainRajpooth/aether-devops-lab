#!/usr/bin/env bash
# 20261104-EJ — Official v4 architecture, corrected.
# Fixes EI: use named volume + --user 0 so login-client.pat is actually written.
# Also adds zitadel-login container and safe Traefik routing for id.aether.home.
set -uo pipefail

HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
SUDIR="$HOME_/.config/systemd/user"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
CANON="$HOME_/DevOps/aether/infra/scripts/aether-dns-wait.sh"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ej-official-v4-named-volume-user0-traefik-v1"

DOMAIN="id.aether.home"
NET="aether"
CORE_IMAGE="ghcr.io/zitadel/zitadel:latest"
LOGIN_IMAGE="ghcr.io/zitadel/zitadel-login:latest"
VOL="zitadel-bootstrap"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
redact(){ awk -v a="$MKEY" -v b="$PGPASS" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "    [REDACTED-LINE]"; else print }'; }

wait_code(){
  local url="$1" want="$2" i code=000
  for i in $(seq 1 45); do
    code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
    if [ "$code" = "$want" ]; then printf '%s' "$code"; return 0; fi
    sleep 2
  done
  printf '%s' "$code"; return 1
}

hr "J0 preflight"
[ -x "$CANON" ] && bash -n "$CANON" || { say "[HALT] CANON guard missing/bad"; exit 1; }
[ -n "$MKEY" ] || { say "[HALT] missing zitadel-masterkey"; exit 1; }
[ "${#MKEY}" -eq 32 ] || { say "[HALT] masterkey not 32 chars"; exit 1; }
mkdir -p "$SEC" "$UDIR" "$SUDIR/default.target.wants" "$ZIT_DIR"

hr "J1 pull official v4 images"
podman pull "$CORE_IMAGE" >/dev/null 2>&1 || { say "[HALT] could not pull $CORE_IMAGE"; exit 1; }
podman pull "$LOGIN_IMAGE" >/dev/null 2>&1 || { say "[HALT] could not pull $LOGIN_IMAGE"; exit 1; }
say "pulled $CORE_IMAGE"
say "pulled $LOGIN_IMAGE"

hr "J2 stop/remove old zitadel units and bootstrap volume"
systemctl --user stop zitadel.service zitadel-login.service 2>/dev/null || true
systemctl --user disable zitadel.service zitadel-login.service 2>/dev/null || true
rm -f "$UDIR/zitadel.container" "$UDIR/zitadel-login.container" 2>/dev/null || true
podman rm -f zitadel zitadel-login systemd-zitadel systemd-zitadel-login 2>/dev/null || true
podman volume rm -f "$VOL" 2>/dev/null || true
systemctl --user daemon-reload
say "old units/containers/volume removed"

hr "J3 drop/recreate zitadel DB"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
PGPASS="$(podman exec postgres printenv POSTGRES_PASSWORD 2>/dev/null || true)"
[ -n "$PGPASS" ] || { say "[HALT] POSTGRES_PASSWORD missing from postgres container"; exit 1; }
podman exec postgres psql -U "$PGUSER" -d postgres -tAc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zitadel' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS zitadel;" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "CREATE DATABASE zitadel OWNER $PGUSER;" >/dev/null 2>&1 || true
EXISTS="$(podman exec postgres psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='zitadel'" 2>/dev/null | tr -d ' \n')"
[ "$EXISTS" = 1 ] || { say "[HALT] could not recreate zitadel DB"; exit 1; }
say "zitadel DB recreated (user=$PGUSER)"

hr "J4 create named bootstrap volume"
podman volume create "$VOL" >/dev/null
say "volume created: $VOL"

hr "J5 run official-style start-from-init with --user 0 and named volume"
SETUP_LOG="$ZIT_DIR/setup-ej-$(date +%Y%m%d-%H%M%S).log"
set +e
timeout 300 podman run --rm --user 0 --network "$NET" \
  -v "$VOL":/zitadel/bootstrap:rw \
  -e ZITADEL_PORT=8080 \
  -e ZITADEL_EXTERNALDOMAIN="$DOMAIN" \
  -e ZITADEL_EXTERNALPORT=80 \
  -e ZITADEL_EXTERNALSECURE=false \
  -e ZITADEL_TLS_ENABLED=false \
  -e ZITADEL_DATABASE_POSTGRES_HOST=postgres \
  -e ZITADEL_DATABASE_POSTGRES_PORT=5432 \
  -e ZITADEL_DATABASE_POSTGRES_DATABASE=zitadel \
  -e "ZITADEL_DATABASE_POSTGRES_USER_USERNAME=$PGUSER" \
  -e "ZITADEL_DATABASE_POSTGRES_USER_PASSWORD=$PGPASS" \
  -e ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE=disable \
  -e "ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME=$PGUSER" \
  -e "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD=$PGPASS" \
  -e ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE=disable \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGEREQUIRED=false \
  -e ZITADEL_FIRSTINSTANCE_LOGINCLIENTPATPATH=/zitadel/bootstrap/login-client.pat \
  -e ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_PATPATH=/zitadel/bootstrap/login-client.pat \
  -e ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_USERNAME=login-client \
  -e ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINEUSERNAME=login-client \
  -e "ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_NAME=Automatically Initialized IAM_LOGIN_CLIENT" \
  -e ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED=true \
  -e "ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_BASEURI=http://$DOMAIN/ui/v2/login/" \
  -e "ZITADEL_OIDC_DEFAULTLOGINURLV2=http://$DOMAIN/ui/v2/login/login?authRequest=" \
  -e "ZITADEL_OIDC_DEFAULTLOGOUTURLV2=http://$DOMAIN/ui/v2/login/logout?post_logout_redirect=" \
  -e "ZITADEL_SAML_DEFAULTLOGINURLV2=http://$DOMAIN/ui/v2/login/login?samlRequest=" \
  "$CORE_IMAGE" start-from-init --masterkey "$MKEY" --tlsMode disabled >"$SETUP_LOG" 2>&1
SRC=$?
set -e
chmod 600 "$SETUP_LOG"
say "start-from-init rc=$SRC"

if [ "$SRC" -ne 0 ] && [ "$SRC" -ne 124 ]; then
  say "--- redacted init tail ---"
  redact < "$SETUP_LOG" | tail -30 | sed 's/^/    /'
  say "[HALT] init failed"
  exit 1
fi

PAT_OK=no
if podman run --rm --user 0 -v "$VOL":/zitadel/bootstrap:ro "$CORE_IMAGE" /bin/sh -c 'test -s /zitadel/bootstrap/login-client.pat' >/dev/null 2>&1; then
  PAT_OK=yes
fi
say "login-client.pat present in volume: $PAT_OK"
if [ "$PAT_OK" != yes ]; then
  say "--- redacted diagnostic grep from setup log ---"
  redact < "$SETUP_LOG" | grep -iE 'login.client|pat|permission|denied|firstinstance|unknown|invalid|error|fatal' | tail -40 | sed 's/^/    /' || true
  say "[HALT] PAT still not generated; paste the diagnostic block above"
  exit 1
fi

hr "J6 write zitadel core quadlet"
cat > "$UDIR/zitadel.container" <<QEOF
[Unit]
Description=Zitadel v4 Core (official compose architecture)
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
Environment=ZITADEL_EXTERNALPORT=80
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
Environment=ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED=true
Environment=ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_BASEURI=http://$DOMAIN/ui/v2/login/
Volume=$VOL:/zitadel/bootstrap:rw
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
say "wrote $UDIR/zitadel.container"

hr "J7 write zitadel-login companion quadlet"
COOKIE_SECRET="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
cat > "$UDIR/zitadel-login.container" <<QEOF
[Unit]
Description=Zitadel v4 Login UI companion
After=local-fs.target network-online.target zitadel.service
Wants=zitadel.service

[Container]
Image=$LOGIN_IMAGE
ContainerName=zitadel-login
Network=$NET
PublishPort=127.0.0.1:3000:3000
User=0
Environment=ZITADEL_API_URL=http://zitadel:8080
Environment=NEXT_PUBLIC_BASE_PATH=/ui/v2/login
Environment=ZITADEL_SERVICE_USER_TOKEN_FILE=/zitadel/bootstrap/login-client.pat
Environment=ZITADEL_SESSION_COOKIE_SECRET=$COOKIE_SECRET
Environment=CUSTOM_REQUEST_HEADERS=Host:$DOMAIN,X-Forwarded-Proto:http
Volume=$VOL:/zitadel/bootstrap:ro

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=90

[Install]
WantedBy=default.target
QEOF
chmod 600 "$UDIR/zitadel-login.container"
say "wrote $UDIR/zitadel-login.container"

hr "J8 configure Traefik routing for $DOMAIN"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
TRAF_BASE="$HOME_/DevOps/aether/infra/traefik"
TRAF_STATIC="$TRAF_BASE/traefik.yml"
TRAF_DIR="$TRAF_BASE/dynamic"
TRAF_MODE=""
TRAF_TARGET=""

if [ -f "$TRAF_STATIC" ] && grep -Eq '^[[:space:]]*directory:' "$TRAF_STATIC" && [ -d "$TRAF_DIR" ]; then
  TRAF_MODE="dir"
  TRAF_TARGET="$TRAF_DIR/zitadel.yml"
elif [ -f "$TRAF_DIR/dynamic.yml" ]; then
  TRAF_MODE="merge"
  TRAF_TARGET="$TRAF_DIR/dynamic.yml"
elif [ -f "$TRAF_BASE/dynamic.yml" ]; then
  TRAF_MODE="merge"
  TRAF_TARGET="$TRAF_BASE/dynamic.yml"
else
  say "[HALT] could not locate Traefik dynamic config"
  exit 1
fi
say "traefik mode=$TRAF_MODE target=$TRAF_TARGET"

if grep -q 'zitadel-login-web' "$TRAF_TARGET" 2>/dev/null; then
  say "Traefik rules already present"
else
  cp -p "$TRAF_TARGET" "$TRAF_TARGET.pre-EJ.bak" 2>/dev/null || true
  if [ "$TRAF_MODE" = "dir" ]; then
    cat > "$TRAF_TARGET" <<SNIP
http:
  routers:
    zitadel-login-web:
      rule: "Host(\`$DOMAIN\`) && PathPrefix(\`/ui/v2/login\`)"
      entryPoints: [web]
      service: zitadel-login
    zitadel-api-web:
      rule: "Host(\`$DOMAIN\`) && !PathPrefix(\`/ui/v2/login\`)"
      entryPoints: [web]
      service: zitadel-api
  services:
    zitadel-login:
      loadBalancer:
        servers:
          - url: "http://zitadel-login:3000"
    zitadel-api:
      loadBalancer:
        servers:
          - url: "h2c://zitadel:8080"
SNIP
  else
    if ! grep -q '^  routers:$' "$TRAF_TARGET" || ! grep -q '^  services:$' "$TRAF_TARGET"; then
      say "[HALT] Traefik dynamic file does not have expected http/routers/services structure"
      say "Paste head -40 $TRAF_TARGET"
      exit 1
    fi
    cat > "$TMPD/router.snip" <<SNIP
    zitadel-login-web:
      rule: "Host(\`$DOMAIN\`) && PathPrefix(\`/ui/v2/login\`)"
      entryPoints: [web]
      service: zitadel-login
    zitadel-api-web:
      rule: "Host(\`$DOMAIN\`) && !PathPrefix(\`/ui/v2/login\`)"
      entryPoints: [web]
      service: zitadel-api
SNIP
    cat > "$TMPD/service.snip" <<SNIP
    zitadel-login:
      loadBalancer:
        servers:
          - url: "http://zitadel-login:3000"
    zitadel-api:
      loadBalancer:
        servers:
          - url: "h2c://zitadel:8080"
SNIP
    awk -v rs="$TMPD/router.snip" -v ss="$TMPD/service.snip" '
      /^  routers:$/ && !r { print; while ((getline line < rs) > 0) print line; close(rs); r=1; next }
      /^  services:$/ && !s { print; while ((getline line < ss) > 0) print line; close(ss); s=1; next }
      { print }
    ' "$TRAF_TARGET" > "$TMPD/traefik.new"
    mv "$TMPD/traefik.new" "$TRAF_TARGET"
  fi
  say "Traefik config updated"
  systemctl --user restart traefik.service >/dev/null 2>&1 || true
  sleep 5
  if ! systemctl --user is-active --quiet traefik.service; then
    if [ -f "$TRAF_TARGET.pre-EJ.bak" ]; then cp -p "$TRAF_TARGET.pre-EJ.bak" "$TRAF_TARGET"; else rm -f "$TRAF_TARGET"; fi
    systemctl --user restart traefik.service >/dev/null 2>&1 || true
    say "[HALT] Traefik rejected new config; rolled back"
    journalctl --user -u traefik.service -n 30 --no-pager 2>/dev/null | redact | sed 's/^/    /' || true
    exit 1
  fi
fi

hr "J9 start units and pin boot persistence"
systemctl --user daemon-reload
systemctl --user reset-failed zitadel.service zitadel-login.service 2>/dev/null || true
systemctl --user start zitadel.service
sleep 5
systemctl --user start zitadel-login.service
sleep 15
for u in zitadel.service zitadel-login.service; do
  fp="$(systemctl --user show "$u" -p FragmentPath --value 2>/dev/null | tr -d '\r' || true)"
  case "$fp" in
    /run/user/*/systemd/generator/*)
      [ -e "$fp" ] && ln -sfn "$fp" "$SUDIR/default.target.wants/$u" && say "pinned $u -> $fp"
      ;;
  esac
done
say "zitadel unit=$(systemctl --user is-active zitadel.service 2>/dev/null | tr -d '\n') cont=$(podman inspect zitadel --format '{{.State.Status}}' 2>/dev/null || echo absent)"
say "zitadel-login unit=$(systemctl --user is-active zitadel-login.service 2>/dev/null | tr -d '\n') cont=$(podman inspect zitadel-login --format '{{.State.Status}}' 2>/dev/null || echo absent)"

hr "J10 gates"
CORE_HEALTH="$(wait_code http://127.0.0.1:8082/debug/healthz 200 || true)"
LOGIN_DIRECT="$(wait_code http://127.0.0.1:3000/ui/v2/login/healthy 200 || true)"
TRAF_LOGIN="$(wait_code http://$DOMAIN/ui/v2/login/healthy 200 || true)"
TRAF_DISC="$(wait_code http://$DOMAIN/.well-known/openid-configuration 200 || true)"
ISSUER="$(curl -sS -m 8 "http://$DOMAIN/.well-known/openid-configuration" 2>/dev/null | grep -oE '"issuer"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
DIRECT_HOST_DISC="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" http://127.0.0.1:8082/.well-known/openid-configuration 2>/dev/null || echo 000)"
say "core direct health=$CORE_HEALTH"
say "login direct healthy=$LOGIN_DIRECT"
say "traefik login healthy=$TRAF_LOGIN"
say "traefik discovery=$TRAF_DISC"
say "issuer='$ISSUER' expected='http://$DOMAIN'"
say "direct Host discovery=$DIRECT_HOST_DISC"

PASS=no
if [ "$CORE_HEALTH" = 200 ] && [ "$LOGIN_DIRECT" = 200 ] && [ "$TRAF_LOGIN" = 200 ] && [ "$TRAF_DISC" = 200 ] && [ "$ISSUER" = "http://$DOMAIN" ]; then
  PASS=yes
fi

hr "J11 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EJ: official v4 architecture corrected: named bootstrap volume + --user 0 generated login-client.pat; deployed zitadel-login companion; Traefik routed %s; core health=%s login direct=%s traefik login=%s issuer=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$PASS" "$DOMAIN" "$CORE_HEALTH" "$LOGIN_DIRECT" "$TRAF_LOGIN" "${ISSUER:-NONE}" >> "$IDX"
  say "ledger row appended"
fi

if [ "$PASS" = yes ]; then
  say "[RESULT] EJ COMPLETE - Zitadel v4 official architecture is live."
  say "  Open: http://$DOMAIN/ui/console/"
  say "  Login UI route: http://$DOMAIN/ui/v2/login/login"
  say "  Initial admin credentials are in: $SETUP_LOG"
  say "  Read that log locally. Do NOT paste it here."
else
  say "[RESULT] EJ PARTIAL - paste J9-J10 only."
  if [ "$LOGIN_DIRECT" = 200 ] && [ "$TRAF_LOGIN" != 200 ]; then
    say "  Diagnosis: companion login works directly, Traefik routing/backend is the remaining issue."
  fi
fi
exit 0
