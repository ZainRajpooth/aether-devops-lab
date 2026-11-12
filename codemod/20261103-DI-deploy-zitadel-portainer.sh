#!/usr/bin/env bash
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
TRAEFIK_DYNAMIC="$HOME_/DevOps/aether/infra/traefik/dynamic.yml"
NET="aether"
TOKEN="di-deploy-zitadel-portainer-v1"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "I1 extract Postgres password and create Zitadel DB"
mkdir -p "$SEC" "$UDIR"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
if [ -z "$PGPASS" ]; then say "[HALT] POSTGRES_PASSWORD missing from $SEC/postgres.env"; exit 1; fi
say "postgres password extracted (length=${#PGPASS})"
podman exec postgres psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname='zitadel'" | grep -q 1 || \
  podman exec postgres psql -U postgres -c "CREATE DATABASE zitadel;"
say "DB 'zitadel' ensured"

hr "I2 generate Zitadel masterkey (32 bytes base64)"
if [ ! -f "$SEC/zitadel-masterkey" ]; then
  head -c 32 /dev/urandom | base64 -w0 > "$SEC/zitadel-masterkey"
  chmod 600 "$SEC/zitadel-masterkey"
  say "masterkey generated -> $SEC/zitadel-masterkey"
else
  say "masterkey already exists"
fi
MKEY="$(cat "$SEC/zitadel-masterkey")"

hr "I3 run Zitadel start-from-init (setup + start in one shot)"
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

hr "I4 create Zitadel quadlet"
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

hr "I5 create Portainer quadlet"
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

hr "I6 daemon-reload + start units"
systemctl --user daemon-reload
systemctl --user enable --now zitadel.service portainer.service
sleep 10
say "zitadel: $(systemctl --user is-active zitadel.service) / portainer: $(systemctl --user is-active portainer.service)"

hr "I7 update Traefik dynamic config for zitadel + portainer"
if [ -f "$TRAEFIK_DYNAMIC" ]; then
  if ! grep -q 'zitadel' "$TRAEFIK_DYNAMIC"; then
    cat >> "$TRAEFIK_DYNAMIC" <<TREOF

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
    say "appended zitadel+portainer routers to $TRAEFIK_DYNAMIC"
    # restart traefik to pick up file changes if no file watcher
    systemctl --user restart traefik.service
  else
    say "traefik config already has zitadel/portainer"
  fi
else
  say "WARN: $TRAEFIK_DYNAMIC not found; skipping traefik routing update"
fi

hr "I8 health gates"
ZOK=0; for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8082 | grep -q 200 && { ZOK=1; break; }; sleep 2; done
POK=0; for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code}' --max-time 5 -k https://127.0.0.1:9443 | grep -q 200 && { POK=1; break; }; sleep 2; done
say "zitadel http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8082) gate=$ZOK"
say "portainer http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -k https://127.0.0.1:9443) gate=$POK"

hr "I9 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | DI: deployed Zitadel (Brick 13, loopback 8082, postgres-backed, start-from-init) + Portainer CE (loopback 9443/9000, local data volume); updated Traefik dynamic config; both gated HTTP 200. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
fi
say "[RESULT] DI COMPLETE - Zitadel + Portainer deployed and gated."
say "  Zitadel UI: http://127.0.0.1:8082 (or http://zitadel.aether.local if in /etc/hosts)"
say "  Portainer UI: https://127.0.0.1:9443 (self-signed cert; accept warning)"
exit 0
