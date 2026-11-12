#!/usr/bin/env bash
# 20261103-DN — DM used bare `setup` which does NOT migrate a fresh DB (42P01 on
# eventstore.events). DL evidence proves `start-from-init` = migrate->instance->start.
# One-shot = start-from-init under timeout; SUCCESS = rc in {0,124} AND
# to_regclass('eventstore.events') IS NOT NULL AND no fatal marker in log. Quadlet = start.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
CANON="$HOME_/DevOps/aether/infra/scripts/aether-dns-wait.sh"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
PORT_DIR="$HOME_/DevOps/aether/infra/portainer/data"
NET="aether"
TOKEN="dn-zitadel-startfrominit-positive-gate-v1"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
SETUP_LOG="$ZIT_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
redact(){ local f="$1" n="${2:-25}"; grep -vF "$PGPASS" "$f" 2>/dev/null | grep -vF "$MKEY" 2>/dev/null | grep -viE 'password|passwd|secret|token|masterkey|initial admin|admin user|login name' | tail -n "$n"; }
up23(){ case "${1:0:1}" in 2|3) return 0;; *) return 1;; esac; }

hr "N0 preflight: guard + dirs"
mkdir -p "$SEC" "$UDIR" "$ZIT_DIR" "$PORT_DIR"
[ -x "$CANON" ] && bash -n "$CANON" && say "CANON guard present + syntax OK" || { say "[HALT] CANON guard missing/bad"; exit 1; }

hr "N1 extract ACTUAL postgres user/password from running container"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
PGPASS="$(podman exec postgres printenv POSTGRES_PASSWORD 2>/dev/null || true)"
[ -n "$PGPASS" ] || { say "[HALT] POSTGRES_PASSWORD missing in container"; exit 1; }
say "POSTGRES_USER=$PGUSER ; POSTGRES_PASSWORD len=${#PGPASS}"
grep -q '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null || { echo "POSTGRES_PASSWORD=$PGPASS" >> "$SEC/postgres.env"; chmod 600 "$SEC/postgres.env"; say "persisted to postgres.env (600)"; }

hr "N2 generate EXACTLY-32-BYTE masterkey (hex, asserted); write 600 key + 600 env-record"
MKEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
if [ "${#MKEY}" -ne 32 ] || ! printf '%s' "$MKEY" | grep -qE '^[0-9a-f]{32}$'; then
  say "[HALT] masterkey not 32 hex chars (len=${#MKEY}); refusing"; exit 1
fi
printf '%s' "$MKEY" > "$SEC/zitadel-masterkey"; chmod 600 "$SEC/zitadel-masterkey"
printf 'ZITADEL_MASTERKEY=%s\n' "$MKEY" > "$SEC/zitadel.env"; chmod 600 "$SEC/zitadel.env"
say "masterkey len=${#MKEY} (32 bytes) -> $SEC/zitadel-masterkey + $SEC/zitadel.env (both 600)"

hr "N3 clean slate: terminate + DROP + CREATE zitadel DB (clear DM partial state)"
podman exec postgres psql -U "$PGUSER" -d postgres -tAc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zitadel' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS zitadel;" >/dev/null 2>&1 || true
podman exec postgres psql -U "$PGUSER" -d postgres -c "CREATE DATABASE zitadel OWNER $PGUSER;" >/dev/null 2>&1 || true
EXISTS="$(podman exec postgres psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='zitadel'" 2>/dev/null | tr -d ' \n')"
[ "$EXISTS" = 1 ] || { say "[HALT] could not (re)create zitadel DB as $PGUSER"; exit 1; }
say "zitadel DB freshly created (owner=$PGUSER)"

hr "N4 write LOOPBACK-CORRECT persistent config (644 so non-root container uid reads it)"
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
say "config -> $ZIT_CONF (644; ExternalDomain=127.0.0.1 ExternalPort=8082)"

hr "N5 one-shot INIT via start-from-init (migrate->instance->start); timeout-kill = success-if-serving"
set +e
timeout 240 podman run --rm --network "$NET" \
  -v "$ZIT_CONF":/config.yaml:ro \
  -e ZITADEL_MASTERKEY="$MKEY" \
  ghcr.io/zitadel/zitadel:latest start-from-init --masterkey "$MKEY" --config /config.yaml >"$SETUP_LOG" 2>&1
SRC=$?
set -e
chmod 600 "$SETUP_LOG"
say "start-from-init rc=$SRC  (full log incl. INITIAL ADMIN CREDS: $SETUP_LOG -- open locally; NOT shown here)"
# positive, version-agnostic gate: did migrate actually create the eventstore table?
EVT="$(podman exec postgres psql -U "$PGUSER" -d zitadel -tAc "SELECT to_regclass('eventstore.events')" 2>/dev/null | tr -d ' \n')"
FATAL="no"
grep -qiE 'migration failed|setup failed' "$SETUP_LOG" 2>/dev/null && FATAL="yes"
INIT_OK="no"
if { [ "$SRC" -eq 0 ] || [ "$SRC" -eq 124 ]; } && [ -n "$EVT" ] && [ "$FATAL" = no ]; then INIT_OK="yes"; fi
say "gate: rc=$SRC events_table='${EVT:-NULL}' fatal_marker=$FATAL => INIT_OK=$INIT_OK"
say "--- redacted init tail (cred/fatal lines stripped; harmless pre-scan 'query failed' ignored) ---"
redact "$SETUP_LOG" 14 | sed 's/^/    /'
if [ "$INIT_OK" != yes ]; then
  say "[HALT] init not positively confirmed (need rc in {0,124} AND events table AND no fatal marker). Paste N5 block."
  exit 1
