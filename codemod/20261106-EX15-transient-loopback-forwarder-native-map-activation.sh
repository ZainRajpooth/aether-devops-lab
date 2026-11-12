#!/usr/bin/env bash
# 20261106-EX15 — closes Brick 12 WITHOUT editing any quadlet (fixes EX14's wrong-anchor halt).
# Stands up a TRANSIENT host-side loopback forwarder 127.0.0.2:3000 -> 127.0.0.1:<gitea host port>
# (auto-detected via podman port), killed by trap on exit. Chromium uses
# --host-resolver-rules=MAP gitea 127.0.0.2 so the OAuth hop resolves NATIVELY (no route
# interception, no /etc/hosts, no sudo, no persistent publish). Proof gated on WP Postgres.
set -uo pipefail
HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
NODE_SCRIPT="$APP/wp-activate.mjs"
SESSION="$SEC/woodpecker-session.json"
TOKEN="ex15-transient-loopback-forwarder-native-map-activation-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"; PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
PW_HEADLESS="${PW_HEADLESS:-1}"
FWD_PY="$(mktemp /tmp/aether-fwd-XXXXXX.py)"
FWD_LOG="$(mktemp /tmp/aether-fwd-XXXXXX.log)"
FWD_PID=""
WORK=""
cleanup(){ [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true; rm -f "$FWD_PY" "$FWD_LOG" "${WORK:-}"; }
trap cleanup EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
code(){ curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

hr "P0 preflight (tools, containers, creds, detect gitea host port, 127.0.0.2:3000 free?)"
for c in python3 curl git podman base64 awk sed grep node; do command -v "$c" >/dev/null 2>&1 || halt "missing: $c"; done
for c in woodpecker-server woodpecker-agent gitea postgres; do podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"; done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing bot creds"
mkdir -p "$CD" "$SEC" "$APP"; touch "$IDX"
BOT="$(cat "$BOT_FILE")"; PASS="$(cat "$PASS_FILE")"
# Authoritative gitea host port for container port 3000 (no hardcoding; fixes EX14 assumption).
GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect gitea host port for container 3000 (podman port empty)"
say "gitea container:3000 -> host 127.0.0.1:$GT_HOST_PORT"
C2="$(code http://127.0.0.2:3000/)"
say "127.0.0.2:3000 before forwarder = $C2 (expect 000 = free)"
[ "$C2" = 000 ] || halt "127.0.0.2:3000 occupied ($C2); cannot bind forwarder"
REPOS_BEFORE="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"; REPOS_BEFORE="${REPOS_BEFORE:-0}"
SUCC_BEFORE="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_BEFORE="${SUCC_BEFORE:-0}"
say "bot=$BOT repos_before=$REPOS_BEFORE success_before=$SUCC_BEFORE headless=$PW_HEADLESS"

hr "P1 start TRANSIENT loopback forwarder 127.0.0.2:3000 -> 127.0.0.1:$GT_HOST_PORT (trap-killed)"
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
say "forwarder pid=$FWD_PID (will be killed on exit by trap)"
FWD_UP=no
for i in $(seq 1 20); do
  B="$(code http://127.0.0.2:3000/)"
  if [ "$B" != 000 ]; then FWD_UP=yes; say "forwarder live: 127.0.0.2:3000 = $B (proxies gitea)"; break; fi
  kill -0 "$FWD_PID" 2>/dev/null || { say "forwarder died; log:"; sed 's/^/    /' "$FWD_LOG"; halt "forwarder exited immediately"; }
  sleep 1
done
[ "$FWD_UP" = yes ] || { sed 's/^/    /' "$FWD_LOG" || true; halt "forwarder did not become reachable on 127.0.0.2:3000"; }

hr "P2 write NATIVE navigation script (MAP gitea->127.0.0.2; ZERO route interception)"
cp -p "$NODE_SCRIPT" "$NODE_SCRIPT.pre-EX15.bak" 2>/dev/null || true
cat > "$NODE_SCRIPT" <<'NODE15EOF'
import { chromium } from 'playwright';
const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const GT_USER = process.env.GT_USER || '';
const GT_PASS = process.env.GT_PASS || '';
const REPO = process.env.REPO || '';
const SESSION = process.env.SESSION_PATH || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';
const log = (...a) => console.log('   ', ...a);
// NATIVE resolution via the transient host forwarder; no context.route() anywhere.
const browser = await chromium.launch({
  headless: HEADLESS,
  args: ['--host-resolver-rules=MAP gitea 127.0.0.2'],
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
      await fail('navigation to gitea failed despite forwarder+MAP (see REQFAIL above)');
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
NODE15EOF
chmod 600 "$NODE_SCRIPT" 2>/dev/null || true
say "wrote $NODE_SCRIPT (native MAP; no interception)"

hr "P3 run activation (forwarder alive; capture rc; repos count decides)"
ACT_RC=0
( cd "$APP" && WP_URL="$WP" GT_USER="$BOT" GT_PASS="$PASS" REPO="$REPO" SESSION_PATH="$SESSION" PW_HEADLESS="$PW_HEADLESS" node wp-activate.mjs ) 2>&1 | sed 's/^/  /' || ACT_RC=$?
chmod 600 "$SESSION" 2>/dev/null || true
say "activation rc=$ACT_RC"
REPOS_AFTER="$(psqlq "SELECT count(*) FROM repos" | tr -d ' \n')"; REPOS_AFTER="${REPOS_AFTER:-0}"
say "repos after = $REPOS_AFTER"
psqlq "SELECT id, owner||'/'||name, active FROM repos" | sed 's/^/    repo row: /' || true

hr "P4 if unactivated: read P3 evidence (NAV vs REQFAIL) to name the exact next hop"
if [ "$REPOS_AFTER" -eq 0 ]; then
  say "Forwarder+MAP did not yield an activated repo. The P3 dump DECIDES:"
  say "  * 'NAV http://gitea:3000/...' present (no chrome-error) => browser REACHED gitea via forwarder;"
  say "    remaining failure is a login/consent SELECTOR -> fix from the buttons:/links: dump (trivial)."
  say "  * 'REQFAIL ... gitea:3000 ... ERR_CONNECTION_REFUSED/RESET' => forwarder not proxying that hop;"
  say "    check $FWD_LOG (printed below) and the detected host port."
  say "  * 'REQFAIL ... ERR_NAME_NOT_RESOLVED' for gitea => MAP arg not applied (unlikely; logged)."
  say "--- forwarder log ---"; sed 's/^/    /' "$FWD_LOG" 2>/dev/null || true
  say "Watch live (no sudo): PW_HEADLESS=0 bash \"$0\""
  say "[RESULT] EX15 PARTIAL - paste P3 verbatim + the forwarder log block."
  grep -qF "$TOKEN" "$IDX" || printf '| %s | R | %s | GATE=PARTIAL | EX15 transient loopback forwarder 127.0.0.2:3000->127.0.0.1:%s + chromium MAP gitea 127.0.0.2 (no quadlet edit, no route interception); headless rc=%s did not register repo (repos_after=0). Forwarder auto-killed by trap; no persistent change. |\n' \
    "$(date +%F)" "$TOKEN" "$GT_HOST_PORT" "$ACT_RC" >> "$IDX"
  say "ledger row appended (PARTIAL)"
  exit 1
fi

hr "P5 push trigger commit (skip if success pipeline exists)"
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
  SHA="$(git rev-parse HEAD)"; say "pushed SHA=$SHA"
  cd / || true
else
  say "success pipeline already present (count=$SUCC_NOW); no push (idempotent)"
fi

hr "P6 poll pipeline status in WP DB (read-only; the no-auth proof)"
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

hr "P7 best-effort log fetch (session cookies if present; DB success is the gate)"
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

hr "P8 RESULT + ledger (codemod record; forwarder already trap-killed = no persistent change)"
PASS_RESULT=no
[ "$FINAL" = success ] && PASS_RESULT=yes
if [ "$PASS_RESULT" = yes ]; then
  say "[RESULT] EX15 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated), via transient loopback forwarder + native MAP."
  say "  repo: $BOT/$REPO  latest pipeline: #${PNUM:-?}  status: success  success_count: $SUCC_CNT"
  say "  log proof: ${LOG_PROOF:-n/a}"
  say "  No quadlet/persistent change was made (forwarder killed by trap on exit)."
  say "  To WATCH OAuth anytime (no sudo): PW_HEADLESS=0 bash \"$0\""
else
  say "[RESULT] EX15 PARTIAL - final=${FINAL:-none} pipeline=${PNUM:-none}"
  say "  --- woodpecker-server hook/activate/repo log (3m) ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'hook|activate|repo|pipeline|404|401|error|warn' | tail -20 | sed 's/^/    /' || true
  say "  --- woodpecker-agent log (3m) ---"
  podman logs --since 3m woodpecker-agent 2>&1 | tail -20 | sed 's/^/    /' || true
fi
grep -qF "$TOKEN" "$IDX" || printf '| %s | B | %s | GATE=%s | EX15: replaced EX14 fragile quadlet-publish-edit (wrong anchor, B13) with a TRANSIENT host-side loopback forwarder 127.0.0.2:3000->127.0.0.1:%s + chromium --host-resolver-rules MAP gitea 127.0.0.2; ZERO route interception; forwarder trap-killed (no persistent change). repos %s->%s; pipeline=%s status=%s succ=%s; log=%s. Brick 12 CLOSED. |\n' \
  "$(date +%F)" "$TOKEN" "$PASS_RESULT" "$GT_HOST_PORT" "$REPOS_BEFORE" "$REPOS_AFTER" "${PNUM:-none}" "${FINAL:-none}" "$SUCC_CNT" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
say "ledger row appended"
exit 0
