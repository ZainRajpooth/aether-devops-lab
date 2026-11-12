#!/usr/bin/env bash
# 20261104-EL — Single container with embedded Login V1 (matches user's docker experience).
# Forces V1 by setting LOGINV2_REQUIRED=false. No companion, no PAT, no shared volume.
set -uo pipefail

HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
SUDIR="$HOME_/.config/systemd/user"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
CANON="$HOME_/DevOps/aether/infra/scripts/aether-dns-wait.sh"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="el-single-container-v1-login-v1"

DOMAIN="id.aether.home"
NET="aether"
CORE_IMAGE="ghcr.io/zitadel/zitadel:latest"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
redact(){ awk -v a="$MKEY" -v b="$PGPASS" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "    [REDACTED-LINE]"; else print }'; }

wait_code(){
  local url="$1" want="$2" i code=000
  for i in $(seq 1 60); do
    code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
    if [ "$code" = "$want" ]; then printf '%s' "$code"; return 0; fi
    sleep 2
  done
  printf '%s' "$code"; return 1
}

hr "L0 preflight"
[ -x "$CANON" ] && bash -n "$CANON" || { say "[HALT] CANON guard missing/bad"; exit 1; }
[ -n "$MKEY" ] || { say "[HALT] missing zitadel-masterkey"; exit 1; }
[ "${#MKEY}" -eq 32 ] || { say "[HALT] masterkey not 32 chars"; exit 1; }
mkdir -p "$SEC" "$UDIR" "$SUDIR/default.target.wants" "$ZIT_DIR"

hr "L1 stop and remove ALL zitadel units/containers/volumes"
systemctl --user stop zitadel.service zitadel-login.service 2>/dev/null || true
systemctl --user disable zitadel.service zitadel-login.service 2>/dev/null || true
rm -f "$UDIR/zitadel.container" "$UDIR/zitadel-login.container" 2>/dev/null || true
podman rm -f zitadel zitadel-login systemd-zitadel systemd-zitadel-login 2>/dev/null || true
podman volume rm -f zitadel-bootstrap 2>/dev/null || true
systemctl --user daemon-reload
say "all zitadel state cleaned"

hr "L2 drop and recreate zitadel DB"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
podman exec postgres psql -U "$PGUSER" -d postgres -tAc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zitadel' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS zitadel;" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "CREATE DATABASE zitadel OWNER $PGUSER;" >/dev/null 2>&1 || true
EXISTS="$(podman exec postgres psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='zitadel'" 2>/dev/null | tr -d ' \n')"
[ "$EXISTS" = 1 ] || { say "[HALT] could not recreate zitadel DB"; exit 1; }
say "zitadel DB recreated (user=$PGUSER)"

hr "L3 run start-from-init with LOGINV2_REQUIRED=false (forces embedded V1)"
SETUP_LOG="$ZIT_DIR/setup-el-$(date +%Y%m%d-%H%M%S).log"
set +e
timeout 300 podman run --rm --user 0 --network "$NET" \
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
  -e ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED=false \
  "$CORE_IMAGE" start-from-init --masterkey "$MKEY" --tlsMode disabled >"$SETUP_LOG" 2>&1
SRC=$?
set -e
chmod 600 "$SETUP_LOG"
say "start-from-init rc=$SRC"

EVTN="$(podman exec postgres psql -U "$PGUSER" -d zitadel -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='eventstore'" 2>/dev/null | tr -d ' \n')"
[ -z "$EVTN" ] && EVTN=0
if [ "$SRC" -ne 0 ] && [ "$SRC" -ne 124 ]; then
  say "--- redacted init tail ---"
  redact < "$SETUP_LOG" | tail -20 | sed 's/^/    /'
  say "[HALT] init failed"
  exit 1
fi
[ "$EVTN" -ge 1 ] || { say "[HALT] eventstore tables missing"; exit 1; }
say "INIT OK (eventstore tables=$EVTN); admin creds in $SETUP_LOG"

hr "L4 write zitadel quadlet (single container, no companion)"
cat > "$UDIR/zitadel.container" <<QEOF
[Unit]
Description=Zitadel v4 (Login V1 embedded)
After=local-fs.target network-online.target postgres.service
Wants=postgres.service

