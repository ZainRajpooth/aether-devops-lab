#!/usr/bin/env bash
# 20261104-EX3 — Heal Gitea CI bot auth, then run Brick 12 steel thread:
# Gitea repo -> webhook -> Woodpecker server -> agent -> green build -> log proof.
# Idempotent after success. Modes: check | run.
set -uo pipefail

HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ex3-woodpecker-gitea-auth-heal-steel-thread-v1"
MODE="${1:-run}"

REPO="woodpecker-proof"
BOT_DEFAULT="wp-ci-bot"
GT="http://127.0.0.1:3000"
WP_PUBLIC="http://127.0.0.1:8000"
WP_INTERNAL="http://woodpecker-server:8000"
UIDn="$(id -u)"
PODSOCK="/run/user/${UIDn}/podman/podman.sock"
BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=""
PGPASS=""

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
backup_file(){ local f="$1"; [ -f "$f" ] && [ ! -f "$f.pre-EX3.bak" ] && cp -p "$f" "$f.pre-EX3.bak"; }
redact(){
  awk -v a="$PASS" -v b="$PGPASS" '
    { if ((a!="" && index($0,a)) || (b!="" && index($0,b))) print "    [REDACTED-LINE]"; else print }
  '
}

json_dict_field(){
  local field="$1"
  python3 -c '
import sys, json
field=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
if isinstance(d, dict):
    v=d.get(field, "")
    if v is not None: print(v)
' "$field" 2>/dev/null || true
}

json_first_list_field(){
  local field="$1"
  python3 -c '
import sys, json
field=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
if isinstance(d, list) and d and isinstance(d[0], dict):
    v=d[0].get(field, "")
    if v is not None: print(v)
' "$field" 2>/dev/null || true
}

json_last_list_field(){
  local field="$1"
  python3 -c '
import sys, json
field=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
if isinstance(d, list) and d and isinstance(d[-1], dict):
    v=d[-1].get(field, "")
    if v is not None: print(v)
' "$field" 2>/dev/null || true
}

build_num_from_statuses(){
  python3 -c '
import sys, json, re
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
if isinstance(d, list) and d and isinstance(d[-1], dict):
    u=d[-1].get("target_url", "") or ""
    m=re.search(r"/builds/([0-9]+)", u)
    if m: print(m.group(1))
' 2>/dev/null || true
}

find_gitea_db_with_user_table(){
  local dbs db has_table has_active
  dbs="$(podman exec postgres psql -U "$PGUSER" -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)"
  for db in $dbs; do
    [ -z "$db" ] && continue
    has_table="$(podman exec postgres psql -U "$PGUSER" -d "$db" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user' LIMIT 1" 2>/dev/null || true)"
    [ "$has_table" = "1" ] || continue
    has_active="$(podman exec postgres psql -U "$PGUSER" -d "$db" -tAc "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='user' AND column_name='is_active' LIMIT 1" 2>/dev/null || true)"
    [ "$has_active" = "1" ] || continue
    printf '%s' "$db"
    return 0
  done
  return 1
}

sql_activate_bot(){
  local user="$1" db set_sql has_col
  db="$(find_gitea_db_with_user_table || true)"
  [ -n "$db" ] || return 1
  set_sql="is_active=true, is_admin=true"
  has_col="$(podman exec postgres psql -U "$PGUSER" -d "$db" -tAc "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='user' AND column_name='must_change_password' LIMIT 1" 2>/dev/null || true)"
  [ "$has_col" = "1" ] && set_sql="$set_sql, must_change_password=false"
  podman exec postgres psql -U "$PGUSER" -d "$db" -c "UPDATE public.\"user\" SET $set_sql WHERE lower_name=lower('$user');" >/dev/null 2>&1 || return 1
  return 0
}

verify_gitea_auth(){
  local user="$1" pass="$2" resp login
  resp="$(curl -sS -m 10 -u "$user:$pass" "$GT/api/v1/user" 2>/dev/null || echo '{}')"
  login="$(printf '%s' "$resp" | json_dict_field login)"
  [ "$login" = "$user" ]
}

