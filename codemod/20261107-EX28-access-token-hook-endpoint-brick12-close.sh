#!/usr/bin/env bash
# 20261107-EX28 — final Brick 12 closure.
#
# EX27 proved:
#   - repo hash exists and is the real per-repo webhook token/secret;
#   - /api/hook requires access_token;
#   - current Gitea hook URL /hook?source=... hits frontend HTML, not API.
#
# EX28:
#   1) extracts repo hash safely;
#   2) discovers working Woodpecker hook endpoint using access_token variants;
#   3) replaces Gitea webhook with internal woodpecker-server URL;
#   4) restarts Gitea;
#   5) clean real push;
#   6) polls Woodpecker Postgres for a NEW pipeline success;
#   7) dumps Gitea webhook/hook_task diagnostics from the correct gitea DB.
#
# No Woodpecker quadlet change. No gRPC change. No DB mutation. Secrets masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
SESSION="$SEC/woodpecker-session.json"

TOKEN="ex28-access-token-hook-endpoint-brick12-close-v1"
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
  python3 - "${WP_SECRET:-}" "${PASS:-}" "${REPO_HASH:-}" "${TOKEN_ENC:-}" <<'PYMASK'
import sys, re
vals = [v for v in sys.argv[1:] if v]
for line in sys.stdin:
    for v in vals:
        line = line.replace(v, '[REDACTED]')
    line = re.sub(r'[0-9a-fA-F]{40,}', '[HEX]', line)
    sys.stdout.write(line)
PYMASK
}

mask_str(){
  printf '%s\n' "$1" | mask_all
}

cookies_from_session(){
  [ -s "$SESSION" ] || return 0
  python3 - "$SESSION" <<'PYCOOKIE'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
parts = []
for c in d.get("cookies", []) or []:
    dom = (c.get("domain") or "").lstrip(".")
    if dom in ("127.0.0.1", "localhost", ""):
        parts.append(f"{c.get('name')}={c.get('value')}")
print("; ".join(parts))
PYCOOKIE
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
mkdir -p "$CD" "$SEC"
touch "$IDX"

BOT="$(cat "$BOT_FILE")"
PASS="$(cat "$PASS_FILE")"
WP_SECRET="$(envval woodpecker-server WOODPECKER_GITEA_SECRET)"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"

REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"

ROW="$(psql_wp "SELECT hash||'|'||forge_remote_id FROM repos WHERE id=$REPO_ID LIMIT 1")"
REPO_HASH="${ROW%%|*}"
FORGE_ID="${ROW##*|}"
[ -n "$REPO_HASH" ] || halt "could not extract repo hash"
[ -n "$FORGE_ID" ] || halt "could not extract forge_remote_id"

TOKEN_ENC="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$REPO_HASH")"

say "bot=$BOT"
say "gitea_url=$GT"
say "woodpecker_url=$WP"
say "woodpecker_repo_id=$REPO_ID forge_remote_id=$FORGE_ID"
say "repo_hash_mask=$(mask_str "${REPO_HASH:0:6}...len=${#REPO_HASH}")"

hr "E1 detect Gitea Postgres DB for hook diagnostics"
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
  gitea_sql "SELECT id, repo_id, url, http_method, content_type, is_active, type FROM webhook ORDER BY id DESC LIMIT 10;" | sed 's/^/    /'
  hr "Gitea hook_task rows"
  gitea_sql "SELECT * FROM hook_task ORDER BY id DESC LIMIT 10;" | sed 's/^/    /'
}

dump_wp_logs(){
  say "--- woodpecker-server logs tail 120 ---"
  podman logs --tail 120 woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
}

dump_agent_logs(){
  say "--- woodpecker-agent logs tail 120 ---"
  podman logs --tail 120 woodpecker-agent 2>&1 | mask_all | sed 's/^/    /' || true
}

pipe_max_id(){
  psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n'
}

latest_pipeline_row(){
  psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1"
}

hr "E2 build realistic Gitea push payload"
REPO_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" 2>/dev/null || echo '{}')"
DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print((d.get("default_branch") or "main") if isinstance(d, dict) else "main")
' 2>/dev/null || echo main)"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"

