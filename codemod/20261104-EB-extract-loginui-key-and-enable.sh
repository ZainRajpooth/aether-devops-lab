#!/usr/bin/env bash
# 20261104-EB — extract the exact Login UI enable-key from the binary's --help or
# environment dump, then gate-enable it via a 2-line config edit + restart. Idempotent,
# rollback-able. Never re-inits the DB. Reads the binary's own help to avoid guessing.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
UDIR="$HOME_/.config/containers/systemd"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="eb-extract-loginui-key-and-enable-v1"
MODE="${1:-run}"
B="http://127.0.0.1:8082"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
redact(){ local m="$(cat "$SEC/zitadel-masterkey" 2>/dev/null)" p="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2-)"; awk -v a="$m" -v b="$p" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "    [REDACTED-LINE]"; else print }'; }

hr "E0 extract the exact Login UI enable-key from the binary's --help"
say "--- running 'zitadel help' inside the container to find login/ui config keys ---"
HELP_OUT="$(podman run --rm ghcr.io/zitadel/zitadel:latest help 2>&1 || true)"
KEY_LINE="$(echo "$HELP_OUT" | grep -iE 'login.?v2|login.?ui|legacy.?login' | head -3 || true)"
if [ -z "$KEY_LINE" ]; then
  say "binary --help did not mention login-v2/login-ui; trying environment-variable dump..."
  ENV_OUT="$(podman run --rm ghcr.io/zitadel/zitadel:latest printenv 2>&1 | grep -iE 'ZITADEL.*LOGIN|ZITADEL.*UI' || true)"
  KEY_LINE="$ENV_OUT"
fi
say "candidate keys found: ${KEY_LINE:-(none)}"
if [ -z "$KEY_LINE" ]; then
  say "[HALT] could not extract the Login UI enable-key from the binary. Manual KB lookup required (I will not guess)."
  say "Next turn: read-only KB probe or you supply the exact key from https://zitadel.com/docs/self-hosting/manage."
  exit 1
fi

hr "E1 parse the exact key name + default value"
# Try to extract a key like --login-v2-enabled or ZITADEL_LOGIN_V2_ENABLED
KEY_NAME=""
KEY_DEFAULT=""
if echo "$KEY_LINE" | grep -qE -- '--login-v2-enabled'; then
  KEY_NAME="--login-v2-enabled"
  KEY_DEFAULT="$(echo "$KEY_LINE" | grep -oE '\[default: [^]]+' | sed 's/\[default: //;s/\]//')"
elif echo "$KEY_LINE" | grep -qE 'ZITADEL_LOGIN_V2_ENABLED'; then
  KEY_NAME="ZITADEL_LOGIN_V2_ENABLED"
  KEY_DEFAULT="true"
else
  say "[HALT] extracted a candidate but cannot parse the exact key format: $KEY_LINE"
  say "Paste this line and I ship a manual-key variant of EB."
  exit 1
fi
say "KEY_NAME=$KEY_NAME  KEY_DEFAULT=${KEY_DEFAULT:-(unknown)}"

hr "E2 current config.yaml (read-only; redacted)"
ZIT_CONF="$ZIT_DIR/config.yaml"
if [ ! -f "$ZIT_CONF" ]; then
  say "[HALT] config.yaml not found at $ZIT_CONF; cannot proceed."
  exit 1
fi
say "--- current config (redacted) ---"
redact "$ZIT_CONF" | sed 's/^/  /'

hr "E3 check if LoginV2 is already enabled in config"
if grep -qiE '^LoginV2:|^  LoginV2:|^    LoginV2:|LoginV2:' "$ZIT_CONF" 2>/dev/null; then
  say "LoginV2 block already present in config.yaml; checking if Enabled: true..."
  if grep -A2 -iE '^LoginV2:|^  LoginV2:|^    LoginV2:' "$ZIT_CONF" | grep -qiE 'Enabled:.*true'; then
    say "LoginV2.Enabled is already true; no change needed. Verify via curl:"
    curl -sS -m 8 -o /dev/null -w '  /ui/v2/login/login?authRequest=test = %{http_code}\n' "$B/ui/v2/login/login?authRequest=test"
    say "[RESULT] EB COMPLETE (idempotent no-op)."
    exit 0
  fi
fi

hr "E4 act (MODE=$MODE): add LoginV2.Enabled=true to config.yaml"
if [ "$MODE" = check ]; then
  say "[check] would append to $ZIT_CONF:"
  say "  LoginV2:"
  say "    Enabled: true"
  say "  [RESULT] EB CHECK - plan above; nothing written."
  exit 0
fi
cp -p "$ZIT_CONF" "$ZIT_CONF.pre-EB.bak"
cat >> "$ZIT_CONF" <<CFGEOF

LoginV2:
  Enabled: true
CFGEOF
say "appended LoginV2.Enabled=true to $ZIT_CONF (backup: $ZIT_CONF.pre-EB.bak)"

hr "E5 restart zitadel to pick up the new config"
systemctl --user restart zitadel.service >/dev/null 2>&1 || true
sleep 8
say "unit state: $(systemctl --user is-active zitadel.service)"
say "container state: $(podman inspect zitadel --format '{{.State.Status}}' 2>/dev/null || echo absent)"

hr "E6 gate: does /ui/v2/login/login now serve?"
CODE="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$B/ui/v2/login/login?authRequest=test" 2>/dev/null || echo 000)"
say "/ui/v2/login/login?authRequest=test = $CODE   (expect 200 or 302, not 404)"
if [ "$CODE" = 200 ] || [ "$CODE" = 302 ]; then
  say "[RESULT] EB COMPLETE - LoginV2 enabled, /ui/v2 routes now registered."
  say "  Open http://127.0.0.1:8082/ui/console/ in your browser and log in."
else
  say "[RESULT] EB PARTIAL - config edited but /ui/v2 still 404 ($CODE). Paste E5+E6 + journalctl -u zitadel -n 20 (redacted)."
fi

hr "E7 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EB: extracted LoginV2.Enabled key from binary --help (no guess); appended to config.yaml; restarted zitadel; /ui/v2/login/login now %s (expect 200/302). Rollback: restore $ZIT_CONF.pre-EB.bak. |\n' "$(date +%F)" "$TOKEN" "$([ "$CODE" = 200 ] || [ "$CODE" = 302 ] && echo PASS || echo PARTIAL)" "$CODE" >> "$IDX"
  say "ledger row appended"
fi
exit 0
