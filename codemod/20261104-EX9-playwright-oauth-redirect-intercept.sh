#!/usr/bin/env bash
# 20261104-EX9 — Fix EX8's chrome-error halt by intercepting the Gitea OAuth redirect
# in Playwright's network layer. Maps gitea:3000 -> 127.0.0.1:3001 without touching
# container env vars or /etc/hosts. Re-runs activation, polls DB, retrieves logs.
set -uo pipefail
HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
NODE_SCRIPT="$APP/wp-activate.mjs"
SESSION="$SEC/woodpecker-session.json"
TOKEN="ex9-playwright-oauth-redirect-intercept-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"; PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }

hr "E0 preflight"
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing bot creds"
BOT="$(cat "$BOT_FILE")"; PASS="$(cat "$PASS_FILE")"
REPOS_BEFORE="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"
say "repos before = ${REPOS_BEFORE:-0}"

hr "E1 rewrite wp-activate.mjs with network interception"
cp -p "$NODE_SCRIPT" "$NODE_SCRIPT.pre-EX9.bak" 2>/dev/null || true
cat > "$NODE_SCRIPT" <<'NODEEOF'
import { chromium } from 'playwright';
const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const GT_USER = process.env.GT_USER || '';
const GT_PASS = process.env.GT_PASS || '';
const REPO = process.env.REPO || '';
const SESSION = process.env.SESSION_PATH || '';
const log = (...a) => console.log('   ', ...a);

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();

// INTERCEPT: Rewrite gitea:3000 -> 127.0.0.1:3001 for host-side browser
await context.route('**/*', async route => {
  const url = route.request().url();
  if (url.startsWith('http://gitea:3000/')) {
    const newUrl = url.replace('http://gitea:3000/', 'http://127.0.0.1:3001/');
    log('intercept: rewriting', url, '->', newUrl);
    await route.continue({ url: newUrl });
  } else {
    await route.continue();
  }
});

const page = await context.newPage();
const fail = async (msg) => {
  const btns = await page.getByRole('button').allTextContents().catch(() => []);
  const links = await page.getByRole('link').allTextContents().catch(() => []);
  log('FAIL:', msg, '| url=', page.url());
  log('visible buttons:', JSON.stringify(btns.slice(0, 25)));
  log('visible links:', JSON.stringify(links.slice(0, 25)));
  await page.screenshot({ path: '/tmp/wp-activate-fail.png' }).catch(() => {});
  await browser.close(); process.exit(1);
};

try {
  await page.goto(WP, { waitUntil: 'domcontentloaded', timeout: 30000 });
  
  // Look for Gitea login button/link on WP UI
  const loginLoc = page.getByRole('link', { name: /gitea/i }).or(page.getByRole('button', { name: /gitea/i })).or(page.locator('a[href*="gitea"], button:has-text("Gitea")'));
  if (await loginLoc.count()) {
    log('login: clicking Gitea forge button');
    await loginLoc.first().click();
    
    // Wait for Gitea login page to load
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
    
    const userSel = ['input[name="user_name"]', 'input[name="user"]', 'input[name="username"]', 'input[type="text"]'];
    let filled = false;
    for (const s of userSel) { 
      if (await page.locator(s).count()) { 
        await page.locator(s).first().fill(GT_USER); 
        filled = true; 
        break; 
      } 
    }
    if (!filled) await fail('gitea login user field not found');
    
    if (!(await page.locator('input[name="password"]').count())) await fail('gitea password field not found');
    await page.locator('input[name="password"]').first().fill(GT_PASS);
    
    await page.locator('button[type="submit"], input[type="submit"]').first().click();
    await page.waitForTimeout(2000);
    
    // Handle OAuth consent screen if it appears
    if (/oauth\/authorize|grant/i.test(page.url())) {
      const grant = page.getByRole('button', { name: /authorize|grant|allow/i }).first();
      if (await grant.count()) { 
        log('login: approving oauth consent'); 
        await grant.click(); 
        await page.waitForTimeout(2000);
      }
    }
    
    await page.waitForURL(u => String(u).startsWith(WP), { timeout: 30000 }).catch(() => fail('did not return to WP after login'));
    log('login: back at WP, url=', page.url());
  } else {
    log('login: already authenticated (no forge button visible)');
  }

  const me = await context.request.get(`${WP}/api/user`);
  if (me.status() !== 200) await fail(`/api/user status ${me.status()} after login`);
  log('session OK:', JSON.stringify(await me.json()).slice(0, 160));

  const act = await context.request.post(`${WP}/api/repos/${GT_USER}/${REPO}`);
  const actBody = await act.text().catch(() => '');
  log('activate POST status=', act.status(), 'body160=', actBody.slice(0, 160).replace(/\s+/g, ' '));
  if (act.status() !== 200 && act.status() !== 201 && act.status() !== 409) await fail(`activation POST status ${act.status()}`);

  const list = await context.request.get(`${WP}/api/repos`);
  const repos = await list.json().catch(() => []);
  const names = (Array.isArray(repos) ? repos : []).map(r => `${r.owner}/${r.name}`);
  log('activated repos visible to session:', JSON.stringify(names));
  if (!names.includes(`${GT_USER}/${REPO}`)) await fail('repo not present in /api/repos after activation');

  if (SESSION) { 
    await context.storageState({ path: SESSION }); 
    log('session saved (600):', SESSION); 
  }
  await browser.close(); process.exit(0);
} catch (e) { await fail(String(e && e.message || e)); }
NODEEOF
chmod 600 "$NODE_SCRIPT"
say "rewrote $NODE_SCRIPT with context.route interception"

