#!/usr/bin/env bash
# 20261104-EH — Wipe and redeploy Zitadel v3.3.4 (Login V1 embedded).
# This restores the "old times" experience where the login UI is served directly
# by the core at /ui/login, without needing a separate companion container.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="eh-wipe-redeploy-zitadel-v3-v1"
B="http://127.0.0.1:8082"
NET="aether"
V3_TAG="v3.3.4"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "H0 stop and remove existing zitadel container/unit"
systemctl --user stop zitadel.service zitadel-login.service 2>/dev/null || true
systemctl --user disable zitadel.service zitadel-login.service 2>/dev/null || true
rm -f "$UDIR/zitadel.container" "$UDIR/zitadel-login.container" 2>/dev/null || true
podman rm -f zitadel zitadel-login 2>/dev/null || true
systemctl --user daemon-reload
say "stopped and removed old zitadel units/containers"

hr "H1 drop and recreate the zitadel DB (fresh start for v3)"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
podman exec postgres psql -U "$PGUSER" -d postgres -tAc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zitadel' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS zitadel;" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "CREATE DATABASE zitadel OWNER $PGUSER;" >/dev/null 2>&1 || true
say "zitadel DB dropped and recreated"

hr "H2 pull Zitadel v3.3.4 (Login V1 embedded)"
V3_IMAGE="ghcr.io/zitadel/zitadel:$V3_TAG"
podman pull "$V3_IMAGE" >/dev/null 2>&1 || { say "[HALT] could not pull $V3_IMAGE"; exit 1; }
say "pulled $V3_IMAGE"

hr "H3 generate fresh masterkey and config for v3"
mkdir -p "$ZIT_DIR" "$SEC"
MKEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s' "$MKEY" > "$SEC/zitadel-masterkey"; chmod 600 "$SEC/zitadel-masterkey"
PGPASS="$(podman exec postgres printenv POSTGRES_PASSWORD 2>/dev/null || true)"
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
ExternalDomain: 127.0.0.1
ExternalPort: 8082
CFGEOF
chmod 644 "$ZIT_CONF"
say "config written for v3 (Login V1 embedded, no LoginV2 block needed)"

hr "H4 run start-from-init for v3 (creates initial admin + DB schema)"
SETUP_LOG="$ZIT_DIR/setup-eh-$(date +%Y%m%d-%H%M%S).log"
set +e
timeout 240 podman run --rm --network "$NET" \
  -v "$ZIT_CONF":/config.yaml:ro \
  -e ZITADEL_MASTERKEY="$MKEY" \
  "$V3_IMAGE" start-from-init --masterkey "$MKEY" --config /config.yaml --tlsMode disabled >"$SETUP_LOG" 2>&1
SRC=$?
set -e
chmod 600 "$SETUP_LOG"
say "start-from-init rc=$SRC  (log: $SETUP_LOG)"
EVTN="$(podman exec postgres psql -U "$PGUSER" -d zitadel -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='eventstore'" 2>/dev/null | tr -d ' \n')"
[ -z "$EVTN" ] && EVTN=0
if [ "$SRC" -ne 0 ] && [ "$SRC" -ne 124 ]; then
  say "[HALT] init failed; redacted tail:"
  tail -15 "$SETUP_LOG" | sed 's/^/    /'
  exit 1
fi
[ "$EVTN" -ge 1 ] || { say "[HALT] eventstore tables missing"; exit 1; }
say "INIT OK (eventstore tables=$EVTN); new admin creds in $SETUP_LOG"

hr "H5 create v3 quadlet (plain start, no companion needed)"
cat > "$UDIR/zitadel.container" <<QEOF
[Unit]
Description=Zitadel v3 (Login V1 Embedded)
After=local-fs.target network-online.target postgres.service
Wants=postgres.service

[Container]
Image=$V3_IMAGE
Network=$NET
PublishPort=127.0.0.1:8082:8080
Environment=ZITADEL_MASTERKEY=$MKEY
Volume=$ZIT_CONF:/config.yaml:ro
Exec=start --masterkey $MKEY --config /config.yaml --tlsMode disabled

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/zitadel.container (v3 core only)"

hr "H6 daemon-reload + start"
systemctl --user daemon-reload
systemctl --user enable --now zitadel.service
sleep 10
say "unit: $(systemctl --user is-active zitadel.service) ; cont: $(podman inspect zitadel --format '{{.State.Status}}' 2>/dev/null || echo absent)"

hr "H7 gate: does /ui/login (Login V1) now serve?"
CODE="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$B/ui/login" 2>/dev/null || echo 000)"
say "/ui/login = $CODE   (expect 200 or 301/302 -> Login V1 is embedded in v3)"
if [ "$CODE" = 200 ] || [ "$CODE" = 301 ] || [ "$CODE" = 302 ]; then
  say "[RESULT] EH COMPLETE - Zitadel v3.3.4 deployed. Login V1 UI restored at http://127.0.0.1:8082/ui/login"
  say "  Initial admin creds are in: $SETUP_LOG (read locally, never paste)"
else
  say "[RESULT] EH PARTIAL - v3 running but /ui/login still $CODE. Paste H7 + journalctl -u zitadel -n 20."
fi

hr "H8 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EH: wiped v4 core+DB, redeployed Zitadel v3.3.4 (Login V1 embedded). /ui/login now %s. Rollback: restore v4 quadlet if backup exists. |\n' "$(date +%F)" "$TOKEN" "$([ "$CODE" = 200 ] || [ "$CODE" = 301 ] || [ "$CODE" = 302 ] && echo PASS || echo PARTIAL)" "$CODE" >> "$IDX"
  say "ledger row appended"
fi
exit 0