[Container]
Image=$CORE_IMAGE
ContainerName=zitadel
Network=$NET
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
say "wrote $UDIR/zitadel.container"

hr "L5 configure Traefik: single Host rule for $DOMAIN (no path splitting)"
TRAF_BASE="$HOME_/DevOps/aether/infra/traefik"
TRAF_DIR="$TRAF_BASE/dynamic"
TRAF_TARGET=""
if [ -f "$TRAF_DIR/dynamic.yml" ]; then
  TRAF_TARGET="$TRAF_DIR/dynamic.yml"
elif [ -f "$TRAF_BASE/dynamic.yml" ]; then
  TRAF_TARGET="$TRAF_BASE/dynamic.yml"
fi
[ -n "$TRAF_TARGET" ] || { say "[HALT] could not locate Traefik dynamic config"; exit 1; }

if ! grep -q "Host(\`$DOMAIN\`)" "$TRAF_TARGET" 2>/dev/null; then
  cp -p "$TRAF_TARGET" "$TRAF_TARGET.pre-EL.bak" 2>/dev/null || true
  cat >> "$TRAF_TARGET" <<TREOF

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
TREOF
  say "Traefik config updated"
  systemctl --user restart traefik.service >/dev/null 2>&1 || true
  sleep 5
fi

hr "L6 start unit and pin boot persistence"
systemctl --user daemon-reload
systemctl --user reset-failed zitadel.service 2>/dev/null || true
systemctl --user start zitadel.service
sleep 15
fp="$(systemctl --user show zitadel.service -p FragmentPath --value 2>/dev/null | tr -d '\r' || true)"
case "$fp" in
  /run/user/*/systemd/generator/*)
    [ -e "$fp" ] && ln -sfn "$fp" "$SUDIR/default.target.wants/zitadel.service" && say "pinned zitadel.service -> $fp"
    ;;
esac
say "zitadel unit=$(systemctl --user is-active zitadel.service 2>/dev/null | tr -d '\n') cont=$(podman inspect zitadel --format '{{.State.Status}}' 2>/dev/null || echo absent)"

hr "L7 gates"
DIRECT_LOGIN="$(wait_code http://127.0.0.1:8080/ui/login 200 || true)"
TRAF_LOGIN="$(wait_code http://$DOMAIN/ui/login 200 || true)"
TRAF_DISC="$(wait_code http://$DOMAIN/.well-known/openid-configuration 200 || true)"
ISSUER="$(curl -sS -m 8 "http://$DOMAIN/.well-known/openid-configuration" 2>/dev/null | grep -oE '"issuer"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
say "direct /ui/login=$DIRECT_LOGIN (inside aether net)"
say "traefik $DOMAIN/ui/login=$TRAF_LOGIN"
say "traefik discovery=$TRAF_DISC"
say "issuer='$ISSUER' expected='http://$DOMAIN'"

PASS=no
if [ "$DIRECT_LOGIN" = 200 ] && [ "$TRAF_LOGIN" = 200 ] && [ "$TRAF_DISC" = 200 ] && [ "$ISSUER" = "http://$DOMAIN" ]; then
  PASS=yes
fi

hr "L8 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EL: single container with embedded Login V1 (LOGINV2_REQUIRED=false). Matches user docker experience. No companion, no PAT. direct=%s traefik=%s issuer=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$PASS" "$DIRECT_LOGIN" "$TRAF_LOGIN" "${ISSUER:-NONE}" >> "$IDX"
  say "ledger row appended"
fi

if [ "$PASS" = yes ]; then
  say "[RESULT] EL COMPLETE - Zitadel v4 with embedded Login V1 is live."
  say "  Open: http://$DOMAIN/ui/login"
  say "  Or:   http://$DOMAIN/ui/console/"
  say "  Initial admin credentials are in: $SETUP_LOG"
  say "  Read that log locally. Do NOT paste it here."
else
  say "[RESULT] EL PARTIAL - paste L7 gates."
fi
exit 0
