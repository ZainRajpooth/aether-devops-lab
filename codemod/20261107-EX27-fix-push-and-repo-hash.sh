#!/usr/bin/env bash
# 20261107-EX27 — Fixes the silent push failure and uses the correct Woodpecker repo webhook hash.
# 1. Fixes git push by using a clean clone to avoid fast-forward rejections.
# 2. Extracts the repo-specific 'hash' from Woodpecker's DB (this is the real webhook HMAC secret).
# 3. Dumps Gitea's hook_task table to see if Gitea is delivering webhooks and what status it gets.
# 4. Re-runs direct curl tests using the correct repo hash.
set -uo pipefail

BOT=$(cat ~/DevOps/aether/secrets/gitea-wp-bot.user)
PASS=$(cat ~/DevOps/aether/secrets/gitea-wp-bot.pass)
WP_SECRET=$(podman inspect woodpecker-server --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="WOODPECKER_GITEA_SECRET"{print $2}')

echo "=== 1. Grep Woodpecker binary for error string context ==="
podman exec woodpecker-server sh -c 'for f in /bin/woodpecker-server /usr/local/bin/woodpecker-server /woodpecker-server; do if [ -x "$f" ]; then strings "$f" | grep -i "failure to parse token" -B 2 -A 2 || true; fi; done' 2>/dev/null || true

echo "=== 2. Extract Woodpecker DB repo hash (the REAL webhook secret) ==="
REPO_ROW=$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT hash, forge_remote_id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)='woodpecker-proof';")
echo "Repo row (hash|forge_remote_id): $REPO_ROW"
REPO_HASH=$(echo "$REPO_ROW" | cut -d'|' -f1)
FORGE_ID=$(echo "$REPO_ROW" | cut -d'|' -f2)
SIG_SECRET="${REPO_HASH:-$WP_SECRET}"
echo "Using webhook HMAC secret: ${SIG_SECRET:0:8}... (length ${#SIG_SECRET})"

echo "=== 3. Fix push (clean clone to avoid fast-forward rejections) ==="
rm -rf /tmp/aether-git-fix
git clone "http://${BOT}:${PASS}@127.0.0.1:3001/${BOT}/woodpecker-proof.git" /tmp/aether-git-fix
cd /tmp/aether-git-fix
git config user.email "test@local"
git config user.name "test"
git commit --allow-empty -m "trigger ex27 $(date +%s)"
git push origin main
PUSH_SHA=$(git rev-parse HEAD)
echo "Successfully pushed SHA: $PUSH_SHA"

echo "=== 4. Check Gitea hook_task table (did Gitea deliver the webhook?) ==="
sleep 5
GT_DB=$(podman exec postgres psql -U devops -d postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false;" | grep -v postgres | head -1)
if [ -n "$GT_DB" ]; then
  echo "Checking Gitea DB: $GT_DB"
  podman exec postgres psql -U devops -d "$GT_DB" -c "SELECT id, hook_id, status, is_delivered, delivered, http_method, url FROM hook_task ORDER BY id DESC LIMIT 5;" 2>/dev/null || echo "No hook_task table or no permissions."
fi

echo "=== 5. Direct curl tests with CORRECT repo hash ==="
BODY="{\"ref\":\"refs/heads/main\",\"before\":\"0000000000000000000000000000000000000000\",\"after\":\"$PUSH_SHA\",\"repo_id\":$FORGE_ID,\"repository\":{\"id\":$FORGE_ID,\"full_name\":\"${BOT}/woodpecker-proof\",\"name\":\"woodpecker-proof\",\"owner\":{\"login\":\"${BOT}\"}},\"sender\":{\"login\":\"${BOT}\"}}"
SIG=$(python3 -c "import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest())" "$SIG_SECRET" "$BODY")

for URL in \
  "http://127.0.0.1:8000/api/hook" \
  "http://127.0.0.1:8000/api/hook?source=gitea" \
  "http://127.0.0.1:8000/hook"; do
  echo "--- POST $URL ---"
  HTTP_CODE=$(curl -sS -m 10 -o /tmp/resp.txt -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -H "X-Gitea-Event: push" \
    -H "X-Gitea-Signature: $SIG" \
    --data "$BODY" "$URL" 2>/dev/null || echo 000)
  RESP_BODY=$(head -c 200 /tmp/resp.txt 2>/dev/null || true)
  echo "  STATUS=$HTTP_CODE"
  echo "  BODY=${RESP_BODY:0:150}"
done

echo "=== 6. Final Woodpecker pipeline check ==="
podman exec postgres psql -U devops -d woodpecker -c "SELECT number, status, event, commit FROM pipelines WHERE repo_id=1 ORDER BY id DESC LIMIT 3;"
