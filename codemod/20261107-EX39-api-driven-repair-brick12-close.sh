#!/usr/bin/env bash
# 20261107-EX39 — definitive Brick 12 closure via API-driven repair.
# Grants admin to bot by login name, restarts WP, uses Playwright page.evaluate to call
# the repair API directly (bypassing UI selector issues), verifies webhook, pushes, gates on DB.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
APP="$HOME_/DevOps/aether/apps/playwright"
IDX="$CD/INDEX.md"

TOKEN="ex39-api-driven-repair-brick12-close-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"
PGDB="woodpecker"

BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

PW_HEADLESS="${PW_HEADLESS:-1}"
MODE="${1:-run}"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

psql_wp(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
gitea_sql_raw(){ podman exec postgres psql -U "$PGU" -d gitea -tAc "$1" 2>/dev/null || true; }

mask_all(){
  python3 -c '
import sys, re
vals = [v for v in sys.argv[1:] if v]
for line in sys.stdin:
    for v in vals: line = line.replace(v, "[REDACTED]")
    line = re.sub(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}", "[JWT]", line)
    line = re.sub(r"[0-9a-fA-F]{40,}", "[HEX]", line)
    sys.stdout.write(line)
' "${PASS:-}" "${PASS_ENC:-}"
}

pipe_max_id(){ psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n'; }
latest_pipeline_row(){ psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1"; }

ledger(){
  local gate="$1" desc="$2" row_token="${TOKEN}:${1}"
  mkdir -p "$CD"; touch "$IDX"
  if ! grep -qF "$row_token" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$row_token" "$gate" "$desc" >> "$IDX"
    say "ledger row appended: $row_token"
  fi
}

hr "X0 preflight"
for c in python3 curl git podman awk sed grep base64 node; do command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"; done
for c in woodpecker-server woodpecker-agent gitea postgres; do podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"; done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
mkdir -p "$CD" "$SEC" "$APP"; touch "$IDX"

BOT="$(cat "$BOT_FILE" | tr -d '\n\r')"
PASS="$(cat "$PASS_FILE" | tr -d '\n\r')"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"

REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"

BOT_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PASS")"

BOT_SQL="${BOT//\'/\'\'}"
say "bot=$BOT gitea_url=$GT woodpecker_repo_id=$REPO_ID"

if [ "$MODE" = check ]; then hr "X1 plan"; say "1) Grant admin by login 2) Restart WP 3) Playwright OAuth + API repair 4) Verify webhook 5) Push 6) DB gate"; say "[RESULT] EX39 CHECK"; exit 0; fi

hr "X1 grant Woodpecker admin to bot by login name and restart"
psql_wp "UPDATE users SET admin = true WHERE login = '$BOT_SQL';" >/dev/null
say "granted admin to bot login=$BOT"
systemctl --user restart woodpecker-server.service 2>/dev/null || podman restart woodpecker-server
say "restarting woodpecker-server..."

WP_UP=no
for i in $(seq 1 40); do
  C="$(curl -sS -m 2 -o /dev/null -w '%{http_code}' "$WP/api/user" 2>/dev/null || echo 000)"
  if [ "$C" = 200 ] || [ "$C" = 401 ]; then WP_UP=yes; say "woodpecker-server up: $WP = $C"; break; fi
  sleep 2
done
[ "$WP_UP" = yes ] || halt "woodpecker-server not reachable after restart"

hr "X2 Playwright OAuth login + API-driven Repair"
cat > "$APP/wp-repair-api.mjs" <<'NODE39EOF'
import { chromium } from 'playwright';
const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const BOT = process.env.BOT_USER || '';
const PASS = process.env.BOT_PASS || '';
const REPO_ID = process.env.REPO_ID || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';
const log = (...a) => console.log('   ', ...a);

const browser = await chromium.launch({ headless: HEADLESS });
const context = await browser.newContext();
const page = await context.newPage();
page.on('response', async resp => { try { if (resp.url().includes('/api/')) log('APIRESP', resp.request().method(), resp.status(), resp.url()); } catch {} });

try {
  log('navigating to WP login');
  await page.goto(WP + '/login', { waitUntil: 'domcontentloaded', timeout: 30000 });
  
  const giteaBtn = page.getByRole('button', { name: /gitea/i }).first();
  await giteaBtn.waitFor({ state: 'visible', timeout: 10000 });
  log('clicking Gitea login button');
  await giteaBtn.click();

  log('waiting for Gitea login page');
  await page.waitForURL(/gitea:3000/, { timeout: 15000 });
  await page.fill('input[name="user_name"]', BOT);
  await page.fill('input[name="password"]', PASS);
  await page.getByRole('button', { name: /^\s*sign\s+in\s*$/i }).click();

  try {
    await page.waitForURL(/\/authorize/, { timeout: 10000 });
    const authBtn = page.getByRole('button', { name: /authorize|grant|allow|approve/i }).first();
    if (await authBtn.isVisible()) { log('clicking Authorize'); await authBtn.click(); }
  } catch (e) { log('no consent page, already authorized'); }

  await page.waitForURL(/127\.0\.0\.1:8000/, { timeout: 15000 });
  log('logged into Woodpecker successfully');

  log('navigating to repo settings to warm up session');
  await page.goto(`${WP}/repos/${BOT}/woodpecker-proof/settings`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(2000);

  log('attempting API repair via page context');
  const repairResult = await page.evaluate(async (repoId) => {
    const endpoints = [
      `/api/repos/${repoId}/repair`,
      `/api/repos/${repoId}`
    ];
    for (const ep of endpoints) {
      try {
        const r = await fetch(ep, { method: 'POST', credentials: 'include' });
        const text = await r.text();
        if (r.ok || r.status === 204) {
          return { success: true, endpoint: ep, status: r.status, text: text.substring(0, 200) };
        }
      } catch (e) {}
    }
    return { success: false };
  }, REPO_ID);
  
  log('API repair result:', JSON.stringify(repairResult));
  
  if (!repairResult.success) {
    log('API repair failed, attempting UI button click fallback');
    const btns = await page.getByRole('button').allTextContents().catch(() => []);
    log('buttons on page:', JSON.stringify(btns));
    const repairBtn = page.locator('button[aria-label*="repair" i], button[title*="repair" i], button[aria-label*="refresh" i]').first();
    if (await repairBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
      log('found icon repair button, clicking');
      await repairBtn.click();
      await page.waitForTimeout(4000);
    } else {
      log('no repair button found via API or UI');
      await page.screenshot({ path: '/tmp/wp-repair-api-fail.png' });
      await browser.close(); process.exit(1);
    }
  }

  await browser.close(); process.exit(0);
} catch (e) {
  log('FAIL:', String(e && e.message || e));
  await page.screenshot({ path: '/tmp/wp-repair-api-fail.png' }).catch(() => {});
  await browser.close(); process.exit(1);
}
NODE39EOF
chmod 600 "$APP/wp-repair-api.mjs"

UI_RC=0
( cd "$APP" || exit 1; WP_URL="$WP" BOT_USER="$BOT" BOT_PASS="$PASS" REPO_ID="$REPO_ID" PW_HEADLESS="$PW_HEADLESS" node wp-repair-api.mjs ) 2>&1 | sed 's/^/  /' || UI_RC=$?
say "playwright repair rc=$UI_RC"
[ "$UI_RC" = 0 ] || halt "Playwright repair failed"

hr "X3 verify webhook creation in Gitea"
WEBHOOK_COUNT="$(gitea_sql_raw "SELECT COUNT(*) FROM webhook WHERE repo_id=2" | tr -d ' \n')"
say "gitea webhook_count=$WEBHOOK_COUNT"
if [ "${WEBHOOK_COUNT:-0}" -eq 0 ]; then
  say "--- woodpecker-server logs tail 20 ---"
  podman logs --tail 20 woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  halt "webhook not created after repair"
fi
gitea_sql_raw "SELECT id, repo_id, url, is_active FROM webhook WHERE repo_id=2 ORDER BY id DESC LIMIT 1;" | mask_all | sed 's/^/    /' || true

hr "X4 clean real push"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BEFORE_PUSH_PIPE="$(pipe_max_id)"
WORK="$TMP/git"; rm -rf "$WORK"

git clone -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "$WORK" || halt "clone failed"
cd "$WORK" || halt "cd worktree failed"
git config user.email "${BOT}@local"; git config user.name "Woodpecker Proof"

cat > .woodpecker.yml <<'YML'
steps:
  - name: hello-world
    image: alpine:latest
    commands: [ 'echo "Hello from Woodpecker CI!"', 'date', 'whoami' ]
YML

git add .woodpecker.yml
[ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ] && git commit -q -m "ci: ex39 real push $(date -Is)" || git commit -q --allow-empty -m "ci: ex39 retrigger $(date -Is)"
git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_HOST_PORT/$BOT/$REPO.git" "HEAD:main" || halt "push failed"
PUSH_SHA="$(git rev-parse HEAD)"; say "pushed SHA=$PUSH_SHA"; cd / || true

hr "X5 poll for NEW pipeline"
NEW_ID=""; PIPE_NUM=""; PIPE_STATUS=""; SUCCESS=no
for i in $(seq 1 60); do
  ROW="$(latest_pipeline_row)"
  if [ -n "$ROW" ]; then
    read -r NEW_ID PIPE_NUM PIPE_STATUS <<<"$ROW"
    if [ "${NEW_ID:-0}" -gt "${BEFORE_PUSH_PIPE:-0}" ]; then
      say "new pipeline id=$NEW_ID number=#${PIPE_NUM:-?} status=${PIPE_STATUS:-none}"
      if [ "$PIPE_STATUS" = success ]; then SUCCESS=yes; break; fi
      case "$PIPE_STATUS" in failure|error|killed) break ;; esac
    fi
  fi
  sleep 3
done

if [ "$SUCCESS" != yes ]; then
  hr "X6 failure diagnostics"
  say "latest pipeline id=${NEW_ID:-none} #${PIPE_NUM:-none} status=${PIPE_STATUS:-none}"
  say "--- woodpecker-server logs since $SINCE ---"
  podman logs --since "$SINCE" woodpecker-server 2>&1 | mask_all | sed 's/^/    /' || true
  ledger "PARTIAL" "EX39 webhook created, push SHA=$PUSH_SHA; pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none}."
  halt "pipeline did not succeed"
fi

hr "X7 RESULT"
say "[RESULT] EX39 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
say "  repo: $BOT/$REPO"
say "  pipeline: #${PIPE_NUM:-?}"
say "  status: success"
say "  push SHA: $PUSH_SHA"

ledger "PASS" "EX39: API-driven repair via Playwright context, webhook created, pipeline #$PIPE_NUM success. Brick 12 CLOSED."
exit 0
