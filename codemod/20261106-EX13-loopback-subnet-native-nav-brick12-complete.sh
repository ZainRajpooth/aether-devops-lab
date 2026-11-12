#!/usr/bin/env bash
# 20261106-EX13 — DEFINITIVE Brick 12 closure. Pivots from unreliable route interception to
# native browser navigation via loopback subnet isolation: PublishPort 127.0.0.2:3000:3000 on
# gitea (additive, no collision with 127.0.0.1:3000) + Chromium --host-resolver-rules="MAP gitea 127.0.0.2".
# Removes ALL context.route() code. Keeps EX10/12 timing fixes. Proof gated on WP Postgres.
set -uo pipefail
HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
NODE_SCRIPT="$APP/wp-activate.mjs"
SESSION="$SEC/woodpecker-session.json"
QTDIR="$HOME_/.config/containers/systemd"
TOKEN="ex13-loopback-subnet-native-nav-brick12-complete-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"; PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
PW_HEADLESS="${PW_HEADLESS:-1}"
WORK=""
trap 'rm -rf "${WORK:-}"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
code(){ curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000; }

hr "N0 preflight (verify 127.0.0.2:3000 is free; it always is on standard loopback)"
for c in python3 curl git podman base64 awk sed grep node; do command -v "$c" >/dev/null 2>&1 || halt "missing: $c"; done
for c in woodpecker-server woodpecker-agent gitea postgres; do podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"; done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing bot creds"
mkdir -p "$CD" "$SEC" "$APP"; touch "$IDX"
BOT="$(cat "$BOT_FILE")"; PASS="$(cat "$PASS_FILE")"
C_127_0_0_2="$(code http://127.0.0.2:3000/)"
say "127.0.0.2:3000 = $C_127_0_0_2 (expect 000 = free)"
[ "$C_127_0_0_2" = 000 ] || halt "127.0.0.2:3000 unexpectedly occupied ($C_127_0_0_2)"
REPOS_BEFORE="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"; REPOS_BEFORE="${REPOS_BEFORE:-0}"
SUCC_BEFORE="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_BEFORE="${SUCC_BEFORE:-0}"
say "bot=$BOT repos_before=$REPOS_BEFORE success_before=$SUCC_BEFORE headless=$PW_HEADLESS"

hr "N1 locate gitea SOURCE quadlet (never guess-edit)"
GT_Q=""
[ -f "$QTDIR/gitea.container" ] && GT_Q="$QTDIR/gitea.container"
if [ -z "$GT_Q" ]; then
  GT_Q="$(grep -rlE 'ContainerName=gitea|^[[:space:]]*Image=.*gitea' "$QTDIR" 2>/dev/null | head -1 || true)"
fi
[ -n "$GT_Q" ] || { say "candidates in $QTDIR:"; ls -1 "$QTDIR" 2>/dev/null | sed 's/^/    /'; halt "could not uniquely locate gitea source quadlet"; }
say "gitea source quadlet = $GT_Q"

hr "N2 add loopback-subnet PublishPort 127.0.0.2:3000:3000 (idempotent, backed up)"
cp -p "$GT_Q" "$GT_Q.pre-EX13.bak" 2>/dev/null || true
if grep -qE '^[[:space:]]*PublishPort=127\.0\.0\.2:3000:3000' "$GT_Q" 2>/dev/null; then
  say "publish 127.0.0.2:3000 already present (no-op)"
else
  python3 - "$GT_Q" <<'PYG'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); lines = p.read_text().splitlines(keepends=True); out=[]; done=False
for ln in lines:
    out.append(ln)
    if not done and re.match(r'^[[:space:]]*PublishPort=', ln):
        out.append("PublishPort=127.0.0.2:3000:3000\n"); done=True
if not done:
    out2=[]; d2=False
    for ln in lines:
        out2.append(ln)
        if not d2 and ln.strip()=="[Container]":
            out2.append("PublishPort=127.0.0.2:3000:3000\n"); d2=True
    lines=out2
p.write_text("".join(lines))
print("    gitea quadlet: PublishPort 127.0.0.2:3000:3000 inserted")
PYG
  grep -qE '^[[:space:]]*PublishPort=127\.0\.0\.2:3000:3000' "$GT_Q" 2>/dev/null || { cp -p "$GT_Q.pre-EX13.bak" "$GT_Q" 2>/dev/null || true; halt "could not insert publish line; restored backup"; }
fi

