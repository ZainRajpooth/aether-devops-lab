#!/usr/bin/env bash
# 20261104-EX10 — fixes EX9's hydration-timing mis-detection (NOT the interception, which was
# correct but never ran). Headless (or PW_HEADLESS=0 to watch) OAuth login via Playwright with
# host-scoped gitea:3000->127.0.0.1:3001 network rewrite, then authenticated repo activation.
# Proof is gated on Woodpecker's OWN Postgres (pipelines.status='success') = no-auth steel thread.
# Touches NO quadlet / NO network / NO /etc/hosts / NO sudo. Records to codemod/INDEX (standing rule).
set -uo pipefail
HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
NODE_SCRIPT="$APP/wp-activate.mjs"
SESSION="$SEC/woodpecker-session.json"
TOKEN="ex10-headless-oauth-activation-and-db-gated-proof-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"; PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
PW_HEADLESS="${PW_HEADLESS:-1}"
WORK=""; trap 'rm -rf "${WORK:-}"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }

hr "L0 preflight"
for c in python3 curl git podman base64 awk sed grep node; do command -v "$c" >/dev/null 2>&1 || halt "missing: $c"; done
for c in woodpecker-server woodpecker-agent gitea postgres; do podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"; done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing bot creds (run EX6/EPW4 first)"
mkdir -p "$CD" "$SEC" "$APP"; touch "$IDX"
BOT="$(cat "$BOT_FILE")"; PASS="$(cat "$PASS_FILE")"
REPOS_BEFORE="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"; REPOS_BEFORE="${REPOS_BEFORE:-0}"
SUCC_BEFORE="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_BEFORE="${SUCC_BEFORE:-0}"
say "bot=$BOT repos_before=$REPOS_BEFORE success_before=$SUCC_BEFORE headless=$PW_HEADLESS"

hr "L1 write timing-fixed activation script (probe-session-first, wait-for-button, host-scoped rewrite)"
cp -p "$NODE_SCRIPT" "$NODE_SCRIPT.pre-EX10.bak" 2>/dev/null || true
cat > "$NODE_SCRIPT" <<'NODE10EOF'
import { chromium } from 'playwright';
const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const GT_USER = process.env.GT_USER || '';
const GT_PASS = process.env.GT_PASS || '';
const REPO = process.env.REPO || '';
const SESSION = process.env.SESSION_PATH || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';
const log = (...a) => console.log('   ', ...a);
const browser = await chromium.launch({ headless: HEADLESS });
const context = await browser.newContext();
// host-scoped rewrite: ONLY gitea-host requests are remapped; WP websockets/SSE untouched.
await context.route(u => u.hostname === 'gitea', async route => {
  const u = new URL(route.request().url());
  const nu = new URL(u.toString());
  nu.hostname = '127.0.0.1'; nu.port = '3001';
  log('intercept gitea ->', nu.toString());
  await route.continue({ url: nu.toString() });
});
const page = await context.newPage();
const api = context.request;            // shares the context cookie jar
const fail = async (msg) => {
  const btns = await page.getByRole('button').allTextContents().catch(() => []);
  const links = await page.getByRole('link').allTextContents().catch(() => []);
  log('FAIL:', msg, '| url=', page.url());
  log('buttons:', JSON.stringify(btns.slice(0, 30)));
  log('links:', JSON.stringify(links.slice(0, 30)));
  await page.screenshot({ path: '/tmp/wp-activate-fail.png' }).catch(() => {});
  await browser.close().catch(() => {}); process.exit(1);
};
try {
  await page.goto(WP, { waitUntil: 'domcontentloaded', timeout: 30000 });
  let me = await api.get(WP + '/api/user');
  if (me.status() === 200) {
    log('already authenticated (session valid)');
  } else {
    log('not authed (api/user=' + me.status() + '); waiting for gitea login control');
    const btn = page.getByRole('button', { name: /gitea/i }).first();
    await btn.waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
    if (await btn.isVisible().catch(() => false)) { log('click gitea button'); await btn.click(); }
    else {
      const lk = page.getByRole('link', { name: /gitea/i }).first();
      await lk.waitFor({ state: 'visible', timeout: 10000 }).catch(() => {});
      if (await lk.isVisible().catch(() => false)) { log('click gitea link'); await lk.click(); }
      else await fail('no gitea login control after waitFor');
    }
    // wait until we are on the rewritten gitea origin (127.0.0.1:3001)
    await page.waitForFunction(() => location.hostname === '127.0.0.1' && location.port === '3001', { timeout: 20000 }).catch(() => {});
    const user = page.locator('input[name="user_name"], input[name="username"], input#user_name, input[type="text"]').first();
    await user.waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
    if (!(await user.isVisible().catch(() => false))) await fail('gitea user field not visible; url=' + page.url());
    await user.fill(GT_USER);
    const pw = page.locator('input[name="password"], input#password, input[type="password"]').first();
    await pw.waitFor({ state: 'visible', timeout: 10000 }).catch(() => {});
    await pw.fill(GT_PASS);
    await page.locator('button[type="submit"], input[type="submit"], button:has-text("Sign in"), button:has-text("Log in")').first().click();
    log('submitted gitea login; awaiting consent/return');
    const deadline = Date.now() + 45000;
    while (Date.now() < deadline) {
      const cur = page.url();
      if (cur.startsWith(WP)) break;
      if (/\/login\/oauth\/authorize|\/authorize\b/.test(cur)) {
        const g = page.getByRole('button', { name: /authorize|grant|allow|approve/i }).first();
        if (await g.isVisible().catch(() => false)) { log('consent: authorizing'); await g.click(); await page.waitForTimeout(1500); }
      }
      await page.waitForTimeout(700);
    }
    if (!page.url().startsWith(WP)) await fail('did not return to WP after login; url=' + page.url());
    me = await api.get(WP + '/api/user');
    if (me.status() !== 200) await fail('/api/user ' + me.status() + ' after login');
  }
  log('session OK:', JSON.stringify(await me.json()).slice(0, 180));
  const act = await api.post(WP + '/api/repos/' + GT_USER + '/' + REPO);
  const actBody = (await act.text().catch(() => '')).replace(/\s+/g, ' ');
  log('activate POST status=', act.status(), 'body160=', actBody.slice(0, 160));
  if (![200, 201, 409].includes(act.status())) await fail('activation POST status ' + act.status());
  const list = await api.get(WP + '/api/repos');
  const repos = await list.json().catch(() => []);
  const names = (Array.isArray(repos) ? repos : []).map(r => (r.owner || '') + '/' + (r.name || ''));
  log('activated repos visible:', JSON.stringify(names));
  if (!names.includes(GT_USER + '/' + REPO)) await fail('repo absent from /api/repos after activation');
  if (SESSION) { await context.storageState({ path: SESSION }); log('session saved:', SESSION); }
  await browser.close().catch(() => {}); process.exit(0);
} catch (e) { await fail(String((e && e.message) || e)); }
NODE10EOF
chmod 600 "$NODE_SCRIPT" 2>/dev/null || true
say "wrote $NODE_SCRIPT"