ensure_gitea_bot(){
  local user="$1" pass="$2" email="$3"
  podman exec gitea gitea admin user create \
    --username "$user" --password "$pass" --email "$email" \
    --admin --active --must-change-password=false >/dev/null 2>&1 ||
  podman exec gitea gitea admin user create \
    --username "$user" --password "$pass" --email "$email" \
    --admin >/dev/null 2>&1 || true

  podman exec gitea gitea admin user change-password \
    --username "$user" --password "$pass" --must-change-password=false >/dev/null 2>&1 ||
  podman exec gitea gitea admin user change-password \
    --username "$user" --password "$pass" >/dev/null 2>&1 || true

  sql_activate_bot "$user" || true
  verify_gitea_auth "$user" "$pass"
}

diagnose_gitea_auth(){
  say "--- gitea recent logs ---"
  podman logs --since 3m gitea 2>&1 | tail -30 | redact | sed 's/^/    /' || true
  say "--- gitea app.ini auth-relevant lines ---"
  podman exec gitea grep -E 'DISABLE_BASIC_AUTHENTICATION|REQUIRE_SIGNIN|PASSWORD_COMPLEXITY|MIN_PASSWORD_LENGTH|INSTALL_LOCK' /data/gitea/conf/app.ini 2>/dev/null | redact | sed 's/^/    /' || true
  say "--- gitea admin user list head ---"
  podman exec gitea gitea admin user list 2>/dev/null | head -12 | redact | sed 's/^/    /' || true
}

hr "X0 preflight"
for c in python3 curl git podman base64 awk sed grep; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container not present/running: $c"
done
mkdir -p "$SEC"
PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
SV="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WP_PUBLIC/api/version" 2>/dev/null || echo 000)"
say "woodpecker server API=$SV"
say "podman socket on host: $([ -S "$PODSOCK" ] && echo yes || echo no) ($PODSOCK)"
[ "$SV" = 200 ] || halt "Woodpecker server API not reachable"

if [ "$MODE" = check ]; then
  say "plan: heal Gitea bot auth, create/ensure repo+webhook, push static .woodpecker.yml, poll build, fetch logs"
  say "[RESULT] EX3 CHECK - nothing written."
  exit 0
fi

hr "X1 Gitea bot auth heal"
backup_file "$BOT_FILE"
backup_file "$PASS_FILE"
BOT="$BOT_DEFAULT"
[ -s "$BOT_FILE" ] && BOT="$(cat "$BOT_FILE")"
if [ -s "$PASS_FILE" ]; then
  PASS="$(cat "$PASS_FILE")"
else
  PASS="WpCi$(date +%s)!"
  printf '%s\n' "$PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"
fi
printf '%s\n' "$BOT" > "$BOT_FILE"; chmod 600 "$BOT_FILE"

if ! ensure_gitea_bot "$BOT" "$PASS" "${BOT}@local"; then
  say "primary bot '$BOT' failed auth; creating alternate disposable bot"
  BOT="wp-ci-bot-$(date +%s)"
  PASS="WpCi$(date +%s%N)!"
  printf '%s\n' "$BOT" > "$BOT_FILE"; chmod 600 "$BOT_FILE"
  printf '%s\n' "$PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"
  if ! ensure_gitea_bot "$BOT" "$PASS" "${BOT}@local"; then
    diagnose_gitea_auth
    halt "Gitea auth still failed for alternate bot"
  fi
fi
say "Gitea bot auth OK user=$BOT"
AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"

hr "X2 Gitea repo"
REPO_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" 2>/dev/null || echo '{}')"
REPO_ID="$(printf '%s' "$REPO_JSON" | json_dict_field id)"
if [ -z "$REPO_ID" ]; then
  python3 - "$REPO" > "$TMP/repo.json" <<'PYREPO'
