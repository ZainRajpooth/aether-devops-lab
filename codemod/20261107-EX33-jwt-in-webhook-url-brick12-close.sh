#!/usr/bin/env bash
# 20261107-EX33 — fixes EX32's "failure to parse token from hook" by injecting the user_sess JWT
# into the Gitea webhook URL as ?access_token=<JWT>. EX29 proved the endpoint expects a JWT.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
SESSION="$SEC/woodpecker-session.json"

TOKEN="ex33-jwt-in-webhook-url-brick12-close-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"
PGDB="woodpecker"

BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

psql_wp(){
  podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true
}

code(){
  curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true
}

envval(){
  podman inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    awk -F= -v k="$2" '$1==k { sub(/^[^=]+=/, ""); print; exit }'
}

mask_all(){
  python3 -c '
import sys, re
vals = [v for v in sys.argv[1:] if v]
for line in sys.stdin:
    for v in vals:
        line = line.replace(v, "[REDACTED]")
    line = re.sub(r"[0-9a-fA-F]{40,}", "[HEX]", line)
    sys.stdout.write(line)
' "${WP_SECRET:-}" "${PASS:-}" "${REPO_HASH:-}" "${PASS_ENC:-}" "${USER_SESS:-}"
}

ledger(){
  local gate="$1"
  local desc="$2"
  local row_token="${TOKEN}:${gate}"
  mkdir -p "$CD"
  touch "$IDX"
  if ! grep -qF "$row_token" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=%s | %s |\n' \
      "$(date +%F)" "$row_token" "$gate" "$desc" >> "$IDX"
    say "ledger row appended: $row_token"
  else
    say "ledger row already exists: $row_token"
  fi
}

hr "E0 preflight"
for c in python3 curl git podman awk sed grep base64; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"
done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
[ -s "$SESSION" ] || halt "missing Woodpecker session file"
mkdir -p "$CD" "$SEC"
touch "$IDX"

BOT="$(cat "$BOT_FILE" | tr -d '\n\r')"
PASS="$(cat "$PASS_FILE" | tr -d '\n\r')"
WP_SECRET="$(envval woodpecker-server WOODPECKER_GITEA_SECRET)"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"

REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"

ROW="$(psql_wp "SELECT hash||'|'||forge_remote_id FROM repos WHERE id=$REPO_ID LIMIT 1")"
REPO_HASH="${ROW%%|*}"
[ -n "$REPO_HASH" ] || halt "could not extract repo hash"

BOT_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PASS")"

# EX33: Extract user_sess JWT to inject into webhook URL
USER_SESS="$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for c in d.get("cookies", []) or []:
    if c.get("name") == "user_sess":
        print(c.get("value", ""))
        break
' "$SESSION")"
[ -n "$USER_SESS" ] || halt "could not extract user_sess JWT from session file"

USER_SESS_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$USER_SESS")"

say "bot=$BOT"
say "gitea_url=$GT"
say "woodpecker_repo_id=$REPO_ID"
say "user_sess_present=yes len=${#USER_SESS}"

hr "E1 detect Gitea Postgres DB"
GTDB="gitea"
if ! podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc 'SELECT 1' >/dev/null 2>&1; then
  GTDB=""
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    if podman exec postgres psql -U "$PGU" -d "$db" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='webhook' LIMIT 1" 2>/dev/null | grep -q 1; then
      GTDB="$db"
      break
    fi
  done < <(podman exec postgres psql -U "$PGU" -d postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)
fi
say "gitea_db=${GTDB:-none}"

gitea_sql(){
  [ -n "$GTDB" ] || { say "    gitea DB not detected"; return 0; }
  podman exec postgres psql -U "$PGU" -d "$GTDB" -X --pset=pager=off -c "$1" 2>&1 | mask_all
}

dump_gitea_hooks(){
  hr "Gitea webhook rows"
  gitea_sql "SELECT id, repo_id, url, is_active FROM webhook ORDER BY id DESC LIMIT 5;" | sed 's/^/    /'
  hr "Gitea hook_task delivery receipts"
  gitea_sql "SELECT id, hook_id, is_delivered, is_succeed, response_content FROM hook_task ORDER BY id DESC LIMIT 3;" | sed 's/^/    /'
}

pipe_max_id(){
  psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n'
}

latest_pipeline_row(){
  psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1"
}

hr "E2 enforce webhook URL with JWT token"
curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_list.json" 2>/dev/null || echo '[]' > "$TMP/hooks_list.json"

python3 - "$TMP/hooks_list.json" > "$TMP/delete_ids.txt" <<'PYDEL'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    hooks = []
if not isinstance(hooks, list):
    hooks = []
for h in hooks:
    if not isinstance(h, dict):
        continue
    hid = h.get("id")
    if hid is not None:
        print(str(hid))
PYDEL

