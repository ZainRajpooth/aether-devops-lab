#!/usr/bin/env bash
# 20261107-EX34 — definitive Brick 12 closure.
# Stops guessing webhook URLs. Uses saved Playwright session to click "Repair" in the
# Woodpecker UI, forcing Woodpecker to register the correct webhook in Gitea.
# Then pushes and polls DB for success.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
SESSION="$SEC/woodpecker-session.json"

TOKEN="ex34-ui-driven-webhook-repair-brick12-close-v1"
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

mask_all(){
  python3 -c '
import sys, re
vals = [v for v in sys.argv[1:] if v]
for line in sys.stdin:
    for v in vals:
        line = line.replace(v, "[REDACTED]")
    line = re.sub(r"[0-9a-fA-F]{40,}", "[HEX]", line)
    sys.stdout.write(line)
' "${PASS:-}" "${PASS_ENC:-}"
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
for c in python3 curl git podman awk sed grep base64 node; do
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

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"

BOT_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PASS")"

REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"

say "bot=$BOT"
say "gitea_url=$GT"
say "woodpecker_repo_id=$REPO_ID"

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
  hr "Gitea webhook rows (after repair)"
  gitea_sql "SELECT id, repo_id, url, is_active FROM webhook ORDER BY id DESC LIMIT 5;" | sed 's/^/    /'
}

pipe_max_id(){
  psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n'
}

latest_pipeline_row(){
  psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1"
}

hr "E2 write Playwright UI repair script"
cat > "$TMP/repair.mjs" <<'NODEJS_EOF'
import { chromium } from 'playwright';

const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const SESSION = process.env.SESSION_PATH || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';
const REPO_ID = process.env.REPO_ID || '1';

const log = (...a) => console.log('   ', ...a);

const browser = await chromium.launch({ headless: HEADLESS });
const context = await browser.newContext({ storageState: SESSION });
const page = await context.newPage();

page.on('response', async resp => {
  const u = resp.url();
  if (u.includes('/api/')) {
    log('APIRESP', resp.request().method(), resp.status(), u);
  }
});

try {
  log('navigating to repo settings');
  await page.goto(WP + '/repos/wp-ci-bot-1793813218/woodpecker-proof/settings', { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(3000);
  
  if (page.url().includes('/repos/add') || page.url().endsWith('/repos')) {
    log('redirected to repos list, trying to activate via API');
    await page.evaluate(async (id) => {
      await fetch(`/api/repos/${id}`, { method: 'POST', credentials: 'include' });
    }, REPO_ID);
    await page.waitForTimeout(2000);
  }
  
  log('looking for Repair button');
  const repairBtn = page.getByRole('button', { name: /repair/i }).first();
  if (await repairBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
    log('clicking Repair button');
    await repairBtn.click();
    await page.waitForTimeout(4000);
  } else {
    log('Repair button not found in UI, trying direct API call');
    const res = await page.evaluate(async (id) => {
      const r = await fetch(`/api/repos/${id}/repair`, { method: 'POST', credentials: 'include' });
      return { status: r.status, body: await r.text() };
    }, REPO_ID);
    log('API repair result:', res);
  }
  
  await browser.close();
  process.exit(0);
} catch (e) {
  log('FAIL:', e.message);
  await page.screenshot({ path: '/tmp/wp-repair-fail.png' }).catch(() => {});
  await browser.close();
  process.exit(1);
}
NODEJS_EOF

hr "E3 run Playwright UI repair"
REPAIR_RC=0
(
  cd "$TMP" || exit 1
  WP_URL="$WP" SESSION_PATH="$SESSION" PW_HEADLESS="$PW_HEADLESS" REPO_ID="$REPO_ID" node repair.mjs
) 2>&1 | sed 's/^/  /' || REPAIR_RC=$?
say "repair rc=$REPAIR_RC"

hr "E4 verify Gitea webhook state"
dump_gitea_hooks

hr "E5 clean real push"
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
  git commit -q -m "ci: ex34 real push $(date -Is)" || halt "commit failed"
else
  git commit -q --allow-empty -m "ci: ex34 retrigger $(date -Is)" || halt "empty commit failed"
fi

git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "HEAD:$DEFAULT_BRANCH" || halt "push failed"
PUSH_SHA="$(git rev-parse HEAD)"
say "pushed SHA=$PUSH_SHA"
cd / || true

hr "E6 poll for NEW pipeline"
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

hr "E7 final evidence"
dump_gitea_hooks

if [ "$SUCCESS" != yes ]; then
  hr "E8 failure diagnostics"
  say "latest pipeline id=${NEW_ID:-none} #${PIPE_NUM:-none} status=${PIPE_STATUS:-none}"
  say "--- woodpecker-server logs tail 40 ---"
  podman logs --tail 40 woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  say "--- woodpecker-agent logs tail 40 ---"
  podman logs --tail 40 woodpecker-agent 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX34 UI repair attempted (rc=$REPAIR_RC); push SHA=$PUSH_SHA; pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none}. Paste E4-E8."
  halt "pipeline did not succeed"
fi

hr "E9 RESULT"
say "[RESULT] EX34 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
say "  repo: $BOT/$REPO"
say "  pipeline: #${PIPE_NUM:-?}"
say "  status: success"
say "  push SHA: $PUSH_SHA"

ledger "PASS" "EX34: used Playwright to click Repair in Woodpecker UI, forcing native webhook registration in Gitea; real push created pipeline #$PIPE_NUM status=success. Brick 12 CLOSED."

exit 0