import json, sys
print(json.dumps({"name": sys.argv[1], "private": False, "auto_init": True, "default_branch": "main"}))
PYREPO
  REPO_JSON="$(curl -sS -m 15 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d @"$TMP/repo.json" -X POST "$GT/api/v1/user/repos" 2>/dev/null || echo '{}')"
  REPO_ID="$(printf '%s' "$REPO_JSON" | json_dict_field id)"
  [ -n "$REPO_ID" ] || { say "repo response: $REPO_JSON"; halt "could not create repo"; }
  say "created repo $BOT/$REPO"
else
  say "repo already exists $BOT/$REPO"
fi
DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | json_dict_field default_branch)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
say "default branch=$DEFAULT_BRANCH"

hr "X3 Woodpecker webhook"
HOOK_URL="$WP_INTERNAL/hook?source=gitea&owner=$BOT&repo=$REPO"
HOOKS="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '[]')"
if printf '%s' "$HOOKS" | tr -d '\\' | grep -qF "$HOOK_URL"; then
  say "webhook already present"
else
  WP_SECRET="$(podman inspect woodpecker-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '/^WOODPECKER_GITEA_SECRET=/{sub(/^[^=]+=/,""); print; exit}')"
  python3 - "$HOOK_URL" "$WP_SECRET" > "$TMP/hook.json" <<'PYHOOK'
import json, sys
url, secret = sys.argv[1], sys.argv[2]
cfg = {"url": url, "content_type": "json"}
if secret:
    cfg["secret"] = secret
print(json.dumps({"type": "gitea", "active": True, "events": ["push"], "config": cfg}))
PYHOOK
  HOOK_RESP="$(curl -sS -m 15 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d @"$TMP/hook.json" -X POST "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '{}')"
  HOOK_ID="$(printf '%s' "$HOOK_RESP" | json_dict_field id)"
  [ -n "$HOOK_ID" ] && say "webhook created id=$HOOK_ID" || say "webhook create response: $HOOK_RESP"
fi

WP_TOKEN=""
[ -s "$SEC/woodpecker-token" ] && WP_TOKEN="$(cat "$SEC/woodpecker-token")"
WP_AUTH=()
[ -n "$WP_TOKEN" ] && WP_AUTH=(-H "Authorization: Bearer $WP_TOKEN")
wp_get(){
  curl -sS -m 10 ${WP_AUTH[@]+"${WP_AUTH[@]}"} "$1" 2>/dev/null || echo ''
}

hr "X4 commit/push .woodpecker.yml"
WORK="$TMP/git"; mkdir -p "$WORK"; cd "$WORK" || halt "cd work failed"
git -c init.defaultBranch=main init -q
git remote add origin "$GT/$BOT/$REPO.git"
git -c http.extraHeader="Authorization: Basic $AUTH_B64" pull -q origin "$DEFAULT_BRANCH" --rebase >/dev/null 2>&1 || true

cat > .woodpecker.yml <<'YMLEOF'
steps:
  hello-world:
    image: alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
YMLEOF

git add .woodpecker.yml
COMMIT_NEEDED=no
[ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ] && COMMIT_NEEDED=yes

BLIST="$(wp_get "$WP_PUBLIC/api/repos/$BOT/$REPO/builds")"
EXISTING_BUILD="$(printf '%s' "$BLIST" | json_first_list_field number)"

if [ "$COMMIT_NEEDED" = yes ] || [ -z "$EXISTING_BUILD" ]; then
  if [ "$COMMIT_NEEDED" = no ]; then
    git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q --allow-empty -m "ci: trigger woodpecker $(date -Is)" || halt "empty commit failed"
  else
    git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q -m "ci: woodpecker steel thread" || halt "commit failed"
  fi
  git -c http.extraHeader="Authorization: Basic $AUTH_B64" push -q origin "HEAD:$DEFAULT_BRANCH" || halt "git push failed"
  say "pushed trigger commit"