COMMITS_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/commits?limit=2" 2>/dev/null || echo '[]')"
read -r SHA PREV <<EOF2
$(printf '%s' "$COMMITS_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
sha = ""
prev = "0"*40
if isinstance(d, list):
    if len(d) > 0 and isinstance(d[0], dict):
        sha = d[0].get("sha", "")
    if len(d) > 1 and isinstance(d[1], dict):
        prev = d[1].get("sha", prev)
print(sha, prev)
' 2>/dev/null)
EOF2

[ -n "$SHA" ] || halt "could not resolve latest commit SHA from Gitea API"
say "default_branch=$DEFAULT_BRANCH sha=${SHA:0:8}... prev=${PREV:0:8}..."

python3 - "$BOT" "$REPO" "$FORGE_ID" "$DEFAULT_BRANCH" "$SHA" "$PREV" > "$TMP/body.json" <<'PYBODY'
import json, sys
owner, repo, forge_id, branch, sha, prev = sys.argv[1:7]
rid = int(forge_id) if str(forge_id).isdigit() else forge_id
full = f"{owner}/{repo}"
print(json.dumps({
    "ref": f"refs/heads/{branch}",
    "before": prev,
    "after": sha,
    "repo_id": rid,
    "repository": {
        "id": rid,
        "full_name": full,
        "name": repo,
        "owner": {"login": owner},
        "clone_url": f"http://gitea:3000/{full}.git",
        "html_url": f"http://gitea:3000/{full}",
        "private": False,
        "fork": False
    },
    "sender": {"login": owner},
    "pusher": {"name": owner, "email": f"{owner}@local"},
    "commits": [
        {
            "id": sha,
            "message": "ci: ex28 endpoint discovery",
            "timestamp": "2026-11-07T00:00:00Z"
        }
    ],
    "total_commits": 1
}))
PYBODY

SIG_REPO="$(python3 -c '
import hmac, hashlib, sys
secret = sys.argv[1].encode()
body = open(sys.argv[2], "rb").read()
print(hmac.new(secret, body, hashlib.sha256).hexdigest())
' "$REPO_HASH" "$TMP/body.json")"

SIG_GLOBAL="$(python3 -c '
import hmac, hashlib, sys
secret = sys.argv[1].encode()
body = open(sys.argv[2], "rb").read()
print(hmac.new(secret, body, hashlib.sha256).hexdigest())
' "${WP_SECRET:-}" "$TMP/body.json")"

say "payload bytes=$(wc -c < "$TMP/body.json" | tr -d ' ')"

hr "E3 discover working hook endpoint via access_token variants"
WORKING_URL=""
WORKING_MODE=""

attempt(){
  local url="$1"
  local mode="$2"
  local before after http body_snippet

  before="$(pipe_max_id)"

  local args=(
    -sS -m 15
    -o "$TMP/resp.txt"
    -w '%{http_code}'
    -X POST
    -H 'Content-Type: application/json'
    -H 'X-Gitea-Event: push'
    -H "X-Gitea-Delivery: ex28-$(date +%s%N)-$RANDOM"
    --data @"$TMP/body.json"
  )

  case "$mode" in
    repo)
      args+=(
        -H "X-Gitea-Signature: $SIG_REPO"
        -H "X-Hub-Signature-256: sha256=$SIG_REPO"
      )
      ;;
    global)
      args+=(
        -H "X-Gitea-Signature: $SIG_GLOBAL"
        -H "X-Hub-Signature-256: sha256=$SIG_GLOBAL"
      )
      ;;
    none)
      ;;
  esac

  say "TRY mode=$mode url=$(mask_str "$url")"
  http="$(curl "${args[@]}" "$url" 2>"$TMP/curl.err" || true)"
  [ -n "$http" ] || http=000

  body_snippet="$(head -c 220 "$TMP/resp.txt" 2>/dev/null | tr '\n\r' '  ' | mask_all || true)"
  say "  STATUS=$http BODY=${body_snippet:-}"

  if [ "$http" != 000 ]; then
    after="$(pipe_max_id)"
    if [ "${after:-0}" -le "${before:-0}" ]; then
      sleep 2
      after="$(pipe_max_id)"
    fi
    if [ "${after:-0}" -gt "${before:-0}" ]; then
      say "  NEW_PIPELINE_INGESTED id_before=$before id_after=$after"
      WORKING_URL="$url"
      WORKING_MODE="$mode"
      return 0
    fi
  else
    say "  CURL_ERR=$(head -c 200 "$TMP/curl.err" 2>/dev/null | mask_all || true)"
  fi

  # Small evidence hint on failure.
  podman logs --tail 20 woodpecker-server 2>&1 |
    grep -iE 'hook|token|failure|signature|error|warn' |
    tail -3 |
    mask_all |
    sed 's/^/    wp: /' || true

  return 1
}

