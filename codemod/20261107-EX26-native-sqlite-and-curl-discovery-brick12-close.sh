#!/usr/bin/env bash
# 20261107-EX26 — replaces fragile Python heredocs with native sqlite3 and curl.
# 1) Checks for Gitea SQLite DB first; dumps webhook/hook_task via sqlite3.
# 2) Uses curl + 1-line python for signed webhook discovery (no stdin conflicts).
# 3) Uses sed for redaction (no python heredoc dependencies).
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
SESSION="$SEC/woodpecker-session.json"

TOKEN="ex26-native-sqlite-and-curl-discovery-brick12-close-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"
PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

MODE="${1:-run}"
TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
code(){ curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true; }
envval(){ podman inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= -v k="$2" '$1==k { sub(/^[^=]+=/, ""); print; exit }'; }

redact_text(){
  local s="${WP_SECRET:-}" p="${PASS:-}"
  if [ -n "$s" ] && [ -n "$p" ]; then
    sed "s/$s/[REDACTED]/g; s/$p/[REDACTED]/g" | sed -E 's/[0-9a-fA-F]{40,}/[HEX]/g'
  elif [ -n "$s" ]; then
    sed "s/$s/[REDACTED]/g" | sed -E 's/[0-9a-fA-F]{40,}/[HEX]/g'
  elif [ -n "$p" ]; then
    sed "s/$p/[REDACTED]/g" | sed -E 's/[0-9a-fA-F]{40,}/[HEX]/g'
  else
    sed -E 's/[0-9a-fA-F]{40,}/[HEX]/g'
  fi
}

hr "D0 preflight"
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing bot creds"
BOT="$(cat "$BOT_FILE")"; PASS="$(cat "$PASS_FILE")"
WP_SECRET="$(envval woodpecker-server WOODPECKER_GITEA_SECRET)"
GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
GT="http://127.0.0.1:$GT_HOST_PORT"
CONF="$(podman exec gitea sh -c 'for c in /data/gitea/conf/app.ini /etc/gitea/app.ini; do if [ -f "$c" ]; then echo "$c"; break; fi; done' 2>/dev/null || true)"
REPO_ID="$(psqlq "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
FORGE_REMOTE_ID="$(psqlq "SELECT forge_remote_id FROM repos WHERE id=$REPO_ID LIMIT 1" | tr -d ' \n')"
say "woodpecker_repo_id=$REPO_ID forge_remote_id=${FORGE_REMOTE_ID:-unknown}"

hr "D1 Gitea DB probe (SQLite vs Postgres)"
GT_DB_TYPE="unknown"
GT_DB_PATH=""
if podman exec gitea sh -c 'test -f /data/gitea/gitea.db' 2>/dev/null; then
  GT_DB_TYPE="sqlite"
  GT_DB_PATH="/data/gitea/gitea.db"
  say "gitea_db_type=sqlite path=$GT_DB_PATH"
else
  say "gitea_db_type=postgres (or unknown)"
fi

dump_hooks(){
  if [ "$GT_DB_TYPE" = "sqlite" ]; then
    say "    --- sqlite3 webhook table ---"
    podman exec gitea sqlite3 "$GT_DB_PATH" "SELECT id, repo_id, url, is_active, has_secret FROM webhook ORDER BY id DESC LIMIT 10;" 2>/dev/null | sed 's/^/    /' || say "    sqlite3 query failed"
  else
    say "    (postgres dump skipped/empty)"
  fi
}

dump_new_tasks(){
  if [ "$GT_DB_TYPE" = "sqlite" ]; then
    say "    --- sqlite3 hook_task table (latest 10) ---"
    podman exec gitea sqlite3 "$GT_DB_PATH" "SELECT id, hook_id, status, is_delivered, delivered FROM hook_task ORDER BY id DESC LIMIT 10;" 2>/dev/null | sed 's/^/    /' || say "    sqlite3 query failed"
  fi
}

hr "D2 inspect Gitea config"
podman exec gitea sh -c 'grep -nE "^\[(security|webhook)\]|ALLOWED_HOST_LIST|EGRESS_MODE" "$1"' sh "$CONF" 2>&1 | sed 's/^/    /' | redact_text || true