else
  say "config already present and build already exists; no push"
fi
SHA="$(git rev-parse HEAD)"
say "HEAD SHA=$SHA"

hr "X5 poll build/status"
BUILD_NUM="$EXISTING_BUILD"
FINAL=""
GSTATE=""
for i in $(seq 1 40); do
  BLIST="$(wp_get "$WP_PUBLIC/api/repos/$BOT/$REPO/builds")"
  BN="$(printf '%s' "$BLIST" | json_first_list_field number)"
  [ -n "$BN" ] && BUILD_NUM="$BN"

  if [ -n "$BUILD_NUM" ]; then
    DET="$(wp_get "$WP_PUBLIC/api/repos/$BOT/$REPO/builds/$BUILD_NUM")"
    FINAL="$(printf '%s' "$DET" | json_dict_field status)"
  fi

  ST="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/repos/$BOT/$REPO/commits/$SHA/statuses" 2>/dev/null || echo '[]')"
  GS="$(printf '%s' "$ST" | json_last_list_field status)"
  [ -n "$GS" ] && GSTATE="$GS"
  if [ -z "$BUILD_NUM" ]; then
    BN2="$(printf '%s' "$ST" | build_num_from_statuses)"
    [ -n "$BN2" ] && BUILD_NUM="$BN2"
  fi

  [ -z "$FINAL" ] && FINAL="$GSTATE"
  case "$FINAL" in success|failure|error) break;; esac
  sleep 3
done

say "woodpecker build number=${BUILD_NUM:-none}"
say "woodpecker final status=${FINAL:-unknown}"
say "gitea commit status=${GSTATE:-none}"

hr "X6 retrieve logs / proof"
LOG_PROOF=""
if [ -n "$BUILD_NUM" ]; then
  LOGS_RAW="$(wp_get "$WP_PUBLIC/api/repos/$BOT/$REPO/builds/$BUILD_NUM/logs")"
  LOG_PROOF="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
fi
if [ -z "$LOG_PROOF" ]; then
  LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
fi
if [ -z "$BUILD_NUM" ] && [ -z "$GSTATE" ]; then
  say "--- woodpecker-server recent hook/error logs ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'hook|gitea|error|warn' | tail -20 | redact | sed 's/^/    /' || true
  say "--- woodpecker-agent recent logs ---"
  podman logs --since 3m woodpecker-agent 2>&1 | tail -20 | redact | sed 's/^/    /' || true
fi

hr "X7 result"
PASS_RESULT=no
if [ "$FINAL" = success ] && [ -n "$LOG_PROOF" ]; then
  PASS_RESULT=yes
  say "[RESULT] EX3 COMPLETE - Brick 12 steel thread PASSED."
  say "  repo:  $GT/$BOT/$REPO"
  say "  build: $WP_PUBLIC/$BOT/$REPO/builds/${BUILD_NUM:-?}"
  say "  log proof: $LOG_PROOF"
elif [ "$FINAL" = success ]; then
  PASS_RESULT=green_no_logs
  say "[RESULT] EX3 GREEN BUT LOG API NEEDS TOKEN - build succeeded, logs not anonymously retrievable."
  say "  Create a Woodpecker API token once, then save locally:"
  say "    install -d -m 700 '$SEC'"
  say "    umask 077"
  say "    printf '%s' 'PASTE_TOKEN_HERE' > '$SEC/woodpecker-token'"
  say "  Then re-run EX3."
else
  say "[RESULT] EX3 PARTIAL - final=${FINAL:-unknown} build=${BUILD_NUM:-none} gitea_status=${GSTATE:-none}"
fi

hr "X8 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EX3: healed Gitea bot auth via active/must-change SQL fallback; repo/webhook/push/poll. build=%s final=%s gitea_status=%s log_proof=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$PASS_RESULT" "${BUILD_NUM:-none}" "${FINAL:-unknown}" "${GSTATE:-none}" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
  say "ledger row appended"
fi
exit 0
