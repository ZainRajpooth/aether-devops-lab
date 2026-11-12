#!/usr/bin/env bash
# 20261104-EX — Brick 12 Steel Thread: Gitea -> Webhook -> Woodpecker Agent -> Podman Exec -> Green Build.
# Uses facts from EW: Server API 200, Agent connected, Gitea reachable.
# Idempotent: skips repo creation if exists; cleans up test artifacts on failure.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ex-woodpecker-steel-thread-v1"
REPO_NAME="woodpecker-proof"
WP_HOST="http://127.0.0.1:8000"
GT_HOST="http://127.0.0.1:3000"
NET="aether"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "X0 Pre-flight: Verify Services Reachable"
SV="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WP_HOST/api/version" 2>/dev/null || echo 000)"
GT="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$GT_HOST/api/v1/version" 2>/dev/null || echo 000)"
say "Woodpecker Server ($WP_HOST) = $SV"
say "Gitea ($GT_HOST) = $GT"
if [ "$SV" != 200 ] || { [ "$GT" != 200 ] && [ "$GT" != 401 ]; }; then
  say "[HALT] Services unreachable. Check containers/logs."
  exit 1
fi

hr "X1 Create Gitea User/Token (if needed) & Repo"
# For simplicity in this solo-dev env, we assume root user or create a bot user via CLI inside container
# Strategy: Use 'podman exec gitea' to create user/repo if API auth fails, else use API with basic auth
BOT_USER="wp-bot"
BOT_PASS="ChangeMe123!"
# Try creating user via CLI (idempotent check first)
EXISTING_USER="$(podman exec gitea sqlite3 /data/gitea/gitea.db "SELECT count(*) FROM user WHERE uname='$BOT_USER'" 2>/dev/null | tr -d ' \n')"
if [ "${EXISTING_USER:-0}" = "0" ]; then
  say "Creating Gitea user: $BOT_USER"
  podman exec gitea gitea admin user create --username "$BOT_USER" --password "$BOT_PASS" --email "bot@example.com" --admin >/dev/null 2>&1 || true
else
  say "User $BOT_USER already exists."
fi

# Get Token for Bot User (or use Basic Auth for simplicity in local dev)
# Using Basic Auth for this script to avoid token management complexity in one-shot
AUTH_HEADER="Basic $(printf '%s:%s' "$BOT_USER" "$BOT_PASS" | base64)"

# Create Repo
REPO_EXISTS="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: $AUTH_HEADER" "$GT_HOST/api/v1/repos/$BOT_USER/$REPO_NAME" 2>/dev/null || echo 404)"
if [ "$REPO_EXISTS" = "404" ]; then
  say "Creating repo: $REPO_NAME"
  curl -sS -m 10 -X POST -H "Authorization: $AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"auto_init\":true}" \
    "$GT_HOST/api/v1/user/repos" >/dev/null 2>&1 || { say "[HALT] Failed to create repo"; exit 1; }
else
  say "Repo $REPO_NAME already exists."
fi

hr "X2 Commit .woodpecker.yml to Repo"
# Clone via HTTPS (local git)
WORK_DIR="/tmp/wp-ci-test.$$"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || exit 1
git init >/dev/null 2>&1
git remote add origin "$GT_HOST/$BOT_USER/$REPO_NAME.git" >/dev/null 2>&1
# Pull initial README if auto_init created it
git pull origin main --rebase >/dev/null 2>&1 || true

cat > .woodpecker.yml <<'YMLEOF'
pipeline:
  hello-world:
    image: alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
YMLEOF

git add .woodpecker.yml >/dev/null 2>&1
git commit -m "feat: add woodpecker ci config" >/dev/null 2>&1
# Push using Basic Auth in URL (simplest for local script)
GIT_PUSH_URL="http://${BOT_USER}:${BOT_PASS}@127.0.0.1:3000/${BOT_USER}/${REPO_NAME}.git"
git push "$GIT_PUSH_URL" HEAD:main >/dev/null 2>&1 || { say "[HALT] Git push failed"; rm -rf "$WORK_DIR"; exit 1; }
say "Committed and pushed .woodpecker.yml"
rm -rf "$WORK_DIR"