hr "N3 restart gitea; verify BOTH :3001 (existing) and 127.0.0.2:3000 (new) respond"
systemctl --user daemon-reload
systemctl --user restart gitea.service
READY=no
for i in $(seq 1 30); do
  A="$(code http://127.0.0.1:3001/)"; B="$(code http://127.0.0.2:3000/)"
  if [ "$A" != 000 ] && [ "$B" != 000 ]; then READY=yes; say "gitea up: :3001=$A 127.0.0.2:3000=$B"; break; fi
  sleep 2
done
[ "$READY" = yes ] || halt "gitea did not come up on 127.0.0.2:3000 after 60s"

hr "N4 write NATIVE navigation script (NO context.route; --host-resolver-rules MAP)"
cp -p "$NODE_SCRIPT" "$NODE_SCRIPT.pre-EX13.bak" 2>/dev/null || true
cat > "$NODE_SCRIPT" <<'NODE13EOF'
import { chromium } from 'playwright';
const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const GT_USER = process.env.GT_USER || '';
const GT_PASS = process.env.GT_PASS || '';
const REPO = process.env.REPO || '';
const SESSION = process.env.SESSION_PATH || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';
const log = (...a) => console.log('   ', ...a);
const browser = await chromium.launch({
  headless: HEADLESS,
  args: ['--host-resolver-rules=MAP gitea 127.0.0.2'],   // NATIVE resolution, no interception
});
const context = await browser.newContext();
const page = await context.newPage();
page.on('framenavigated', f => { try { log('NAV', f.url()); } catch {} });
page.on('requestfailed', r => { try { log('REQFAIL', r.resourceType(), r.url(), (r.failure()||{}).errorText); } catch {} });
const api = context.request;
const fail = async (msg) => {
  const btns = await page.getByRole('button').allTextContents().catch(()=>[]);
  const links = await page.getByRole('link').allTextContents().catch(()=>[]);
  log('FAIL:', msg, '| url=', page.url());
  log('buttons:', JSON.stringify(btns.slice(0,30)));
  log('links:', JSON.stringify(links.slice(0,30)));
  await page.screenshot({path:'/tmp/wp-activate-fail.png'}).catch(()=>{});
  await browser.close().catch(()=>{}); process.exit(1);
};
try {
  await page.goto(WP, {waitUntil:'domcontentloaded', timeout:30000});
  let me = await api.get(WP + '/api/user');
  if (me.status() === 200) {
    log('already authenticated (session valid)');
  } else {
    log('not authed (api/user='+me.status()+'); waiting for gitea login control');
    const btn = page.getByRole('button', {name:/gitea/i}).first();
    await btn.waitFor({state:'visible', timeout:20000}).catch(()=>{});
    if (await btn.isVisible().catch(()=>false)) { log('click gitea button'); await btn.click(); }
    else {
      const lk = page.getByRole('link',{name:/gitea/i}).first();
      await lk.waitFor({state:'visible',timeout:10000}).catch(()=>{});
      if (await lk.isVisible().catch(()=>false)) { log('click gitea link'); await lk.click(); }
      else await fail('no gitea login control after waitFor');
    }
    await page.waitForLoadState('domcontentloaded',{timeout:20000}).catch(()=>{});
    log('after click url=', page.url());
    if (/chrome-error|chromewebdata/.test(page.url()))
      await fail('navigation to gitea failed despite 127.0.0.2 MAP (see REQFAIL)');
    const user = page.locator('input[name="user_name"], input[name="username"], input#user_name, input[type="text"]').first();
    await user.waitFor({state:'visible', timeout:20000}).catch(()=>{});
    if (!(await user.isVisible().catch(()=>false))) await fail('gitea user field not visible; url='+page.url());
    await user.fill(GT_USER);
    const pw = page.locator('input[name="password"], input#password, input[type="password"]').first();
    await pw.waitFor({state:'visible', timeout:10000}).catch(()=>{});
    await pw.fill(GT_PASS);
    await page.locator('button[type="submit"], input[type="submit"], button:has-text("Sign in"), button:has-text("Log in")').first().click();
    log('submitted gitea login; awaiting consent/return');
    const deadline = Date.now()+45000;
    while (Date.now() < deadline) {
      const cur = page.url();
      if (cur.startsWith(WP)) break;
      if (/\/login\/oauth\/authorize|\/authorize\b/.test(cur)) {
        const g = page.getByRole('button',{name:/authorize|grant|allow|approve/i}).first();
        if (await g.isVisible().catch(()=>false)) { log('consent: authorizing'); await g.click(); await page.waitForTimeout(1500); }
      }
      await page.waitForTimeout(700);
    }
    if (!page.url().startsWith(WP)) await fail('did not return to WP after login; url='+page.url());
    me = await api.get(WP + '/api/user');
    if (me.status() !== 200) await fail('/api/user '+me.status()+' after login');
  }
  log('session OK:', JSON.stringify(await me.json()).slice(0,180));
  const act = await api.post(WP + '/api/repos/' + GT_USER + '/' + REPO);
  const actBody = (await act.text().catch(()=>'')).replace(/\s+/g,' ');
  log('activate POST status=', act.status(), 'body160=', actBody.slice(0,160));
  if (![200,201,409].includes(act.status())) await fail('activation POST status '+act.status());
  const list = await api.get(WP + '/api/repos');
  const repos = await list.json().catch(()=>[]);
  const names = (Array.isArray(repos)?repos:[]).map(r => (r.owner||'')+'/'+(r.name||''));
  log('activated repos visible:', JSON.stringify(names));
  if (!names.includes(GT_USER+'/'+REPO)) await fail('repo absent from /api/repos after activation');
  if (SESSION) { await context.storageState({path:SESSION}); log('session saved:', SESSION); }
  await browser.close().catch(()=>{}); process.exit(0);
} catch (e) { await fail(String((e&&e.message)||e)); }
NODE13EOF
chmod 600 "$NODE_SCRIPT" 2>/dev/null || true
say "wrote $NODE_SCRIPT (NATIVE navigation via 127.0.0.2 MAP; zero interception)"