CANDIDATES=(
  "$WP/api/hook?access_token=$TOKEN_ENC"
  "$WP/api/hook?access_token=$TOKEN_ENC&source=gitea"
  "$WP/api/hook?access_token=$TOKEN_ENC&source=gitea&branch=$DEFAULT_BRANCH"
  "$WP/api/hook?token=$TOKEN_ENC"
  "$WP/api/hook?hook_token=$TOKEN_ENC"
  "$WP/hook?access_token=$TOKEN_ENC"
  "$WP/hook?access_token=$TOKEN_ENC&source=gitea"
)

for u in "${CANDIDATES[@]}"; do
  for mode in none repo global; do
    if attempt "$u" "$mode"; then
      break 2
    fi
  done
done

if [ -z "$WORKING_URL" ]; then
  hr "E4 endpoint discovery failed"
  dump_wp_logs
  dump_gitea_hooks
  ledger "PARTIAL" "EX28 could not discover working hook endpoint. Paste E3 attempts + E4 diagnostics."
  halt "no working hook endpoint discovered"
fi

say "WORKING_ENDPOINT=$(mask_str "$WORKING_URL")"
say "WORKING_MODE=$WORKING_MODE"

hr "E5 convert working endpoint to internal Gitea-reachable URL"
INTERNAL_WP="http://woodpecker-server:8000"
if [[ "$WORKING_URL" == "$WP"* ]]; then
  HOOK_URL="${WORKING_URL/$WP/$INTERNAL_WP}"
else
  HOOK_URL="$WORKING_URL"
fi

case "$WORKING_MODE" in
  repo) HOOK_SECRET="$REPO_HASH" ;;
  global) HOOK_SECRET="$WP_SECRET" ;;
  *) HOOK_SECRET="" ;;
esac

say "internal_hook_url=$(mask_str "$HOOK_URL")"
say "hook_secret_present=$([ -n "$HOOK_SECRET" ] && echo yes || echo no)"

hr "E6 replace Gitea webhook with correct internal endpoint"
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
    cfg = h.get("config") or {}
    url = (cfg.get("url") or "").lower()
    if (
        "woodpecker" in url
        or "/api/hook" in url
        or "/hook" in url
        or "access_token=" in url
        or "token=" in url
    ):
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

python3 - "$HOOK_URL" "$HOOK_SECRET" > "$TMP/hook_create.json" <<'PYHOOK'
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
say "--- hook create response, masked ---"
mask_all < "$TMP/hook_create_resp.json" | sed 's/^/    /' || true

curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_verify.json" 2>/dev/null || echo '[]' > "$TMP/hooks_verify.json"

if ! python3 - "$TMP/hooks_verify.json" "$HOOK_URL" <<'PYVERIFY'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
want = sys.argv[2]
if not isinstance(hooks, list):
    sys.exit(1)
for h in hooks:
    if not isinstance(h, dict):
        continue
    url = ((h.get("config") or {}).get("url") or "").replace("&amp;", "&")
    if url == want:
        sys.exit(0)
sys.exit(1)
PYVERIFY
then
  say "--- hooks verify, masked ---"
  mask_all < "$TMP/hooks_verify.json" | sed 's/^/    /' || true
  halt "correct internal hook was not present after enforcement"