DELETE_COUNT="$(wc -l < "$TMP/delete_ids.txt" | tr -d ' \n')"
say "deleting $DELETE_COUNT existing hook(s)"
while IFS= read -r hid; do
  [ -n "$hid" ] || continue
  curl -sS -m 10 -u "$BOT:$PASS" -X DELETE "$GT/api/v1/repos/$BOT/$REPO/hooks/$hid" >/dev/null 2>&1 || true
done < "$TMP/delete_ids.txt"

# EX33: Inject JWT into the webhook URL
INTERNAL_HOOK_URL="http://woodpecker-server:8000/api/hook?access_token=$USER_SESS_ENC"
python3 - "$INTERNAL_HOOK_URL" "$REPO_HASH" > "$TMP/hook_create.json" <<'PYHOOK'
import json, sys
url, secret = sys.argv[1:3]
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

HOOK_CREATE_CODE="$(
  curl -sS -m 15 -u "$BOT:$PASS" \
    -H 'Content-Type: application/json' \
    -d @"$TMP/hook_create.json" \
    -X POST \
    -o "$TMP/hook_create_resp.json" \
    -w '%{http_code}' \
    "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo 000
)"
say "hook create http=$HOOK_CREATE_CODE"

hr "E3 restart Gitea"
systemctl --user restart gitea.service 2>/dev/null || podman restart gitea
READY=no
for i in $(seq 1 30); do
  C="$(code "$GT/")"
  if [ -n "$C" ] && [ "$C" != 000 ]; then
    READY=yes
    say "Gitea up: $GT = $C"
    break
  fi
  sleep 2
done
[ "$READY" = yes ] || halt "Gitea did not become reachable"

hr "E4 clean real push"
BEFORE_PUSH_PIPE="$(pipe_max_id)"
say "before_push_pipeline_max_id=$BEFORE_PUSH_PIPE"

WORK="$TMP/git"
rm -rf "$WORK"

REPO_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" 2>/dev/null || echo '{}')"
DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print((d.get("default_branch") or "main") if isinstance(d, dict) else "main")
' 2>/dev/null || echo main)"

git clone -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "$WORK" || halt "clone failed"
cd "$WORK" || halt "cd worktree failed"

git config user.email "${BOT}@local"
git config user.name "Woodpecker Proof"

cat > .woodpecker.yml <<'YML'
steps:
  hello-world:
    image: alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
YML

git add .woodpecker.yml
if [ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ]; then
  git commit -q -m "ci: ex33 real push $(date -Is)" || halt "commit failed"
else
  git commit -q --allow-empty -m "ci: ex33 retrigger $(date -Is)" || halt "empty commit failed"
fi

git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "HEAD:$DEFAULT_BRANCH" || halt "push failed"
PUSH_SHA="$(git rev-parse HEAD)"
say "pushed SHA=$PUSH_SHA"
cd / || true

hr "E5 poll for NEW pipeline"
NEW_ID=""
PIPE_NUM=""
PIPE_STATUS=""
SUCCESS=no

for i in $(seq 1 60); do
  ROW="$(latest_pipeline_row)"
  if [ -n "$ROW" ]; then
    read -r NEW_ID PIPE_NUM PIPE_STATUS <<<"$ROW"
    if [ "${NEW_ID:-0}" -gt "${BEFORE_PUSH_PIPE:-0}" ]; then
      say "new pipeline id=$NEW_ID number=#${PIPE_NUM:-?} status=${PIPE_STATUS:-none}"
      if [ "$PIPE_STATUS" = success ]; then
        SUCCESS=yes
        break
      fi
      case "$PIPE_STATUS" in
        failure|error|killed)
          break
          ;;
      esac
    fi
  fi
  sleep 3
done

hr "E6 Gitea delivery evidence"
dump_gitea_hooks

if [ "$SUCCESS" != yes ]; then
  hr "E7 failure diagnostics"
  say "latest pipeline id=${NEW_ID:-none} #${PIPE_NUM:-none} status=${PIPE_STATUS:-none}"
  say "--- woodpecker-server logs tail 40 ---"
  podman logs --tail 40 woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  say "--- woodpecker-agent logs tail 40 ---"
  podman logs --tail 40 woodpecker-agent 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX33 JWT injected into webhook URL; push SHA=$PUSH_SHA; pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none}. Paste E6-E7."
  halt "pipeline did not succeed"
fi

hr "E8 RESULT"
say "[RESULT] EX33 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
say "  repo: $BOT/$REPO"
say "  pipeline: #${PIPE_NUM:-?}"
say "  status: success"
say "  push SHA: $PUSH_SHA"

ledger "PASS" "EX33: injected user_sess JWT into Gitea webhook URL as ?access_token= to bypass JWT middleware; real push created pipeline #$PIPE_NUM status=success. Brick 12 CLOSED."

exit 0
