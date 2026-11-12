#!/usr/bin/env bash
# 20261104-EX4 — READ-ONLY Gitea auth diagnostic for Brick 12.
# Mutates nothing. Prints redacted config, DB user state, API auth result, logs.
set -uo pipefail

HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
GT="http://127.0.0.1:3000"
BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
redact(){
  sed -E 's/(password|passwd|token|secret|key|authorization)[[:space:]]*[=:][[:space:]]*[^[:space:],"]+/\1=***REDACTED***/Ig'
}

hr "D0 containers"
podman ps --filter name=gitea --format '{{.Names}} {{.Status}} {{.Ports}}' | sed 's/^/  /' || true
podman ps --filter name=postgres --format '{{.Names}} {{.Status}} {{.Ports}}' | sed 's/^/  /' || true

hr "D1 locate Gitea config"
CONF=""
for c in /data/gitea/conf/app.ini /etc/gitea/app.ini /var/lib/gitea/conf/app.ini; do
  if podman exec gitea test -f "$c" 2>/dev/null; then
    CONF="$c"
    break
  fi
done
say "config=${CONF:-none}"

hr "D2 relevant app.ini settings (redacted)"
if [ -n "$CONF" ]; then
  podman exec gitea grep -E '^(INSTALL_LOCK|REQUIRE_SIGNIN_VIEW|DISABLE_BASIC_AUTHENTICATION|DISABLE_REGISTRATION|REQUIRE_EMAIL_CONFIRMATION|PASSWORD_COMPLEXITY|MIN_PASSWORD_LENGTH|SESSION_LIFE|LIFETIME|SECRET_KEY|INTERNAL_TOKEN|JWT_SECRET|DB_TYPE|HOST|NAME|USER|PASSWD|SSLMODE)' "$CONF" 2>/dev/null | redact | sed 's/^/    /' || true
  say "--- [security] section ---"
  podman exec gitea sed -n '/^\[security\]/,/^\[/p' "$CONF" 2>/dev/null | redact | sed 's/^/    /' || true
  say "--- [service] section ---"
  podman exec gitea sed -n '/^\[service\]/,/^\[/p' "$CONF" 2>/dev/null | redact | sed 's/^/    /' || true
  say "--- [database] section ---"
  podman exec gitea sed -n '/^\[database\]/,/^\[/p' "$CONF" 2>/dev/null | redact | sed 's/^/    /' || true
fi

hr "D3 Gitea CLI user list"
if [ -n "$CONF" ]; then
  say "--- with --config ---"
  podman exec gitea gitea admin user list --config "$CONF" 2>&1 | head -30 | redact | sed 's/^/    /' || true
fi
say "--- without --config ---"
podman exec gitea gitea admin user list 2>&1 | head -30 | redact | sed 's/^/    /' || true

hr "D4 Postgres Gitea user rows (SELECT only, no password hashes)"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
GDB=""
DBS="$(podman exec postgres psql -U "$PGUSER" -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)"
for db in $DBS; do
  [ -z "$db" ] && continue
  has_user_table="$(podman exec postgres psql -U "$PGUSER" -d "$db" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user' LIMIT 1" 2>/dev/null || true)"
  if [ "$has_user_table" = "1" ]; then
    GDB="$db"
    break
  fi
done
say "gitea_db=${GDB:-none}"

if [ -n "$GDB" ]; then
  say "--- columns in public.user ---"
  podman exec postgres psql -U "$PGUSER" -d "$GDB" -tAc "SELECT column_name||' '||data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='user' ORDER BY ordinal_position" 2>/dev/null | sed 's/^/    /' || true

  SEL="id, login_name, lower_name, is_active, is_admin"
  HAS_MUST="$(podman exec postgres psql -U "$PGUSER" -d "$GDB" -tAc "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='user' AND column_name='must_change_password' LIMIT 1" 2>/dev/null || true)"
  [ "$HAS_MUST" = "1" ] && SEL="$SEL, must_change_password"

  HAS_PASSWD="$(podman exec postgres psql -U "$PGUSER" -d "$GDB" -tAc "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='user' AND column_name='passwd' LIMIT 1" 2>/dev/null || true)"
  [ "$HAS_PASSWD" = "1" ] && SEL="$SEL, length(passwd) AS passwd_len"

  say "--- wp-ci-bot users ---"
  podman exec postgres psql -U "$PGUSER" -d "$GDB" -c "SELECT $SEL FROM public.\"user\" WHERE lower_name LIKE 'wp-ci-bot%' OR login_name LIKE 'wp-ci-bot%' ORDER BY id;" 2>&1 | redact | sed 's/^/    /' || true

  say "--- first 10 users ---"
  podman exec postgres psql -U "$PGUSER" -d "$GDB" -c "SELECT $SEL FROM public.\"user\" ORDER BY id LIMIT 10;" 2>&1 | redact | sed 's/^/    /' || true

  say "--- user count ---"
  podman exec postgres psql -U "$PGUSER" -d "$GDB" -tAc "SELECT count(*) FROM public.\"user\"" 2>/dev/null | sed 's/^/    /' || true
fi

hr "D5 API probes"
VER="$(curl -sS -m 8 -o "$TMP/version.json" -w '%{http_code}' "$GT/api/v1/version" 2>/dev/null || echo 000)"
say "/api/v1/version=$VER"
head -c 300 "$TMP/version.json" 2>/dev/null | redact | sed 's/^/    /' || true
echo

if [ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ]; then
  BOT="$(cat "$BOT_FILE")"
  PASS="$(cat "$PASS_FILE")"
  say "stored bot user=$BOT pass_len=${#PASS}"
  CODE="$(curl -sS -m 10 -o "$TMP/user.json" -w '%{http_code}' -u "$BOT:$PASS" "$GT/api/v1/user" 2>/dev/null || echo 000)"
  say "/api/v1/user with basic auth=$CODE"
  head -c 500 "$TMP/user.json" 2>/dev/null | redact | sed 's/^/    /' || true
  echo
else
  say "no stored bot user/pass files found"
fi

hr "D6 recent Gitea logs"
podman logs --since 10m gitea 2>&1 | grep -iE 'basic|authentication|login|user|token|401|403|password|inactive|must.change' | tail -40 | redact | sed 's/^/    /' || true

hr "D7 synthesis"
say "Likely causes to distinguish from D2-D6:"
say "  - DISABLE_BASIC_AUTHENTICATION=true => use API token instead of basic auth"
say "  - user exists but is_active=false => activate user"
say "  - must_change_password=true => reset/change password correctly"
say "  - CLI user list empty but DB has users => CLI/config/DB mismatch"
say "  - DB has no wp-ci-bot rows => user creation failed silently"
say "[RESULT] EX4 COMPLETE - paste D0-D6 verbatim; next heal will be targeted, not another blind bot creation."
exit 0