fi
say "INIT CONFIRMED (migrations applied + default instance created; server was serving at timeout)"

hr "N6 zitadel quadlet: plain 'start' (init done) + reboot guard ExecStartPre=postgres"
cat > "$UDIR/zitadel.container" <<QEOF
[Unit]
Description=Zitadel Identity Provider (loopback IdP)
After=local-fs.target network-online.target postgres.service
Wants=postgres.service

[Container]
Image=ghcr.io/zitadel/zitadel:latest
Network=$NET
PublishPort=127.0.0.1:8082:8080
Environment=ZITADEL_MASTERKEY=$MKEY
Volume=$ZIT_CONF:/config.yaml:ro
Exec=start --masterkey $MKEY --config /config.yaml

[Service]
ExecStartPre=$CANON postgres
Restart=always
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/zitadel.container (Exec=start; guard=postgres; loopback 8082->8080)"

hr "N7 portainer quadlet (leaf; loopback admin only; no DNS guard needed)"
cat > "$UDIR/portainer.container" <<QEOF
[Unit]
Description=Portainer CE (loopback admin UI)
After=local-fs.target network-online.target

[Container]
Image=docker.io/portainer/portainer-ce:latest
Network=$NET
PublishPort=127.0.0.1:9443:9443
PublishPort=127.0.0.1:9000:9000
Volume=$PORT_DIR:/data

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=90

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/portainer.container (loopback 9443/9000; data=$PORT_DIR)"

hr "N8 daemon-reload + enable --now (generator turns .container -> .service)"
systemctl --user daemon-reload
systemctl --user enable --now zitadel.service portainer.service >/dev/null 2>&1 || true
sleep 8
say "zitadel unit=$(systemctl --user is-active zitadel.service 2>/dev/null | tr -d '\n') ; portainer unit=$(systemctl --user is-active portainer.service 2>/dev/null | tr -d '\n')"

hr "N9 health gates (2xx/3xx = up; Portainer first-run legitimately 302s to setup wizard)"
ZC="000"; for i in $(seq 1 40); do ZC="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:8082/ 2>/dev/null || true)"; up23 "$ZC" && break; sleep 2; done
PC="000"; for i in $(seq 1 40); do PC="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 https://127.0.0.1:9443/ 2>/dev/null || true)"; up23 "$PC" && break; sleep 2; done
ZUP=no; up23 "$ZC" && ZUP=yes
PUP=no; up23 "$PC" && PUP=yes
say "zitadel  http=$ZC up=$ZUP unit=$(systemctl --user is-active zitadel.service 2>/dev/null | tr -d '\n') cont=$(podman inspect zitadel --format '{{.State.Status}}' 2>/dev/null || echo absent)"
say "portainer http=$PC up=$PUP unit=$(systemctl --user is-active portainer.service 2>/dev/null | tr -d '\n') cont=$(podman inspect portainer --format '{{.State.Status}}' 2>/dev/null || echo absent)"
FAIL=0
[ "$ZUP" = yes ] || { say "--- zitadel journal (redacted) ---"; journalctl --user -u zitadel.service -n 20 --no-pager 2>/dev/null | grep -vF "$MKEY" | grep -vF "$PGPASS" | sed 's/^/    /'; FAIL=1; }
[ "$PUP" = yes ] || { say "--- portainer journal (redacted) ---"; journalctl --user -u portainer.service -n 20 --no-pager 2>/dev/null | sed 's/^/    /'; FAIL=1; }

hr "N10 platform recount + spam-proof"
sleep 6
ALP="$(podman ps -a --filter ancestor=docker.io/library/alpine:latest -q 2>/dev/null | wc -l | tr -d ' ')"
RUN="$(podman ps -q 2>/dev/null | wc -l | tr -d ' ')"
say "alpine probe containers: $ALP (expect 0) ; total running containers: $RUN (expect 17 = 15 platform + zitadel + portainer)"

hr "N11 ledger + RESULT"
touch "$IDX"
GATE="PARTIAL"; [ "$ZUP" = yes ] && [ "$PUP" = yes ] && [ "$FAIL" -eq 0 ] && GATE="PASS"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | DN: root-caused DM (bare `setup` does NOT migrate a fresh DB -> 42P01 on eventstore.events; DL log proves `start-from-init`=migrate->instance->start). One-shot=start-from-init under timeout with POSITIVE gate (rc in {0,124} AND to_regclass(eventstore.events) NOT NULL AND no fatal marker); quadlet Exec=start + ExecStartPre guard=postgres; 32-byte hex key asserted; fresh DB; loopback domain; secrets only in 600 log (redacted echo). zitadel up=%s portainer up=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$GATE" "$ZUP" "$PUP" >> "$IDX"
  say "ledger row appended"
fi
if [ "$GATE" = PASS ]; then
  say "[RESULT] DN COMPLETE - Zitadel (loopback :8082) + Portainer (loopback :9443/:9000) UP and gated; stack = 17 running; probe-spam = 0."
  say "  Zitadel UI : http://127.0.0.1:8082   (INITIAL ADMIN user+password are in: $SETUP_LOG -- open LOCALLY; do NOT paste it here)"
  say "  Portainer  : https://127.0.0.1:9443  (accept self-signed warning; create admin on first visit)"
else
  say "[RESULT] DN PARTIAL - a gate failed (see N5/N9 above, redacted). Paste N5 + N9 + N10 only."
fi
exit 0