hr "E2 run activation"
( cd "$APP" && WP_URL="$WP" GT_USER="$BOT" GT_PASS="$PASS" REPO="$REPO" SESSION_PATH="$SESSION" node wp-activate.mjs ) 2>&1 | sed 's/^/  /' || halt "activation script failed (see /tmp/wp-activate-fail.png)"
chmod 600 "$SESSION" 2>/dev/null || true

REPOS_AFTER="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"
say "repos after = ${REPOS_AFTER:-0}"
psqlq "SELECT id, owner||'/'||name, active FROM repos" | sed 's/^/    repo row: /' || true

hr "E3 push trigger commit (skip if success pipeline exists)"
SUCCESS_EXISTS="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"
if [ "${SUCCESS_EXISTS:-0}" -ge 1 ]; then
  say "success pipeline already exists; no push (idempotent)"
  SHA=""
else
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  GT_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"; [ -n "$GT_PORT" ] || GT_PORT=3001
  GT="http://127.0.0.1:$GT_PORT"
  AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"
  cd "$WORK" || halt "cd failed"
  git -c init.defaultBranch=main init -q
  git remote add origin "$GT/$BOT/$REPO.git"
  git -c http.extraHeader="Authorization: Basic $AUTH_B64" pull -q origin main --rebase >/dev/null 2>&1 || true
  printf '%s\n' 'steps:' '  hello-world:' '    image: alpine:latest' '    commands:' '      - echo "Hello from Woodpecker CI!"' '      - date' '      - whoami' > .woodpecker.yml
  git add .woodpecker.yml
  if [ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ]; then
    git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q -m "ci: steel thread $(date -Is)" || halt "commit failed"
  else
    git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q --allow-empty -m "ci: retrigger $(date -Is)" || halt "empty commit failed"
  fi
  git -c http.extraHeader="Authorization: Basic $AUTH_B64" push -q origin HEAD:main || halt "push failed"
  SHA="$(git rev-parse HEAD)"; say "pushed SHA=$SHA"
  cd / || true
fi

hr "E4 poll pipeline status in WP DB (read-only)"
FINAL=""; PNUM=""
for i in $(seq 1 40); do
  ROW="$(psqlq "SELECT number||' '||status FROM pipelines ORDER BY id DESC LIMIT 1")"
  if [ -n "$ROW" ]; then PNUM="${ROW%% *}"; FINAL="${ROW##* }"; fi
  case "$FINAL" in success|failure|error|killed) break;; esac
  sleep 3
done
say "pipeline number=${PNUM:-none} status=${FINAL:-none}"

hr "E5 retrieve logs with session cookies"
LOG_PROOF=""
if [ -n "$PNUM" ] && [ -s "$SESSION" ]; then
  COOKIES="$(python3 -c '
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print("; ".join("%s=%s" % (c["name"], c["value"]) for c in d.get("cookies", [])))
' "$SESSION" 2>/dev/null || true)"
  LOGS_RAW="$(curl -sS -m 15 -b "$COOKIES" "$WP/api/repos/$BOT/$REPO/builds/$PNUM/logs" 2>/dev/null || true)"
  LOG_PROOF="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
fi
[ -z "$LOG_PROOF" ] && LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
say "log proof: ${LOG_PROOF:-none}"

hr "E6 result + ledger"
PASS_RESULT=no
[ "$FINAL" = success ] && [ -n "$LOG_PROOF" ] && PASS_RESULT=yes
if [ "$PASS_RESULT" = yes ]; then
  say "[RESULT] EX9 COMPLETE - Brick 12 steel thread PASSED."
  say "  repo: $BOT/$REPO  pipeline: #$PNUM  status: success"
  say "  log proof: $LOG_PROOF"
else
  say "[RESULT] EX9 PARTIAL - final=${FINAL:-none} pipeline=${PNUM:-none} log=${LOG_PROOF:-none}"
  say "  on selector/API surprise: see /tmp/wp-activate-fail.png + button dump above"
fi
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EX9: fixed EX8 chrome-error halt via Playwright context.route interception (gitea:3000 -> 127.0.0.1:3001); repos before/after=%s/%s; pipeline=%s status=%s; log_proof=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$PASS_RESULT" "${REPOS_BEFORE:-0}" "${REPOS_AFTER:-0}" "${PNUM:-none}" "${FINAL:-none}" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
  say "ledger row appended"
fi
exit 0