hr "L2 run headless activation (capture rc; do NOT halt here - repos count decides)"
ACT_RC=0
( cd "$APP" && WP_URL="$WP" GT_USER="$BOT" GT_PASS="$PASS" REPO="$REPO" SESSION_PATH="$SESSION" PW_HEADLESS="$PW_HEADLESS" node wp-activate.mjs ) 2>&1 | sed 's/^/  /' || ACT_RC=$?
chmod 600 "$SESSION" 2>/dev/null || true
say "activation rc=$ACT_RC"
REPOS_AFTER="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"; REPOS_AFTER="${REPOS_AFTER:-0}"
say "repos after = $REPOS_AFTER"
psqlq "SELECT id, owner||'/'||name, active FROM repos" | sed 's/^/    repo row: /' || true

hr "L3 manual/last-resort note (only reached if headless failed AND repos still 0)"
if [ "$REPOS_AFTER" -eq 0 ]; then
  say "Headless activation did not register the repo. Deterministic options, in order:"
  say "  (1) RE-RUN with a visible browser to watch/confirm the OAuth hop (still no sudo):"
  say "        PW_HEADLESS=0 bash $F"
  say "  (2) Inspect /tmp/wp-activate-fail.png + the L2 FAIL dump (url/buttons/links) for the exact hop."
  say "  (3) LAST RESORT (sudo + fleet change, NOT recommended): make 'gitea' host-resolvable for a real"
  say "      browser: echo '127.0.0.1 gitea' | sudo tee -a /etc/hosts  AND publish Gitea on host:3000, then"
  say "      log in at http://127.0.0.1:8000 in Brave and click 'Activate Repository'. This perturbs the"
  say "      fleet edge, so prefer (1)/(2); the host-scoped rewrite in (1) is the intended clean path."
  say "[RESULT] EX10 PARTIAL - activation not yet present (repos=0); paste L2 FAIL block + screenshot desc."
  touch "$IDX"; grep -qF "$TOKEN" "$IDX" || printf '| %s | R | %s | GATE=PARTIAL | EX10 headless activation did not register repo (repos_after=0, rc=%s); timing-fix+host-scoped rewrite applied but OAuth hop incomplete; manual/last-resort note printed. No fleet change. |\n' "$(date +%F)" "$TOKEN" "$ACT_RC" >> "$IDX"
  exit 1
