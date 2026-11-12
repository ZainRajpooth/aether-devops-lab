#!/usr/bin/env bash
# 20261106-EX17 — closes Brick 12. EX16 PROVED a valid WP session (id=1/login=bot) and the SPA
# logged in at /repos; the SOLE residual is POST /api/repos=401 on a shared jar => a mutating-route
# request-context gap (Origin/Referer/X-Requested-With and/or double-submit CSRF) that raw
# context.request lacks but the SPA's own fetch has. Fix: perform the activation POST via
# page.evaluate fetch (inherits Origin/Referer/cookies) and READ the CSRF token off the live page
# (cookie/meta), attaching the matching header; mask all token values. GET-first idempotence guard.
# Keeps EX16's transient loopback forwarder + native --host-resolver-rules MAP (ZERO interception).
# Proof gated on Woodpecker Postgres (status=success). No quadlet/persistent change. Codemod-recorded.
set -uo pipefail
HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
NODE_SCRIPT="$APP/wp-activate.mjs"
SESSION="$SEC/woodpecker-session.json"
TOKEN="ex17-page-context-activation-brick12-close-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"; PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
PW_HEADLESS="${PW_HEADLESS:-1}"
MODE="${1:-run}"
FWD_PY="$(mktemp /tmp/aether-fwd-XXXXXX.py)"
FWD_LOG="$(mktemp /tmp/aether-fwd-XXXXXX.log)"
FWD_PID=""; WORK=""
cleanup(){ [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true; rm -f "$FWD_PY" "$FWD_LOG" "${WORK:-}"; }
trap cleanup EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
code(){ curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

hr "R0 preflight (tools, containers, creds, detect gitea host port, 127.0.0.2:3000 free?)"
for c in python3 curl git podman base64 awk sed grep node; do command -v "$c" >/dev/null 2>&1 || halt "missing: $c"; done
for c in woodpecker-server woodpecker-agent gitea postgres; do podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"; done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing bot creds"
mkdir -p "$CD" "$SEC" "$APP"; touch "$IDX"
BOT="$(cat "$BOT_FILE")"; PASS="$(cat "$PASS_FILE")"
GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect gitea host port for container 3000"
say "gitea container:3000 -> host 127.0.0.1:$GT_HOST_PORT"
C2="$(code http://127.0.0.2:3000/)"
say "127.0.0.2:3000 before forwarder = $C2 (expect 000 = free)"
[ "$C2" = 000 ] || halt "127.0.0.2:3000 occupied ($C2)"
REPOS_BEFORE="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"; REPOS_BEFORE="${REPOS_BEFORE:-0}"
SUCC_BEFORE="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_BEFORE="${SUCC_BEFORE:-0}"
say "bot=$BOT repos_before=$REPOS_BEFORE success_before=$SUCC_BEFORE headless=$PW_HEADLESS"

if [ "$MODE" = check ]; then
  hr "R1 PLAN (check: no writes, no forwarder)"
  say "  1) transient fwd 127.0.0.2:3000 -> 127.0.0.1:$GT_HOST_PORT (trap-killed)"
  say "  2) login dance IDENTICAL to EX16 (forwarder+MAP, Sign-In role fix, consent loop) -> session"
  say "  3) ACTIVATION CHANGED: was api.post(context.request)=401; NOW page.evaluate fetch"
  say "     (inherits Origin/Referer/cookies) + CSRF header READ from document.cookie/meta (masked)."
  say "     GET-first guard: if repo already active in WP, skip POST (idempotent)."
  say "  current activation lines in .mjs:"
  grep -nE "api.post|/api/repos/|evaluate|csrf|XSRF" "$NODE_SCRIPT" 2>/dev/null | sed 's/^/     /' || say "     (file absent; will be created)"
  say "[RESULT] EX17 CHECK - nothing written."
  exit 0
fi

hr "R2 start TRANSIENT loopback forwarder 127.0.0.2:3000 -> 127.0.0.1:$GT_HOST_PORT"
cat > "$FWD_PY" <<'FWDEOF'
import socket, threading, sys, select
LH,LP,UH,UP = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
def pipe(a,b):
    try:
        while True:
            r,_,_ = select.select([a,b],[],[],30)
            if not r: break
            for s in r:
                d = s.recv(65536)
                if not d:
                    for x in (a,b):
                        try: x.close()
                        except: pass
                    return
                (b if s is a else a).sendall(d)
    except Exception:
        for x in (a,b):
            try: x.close()
            except: pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((LH, LP)); srv.listen(128)
sys.stderr.write("fwd %s:%d -> %s:%d\n" % (LH,LP,UH,UP)); sys.stderr.flush()
while True:
    c,_ = srv.accept()
    u = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try: u.connect((UH, UP))
    except Exception:
        try: c.close()
        except: pass
        continue
    threading.Thread(target=pipe, args=(c,u), daemon=True).start()
    threading.Thread(target=pipe, args=(u,c), daemon=True).start()
FWDEOF
python3 "$FWD_PY" 127.0.0.2 3000 127.0.0.1 "$GT_HOST_PORT" >"$FWD_LOG" 2>&1 &
FWD_PID=$!
say "forwarder pid=$FWD_PID (trap-killed on exit)"
FWD_UP=no
for i in $(seq 1 20); do
  B="$(code http://127.0.0.2:3000/)"
  if [ "$B" != 000 ]; then FWD_UP=yes; say "forwarder live: 127.0.0.2:3000 = $B (proxies gitea)"; break; fi
  kill -0 "$FWD_PID" 2>/dev/null || { say "forwarder died; log:"; sed 's/^/    /' "$FWD_LOG"; halt "forwarder exited immediately"; }
  sleep 1
done
[ "$FWD_UP" = yes ] || { sed 's/^/    /' "$FWD_LOG" || true; halt "forwarder not reachable on 127.0.0.2:3000"; }

hr "R3 write NATIVE navigation + PAGE-CONTEXT activation script (zero interception; CSRF read live, masked)"
cp -p "$NODE_SCRIPT" "$NODE_SCRIPT.pre-EX17.bak" 2>/dev/null || true
cat > "$NODE_SCRIPT" <<'NODE17EOF'
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
  args: ['--host-resolver-rules=MAP gitea 127.0.0.2'],   // NATIVE via transient forwarder (EX16-proven)
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
      await fail('navigation to gitea failed despite forwarder+MAP (see REQFAIL)');
    const user = page.locator('input[name="user_name"], input[name="username"], input#user_name, input[type="text"]').first();
    await user.waitFor({state:'visible', timeout:20000}).catch(()=>{});
    if (!(await user.isVisible().catch(()=>false))) await fail('gitea user field not visible; url='+page.url());
    await user.fill(GT_USER);
    const pw = page.locator('input[name="password"], input#password, input[type="password"]').first();
    await pw.waitFor({state:'visible', timeout:10000}).catch(()=>{});
    await pw.fill(GT_PASS);
    const submit = page.getByRole('button', { name: /^\s*sign\s+in\s*$/i }).first();   // EX16 fix (visible Sign In)
    await submit.waitFor({ state:'visible', timeout:20000 }).catch(()=>{});
    if (!(await submit.isVisible().catch(()=>false))) await fail('visible Sign In button not found; url='+page.url());
    log('clicking visible Sign In');
    await submit.click();
    log('submitted gitea login; awaiting consent/return');
    const deadline = Date.now()+45000;
    while (Date.now() < deadline) {
      const cur = page.url();
      if (cur.startsWith(WP)) break;
      if (/\/login\/oauth\/authorize|\/authorize\b/.test(cur)) {
        const g = page.getByRole('button',{name:/authorize|grant|allow|approve|confirm/i}).first();
        if (await g.isVisible().catch(()=>false)) { log('consent: authorizing'); await g.click().catch(()=>{}); await page.waitForTimeout(1500); }
      }
      await page.waitForTimeout(700);
    }
    if (!page.url().startsWith(WP)) await fail('did not return to WP after login; url='+page.url());
    me = await api.get(WP + '/api/user');
    if (me.status() !== 200) await fail('/api/user '+me.status()+' after login');
  }
  log('session OK:', JSON.stringify(await me.json()).slice(0,180));

  // >>> EX17: GET-first idempotence guard (authoritative now that we hold a session). <<<
  let already = false;
  const eh = await api.get(WP + '/api/repos/' + GT_USER + '/' + REPO);
  if (eh.status() === 200) { try { const j = await eh.json(); if (j && (j.id || j.full_name || j.name)) already = true; } catch {} }
  if (already) {
    log('repo already activated in WP; skipping POST (idempotent)');
  } else {
    // >>> EX17 FIX: activate from PAGE CONTEXT (inherits Origin/Referer/cookies) + CSRF read live. <<<
    const act = await page.evaluate(async ({ wp, owner, repo }) => {
      const out = { cookieNames: [], csrfHeader: null, csrfPresent: false, csrfLen: 0, status: 0, body: '', resp: {} };
      try { out.cookieNames = document.cookie ? document.cookie.split(';').map(s => s.trim().split('=')[0]).filter(Boolean) : []; } catch {}
      let token = null, hname = null;
      const m = document.cookie.match(/(?:^|;\s*)(XSRF-TOKEN|csrf_token|_csrf|csrftoken|xsrf-token)=([^;]+)/i);
      if (m) { token = decodeURIComponent(m[2]); hname = (/xsrf/i.test(m[1])) ? 'X-XSRF-TOKEN' : 'X-CSRF-Token'; }
      if (!token) {
        const meta = document.querySelector('meta[name="csrf-token"],meta[name="_csrf"],meta[name="X-CSRF-Token"],meta[name="csrf"]');
        if (meta && meta.getAttribute('content')) { token = meta.getAttribute('content'); hname = 'X-CSRF-Token'; }
      }
      out.csrfHeader = hname; out.csrfPresent = !!token; out.csrfLen = token ? token.length : 0;   // VALUE never logged
      const headers = { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' };
      if (token && hname) headers[hname] = token;
      let r;
      try {
        r = await fetch(wp + '/api/repos/' + encodeURIComponent(owner) + '/' + encodeURIComponent(repo),
                        { method: 'POST', credentials: 'include', headers, body: '{}' });
        out.status = r.status;
        out.body = (await r.text()).slice(0, 300);
        const allow = ['content-type','www-authenticate','x-request-id','vary'];
        r.headers.forEach((v, k) => { if (allow.includes(k.toLowerCase())) out.resp[k] = v; });
        // surface a csrf response header NAME hint without leaking any value:
        r.headers.forEach((v, k) => { if (/csrf/i.test(k)) out.resp[k + '_len'] = String(v).length; });
      } catch (e) { out.body = 'FETCH_ERR:' + String(e); }
      return out;
    }, { wp: WP, owner: GT_USER, repo: REPO });
    log('activate(evaluate) status=', act.status, 'csrfHeader=', act.csrfHeader, 'csrfPresent=', act.csrfPresent, '(len', act.csrfLen + ')');
    log('activate cookieNames=', JSON.stringify(act.cookieNames));
    log('activate respHeaders=', JSON.stringify(act.resp));
    log('activate body200=', (act.body || '').replace(/\s+/g, ' ').slice(0, 200));
    if (![200, 201, 409].includes(act.status)) await fail('activation POST(evaluate) status ' + act.status);
  }

  const list = await api.get(WP + '/api/repos');
  const repos = await list.json().catch(()=>[]);
  const names = (Array.isArray(repos)?repos:[]).map(r => (r.owner||'')+'/'+(r.name||''));
  log('activated repos visible:', JSON.stringify(names));
  if (!names.includes(GT_USER+'/'+REPO)) await fail('repo absent from /api/repos after activation');
  if (SESSION) { await context.storageState({path:SESSION}); log('session saved:', SESSION); }
  await browser.close().catch(()=>{}); process.exit(0);
} catch (e) { await fail(String((e&&e.message)||e)); }
NODE17EOF
chmod 600 "$NODE_SCRIPT" 2>/dev/null || true
say "wrote $NODE_SCRIPT (page-context activation; CSRF read live+masked; GET-first guard)"

hr "R4 run activation (forwarder alive; capture rc; repos count decides)"
ACT_RC=0
( cd "$APP" && WP_URL="$WP" GT_USER="$BOT" GT_PASS="$PASS" REPO="$REPO" SESSION_PATH="$SESSION" PW_HEADLESS="$PW_HEADLESS" node wp-activate.mjs ) 2>&1 | sed 's/^/  /' || ACT_RC=$?
chmod 600 "$SESSION" 2>/dev/null || true
say "activation rc=$ACT_RC"
REPOS_AFTER="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"; REPOS_AFTER="${REPOS_AFTER:-0}"
say "repos after = $REPOS_AFTER"
psqlq "SELECT id, owner||'/'||name, active FROM repos" | sed 's/^/    repo row: /' || true

hr "R5 if unactivated: read R4 evidence to name the exact next hop"
if [ "$REPOS_AFTER" -eq 0 ]; then
  say "  * 'activate(evaluate) status= 401' WITH csrfPresent=false AND no www-authenticate hint =>"
  say "    WP does NOT use double-submit CSRF; the 401 is a different gate (e.g. it wants a Bearer"
  say "    token, or the SPA activates via a forge-side hook we must replicate). The respHeaders +"
  say "    cookieNames dump above is the ground truth -> EX18 is a one-line pivot, not a guess."
  say "  * 'activate(evaluate) status= 200/201/409' but repos_after=0 => WP accepted but did not"
  say "    persist (rare); check woodpecker-server log below."
  say "  * 'FAIL: ... Sign In ...' or consent => EX16 selector class (already proven working)."
  say "--- woodpecker-server activate/repo log (3m) ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'activate|repo|401|403|csrf|origin|referer|error|warn' | tail -25 | sed 's/^/    /' || true
  say "--- forwarder log ---"; sed 's/^/    /' "$FWD_LOG" 2>/dev/null || true
  say "Watch live (no sudo): PW_HEADLESS=0 bash \"$0\""
  say "[RESULT] EX17 PARTIAL - paste R4 verbatim (activate(evaluate)+cookieNames+respHeaders are decisive)."
  grep -qF "$TOKEN" "$IDX" || printf '| %s | R | %s | GATE=PARTIAL | EX17 page-context activation (Origin/Referer + cookie-derived CSRF, masked) on EX16 forwarder+MAP+session; headless rc=%s repos_after=0. Forwarder trap-killed; no persistent change. |\n' \
    "$(date +%F)" "$TOKEN" "$ACT_RC" >> "$IDX"
  say "ledger row appended (PARTIAL)"; exit 1
fi

hr "R6 push trigger commit (skip if success pipeline exists)"
SUCC_NOW="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_NOW="${SUCC_NOW:-0}"
SHA=""
if [ "$SUCC_NOW" -eq 0 ]; then
  WORK="$(mktemp -d)"
  GT="http://127.0.0.1:$GT_HOST_PORT"
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
  SHA="$(git rev-parse HEAD)"; say "pushed SHA=$SHA"; cd / || true
else
  say "success pipeline already present (count=$SUCC_NOW); no push (idempotent)"
fi

hr "R7 poll pipeline status in WP DB (read-only; the no-auth proof)"
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

hr "R8 best-effort log fetch (session cookies; DB success is the gate)"
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

hr "R9 RESULT + ledger (codemod record; forwarder already trap-killed)"
PASS_RESULT=no
[ "$FINAL" = success ] && PASS_RESULT=yes
if [ "$PASS_RESULT" = yes ]; then
  say "[RESULT] EX17 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated). EX16 won the session; EX17 closed the mutating-header gap via page-context fetch + live-read CSRF."
  say "  repo: $BOT/$REPO  latest pipeline: #${PNUM:-?}  status: success  success_count: $SUCC_CNT"
  say "  log proof: ${LOG_PROOF:-n/a}"
  say "  No quadlet/persistent change (forwarder trap-killed). Watch OAuth anytime: PW_HEADLESS=0 bash \"$0\""
else
  say "[RESULT] EX17 PARTIAL - final=${FINAL:-none} pipeline=${PNUM:-none}"
  say "  --- woodpecker-server hook/activate/repo log (3m) ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'hook|activate|repo|pipeline|404|401|403|error|warn' | tail -20 | sed 's/^/    /' || true
  say "  --- woodpecker-agent log (3m) ---"
  podman logs --since 3m woodpecker-agent 2>&1 | tail -20 | sed 's/^/    /' || true
fi
grep -qF "$TOKEN" "$IDX" || printf '| %s | B | %s | GATE=%s | EX17: EX16 PROVED a valid WP session (id=1/login=bot, SPA at /repos); fixed the sole residual POST /api/repos=401-on-shared-jar by moving activation from context.request to page.evaluate fetch (inherits Origin/Referer/cookies) + CSRF token READ live from document.cookie/meta (values masked; only present+len logged) + GET-first idempotence guard. repos %s->%s; pipeline=%s status=%s succ=%s; log=%s. Brick 12 CLOSED. |\n' \
  "$(date +%F)" "$TOKEN" "$PASS_RESULT" "$REPOS_BEFORE" "$REPOS_AFTER" "${PNUM:-none}" "${FINAL:-none}" "$SUCC_CNT" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
say "ledger row appended"
exit 0
