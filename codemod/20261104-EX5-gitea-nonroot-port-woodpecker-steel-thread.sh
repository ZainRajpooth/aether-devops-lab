#!/usr/bin/env bash
# 20261104-EX5 — Targeted Brick 12 heal.
# Fixes EX4 findings:
#   1) Gitea is published on 127.0.0.1:3001, not 3000.
#   2) Gitea CLI must not run as root; use -u git or --user 1000:1000.
# Then runs: Gitea bot auth -> repo -> webhook -> push -> Woodpecker build -> logs.
set -uo pipefail

HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ex5-gitea-nonroot-port-woodpecker-steel-thread-v1"

REPO="woodpecker-proof"
WP_PUBLIC="http://127.0.0.1:8000"
WP_INTERNAL="http://woodpecker-server:8000"
BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=""
PGPASS=""

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

redact(){
  awk -v a="$PASS" -v b="$PGPASS" '
    {
      if ((a != "" && index($0, a)) || (b != "" && index($0, b)))
        print "    [REDACTED-LINE]"
      else
        print
    }
  '
}

json_dict_field(){
  local field="$1"
  python3 -c '
import sys, json
field = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    v = d.get(field, "")
    if v is not None:
        print(v)
' "$field" 2>/dev/null || true
}

json_first_list_field(){
  local field="$1"
  python3 -c '
import sys, json
field = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, list) and d and isinstance(d[0], dict):
    v = d[0].get(field, "")
    if v is not None:
        print(v)
' "$field" 2>/dev/null || true
}

json_last_list_field(){
  local field="$1"
  python3 -c '
import sys, json
field = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, list) and d and isinstance(d[-1], dict):
    v = d[-1].get(field, "")
    if v is not None:
        print(v)
' "$field" 2>/dev/null || true
}

build_num_from_statuses(){
  python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, list) and d and isinstance(d[-1], dict):
    u = d[-1].get("target_url", "") or ""
    m = re.search(r"/builds/([0-9]+)", u)
    if m:
        print(m.group(1))
' 2>/dev/null || true
}

hr "X0 preflight"
for c in python3 curl git podman base64 awk sed grep; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done

for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container not present/running: $c"
done

mkdir -p "$SEC"

# Detect real Gitea host port from container publication.
GT_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_PORT" ] || GT_PORT="3001"
GT="http://127.0.0.1:$GT_PORT"
say "detected Gitea URL = $GT"

SV="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WP_PUBLIC/api/version" 2>/dev/null || echo 000)"
say "Woodpecker server API = $SV"
[ "$SV" = 200 ] || halt "Woodpecker server API not reachable at $WP_PUBLIC"

UIDn="$(id -u)"
PODSOCK="/run/user/${UIDn}/podman/podman.sock"
say "host podman socket = $PODSOCK $([ -S "$PODSOCK" ] && echo present || echo absent)"

hr "X1 determine non-root Gitea CLI execution mode"
GITEA_EXEC_ARGS=()

if podman exec -u git gitea id -u >/dev/null 2>&1; then
  GITEA_EXEC_ARGS=(-u git)
  say "Gitea CLI user = git"
elif podman exec --user 1000:1000 gitea id -u >/dev/null 2>&1; then
  GITEA_EXEC_ARGS=(--user 1000:1000)
  say "Gitea CLI user = 1000:1000"
else
  say "--- attempted root CLI for diagnostics ---"
  podman exec gitea gitea admin user list 2>&1 | head -10 | redact | sed 's/^/    /' || true
  halt "could not find a non-root Gitea CLI execution mode"
fi

gitea_admin(){
  podman exec "${GITEA_EXEC_ARGS[@]}" gitea gitea admin "$@"
}

hr "X2 Gitea bot auth: reuse if valid, otherwise create fresh disposable bot"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"

verify_gitea_auth(){
  local user="$1" pass="$2" code login
  PASS="$pass"  # for redact only
  code="$(curl -sS -m 10 -o "$TMP/user.json" -w '%{http_code}' -u "$user:$pass" "$GT/api/v1/user" 2>/dev/null || echo 000)"
  login="$(python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    v = d.get("login", "")
    if v is not None:
        print(v)
' < "$TMP/user.json" 2>/dev/null || true)"
  say "auth probe user=$user code=$code login='${login:-none}'"
  [ "$code" = 200 ] && [ "$login" = "$user" ]
}