hr "D3 enforce internal Woodpecker hook"
GOOD_URL="http://woodpecker-server:8000/hook?source=gitea&owner=${BOT}&repo=${REPO}"
# Delete existing
HOOKS_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '[]')"
printf '%s' "$HOOKS_JSON" | python3 -c 'import sys,json; [print(h["id"]) for h in json.load(sys.stdin) if "woodpecker" in h.get("config",{}).get("url","").lower() or "/hook" in h.get("config",{}).get("url","").lower()]' > "$TMP/del_ids.txt" 2>/dev/null
while IFS= read -r hid; do curl -sS -m 10 -u "$BOT:$PASS" -X DELETE "$GT/api/v1/repos/$BOT/$REPO/hooks/$hid" >/dev/null 2>&1; done < "$TMP/del_ids.txt"

# Create new
cat > "$TMP/hook.json" <<PYHOOK
{"type":"gitea","active":true,"events":["push"],"config":{"url":"$GOOD_URL","content_type":"json","secret":"$WP_SECRET"}}
PYHOOK
REAL_CODE="$(curl -sS -m 15 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d @"$TMP/hook.json" -X POST -o /dev/null -w '%{http_code}' "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo 000)"
say "real hook create http=$REAL_CODE"
podman restart gitea
for i in $(seq 1 20); do [ "$(code "$GT/")" != 000 ] && break; sleep 2; done

hr "D4 trigger push"
WORK="$TMP/git"; mkdir -p "$WORK"
AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"
(
  cd "$WORK" || exit 1
  git init -q; git remote add origin "$GT/$BOT/$REPO.git"
  git -c http.extraHeader="Authorization: Basic $AUTH_B64" fetch -q origin main 2>/dev/null || true
  git checkout -q -B ci main 2>/dev/null || git checkout -q -b ci
  cat > .woodpecker.yml <<'YML'
steps:
  hello: { image: alpine, commands: [echo "Hello from Woodpecker CI!", date] }
YML
  git add .; git -c user.email=b@l -c user.name=b commit -q --allow-empty -m "ci trigger $(date +%s)"
  git -c http.extraHeader="Authorization: Basic $AUTH_B64" push -q origin HEAD:main
)
PUSH_SHA="$(cd "$WORK" && git rev-parse HEAD)"
say "pushed SHA=$PUSH_SHA"

hr "D5 poll pipeline"
for i in $(seq 1 20); do
  ROW="$(psqlq "SELECT number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1")"
  [ -n "$ROW" ] && say "pipeline: $ROW" && break
  sleep 3
done

hr "D6 Gitea hook_task diagnostics"
dump_hooks
dump_new_tasks

hr "D7 direct signed endpoint discovery (curl + 1-line python)"
COMMITS_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/commits?limit=2" 2>/dev/null || echo '[]')"
SHA="$(printf '%s' "$COMMITS_JSON" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d[0]["sha"] if isinstance(d,list) and d else "")' 2>/dev/null || true)"
PREV="$(printf '%s' "$COMMITS_JSON" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d[1]["sha"] if isinstance(d,list) and len(d)>1 else "0"*40)' 2>/dev/null || true)"
[ -n "$SHA" ] || SHA="$PUSH_SHA"

BODY="$(python3 -c "import json,sys; print(json.dumps({'ref':'refs/heads/main','before':'$PREV','after':'$SHA','repo_id':$FORGE_REMOTE_ID,'repository':{'id':$FORGE_REMOTE_ID,'full_name':'$BOT/$REPO','name':'$REPO','owner':{'login':'$BOT'}},'sender':{'login':'$BOT'}}))")"

# Compute signature using 1-line python (no stdin conflicts)
SIG=$(python3 -c "import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest())" "$WP_SECRET" "$BODY")

for u in "$WP/api/hook" "$WP/hook" "$WP/api/hook?source=gitea" "$WP/hook?source=gitea"; do
  say "DIRECT_TRY $u"
  HTTP_CODE=$(curl -sS -m 10 -o "$TMP/resp.txt" -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -H "X-Gitea-Event: push" \
    -H "X-Gitea-Signature: $SIG" \
    --data "$BODY" \
    "$u" 2>/dev/null || echo 000)
  RESP_BODY=$(head -c 200 "$TMP/resp.txt" 2>/dev/null || true)
  say "  STATUS=$HTTP_CODE BODY=${RESP_BODY:0:100}"
done

hr "D8 RESULT"
FINAL="$(psqlq "SELECT status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1" | tr -d ' \n')"
if [ "$FINAL" = success ]; then
  say "[RESULT] EX26 COMPLETE - BRICK 12 CLOSED."
  exit 0
else
  say "[RESULT] EX26 PARTIAL - status=${FINAL:-none}. Paste D6, D7."
  exit 1
fi