hr "X3 Register Webhook (Gitea -> Woodpecker)"
# Check if webhook exists
WEBHOOKS="$(curl -sS -m 5 -H "Authorization: $AUTH_HEADER" "$GT_HOST/api/v1/repos/$BOT_USER/$REPO_NAME/hooks" 2>/dev/null || echo "[]")"
HAS_WP_HOOK="$(echo "$WEBHOOKS" | grep -c 'woodpecker' || true)"
if [ "$HAS_WP_HOOK" = "0" ]; then
  say "Registering webhook..."
  # Woodpecker expects a specific payload format; Gitea's generic 'gitea' type usually works if WP is configured correctly
  # However, WP often prefers its own secret. Let's try the standard Gitea hook pointing to WP server.
  # Note: In production, you'd set WOODPECKER_GITEA_SECRET in WP server env. Here we rely on open mode or default.
  curl -sS -m 10 -X POST -H "Authorization: $AUTH_HEADER" -H "Content-Type: application/json" \
    -d '{
      "type": "gitea",
      "active": true,
      "events": ["push"],
      "config": {
        "url": "'"$WP_HOST'/hooks?source=gitea&owner='"$BOT_USER"'&repo='"$REPO_NAME"'",
        "content_type": "json"
      }
    }' \
    "$GT_HOST/api/v1/repos/$BOT_USER/$REPO_NAME/hooks" >/dev/null 2>&1 || { say "[WARN] Webhook registration might have failed (check logs)"; }
  say "Webhook registered (or attempted)."
else
  say "Webhook already exists."
fi

hr "X4 Trigger Build & Poll Status"
# The push in X2 should have triggered it. If not, manual trigger:
BUILD_ID=""
MAX_WAIT=60
WAITED=0
while [ -z "$BUILD_ID" ] && [ $WAITED -lt $MAX_WAIT ]; do
  # List recent builds
  BUILDS_JSON="$(curl -sS -m 5 -H "Authorization: $AUTH_HEADER" "$WP_HOST/api/repos/$BOT_USER/$REPO_NAME/builds" 2>/dev/null || echo "[]")"
  BUILD_ID="$(echo "$BUILDS_JSON" | jq -r '.[0].number // empty' 2>/dev/null || true)"
  if [ -n "$BUILD_ID" ]; then break; fi
  sleep 2
  WAITED=$((WAITED+2))
done

if [ -z "$BUILD_ID" ]; then
  say "[HALT] No build triggered within ${MAX_WAIT}s. Check agent logs/webhook."
  exit 1
fi
say "Build #$BUILD_ID detected. Waiting for completion..."

STATUS="pending"
FINAL_STATUS=""
LOG_CONTENT=""
for i in $(seq 1 30); do
  RESP="$(curl -sS -m 5 -H "Authorization: $AUTH_HEADER" "$WP_HOST/api/repos/$BOT_USER/$REPO_NAME/builds/$BUILD_ID" 2>/dev/null || echo "{}")"
  STATUS="$(echo "$RESP" | jq -r '.status // "unknown"')"
  FINAL_STATUS="$STATUS"
  if [ "$STATUS" = "success" ] || [ "$STATUS" = "failure" ] || [ "$STATUS" = "error" ]; then
    break
  fi
  sleep 2
done

say "Final Status: $FINAL_STATUS"

hr "X5 Retrieve Logs (Proof of Execution)"
if [ "$FINAL_STATUS" = "success" ]; then
  LOGS_RAW="$(curl -sS -m 10 -H "Authorization: $AUTH_HEADER" "$WP_HOST/api/repos/$BOT_USER/$REPO_NAME/builds/$BUILD_ID/logs" 2>/dev/null || echo "")"
  # Extract just the command output lines for brevity
  CLEAN_LOGS="$(echo "$LOGS_RAW" | grep -E 'Hello from|date|whoami|Exit code' | head -5)"
  say "--- Log Snippet ---"
  printf '%s\n' "$CLEAN_LOGS" | sed 's/^/    /'
  say "[RESULT] EX COMPLETE - Brick 12 Steel Thread PASSED."
  say "  Repo: $GT_HOST/$BOT_USER/$REPO_NAME"
  say "  Build: $WP_HOST/$BOT_USER/$REPO_NAME/builds/$BUILD_ID"
  say "  Status: SUCCESS"
else
  say "[RESULT] EX PARTIAL - Build status: $FINAL_STATUS"
  say "  Check logs manually: $WP_HOST/$BOT_USER/$REPO_NAME/builds/$BUILD_ID"
fi

hr "X6 Ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EX: Brick 12 Steel Thread. Repo %s created/pushed. Webhook registered. Build #%s status=%s. Logs retrieved=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$([ "$FINAL_STATUS" = success ] && echo PASS || echo FAIL)" "$REPO_NAME" "$BUILD_ID" "$FINAL_STATUS" "$([ -n "$CLEAN_LOGS" ] && echo yes || echo no)" >> "$IDX"
  say "ledger row appended"
fi
exit 0