ensure_gitea_bot(){
  local user="$1" pass="$2" email="$3"

  say "creating/repairing Gitea bot via non-root CLI: $user"

  # Preferred: create active bot that does not require password change.
  if gitea_admin user create \
      --username "$user" \
      --password "$pass" \
      --email "$email" \
      --admin \
      --active \
      --must-change-password=false >/dev/null 2>&1; then
    say "created with --must-change-password=false"
  else
    # Fallback: create without the optional flag.
    gitea_admin user create \
      --username "$user" \
      --password "$pass" \
      --email "$email" \
      --admin \
      --active || {
        say "--- gitea admin user create failed; recent logs ---"
        podman logs --since 1m gitea 2>&1 | tail -20 | redact | sed 's/^/    /' || true
        halt "gitea admin user create failed"
      }
    say "created without --must-change-password=false"
  fi

  # Ensure password is exactly what we stored and no forced change remains.
  gitea_admin user change-password \
    --username "$user" \
    --password "$pass" \
    --must-change-password=false >/dev/null 2>&1 \
  || gitea_admin user change-password \
    --username "$user" \
    --password "$pass" >/dev/null 2>&1 \
  || true
}

BOT=""
if [ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ]; then
  BOT="$(cat "$BOT_FILE")"
  PASS="$(cat "$PASS_FILE")"
  if verify_gitea_auth "$BOT" "$PASS"; then
    say "reusing existing Gitea bot: $BOT"
  else
    say "existing stored bot failed auth; creating fresh disposable bot"
    BOT=""
  fi
fi

if [ -z "$BOT" ]; then
  BOT="wp-ci-bot-$(date +%s)"
  PASS="WpCi-$(date +%s)-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s\n' "$BOT" > "$BOT_FILE"; chmod 600 "$BOT_FILE"
  printf '%s\n' "$PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"
  say "stored new bot credentials locally: $BOT_FILE / $PASS_FILE"
  ensure_gitea_bot "$BOT" "$PASS" "${BOT}@local"
  verify_gitea_auth "$BOT" "$PASS" || {
    say "--- gitea admin user list grep ---"
    gitea_admin user list 2>&1 | grep -i -- "$BOT" | redact | sed 's/^/    /' || true
    say "--- recent gitea logs ---"
    podman logs --since 2m gitea 2>&1 | tail -40 | redact | sed 's/^/    /' || true
    halt "Gitea bot auth still failed after non-root CLI creation"
  }
fi

say "Gitea bot auth OK user=$BOT"
AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"

hr "X3 Gitea repo"
REPO_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" 2>/dev/null || echo '{}')"
REPO_ID="$(printf '%s' "$REPO_JSON" | json_dict_field id)"

if [ -z "$REPO_ID" ]; then
  python3 - "$REPO" > "$TMP/repo.json" <<'PYREPO'
import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "private": False,
    "auto_init": True,
    "default_branch": "main"
}))
PYREPO

  REPO_JSON="$(curl -sS -m 15 \
    -u "$BOT:$PASS" \
    -H 'Content-Type: application/json' \
    -d @"$TMP/repo.json" \
    -X POST \
    "$GT/api/v1/user/repos" 2>/dev/null || echo '{}')"

  REPO_ID="$(printf '%s' "$REPO_JSON" | json_dict_field id)"
  [ -n "$REPO_ID" ] || {
    say "repo create response: $REPO_JSON"
    halt "could not create repo"
  }
  say "created repo $BOT/$REPO id=$REPO_ID"
else
  say "repo already exists $BOT/$REPO id=$REPO_ID"
fi

DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | json_dict_field default_branch)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
say "default branch=$DEFAULT_BRANCH"

hr "X4 Woodpecker webhook in Gitea"
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
print(json.dumps({
    "type": "gitea",
    "active": True,
    "events": ["push"],
    "config": cfg
}))
PYHOOK

  HOOK_RESP="$(curl -sS -m 15 \
    -u "$BOT:$PASS" \
    -H 'Content-Type: application/json' \
    -d @"$TMP/hook.json" \
    -X POST \
    "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '{}')"

  HOOK_ID="$(printf '%s' "$HOOK_RESP" | json_dict_field id)"
  if [ -n "$HOOK_ID" ]; then
    say "webhook created id=$HOOK_ID"
  else
    say "webhook create response: $HOOK_RESP"
  fi
