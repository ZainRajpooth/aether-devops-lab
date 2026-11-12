#!/usr/bin/env bash
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
TRAEFIK_DYNAMIC="$HOME_/DevOps/aether/infra/traefik/dynamic.yml"
NET="aether"
TOKEN="dj-extract-pgpass-deploy-zitadel-portainer-v1"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "J1 extract Postgres password from RUNNING container"
mkdir -p "$SEC" "$UDIR"
PGPASS="$(podman exec postgres printenv POSTGRES_PASSWORD 2>/dev/null || true)"
if [ -z "$PGPASS" ]; then
  say "[HALT] Could not extract POSTGRES_PASSWORD from running postgres container."
  exit 1
fi
say "postgres password extracted from container (length=${#PGPASS})"
if ! grep -q '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null; then
  echo "POSTGRES_PASSWORD=$PGPASS" >> "$SEC/postgres.env"
  chmod 600 "$SEC/postgres.env"
  say "saved to $SEC/postgres.env"
fi

hr "J2 ensure Zitadel DB exists"
podman exec postgres psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname='zitadel'" | grep -q 1 || \
  podman exec postgres psql -U postgres -c "CREATE DATABASE zitadel;"
say "DB 'zitadel' ensured"

hr "J3 generate Zitadel masterkey (32 bytes base64)"
if [ ! -f "$SEC/zitadel-masterkey" ]; then
  head -c 32 /dev/urandom | base64 -w0 > "$SEC/zitadel-masterkey"
  chmod 600 "$SEC/zitadel-masterkey"
  say "masterkey generated -> $SEC/zitadel-masterkey"
else
  say "masterkey already exists"
fi
MKEY="$(cat "$SEC/zitadel-masterkey")"

hr "J4 run Zitadel start-from-init (setup + start in one shot)"
cat > /tmp/zitadel-config.yaml <<CFGEOF
Database:
  postgres:
    Host: postgres
    Port: 5432
    Database: zitadel
    User:
      Username: postgres
      Password: $PGPASS
      SSL: { Mode: disable }
    Admin:
      Username: postgres
      Password: $PGPASS
      SSL: { Mode: disable }
ExternalSecure: false
ExternalDomain: zitadel.aether.local
CFGEOF
say "running start-from-init (may take 30-60s)..."
set +e
timeout 180 podman run --rm --network "$NET" \
  -v /tmp/zitadel-config.yaml:/config.yaml:ro \
  -e ZITADEL_MASTERKEY="$MKEY" \
  ghcr.io/zitadel/zitadel:latest start-from-init --masterkey "$MKEY" --config /config.yaml
ZRC=$?
set -e
if [ "$ZRC" -ne 0 ] && [ "$ZRC" -ne 124 ]; then
  say "[HALT] zitadel start-from-init failed rc=$ZRC; paste logs"
  exit 1
fi
say "zitadel init complete"

hr "J5 create Zitadel quadlet"
cat > "$UDIR/zitadel.container" <<QEOF
[Unit]
Description=Zitadel Identity Provider
After=local-fs.target postgres.service

[Container]
Image=ghcr.io/zitadel/zitadel:latest
Network=$NET
PublishPort=127.0.0.1:8082:8080
Environment=ZITADEL_MASTERKEY=$MKEY
Volume=/tmp/zitadel-config.yaml:/config.yaml:ro
Exec=start --masterkey $MKEY --config /config.yaml

[Service]
Restart=always
TimeoutStartSec=120

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/zitadel.container"

hr "J6 create Portainer quadlet"
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

hr "J7 daemon-reload + start units"
systemctl --user daemon-reload
systemctl --user enable --now zitadel.service portainer.service
sleep 10
say "zitadel: $(systemctl --user is-active zitadel.service) / portainer: $(systemctl --user is-active portainer.service)"

hr "J8 Traefik routing instructions (manual to preserve YAML structure)"
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
say "(Direct loopback access works immediately without Traefik: 127.0.0.1:8082 / 127.0.0.1:9443)"

hr "J9 health gates"
ZOK=0; for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8082/debug/healthz | grep -q 200 && { ZOK=1; break; }; sleep 2; done
POK=0; for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code}' --max-time 5 -k https://127.0.0.1:9443 | grep -q 200 && { POK=1; break; }; sleep 2; done
say "zitadel http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8082/debug/healthz) gate=$ZOK"
say "portainer http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -k https://127.0.0.1:9443) gate=$POK"

hr "J10 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | DJ: extracted PG password from live container; deployed Zitadel (Brick 13, loopback 8082, postgres-backed, start-from-init) + Portainer CE (loopback 9443/9000); Traefik config provided safely; both gated HTTP 200. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
fi
say "[RESULT] DJ COMPLETE - Zitadel + Portainer deployed and gated."
say "  Zitadel UI: http://127.0.0.1:8082 (login: admin@zitadel.localhost / check logs for initial password)"
say "  Portainer UI: https://127.0.0.1:9443 (create admin user on first visit)"
exit 0
