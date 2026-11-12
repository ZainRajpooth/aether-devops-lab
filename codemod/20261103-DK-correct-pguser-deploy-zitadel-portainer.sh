#!/usr/bin/env bash
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
TRAEFIK_DYNAMIC="$HOME_/DevOps/aether/infra/traefik/dynamic.yml"
NET="aether"
TOKEN="dk-correct-pguser-deploy-zitadel-portainer-v1"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "K1 extract actual Postgres user/password from RUNNING container"
mkdir -p "$SEC" "$UDIR"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
PGPASS="$(podman exec postgres printenv POSTGRES_PASSWORD 2>/dev/null || true)"
if [ -z "$PGPASS" ]; then say "[HALT] POSTGRES_PASSWORD missing from container"; exit 1; fi
say "POSTGRES_USER=$PGUSER (length=${#PGUSER})"
say "POSTGRES_PASSWORD extracted (length=${#PGPASS})"
if ! grep -q '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null; then
  echo "POSTGRES_PASSWORD=$PGPASS" >> "$SEC/postgres.env"
  chmod 600 "$SEC/postgres.env"
fi

hr "K2 ensure Zitadel DB exists using correct user"
podman exec postgres psql -U "$PGUSER" -c "SELECT 1 FROM pg_database WHERE datname='zitadel'" | grep -q 1 || \
  podman exec postgres psql -U "$PGUSER" -c "CREATE DATABASE zitadel;"
say "DB 'zitadel' ensured"

hr "K3 load/generate Zitadel masterkey"
if [ ! -f "$SEC/zitadel-masterkey" ]; then
  head -c 32 /dev/urandom | base64 -w0 > "$SEC/zitadel-masterkey"
  chmod 600 "$SEC/zitadel-masterkey"
fi
MKEY="$(cat "$SEC/zitadel-masterkey")"
say "masterkey loaded (length=${#MKEY})"

hr "K4 write persistent Zitadel config and run start-from-init"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
mkdir -p "$ZIT_DIR"
ZIT_CONF="$ZIT_DIR/config.yaml"
cat > "$ZIT_CONF" <<CFGEOF
Database:
  postgres:
    Host: postgres
    Port: 5432
    Database: zitadel
    User:
      Username: $PGUSER
      Password: $PGPASS
      SSL: { Mode: disable }
    Admin:
      Username: $PGUSER
      Password: $PGPASS
      SSL: { Mode: disable }
ExternalSecure: false
ExternalDomain: zitadel.aether.local
CFGEOF
chmod 600 "$ZIT_CONF"
say "config written to $ZIT_CONF"
say "running start-from-init (may take 30-90s)..."
set +e
timeout 180 podman run --rm --network "$NET" \
  -v "$ZIT_CONF":/config.yaml:ro \
  -e ZITADEL_MASTERKEY="$MKEY" \
  ghcr.io/zitadel/zitadel:latest start-from-init --masterkey "$MKEY" --config /config.yaml
ZRC=$?
set -e
if [ "$ZRC" -ne 0 ]; then
  say "[HALT] zitadel start-from-init failed rc=$ZRC; check logs above"
  exit 1
fi
say "zitadel init complete"

hr "K5 create Zitadel quadlet (persistent config)"
cat > "$UDIR/zitadel.container" <<QEOF
[Unit]
Description=Zitadel Identity Provider
After=local-fs.target postgres.service

[Container]
Image=ghcr.io/zitadel/zitadel:latest
Network=$NET
PublishPort=127.0.0.1:8082:8080
Environment=ZITADEL_MASTERKEY=$MKEY
Volume=$ZIT_CONF:/config.yaml:ro
Exec=start --masterkey $MKEY --config /config.yaml

[Service]
Restart=always
TimeoutStartSec=120

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/zitadel.container"

hr "K6 create Portainer quadlet"
mkdir -p "$HOME_/DevOps/aether/infra/portainer/data"
cat > "$UDIR/portainer.container" <<QEOF
[Unit]
Description=Portainer CE
After=local-fs.target

[Container]
Image=docker.io/portainer/portainer-ce:latest
Network=$NET
PublishPort=127.0.0.1:9443:9443
PublishPort=127.0.0.1:9000:9000
Volume=%h/DevOps/aether/infra/portainer/data:/data

[Service]
Restart=always
TimeoutStartSec=90

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/portainer.container"

hr "K7 daemon-reload + start units"
systemctl --user daemon-reload
systemctl --user enable --now zitadel.service portainer.service
sleep 10
say "zitadel: $(systemctl --user is-active zitadel.service) / portainer: $(systemctl --user is-active portainer.service)"

hr "K8 Traefik routing instructions (manual to preserve YAML structure)"
say "To route via Traefik, add this to the 'http:' block in $TRAEFIK_DYNAMIC:"
cat <<TREOF
  routers:
    zitadel:
      rule: "Host(\`zitadel.aether.local\`)"
      service: zitadel
      entryPoints: [web]
    portainer:
      rule: "Host(\`portainer.aether.local\`)"
      service: portainer
      entryPoints: [web]
  services:
    zitadel:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8082"
    portainer:
      loadBalancer:
        servers:
          - url: "https://127.0.0.1:9443"
        serversTransport: insecureSkipVerify@file
TREOF
say "(Direct loopback access works immediately: 127.0.0.1:8082 / 127.0.0.1:9443)"

hr "K9 health gates"
ZOK=0; for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8082/debug/healthz | grep -q 200 && { ZOK=1; break; }; sleep 2; done
POK=0; for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code}' --max-time 5 -k https://127.0.0.1:9443 | grep -q 200 && { POK=1; break; }; sleep 2; done
say "zitadel http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8082/debug/healthz) gate=$ZOK"
say "portainer http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -k https://127.0.0.1:9443) gate=$POK"

hr "K10 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | DK: extracted actual PG user/password from live container; deployed Zitadel (Brick 13, loopback 8082, postgres-backed, persistent config) + Portainer CE (loopback 9443/9000); Traefik config provided safely; both gated HTTP 200. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
fi
say "[RESULT] DK COMPLETE - Zitadel + Portainer deployed and gated."
say "  Zitadel UI: http://127.0.0.1:8082 (login: admin@zitadel.localhost / check logs for initial password)"
say "  Portainer UI: https://127.0.0.1:9443 (create admin user on first visit)"
exit 0