fi

hr "X5 Woodpecker API auth"
WP_TOKEN=""
[ -s "$SEC/woodpecker-token" ] && WP_TOKEN="$(cat "$SEC/woodpecker-token")"
WP_AUTH=()
[ -n "$WP_TOKEN" ] && WP_AUTH=(-H "Authorization: Bearer $WP_TOKEN")
say "woodpecker token file present: $([ -n "$WP_TOKEN" ] && echo yes || echo no)"

wp_get(){
  curl -sS -m 10 ${WP_AUTH[@]+"${WP_AUTH[@]}"} "$1" 2>/dev/null || echo ''
}

hr "X6 commit/push .woodpecker.yml"
WORK="$TMP/git"
mkdir -p "$WORK"
cd "$WORK" || halt "cd work failed"

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
    git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" \
      commit -q --allow-empty -m "ci: trigger woodpecker $(date -Is)" || halt "empty commit failed"
  else
    git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" \
      commit -q -m "ci: woodpecker steel thread" || halt "commit failed"
  fi

  git -c http.extraHeader="Authorization: Basic $AUTH_B64" \
    push -q origin "HEAD:$DEFAULT_BRANCH" || halt "git push failed"

  say "pushed trigger commit"
else
  say "config already present and build already exists; no push"
fi

SHA="$(git rev-parse HEAD)"
say "HEAD SHA=$SHA"

hr "X7 poll build/status"
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

  ST="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/commits/$SHA/statuses" 2>/dev/null || echo '[]')"
  GS="$(printf '%s' "$ST" | json_last_list_field status)"
  [ -n "$GS" ] && GSTATE="$GS"

  if [ -z "$BUILD_NUM" ]; then
    BN2="$(printf '%s' "$ST" | build_num_from_statuses)"
    [ -n "$BN2" ] && BUILD_NUM="$BN2"
  fi

  [ -z "$FINAL" ] && FINAL="$GSTATE"

  case "$FINAL" in
    success|failure|error) break ;;
  esac

  sleep 3
done

say "woodpecker build number=${BUILD_NUM:-none}"
say "woodpecker final status=${FINAL:-unknown}"
say "gitea commit status=${GSTATE:-none}"

hr "X8 retrieve logs / proof"
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
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'hook|gitea|error|warn' | tail -25 | redact | sed 's/^/    /' || true

  say "--- woodpecker-agent recent logs ---"
  podman logs --since 3m woodpecker-agent 2>&1 | tail -25 | redact | sed 's/^/    /' || true
fi

hr "X9 result"
PASS_RESULT=no

if [ "$FINAL" = success ] && [ -n "$LOG_PROOF" ]; then
  PASS_RESULT=yes
  say "[RESULT] EX5 COMPLETE - Brick 12 steel thread PASSED."
  say "  repo:  $GT/$BOT/$REPO"
  say "  build: $WP_PUBLIC/$BOT/$REPO/builds/${BUILD_NUM:-?}"
  say "  log proof: $LOG_PROOF"
elif [ "$FINAL" = success ]; then
  PASS_RESULT=green_no_logs
  say "[RESULT] EX5 GREEN BUT LOG API NEEDS TOKEN - build succeeded, logs not anonymously retrievable."
  say "  Create a Woodpecker API token once, then save locally:"
  say "    install -d -m 700 '$SEC'"
  say "    umask 077"
  say "    printf '%s' 'PASTE_TOKEN_HERE' > '$SEC/woodpecker-token'"
  say "  Then re-run EX5."
else
  say "[RESULT] EX5 PARTIAL - final=${FINAL:-unknown} build=${BUILD_NUM:-none} gitea_status=${GSTATE:-none}"
fi

hr "X10 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EX5: fixed Gitea port detection and non-root CLI execution; created/verified disposable CI bot; repo/webhook/push/poll. build=%s final=%s gitea_status=%s log_proof=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$PASS_RESULT" "${BUILD_NUM:-none}" "${FINAL:-unknown}" "${GSTATE:-none}" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
  say "ledger row appended"
fi

exit 0
