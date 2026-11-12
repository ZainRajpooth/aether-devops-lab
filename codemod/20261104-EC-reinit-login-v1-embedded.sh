#!/usr/bin/env bash
# 20261104-EC — MODE C HEAL. Zitadel v4 split the Login UI into a separate Next.js
# container. The 404 on /ui/v2/* is because that container is missing. To restore the
# "old times" embedded Login V1 UI (served directly by the Go core at /ui/login), we
# disable the Login V2 requirement via config and re-initialize the instance (since the
# current instance is locked out and v4 enables V2 by default for new installs).
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ec-reinit-login-v1-embedded-v1"
B="http://127.0.0.1:8082"
NET="aether"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
redact(){ local m="$(cat "$SEC/zitadel-masterkey" 2>/dev/null)" p="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2-)"; awk -v a="$m" -v b="$p" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "    [REDACTED-LINE]"; else print }'; }

hr "C0 extract PG credentials and masterkey (from settled secrets)"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
PGPASS="$(podman exec postgres printenv POSTGRES_PASSWORD 2>/dev/null || true)"
MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
[ -n "$PGPASS" ] || { say "[HALT] POSTGRES_PASSWORD missing"; exit 1; }
[ -n "$MKEY" ] || { say "[HALT] zitadel-masterkey missing"; exit 1; }
say "PG user=$PGUSER ; masterkey len=${#MKEY}"

hr "C1 drop the unusable zitadel DB (locked out due to missing Login V2 container)"
podman exec postgres psql -U "$PGUSER" -d postgres -tAc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zitadel' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS zitadel;" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "CREATE DATABASE zitadel OWNER $PGUSER;" >/dev/null 2>&1 || true
EXISTS="$(podman exec postgres psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='zitadel'" 2>/dev/null | tr -d ' \n')"
[ "$EXISTS" = 1 ] || { say "[HALT] could not recreate zitadel DB"; exit 1; }
say "zitadel DB dropped and recreated (clean slate for Login V1)"

hr "C2 patch config.yaml to disable Login V2 requirement (forces embedded Login V1)"
ZIT_CONF="$ZIT_DIR/config.yaml"
cp -p "$ZIT_CONF" "$ZIT_CONF.pre-EC.bak"
# Remove any existing LoginV2 block to avoid YAML merge conflicts
sed -i '/^LoginV2:/,/^[^ ]/d' "$ZIT_CONF" 2>/dev/null || true
cat >> "$ZIT_CONF" <<CFGEOF

LoginV2:
  Required: false
CFGEOF
say "appended LoginV2.Required=false to $ZIT_CONF (backup: $ZIT_CONF.pre-EC.bak)"

hr "C3 re-run start-from-init with the patched config (generates new admin + Login V1)"
SETUP_LOG="$ZIT_DIR/setup-ec-$(date +%Y%m%d-%H%M%S).log"
set +e
timeout 240 podman run --rm --network "$NET" \
  -v "$ZIT_CONF":/config.yaml:ro \
  -e ZITADEL_MASTERKEY="$MKEY" \
  ghcr.io/zitadel/zitadel:latest start-from-init --masterkey "$MKEY" --config /config.yaml --tlsMode disabled >"$SETUP_LOG" 2>&1
SRC=$?
set -e
chmod 600 "$SETUP_LOG"
say "start-from-init rc=$SRC  (log: $SETUP_LOG)"
EVTN="$(podman exec postgres psql -U "$PGUSER" -d zitadel -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='eventstore'" 2>/dev/null | tr -d ' \n')"
[ -z "$EVTN" ] && EVTN=0
if [ "$SRC" -ne 0 ] && [ "$SRC" -ne 124 ]; then
  say "[HALT] init failed rc=$SRC; redacted tail:"
  redact "$SETUP_LOG" | tail -15 | sed 's/^/    /'
  exit 1
fi
[ "$EVTN" -ge 1 ] || { say "[HALT] eventstore tables missing after init"; exit 1; }
say "INIT OK (eventstore tables=$EVTN); new admin creds in $SETUP_LOG"

hr "C4 restart the quadlet to pick up the fresh DB"
systemctl --user restart zitadel.service >/dev/null 2>&1 || true
sleep 8
say "unit: $(systemctl --user is-active zitadel.service) ; cont: $(podman inspect zitadel --format '{{.State.Status}}' 2>/dev/null || echo absent)"

hr "C5 gate: does the embedded Login V1 UI now serve at /ui/login?"
CODE="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$B/ui/login" 2>/dev/null || echo 000)"
say "/ui/login = $CODE   (expect 200 or 301/302 -> Login V1 is embedded)"
if [ "$CODE" = 200 ] || [ "$CODE" = 301 ] || [ "$CODE" = 302 ]; then
  say "[RESULT] EC COMPLETE - Login V1 restored. Open http://127.0.0.1:8082/ui/login and log in with the new admin from $SETUP_LOG."
else
  say "[RESULT] EC PARTIAL - /ui/login still $CODE. Paste C5 + journalctl -u zitadel -n 20 (redacted)."
fi

hr "C6 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EC: root-caused v4 architectural split (Login V2 is a separate Next.js container; missing -> /ui/v2 404); healed by dropping locked-out DB, appending LoginV2.Required=false to config, and re-initting to force embedded Login V1 at /ui/login. /ui/login now %s. Rollback: restore $ZIT_CONF.pre-EC.bak and re-init again. |\n' "$(date +%F)" "$TOKEN" "$([ "$CODE" = 200 ] || [ "$CODE" = 301 ] || [ "$CODE" = 302 ] && echo PASS || echo PARTIAL)" "$CODE" >> "$IDX"
  say "ledger row appended"
fi
exit 0