fi
say "correct internal hook enforced"

hr "E7 restart Gitea to load hook cache"
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
[ "$READY" = yes ] || halt "Gitea did not become reachable after restart"

hr "E8 clean real push"
BEFORE_PUSH_PIPE="$(pipe_max_id)"
say "before_push_pipeline_max_id=$BEFORE_PUSH_PIPE"

WORK="$TMP/git"
rm -rf "$WORK"
AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"

git -c http.extraHeader="Authorization: Basic $AUTH_B64" clone -q "$GT/$BOT/$REPO.git" "$WORK" || halt "clone failed"
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
  git commit -q -m "ci: ex28 real push $(date -Is)" || halt "commit failed"
else
  git commit -q --allow-empty -m "ci: ex28 retrigger $(date -Is)" || halt "empty commit failed"
fi

git -c http.extraHeader="Authorization: Basic $AUTH_B64" push -q origin "HEAD:$DEFAULT_BRANCH" || halt "push failed"
PUSH_SHA="$(git rev-parse HEAD)"
say "pushed SHA=$PUSH_SHA"
cd / || true

hr "E9 poll for NEW pipeline after real push"
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

if [ "$SUCCESS" != yes ]; then
  hr "E10 failure diagnostics"
  say "latest pipeline id=${NEW_ID:-none} #${PIPE_NUM:-none} status=${PIPE_STATUS:-none}"
  if [ -n "${NEW_ID:-}" ]; then
    ERR1="$(psql_wp "SELECT COALESCE(error,'') FROM pipelines WHERE id=$NEW_ID" | tr '\n' ' ')"
    ERR2="$(psql_wp "SELECT COALESCE(errors::text,'') FROM pipelines WHERE id=$NEW_ID" | tr '\n' ' ')"
    say "pipeline_error=${ERR1:-${ERR2:-none}}"
  fi
  dump_wp_logs
  dump_agent_logs
  dump_gitea_hooks
  ledger "PARTIAL" "EX28 working endpoint discovered ($(mask_str "$WORKING_URL")) mode=$WORKING_MODE; hook enforced; push SHA=$PUSH_SHA; pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none}. Paste E9-E10."
  halt "pipeline did not succeed"
fi

hr "E11 best-effort log proof"
LOG_PROOF=""
CK="$(cookies_from_session)"
if [ -n "$CK" ] && [ -n "$PIPE_NUM" ]; then
  for path in \
    "$WP/api/repos/$BOT/$REPO/pipelines/$PIPE_NUM/logs" \
    "$WP/api/repos/$BOT/$REPO/builds/$PIPE_NUM/logs"; do
    LOGS_RAW="$(curl -sS -m 15 -b "$CK" "$path" 2>/dev/null || true)"
    HIT="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
    if [ -n "$HIT" ]; then
      LOG_PROOF="$HIT"
      break
    fi
  done
fi
if [ -z "$LOG_PROOF" ]; then
  LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
fi
say "log proof: ${LOG_PROOF:-none (DB success is the gate)}"

hr "E12 final Gitea delivery evidence"
dump_gitea_hooks

hr "E13 RESULT"
say "[RESULT] EX28 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
say "  repo: $BOT/$REPO"
say "  woodpecker_repo_id: $REPO_ID"
say "  working_endpoint: $(mask_str "$WORKING_URL")"
say "  working_mode: $WORKING_MODE"
say "  internal_hook_url: $(mask_str "$HOOK_URL")"
say "  pipeline: #${PIPE_NUM:-?}"
say "  status: success"
say "  push SHA: $PUSH_SHA"
say "  log proof: ${LOG_PROOF:-n/a}"

ledger "PASS" "EX28: discovered Woodpecker hook endpoint requiring access_token repo hash; replaced bad /hook frontend URL with internal /api/hook?access_token=...; real push created pipeline #$PIPE_NUM status=success; log_proof=$([ -n "$LOG_PROOF" ] && echo yes || echo no). Brick 12 CLOSED."

exit 0