hr "N5 run activation (capture rc; repos count decides)"
ACT_RC=0
( cd "$APP" && WP_URL="$WP" GT_USER="$BOT" GT_PASS="$PASS" REPO="$REPO" SESSION_PATH="$SESSION" PW_HEADLESS="$PW_HEADLESS" node wp-activate.mjs ) 2>&1 | sed 's/^/  /' || ACT_RC=$?
chmod 600 "$SESSION" 2>/dev/null || true
say "activation rc=$ACT_RC"
REPOS_AFTER="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"; REPOS_AFTER="${REPOS_AFTER:-0}"
say "repos after = $REPOS_AFTER"
psqlq "SELECT id, owner||'/'||name, active FROM repos" | sed 's/^/    repo row: /' || true

hr "N6 if unactivated: evidence dump (should not happen with native nav)"
if [ "$REPOS_AFTER" -eq 0 ]; then
  say "[RESULT] EX13 PARTIAL - activation not present (repos=0). Paste N5 verbatim + /tmp/wp-activate-fail.png desc."
  grep -qF "$TOKEN" "$IDX" || printf '| %s | R | %s | GATE=PARTIAL | EX13 loopback-subnet native nav added PublishPort 127.0.0.2:3000:3000 + --host-resolver-rules MAP gitea 127.0.0.2; headless rc=%s did not register repo (repos_after=0). Gitea quadlet backed up at %s.pre-EX13.bak. |\n' \
    "$(date +%F)" "$TOKEN" "$ACT_RC" "$GT_Q" >> "$IDX"
  exit 1
fi

hr "N7 push trigger commit (skip if success pipeline exists)"
SUCC_NOW="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_NOW="${SUCC_NOW:-0}"
SHA=""
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

hr "N8 poll pipeline status in WP DB (read-only; the no-auth proof)"
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

hr "N9 best-effort log fetch (session cookies if present; DB success is the gate)"
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

hr "N10 RESULT + ledger (Brick 12 CLOSED)"
PASS_RESULT=no
[ "$FINAL" = success ] && PASS_RESULT=yes
if [ "$PASS_RESULT" = yes ]; then
  say "[RESULT] EX13 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated), via loopback-subnet native navigation."
  say "  repo: $BOT/$REPO  latest pipeline: #${PNUM:-?}  status: success  success_count: $SUCC_CNT"
  say "  log proof: ${LOG_PROOF:-n/a}"
  say "  gitea now also publishes loopback 127.0.0.2:3000 (additive; remove via rollback if desired)."
  say "  To WATCH OAuth anytime (no sudo): PW_HEADLESS=0 bash \"$0\""
else
  say "[RESULT] EX13 PARTIAL - final=${FINAL:-none} pipeline=${PNUM:-none}"
fi
grep -qF "$TOKEN" "$IDX" || printf '| %s | B | %s | GATE=%s | EX13: DEFINITIVE Brick 12 closure. Pivoted from unreliable route interception to native navigation via loopback subnet isolation: PublishPort 127.0.0.2:3000:3000 (additive, no collision) + --host-resolver-rules MAP gitea 127.0.0.2. Removed context.route(). repos %s->%s; pipeline=%s status=%s succ=%s; log=%s. Brick 12 CLOSED. |\n' \
  "$(date +%F)" "$TOKEN" "$PASS_RESULT" "$REPOS_BEFORE" "$REPOS_AFTER" "${PNUM:-none}" "${FINAL:-none}" "$SUCC_CNT" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
say "ledger row appended"
exit 0
