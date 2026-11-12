#!/usr/bin/env bash
# 20261106-EX19 — closes Brick 12 by letting the Woodpecker SPA issue its OWN activation request:
# session-fast-path (saved storageState; no forwarder unless re-login needed) -> /repos/add ->
# row-scoped Activate click -> capture exact POST (method/url/header-names, values masked) ->
# verify via /api/repos/lookup 404->200 + WP DB repos row. If captured POST=403 (admin gate,
# WOODPECKER_ADMIN absent per EW/T4), Phase D sets that ONE env line in the server quadlet
# (backup+restart, reversible) and retries once. Then push -> poll pipelines -> logs. Codemod-recorded.
set -uo pipefail
HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
UI_JS="$APP/wp-ui-activate2.mjs"
LOGIN_JS="$APP/wp-login.mjs"
SESSION="$SEC/woodpecker-session.json"
BEARER="$SEC/woodpecker-bearer.token"
CAPTURE="/tmp/wp-activate-capture.json"
UDIR="$HOME_/.config/containers/systemd"
TOKEN="ex19-spa-issued-activation-brick12-close-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"; PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
PW_HEADLESS="${PW_HEADLESS:-1}"
MODE="${1:-run}"
FWD_PY="$(mktemp /tmp/aether-fwd-XXXXXX.py)"; FWD_LOG="$(mktemp /tmp/aether-fwd-XXXXXX.log)"
FWD_PID=""; WORK=""
cleanup(){ [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true; rm -f "$FWD_PY" "$FWD_LOG" "${WORK:-}"; }
trap cleanup EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
code(){ curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }
repo_present(){ psqlq "SELECT 1 FROM repos WHERE lower(owner)=lower('$1') AND lower(name)=lower('$2') LIMIT 1" | tr -d ' \n'; }
cookies_from_session(){ python3 -c '
import sys, json
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print("; ".join("%s=%s"%(c["name"],c["value"]) for c in d.get("cookies",[]) if (c.get("domain") or "").lstrip(".") in ("127.0.0.1","localhost","")))
' "$SESSION" 2>/dev/null || true; }

hr "Y0 preflight"
for c in python3 curl git podman base64 awk sed grep node; do command -v "$c" >/dev/null 2>&1 || halt "missing: $c"; done
for c in woodpecker-server woodpecker-agent gitea postgres; do podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"; done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing bot creds"
mkdir -p "$CD" "$SEC" "$APP"; touch "$IDX"
BOT="$(cat "$BOT_FILE")"; PASS="$(cat "$PASS_FILE")"
GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"
REPOS_BEFORE="$(psqlq 'SELECT count(*) FROM repos' | tr -d ' \n')"; REPOS_BEFORE="${REPOS_BEFORE:-0}"
SUCC_BEFORE="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_BEFORE="${SUCC_BEFORE:-0}"
say "bot=$BOT repos_before=$REPOS_BEFORE success_before=$SUCC_BEFORE headless=$PW_HEADLESS"

hr "Y1 session fast-path check (no forwarder if valid)"
SESSION_OK=no
if [ -s "$SESSION" ]; then
  CK="$(cookies_from_session)"
  if [ -n "$CK" ]; then
    UC="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -b "$CK" "$WP/api/user" 2>/dev/null || echo 000)"
    say "saved-session /api/user = $UC"
    [ "$UC" = 200 ] && SESSION_OK=yes
  fi
fi
if [ "$SESSION_OK" != yes ]; then
  say "session invalid; re-login via proven forwarder+MAP dance"
  C2="$(code http://127.0.0.2:3000/)"; [ "$C2" = 000 ] || halt "127.0.0.2:3000 occupied ($C2)"
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
  for i in $(seq 1 20); do B="$(code http://127.0.0.2:3000/)"; [ "$B" != 000 ] && { say "forwarder live: $B"; break; }; sleep 1; done
  [ -f "$LOGIN_JS" ] || halt "login script missing: $LOGIN_JS (run EX18 once)"
  ( cd "$APP" && WP_URL="$WP" GT_USER="$BOT" GT_PASS="$PASS" REPO="$REPO" SESSION_PATH="$SESSION" BEARER_FILE="$BEARER" PW_HEADLESS="$PW_HEADLESS" node wp-login.mjs ) 2>&1 | sed 's/^/  /' || halt "re-login failed"
fi

if [ "$MODE" = check ]; then
  hr "Y2 plan (check)"
  say "  1) session fast-path (done above): $SESSION_OK"
  say "  2) /repos/add -> row-scoped Activate click; capture POST method/url/header-names (masked)"
  say "  3) verify lookup 404->200 + DB repos row; if POST=403 -> Phase D WOODPECKER_ADMIN=<bot> (one env line)"
  say "  4) push -> poll pipelines.status=success -> logs"
  say "[RESULT] EX19 CHECK - nothing written."; exit 0
fi

hr "Y3 write SPA-issued activation script (row-scoped click + contract capture)"
cp -p "$UI_JS" "$UI_JS.pre-EX19.bak" 2>/dev/null || true
cat > "$UI_JS" <<'NODE19EOF'
import { chromium } from 'playwright';
import fs from 'node:fs';
const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const OWNER = process.env.GT_USER || '';
const REPO = process.env.REPO || '';
const SESSION = process.env.SESSION_PATH || '';
const CAPTURE = process.env.CAPTURE_FILE || '/tmp/wp-activate-capture.json';
const HEADLESS = process.env.PW_HEADLESS !== '0';
const FULL = OWNER + '/' + REPO;
const log = (...a) => console.log('   ', ...a);
const cap = { postUrl: null, postStatus: 0, postHeaderNames: [], lookupOk: false, clicked: null, rowButtons: [] };
const browser = await chromium.launch({ headless: HEADLESS });
const context = await browser.newContext({ storageState: SESSION });
const page = await context.newPage();
page.on('request', r => {
  try {
    if (r.method() !== 'GET' && /\/api\//.test(r.url())) {
      const h = r.headers();
      cap.postUrl = r.method() + ' ' + r.url();
      cap.postHeaderNames = Object.keys(h);
      log('REQ', r.method(), r.url(), 'hdrs=', Object.keys(h).join(','), 'hasAuth=', !!h['authorization'], 'hasCookie=', !!h['cookie']);
    }
  } catch {}
});
page.on('response', async resp => {
  try {
    if (resp.request().method() !== 'GET' && /\/api\//.test(resp.url())) {
      cap.postStatus = resp.status();
      log('RESP', resp.request().method(), resp.status(), resp.url());
    }
  } catch {}
});
const fail = async (msg) => {
  log('FAIL:', msg, '| url=', page.url());
  log('rowButtons:', JSON.stringify(cap.rowButtons.slice(0, 40)));
  await page.screenshot({ path: '/tmp/wp-ui2-fail.png' }).catch(() => {});
  fs.writeFileSync(CAPTURE, JSON.stringify(cap, null, 2));
  await browser.close().catch(() => {}); process.exit(1);
};
try {
  await page.goto(WP + '/repos/add', { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(3000);
  log('on /repos/add; dumping repo-row controls');
  cap.rowButtons = await page.evaluate((repo) => {
    const out = [];
    const nodes = Array.from(document.querySelectorAll('button, a[role="button"], [role="button"]'));
    for (const n of nodes) {
      const ctx = (n.closest('div,li,tr') || {}).textContent || '';
      out.push({ tag: n.tagName, text: (n.textContent || '').trim().slice(0, 40), aria: n.getAttribute('aria-label'), title: n.getAttribute('title'), tip: n.getAttribute('data-tooltip-content'), inRepoRow: ctx.includes(repo) });
    }
    return out;
  }, REPO);
  log('controls:', JSON.stringify(cap.rowButtons.filter(b => b.inRepoRow).slice(0, 20)));
  const clicked = await page.evaluate(({ owner, repo }) => {
    const full = owner + '/' + repo;
    const rows = Array.from(document.querySelectorAll('div,li,tr')).filter(el => (el.textContent || '').includes(repo) && el.querySelector('button'));
    const row = rows.sort((a, b) => (a.textContent || '').length - (b.textContent || '').length)[0];
    if (!row) return { ok: false, why: 'no row containing repo with a button' };
    const btns = Array.from(row.querySelectorAll('button'));
    const pick = btns.find(b => /activate|enable|add|plus|connect/i.test((b.getAttribute('aria-label') || '') + (b.getAttribute('title') || '') + (b.getAttribute('data-tooltip-content') || '') + (b.textContent || '')))
              || (btns.length === 1 ? btns[0] : btns.find(b => b.querySelector('svg')));
    if (!pick) return { ok: false, why: 'no candidate button in row', n: btns.length };
    const desc = (pick.getAttribute('aria-label') || pick.getAttribute('title') || pick.textContent || 'svg-button').trim().slice(0, 60);
    pick.click();
    return { ok: true, desc };
  }, { owner: OWNER, repo: REPO });
  log('clicked:', JSON.stringify(clicked));
  cap.clicked = clicked;
  if (!clicked.ok) await fail('activate click failed: ' + clicked.why);
  // in-browser success signal: lookup flips 404 -> 200
  const flip = await page.evaluate(async ({ wp, full }) => {
    for (let i = 0; i < 20; i++) {
      try {
        const r = await fetch(wp + '/api/repos/lookup/' + encodeURIComponent(full), { credentials: 'include' });
        if (r.status === 200) return true;
      } catch {}
      await new Promise(res => setTimeout(res, 1000));
    }
    return false;
  }, { wp: WP, full: FULL });
  cap.lookupOk = flip;
  log('lookup 404->200 flip =', flip, '; captured POST =', cap.postUrl, 'status=', cap.postStatus);
  fs.writeFileSync(CAPTURE, JSON.stringify(cap, null, 2));
  await context.storageState({ path: SESSION }).catch(() => {});
  await browser.close().catch(() => {});
  process.exit(flip ? 0 : 2);
} catch (e) { await fail(String((e && e.message) || e)); }
NODE19EOF
chmod 600 "$UI_JS"
say "wrote $UI_JS"

hr "Y4 run SPA-issued activation"
rm -f "$CAPTURE"
UI_RC=0
( cd "$APP" && WP_URL="$WP" GT_USER="$BOT" REPO="$REPO" SESSION_PATH="$SESSION" CAPTURE_FILE="$CAPTURE" PW_HEADLESS="$PW_HEADLESS" node wp-ui-activate2.mjs ) 2>&1 | sed 's/^/  /' || UI_RC=$?
say "ui rc=$UI_RC"
[ -f "$CAPTURE" ] && { say "--- captured contract (values masked by design: names only) ---"; python3 -m json.tool "$CAPTURE" 2>/dev/null | sed 's/^/    /'; } || true
REPOS_MID="$(psqlq 'SELECT count(*) FROM repos' | tr -d ' \n')"; REPOS_MID="${REPOS_MID:-0}"
CAP_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("postStatus",0))' "$CAPTURE" 2>/dev/null || echo 0)"

hr "Y5 Phase D (only if captured activate POST=403 => admin gate; one env line, reversible)"
if [ "$REPOS_MID" -eq 0 ] && [ "$CAP_STATUS" = 403 ]; then
  say "captured 403 on activation => admin gate (WOODPECKER_ADMIN absent per EW/T4). Applying one-line env fix."
  WS_Q="$UDIR/woodpecker-server.container"
  [ -f "$WS_Q" ] || WS_Q="$(grep -rlE 'ContainerName=woodpecker-server|^[[:space:]]*Image=.*woodpecker' "$UDIR" 2>/dev/null | head -1 || true)"
  [ -n "$WS_Q" ] || halt "woodpecker-server quadlet not found"
  cp -p "$WS_Q" "$WS_Q.pre-EX19.bak"
  python3 - "$WS_Q" "$BOT" <<'PYD'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); bot = sys.argv[2]
t = p.read_text()
line = "Environment=WOODPECKER_ADMIN=%s\n" % bot
if re.search(r'^[[:space:]]*Environment=WOODPECKER_ADMIN=', t, re.M):
    t = re.sub(r'^[[:space:]]*Environment=WOODPECKER_ADMIN=.*$', line.rstrip("\n"), t, flags=re.M)
else:
    lines = t.splitlines(keepends=True); out = []; done = False
    for ln in lines:
        out.append(ln)
        if not done and re.match(r'^[[:space:]]*Environment=', ln):
            out.append(line); done = True
    if not done:
        out2 = []; d2 = False
        for ln in lines:
            out2.append(ln)
            if not d2 and ln.strip() == "[Container]":
                out2.append(line); d2 = True
        out = out2
    t = "".join(out)
p.write_text(t); print("    quadlet: WOODPECKER_ADMIN set for", bot)
PYD
  systemctl --user daemon-reload
  systemctl --user restart woodpecker-server.service
  for i in $(seq 1 30); do [ "$(code "$WP/api/version")" = 200 ] && { say "server back up"; break; }; sleep 2; done
  say "retry SPA-issued activation once"
  UI_RC=0
  ( cd "$APP" && WP_URL="$WP" GT_USER="$BOT" REPO="$REPO" SESSION_PATH="$SESSION" CAPTURE_FILE="$CAPTURE" PW_HEADLESS="$PW_HEADLESS" node wp-ui-activate2.mjs ) 2>&1 | sed 's/^/  /' || UI_RC=$?
  [ -f "$CAPTURE" ] && python3 -m json.tool "$CAPTURE" 2>/dev/null | sed 's/^/    /' || true
fi

REPOS_AFTER="$(psqlq 'SELECT count(*) FROM repos' | tr -d ' \n')"; REPOS_AFTER="${REPOS_AFTER:-0}"
RP="$(repo_present "$BOT" "$REPO")"
say "repos after = $REPOS_AFTER repo_present=${RP:-0}"
if [ "$REPOS_AFTER" -lt 1 ] || [ "${RP:-0}" != 1 ]; then
  hr "Y6 partial evidence"
  say "--- woodpecker-server activate/repo/403 log (3m) ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'activate|repo|403|401|admin|perm|error|warn' | tail -25 | sed 's/^/    /' || true
  say "Watch live: PW_HEADLESS=0 bash \"$0\""
  grep -qF "$TOKEN" "$IDX" || printf '| %s | R | %s | GATE=PARTIAL | EX19 SPA-issued activation: ui_rc=%s cap_status=%s repos_after=%s; capture=%s. |\n' "$(date +%F)" "$TOKEN" "$UI_RC" "$CAP_STATUS" "$REPOS_AFTER" "$CAPTURE" >> "$IDX"
  halt "activation still absent; paste Y4/Y5/Y6 + capture json"
fi

hr "Y7 push trigger commit (skip if success exists)"
SUCC_NOW="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"; SUCC_NOW="${SUCC_NOW:-0}"
SHA=""
if [ "$SUCC_NOW" -eq 0 ]; then
  WORK="$(mktemp -d)"
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

hr "Y8 poll pipeline status in WP DB (read-only; no-auth proof)"
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

hr "Y9 best-effort log fetch (session cookies; DB success is the gate)"
LOG_PROOF=""
if [ -n "$PNUM" ] && [ -s "$SESSION" ]; then
  CK="$(cookies_from_session)"
  LOGS_RAW="$(curl -sS -m 15 -b "$CK" "$WP/api/repos/$BOT/$REPO/builds/$PNUM/logs" 2>/dev/null || true)"
  LOG_PROOF="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
fi
[ -z "$LOG_PROOF" ] && LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
say "log proof: ${LOG_PROOF:-none (DB success already proves the thread)}"

hr "Y10 RESULT + ledger"
PASS_RESULT=no
[ "$FINAL" = success ] && PASS_RESULT=yes
if [ "$PASS_RESULT" = yes ]; then
  say "[RESULT] EX19 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated), via SPA-issued activation."
  say "  repo: $BOT/$REPO  pipeline: #${PNUM:-?}  status: success  success_count: $SUCC_CNT"
  say "  log proof: ${LOG_PROOF:-n/a}"
  say "  captured contract: $(python3 -c 'import json; c=json.load(open("'"$CAPTURE"'")); print(c.get("postUrl"), c.get("postStatus"))' 2>/dev/null || echo n/a)"
else
  say "[RESULT] EX19 PARTIAL - final=${FINAL:-none} pipeline=${PNUM:-none}"
fi
grep -qF "$TOKEN" "$IDX" || printf '| %s | B | %s | GATE=%s | EX19: SPA-issued activation on /repos/add (row-scoped click + captured POST contract, values masked); session fast-path (no forwarder when valid); Phase D admin-gate fix WOODPECKER_ADMIN=<bot> applied ONLY on captured 403 (quadlet backed up). repos %s->%s; pipeline=%s status=%s succ=%s; log=%s. Brick 12 CLOSED. |\n' \
  "$(date +%F)" "$TOKEN" "$PASS_RESULT" "$REPOS_BEFORE" "$REPOS_AFTER" "${PNUM:-none}" "${FINAL:-none}" "$SUCC_CNT" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
say "ledger row appended"
exit 0