fi

hr "L4 push trigger commit (skip if a success pipeline already exists)"
SUCC_NOW="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_NOW="${SUCC_NOW:-0}"
SHA=""
if [ "$SUCC_NOW" -ge 1 ] && [ "$SUCC_NOW" -gt "$SUCC_BEFORE" -o "$SUCC_BEFORE" -ge 1 ]; then
  : # fall through to poll; we still push once below only if no success at all
fi
if [ "$SUCC_NOW" -eq 0 ]; then
  WORK="$(mktemp -d)"
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
else
  say "success pipeline already present (count=$SUCC_NOW); no push (idempotent)"
fi

hr "L5 poll pipeline status in WP DB (read-only; the no-auth proof)"
FINAL=""; PNUM=""; SUCC_CNT="$SUCC_NOW"
for i in $(seq 1 40); do
  ROW="$(psqlq "SELECT number||' '||status FROM pipelines ORDER BY id DESC LIMIT 1")"
  [ -n "$ROW" ] && { PNUM="${ROW%% *}"; FINAL="${ROW##* }"; }
  SUCC_CNT="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_CNT="${SUCC_CNT:-0}"
  [ "$FINAL" = success ] && break
  [ "$SUCC_CNT" -ge 1 ] && [ "$SUCC_CNT" -gt "$SUCC_BEFORE" ] && { FINAL="success"; break; }
  case "$FINAL" in failure|error|killed) break;; esac
  sleep 3
done
say "latest pipeline=#${PNUM:-none} status=${FINAL:-none} success_count=$SUCC_CNT (was $SUCC_BEFORE)"

hr "L6 best-effort log fetch (session cookies if present; DB success is the gate regardless)"
LOG_PROOF=""
if [ -n "$PNUM" ] && [ -s "$SESSION" ]; then
  COOKIES="$(python3 -c '
import sys, json
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print("; ".join("%s=%s"%(c["name"],c["value"]) for c in d.get("cookies",[])))
' "$SESSION" 2>/dev/null || true)"
  LOGS_RAW="$(curl -sS -m 15 -b "$COOKIES" "$WP/api/repos/$BOT/$REPO/builds/$PNUM/logs" 2>/dev/null || true)"
  LOG_PROOF="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
fi
[ -z "$LOG_PROOF" ] && LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
say "log proof: ${LOG_PROOF:-none (view in WP UI; DB success already proves the thread)}"

hr "L7 result + ledger (codemod record)"
PASS_RESULT=no
[ "$FINAL" = success ] && PASS_RESULT=yes
if [ "$PASS_RESULT" = yes ]; then
  say "[RESULT] EX10 COMPLETE - Brick 12 steel thread PASSED (DB-gated)."
  say "  repo: $BOT/$REPO  latest pipeline: #${PNUM:-?}  status: success  success_count: $SUCC_CNT"
  say "  log proof: ${LOG_PROOF:-n/a}"
  say "  To WATCH the OAuth next time: PW_HEADLESS=0 bash $F"
else
  say "[RESULT] EX10 PARTIAL - final=${FINAL:-none} pipeline=${PNUM:-none}"
  say "  --- woodpecker-server hook/activate/repo log (3m) ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'hook|activate|repo|pipeline|404|401|error|warn' | tail -20 | sed 's/^/    /' || true
  say "  --- woodpecker-agent log (3m) ---"
  podman logs --since 3m woodpecker-agent 2>&1 | tail -20 | sed 's/^/    /' || true
fi
grep -qF "$TOKEN" "$IDX" || printf '| %s | B | %s | GATE=%s | EX10: fixed EX9 hydration-timing mis-detect (probe-session-first + waitFor button), host-scoped gitea->127.0.0.1:3001 rewrite; headless OAuth activation; DB-gated proof (no-auth). repos %s->%s; pipeline=%s status=%s succ=%s; log=%s; no fleet change. |\n' \
  "$(date +%F)" "$TOKEN" "$PASS_RESULT" "$REPOS_BEFORE" "$REPOS_AFTER" "${PNUM:-none}" "${FINAL:-none}" "$SUCC_CNT" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
say "ledger row appended"
exit 0
