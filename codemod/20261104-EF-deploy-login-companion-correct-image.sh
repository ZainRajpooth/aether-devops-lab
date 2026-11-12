#!/usr/bin/env bash
# 20261104-EF — CORRECTED: Deploy Login V2 companion with the RIGHT image name.
# Image = ghcr.io/zitadel/zitadel-login (not ghcr.io/zitadel/login).
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ef-deploy-login-companion-correct-image-v1"
B="http://127.0.0.1:8082"
NET="aether"
LOGIN_PORT="3000"
LOGIN_IMAGE="ghcr.io/zitadel/zitadel-login:v4.12.1"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "F0 pull the CORRECT Login V2 companion image"
podman pull "$LOGIN_IMAGE" >/dev/null 2>&1 || { say "[HALT] could not pull $LOGIN_IMAGE"; exit 1; }
say "pulled $LOGIN_IMAGE"

hr "F1 extract admin credentials from the latest setup log"
LOG_FILE="$(ls -1t "$ZIT_DIR"/setup-ec-*.log 2>/dev/null | head -1)"
[ -n "$LOG_FILE" ] || { say "[HALT] no setup-ec-*.log found"; exit 1; }
ADMIN_USER="$(grep -oE 'Username: [^ ]+' "$LOG_FILE" | awk '{print $2}' | head -1 || true)"
ADMIN_PASS="$(grep -oE 'Password: [^ ]+' "$LOG_FILE" | awk '{print $2}' | head -1 || true)"
[ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ] || { say "[HALT] could not parse admin user/pass from $LOG_FILE"; exit 1; }
say "admin user=$ADMIN_USER (pass redacted)"

hr "F2 mint a Machine User PAT via the Management API"
TOKEN_RESP="$(curl -sS -m 10 -X POST "$B/oauth/v2/token" \
  -d "grant_type=password" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" \
  -d "scope=openid profile email urn:zitadel:iam:org:project:id:zitadel:aud" \
  -d "client_id=console" || true)"
ACCESS_TOKEN="$(echo "$TOKEN_RESP" | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4 || true)"
if [ -z "$ACCESS_TOKEN" ]; then
  say "[HALT] could not get access token. Response:"
  echo "$TOKEN_RESP" | head -5
  exit 1
fi
say "admin access token acquired"

SVC_RESP="$(curl -sS -m 10 -X POST "$B/management/v1/users/machine" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "login-ui-svc", "description": "Service user for Login V2 UI"}' || true)"
SVC_ID="$(echo "$SVC_RESP" | grep -oE '"userId":"[^"]+"' | cut -d'"' -f4 || true)"
if [ -z "$SVC_ID" ]; then
  say "[HALT] could not create service user. Response:"
  echo "$SVC_RESP" | head -5
  exit 1
fi
say "service user created: id=$SVC_ID"

PAT_RESP="$(curl -sS -m 10 -X POST "$B/management/v1/users/$SVC_ID/pats" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' || true)"
PAT="$(echo "$PAT_RESP" | grep -oE '"pat":"[^"]+"' | cut -d'"' -f4 || true)"
if [ -z "$PAT" ]; then
  say "[HALT] could not generate PAT. Response:"
  echo "$PAT_RESP" | head -5
  exit 1
fi
printf '%s' "$PAT" > "$SEC/zitadel-login-pat"; chmod 600 "$SEC/zitadel-login-pat"
say "PAT saved to $SEC/zitadel-login-pat"

hr "F3 patch core config to point LoginV2.BaseURI to the companion app"
ZIT_CONF="$ZIT_DIR/config.yaml"
cp -p "$ZIT_CONF" "$ZIT_CONF.pre-EF.bak"
sed -i '/^LoginV2:/,/^[^ ]/d' "$ZIT_CONF" 2>/dev/null || true
cat >> "$ZIT_CONF" <<CFGEOF

LoginV2:
  Enabled: true
  BaseURI: "http://127.0.0.1:$LOGIN_PORT"
CFGEOF
say "appended LoginV2.BaseURI to $ZIT_CONF"

hr "F4 create the Login V2 companion quadlet"
cat > "$UDIR/zitadel-login.container" <<QEOF
[Unit]
Description=Zitadel Login V2 UI (Companion App)
After=local-fs.target network-online.target zitadel.service
Wants=zitadel.service

[Container]
Image=$LOGIN_IMAGE
Network=$NET
PublishPort=127.0.0.1:$LOGIN_PORT:3000
Environment=ZITADEL_API_URL=http://zitadel:8080
Environment=ZITADEL_SERVICE_USER_PAT_FILE=/pat
Volume=$SEC/zitadel-login-pat:/pat:ro

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=90

[Install]
WantedBy=default.target
QEOF
say "wrote $UDIR/zitadel-login.container"

hr "F5 restart core + start companion"
systemctl --user daemon-reload
systemctl --user restart zitadel.service
systemctl --user enable --now zitadel-login.service
sleep 12
say "core: $(systemctl --user is-active zitadel.service) ; login-companion: $(systemctl --user is-active zitadel-login.service)"

hr "F6 gate: does /ui/v2/login/login now serve?"
CODE="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$B/ui/v2/login/login?authRequest=test" 2>/dev/null || echo 000)"
say "/ui/v2/login/login?authRequest=test = $CODE   (expect 200 or 302)"
if [ "$CODE" = 200 ] || [ "$CODE" = 302 ]; then
  say "[RESULT] EF COMPLETE - Login V2 companion deployed. Open http://127.0.0.1:8082/ui/console/ and log in."
  say "  Initial admin creds are in: $LOG_FILE"
else
  say "[RESULT] EF PARTIAL - companion running but /ui/v2 still $CODE. Paste F6 + journalctl -u zitadel-login -n 20."
fi

hr "F7 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EF: deployed Login V2 companion (ghcr.io/zitadel/zitadel-login:v4.12.1) to restore UI on v4 core; automated PAT minting; wired via LoginV2.BaseURI. /ui/v2/login/login now %s. Rollback: restore config.yaml.pre-EF.bak. |\n' "$(date +%F)" "$TOKEN" "$([ "$CODE" = 200 ] || [ "$CODE" = 302 ] && echo PASS || echo PARTIAL)" "$CODE" >> "$IDX"
  say "ledger row appended"
fi
exit 0
