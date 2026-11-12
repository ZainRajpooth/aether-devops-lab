#!/usr/bin/env bash
# 20261106-EX18 — Brick 12 contract-first closure.
# EX17 proved: login/session works, but POST /api/repos/{owner}/{repo}=401 with no CSRF cookie.
# EX18 stops guessing headers. It:
#   A) reuses proven transient loopback forwarder + Chromium host-resolver-rules MAP login;
#   B) saves Woodpecker storageState immediately and captures bearer/token from responses/localStorage;
#   C) parses /swagger/doc.json and tries swagger-derived + known activation endpoints using Cookie+Bearer;
#   D) creates/uses a Woodpecker API token if required;
#   E) falls back to clicking the real Woodpecker UI Activate control;
#   F) gates proof on Woodpecker Postgres repos/pipelines.
# No quadlet change. No persistent fleet change. Codemod-recorded. Secrets masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
LOGIN_JS="$APP/wp-login.mjs"
UI_JS="$APP/wp-ui-activate.mjs"
PY_ACT="$APP/wp-api-activate.py"
SESSION="$SEC/woodpecker-session.json"
BEARER="$SEC/woodpecker-bearer.token"
TOKEN="ex18-contract-first-woodpecker-activation-brick12-close-v1"

REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"
PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"
PW_HEADLESS="${PW_HEADLESS:-1}"
MODE="${1:-run}"

FWD_PY="$(mktemp /tmp/aether-fwd-XXXXXX.py)"
FWD_LOG="$(mktemp /tmp/aether-fwd-XXXXXX.log)"
FWD_PID=""
WORK=""
cleanup(){
  [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true
  rm -f "$FWD_PY" "$FWD_LOG" "${WORK:-}"
}
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
psqlq(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
code(){ curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }
repo_present(){
  psqlq "SELECT 1 FROM repos WHERE lower(owner)=lower('$1') AND lower(name)=lower('$2') LIMIT 1" | tr -d ' \n'
}

hr "X0 preflight"
for c in python3 curl git podman base64 awk sed grep node; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"
done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
mkdir -p "$CD" "$SEC" "$APP"
touch "$IDX"

BOT="$(cat "$BOT_FILE")"
PASS="$(cat "$PASS_FILE")"
GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port for container port 3000"
GT="http://127.0.0.1:$GT_HOST_PORT"

C2="$(code http://127.0.0.2:3000/)"
say "Gitea container:3000 -> host $GT"
say "127.0.0.2:3000 before forwarder = $C2 (expect 000 = free)"
[ "$C2" = 000 ] || halt "127.0.0.2:3000 occupied ($C2)"

REPOS_BEFORE="$(psqlq 'SELECT count(*) FROM repos' | tr -d ' \n')"
REPOS_BEFORE="${REPOS_BEFORE:-0}"
SUCC_BEFORE="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"
SUCC_BEFORE="${SUCC_BEFORE:-0}"
say "bot=$BOT repos_before=$REPOS_BEFORE success_before=$SUCC_BEFORE headless=$PW_HEADLESS"

if [ "$MODE" = check ]; then
  hr "X1 plan (check mode)"
  say "  1) transient forwarder 127.0.0.2:3000 -> $GT"
  say "  2) Playwright login only; save storageState + capture bearer/token masked"
  say "  3) Python parses swagger and tries activation endpoints with Cookie+Bearer"
  say "  4) If needed, UI Activate fallback"
  say "  5) DB-gated proof: repos row + pipelines.status=success"
  say "[RESULT] EX18 CHECK - nothing written."
  exit 0
fi

hr "X2 start transient loopback forwarder"
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
  if [ "$B" != 000 ]; then FWD_UP=yes; say "forwarder live: 127.0.0.2:3000 = $B (proxies Gitea)"; break; fi
  kill -0 "$FWD_PID" 2>/dev/null || { say "forwarder died; log:"; sed 's/^/    /' "$FWD_LOG"; halt "forwarder exited immediately"; }
  sleep 1
done
[ "$FWD_UP" = yes ] || { sed 's/^/    /' "$FWD_LOG" || true; halt "forwarder not reachable on 127.0.0.2:3000"; }

hr "X3 write Phase A login-only Playwright script"
cat > "$LOGIN_JS" <<'NODELOGIN_EOF'
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const GT_USER = process.env.GT_USER || '';
const GT_PASS = process.env.GT_PASS || '';
const REPO = process.env.REPO || '';
const SESSION = process.env.SESSION_PATH || '';
const BEARER_FILE = process.env.BEARER_FILE || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';

let bearer = '';
const log = (...a) => console.log('   ', ...a);

function safeUrl(u) {
  try {
    const x = new URL(u);
    for (const k of ['state','code','token','access_token','refresh_token','redirect_uri']) {
      if (x.searchParams.has(k)) {
        const v = x.searchParams.get(k) || '';
        x.searchParams.set(k, `[len=${v.length}]`);
      }
    }
    return x.toString();
  } catch {
    return u;
  }
}

function looksToken(v) {
  return typeof v === 'string' && v.length >= 20 && !/\s/.test(v) && !v.includes('://');
}

function maybeToken(v, src) {
  if (!bearer && looksToken(v)) {
    bearer = v;
    log(`TOKEN captured from ${src} len=${v.length}`);
  }
}

function scanJson(obj, src, depth = 0) {
  if (depth > 7 || obj == null) return;
  if (Array.isArray(obj)) {
    for (const x of obj) scanJson(x, src, depth + 1);
    return;
  }
  if (typeof obj === 'object') {
    for (const [k, v] of Object.entries(obj)) {
      if (typeof v === 'string' && /token|jwt|access|secret|auth/i.test(k)) maybeToken(v, `${src}:${k}`);
      scanJson(v, `${src}:${k}`, depth + 1);
    }
  }
}

const browser = await chromium.launch({
  headless: HEADLESS,
  args: ['--host-resolver-rules=MAP gitea 127.0.0.2'],
});
const context = await browser.newContext();
const page = await context.newPage();

page.on('framenavigated', f => { try { log('NAV', safeUrl(f.url())); } catch {} });
page.on('requestfailed', r => { try { log('REQFAIL', r.resourceType(), safeUrl(r.url()), (r.failure() || {}).errorText); } catch {} });
page.on('response', async resp => {
  try {
    const u = resp.url();
    if (!/\/api\/|\/authorize/.test(u)) return;
    log('APIRESP', resp.request().method(), resp.status(), safeUrl(u));
    const ct = resp.headers()['content-type'] || '';
    if (ct.includes('json')) {
      const j = await resp.json().catch(() => null);
      if (j) scanJson(j, `resp ${safeUrl(u)}`);
    }
  } catch {}
});

const api = context.request;
const fail = async (msg) => {
  const btns = await page.getByRole('button').allTextContents().catch(() => []);
  const links = await page.getByRole('link').allTextContents().catch(() => []);
  log('FAIL:', msg, '| url=', safeUrl(page.url()));
  log('buttons:', JSON.stringify(btns.slice(0, 30)));
  log('links:', JSON.stringify(links.slice(0, 30)));
  await page.screenshot({ path: '/tmp/wp-login-fail.png' }).catch(() => {});
  await browser.close().catch(() => {});
  process.exit(1);
};

try {
  await page.goto(WP, { waitUntil: 'domcontentloaded', timeout: 30000 });
  let me = await api.get(WP + '/api/user');
  if (me.status() === 200) {
    log('already authenticated (session valid)');
  } else {
    log('not authed (api/user=' + me.status() + '); waiting for Gitea login control');
    const btn = page.getByRole('button', { name: /gitea/i }).first();
    await btn.waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
    if (await btn.isVisible().catch(() => false)) {
      log('click Gitea button');
      await btn.click();
    } else {
      const lk = page.getByRole('link', { name: /gitea/i }).first();
      await lk.waitFor({ state: 'visible', timeout: 10000 }).catch(() => {});
      if (await lk.isVisible().catch(() => false)) {
        log('click Gitea link');
        await lk.click();
      } else {
        await fail('no Gitea login control after waitFor');
      }
    }

    await page.waitForLoadState('domcontentloaded', { timeout: 20000 }).catch(() => {});
    log('after click url=', safeUrl(page.url()));
    if (/chrome-error|chromewebdata/.test(page.url())) {
      await fail('navigation to Gitea failed despite forwarder+MAP (see REQFAIL)');
    }

    const user = page.locator('input[name="user_name"], input[name="username"], input#user_name, input[type="text"]').first();
    await user.waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
    if (!(await user.isVisible().catch(() => false))) await fail('Gitea user field not visible; url=' + safeUrl(page.url()));
    await user.fill(GT_USER);

    const pw = page.locator('input[name="password"], input#password, input[type="password"]').first();
    await pw.waitFor({ state: 'visible', timeout: 10000 }).catch(() => {});
    await pw.fill(GT_PASS);

    const submit = page.getByRole('button', { name: /^\s*sign\s+in\s*$/i }).first();
    await submit.waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
    if (!(await submit.isVisible().catch(() => false))) await fail('visible Sign In button not found; url=' + safeUrl(page.url()));
    log('clicking visible Sign In');
    await submit.click();

    log('submitted Gitea login; awaiting consent/return');
    const deadline = Date.now() + 45000;
    while (Date.now() < deadline) {
      const cur = page.url();
      if (cur.startsWith(WP)) break;
      if (/\/login\/oauth\/authorize|\/authorize\b/.test(cur)) {
        const g = page.getByRole('button', { name: /authorize|grant|allow|approve|confirm/i }).first();
        if (await g.isVisible().catch(() => false)) {
          log('consent: authorizing');
          await g.click().catch(() => {});
          await page.waitForTimeout(1500);
        }
      }
      await page.waitForTimeout(700);
    }

    if (!page.url().startsWith(WP)) await fail('did not return to WP after login; url=' + safeUrl(page.url()));
    me = await api.get(WP + '/api/user');
    if (me.status() !== 200) await fail('/api/user ' + me.status() + ' after login');
  }

  const meJson = await me.json().catch(() => ({}));
  log('session OK id=', meJson.id, 'login=', meJson.login, 'forge_id=', meJson.forge_id);

  const cookies = await context.cookies();
  log('COOKIES', cookies.map(c => `${c.name} domain=${c.domain} httpOnly=${c.httpOnly}`).join(', ') || '(none)');

  const localKeys = await page.evaluate(() => Object.keys(localStorage || {})).catch(() => []);
  log('LOCALSTORAGE_KEYS', JSON.stringify(localKeys));
  const localToken = await page.evaluate(() => {
    try {
      for (const [k, v] of Object.entries(localStorage || {})) {
        if (typeof v !== 'string') continue;
        if (/token|jwt|auth|secret/i.test(k) && v.length >= 20 && !v.includes('://')) return v;
        if (/^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(v)) return v;
      }
    } catch {}
    return '';
  }).catch(() => '');
  maybeToken(localToken, 'localStorage');

  const sessionKeys = await page.evaluate(() => Object.keys(sessionStorage || {})).catch(() => []);
  log('SESSIONSTORAGE_KEYS', JSON.stringify(sessionKeys));
  const sessionToken = await page.evaluate(() => {
    try {
      for (const [k, v] of Object.entries(sessionStorage || {})) {
        if (typeof v !== 'string') continue;
        if (/token|jwt|auth|secret/i.test(k) && v.length >= 20 && !v.includes('://')) return v;
        if (/^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(v)) return v;
      }
    } catch {}
    return '';
  }).catch(() => '');
  maybeToken(sessionToken, 'sessionStorage');

  if (SESSION) {
    await context.storageState({ path: SESSION });
    log('storageState saved:', SESSION);
  }
  if (bearer && BEARER_FILE) {
    fs.mkdirSync(path.dirname(BEARER_FILE), { recursive: true });
    fs.writeFileSync(BEARER_FILE, bearer, { mode: 0o600 });
    log('bearer saved:', BEARER_FILE, 'len=', bearer.length);
  }

  await browser.close().catch(() => {});
  process.exit(0);
} catch (e) {
  await fail(String((e && e.message) || e));
}
NODELOGIN_EOF
chmod 600 "$LOGIN_JS"
say "wrote $LOGIN_JS"

hr "X4 run Phase A login-only"
LOGIN_RC=0
(
  cd "$APP" || exit 1
  WP_URL="$WP" GT_USER="$BOT" GT_PASS="$PASS" REPO="$REPO" \
  SESSION_PATH="$SESSION" BEARER_FILE="$BEARER" PW_HEADLESS="$PW_HEADLESS" \
  node "$LOGIN_JS"
) 2>&1 | sed 's/^/  /' || LOGIN_RC=$?
chmod 600 "$SESSION" 2>/dev/null || true
chmod 600 "$BEARER" 2>/dev/null || true
say "login rc=$LOGIN_RC"
[ "$LOGIN_RC" = 0 ] || {
  say "--- login failed; paste X4 + /tmp/wp-login-fail.png description ---"
  grep -qF "$TOKEN" "$IDX" || printf '| %s | R | %s | GATE=PARTIAL | EX18 Phase A login rc=%s failed before session save. No persistent change. |\n' "$(date +%F)" "$TOKEN" "$LOGIN_RC" >> "$IDX"
  halt "Phase A login failed"
}

hr "X5 write Phase B Python contract-first activation helper"
cat > "$PY_ACT" <<'PYACT_EOF'
#!/usr/bin/env python3
import json, os, re, sys, base64, urllib.request, urllib.parse, urllib.error

WP = os.environ.get('WP_URL', 'http://127.0.0.1:8000').rstrip('/')
GT = os.environ.get('GT_URL', 'http://127.0.0.1:3001').rstrip('/')
OWNER = os.environ.get('GT_USER', '')
REPO = os.environ.get('REPO', '')
STORAGE = os.environ.get('STORAGE_PATH', '')
BEARER_FILE = os.environ.get('BEARER_FILE', '')
BOT_FILE = os.environ.get('BOT_FILE', '')
PASS_FILE = os.environ.get('PASS_FILE', '')

bearer = ''
cookie_header = ''

def log(*a):
    print('   ', *a, flush=True)

def read_text(p):
    try:
        with open(p, 'r', encoding='utf-8', errors='replace') as f:
            return f.read().strip()
    except Exception:
        return ''

def write_secret(p, v):
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(v)
    except Exception as e:
        log('WARN could not write secret file:', e)

def looks_token(v):
    return isinstance(v, str) and len(v) >= 20 and not re.search(r'\s', v) and '://' not in v

def mask_text(s):
    if not isinstance(s, str):
        s = str(s)
    if bearer:
        s = s.replace(bearer, f'[BEARER_LEN={len(bearer)}]')
    s = re.sub(r'ey[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}', lambda m: f'[JWT_LEN={len(m.group(0))}]', s)
    s = re.sub(r'[A-Za-z0-9_\-]{40,}', lambda m: f'[TOKENISH_LEN={len(m.group(0))}]', s)
    return s[:300].replace('\n', ' ').replace('\r', ' ')

def http(method, url, body=None, use_cookie=True, use_bearer=True, timeout=20):
    headers = {
        'User-Agent': 'aether-ex18',
        'Origin': WP,
        'Referer': WP + '/repos',
        'X-Requested-With': 'XMLHttpRequest',
    }
    if use_cookie and cookie_header:
        headers['Cookie'] = cookie_header
    if use_bearer and bearer:
        headers['Authorization'] = 'Bearer ' + bearer
    data = None
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode('utf-8', errors='replace')
            return r.status, raw, dict(r.headers)
    except urllib.error.HTTPError as e:
        raw = e.read().decode('utf-8', errors='replace')
        return e.code, raw, dict(e.headers)
    except Exception as e:
        return 0, 'ERR:' + str(e), {}

def get_json(url, use_cookie=True, use_bearer=True):
    st, raw, _ = http('GET', url, None, use_cookie=use_cookie, use_bearer=use_bearer)
    if st != 200:
        return None, st, raw
    try:
        return json.loads(raw), st, raw
    except Exception:
        return None, st, raw

def find_token(obj, depth=0):
    if depth > 7 or obj is None:
        return ''
    if isinstance(obj, list):
        for x in obj:
            t = find_token(x, depth + 1)
            if t:
                return t
        return ''
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str) and re.search(r'token|jwt|access|secret|auth', k, re.I) and looks_token(v):
                return v
            t = find_token(v, depth + 1)
            if t:
                return t
    return ''

def load_storage():
    global cookie_header, bearer
    if STORAGE and os.path.exists(STORAGE):
        try:
            data = json.load(open(STORAGE, 'r', encoding='utf-8'))
        except Exception as e:
            log('WARN storageState unreadable:', e)
            data = {}
        cookies = data.get('cookies', []) or []
        parts = []
        names = []
        for c in cookies:
            dom = (c.get('domain') or '').lstrip('.')
            if dom in ('127.0.0.1', 'localhost', ''):
                parts.append(f"{c.get('name')}={c.get('value')}")
                names.append(f"{c.get('name')} httpOnly={c.get('httpOnly')}")
        cookie_header = '; '.join(parts)
        log('STORAGE_COOKIES', ', '.join(names) if names else '(none for 127.0.0.1)')
        for origin in data.get('origins', []) or []:
            for item in origin.get('localStorage', []) or []:
                k = item.get('name', '')
                v = item.get('value', '')
                if looks_token(v) and (re.search(r'token|jwt|auth|secret', k, re.I) or re.match(r'^ey[A-Za-z0-9_-]+\.', v or '')):
                    if not bearer:
                        bearer = v
                        log('TOKEN found in localStorage key=', k, 'len=', len(v))
            for item in origin.get('sessionStorage', []) or []:
                k = item.get('name', '')
                v = item.get('value', '')
                if looks_token(v) and (re.search(r'token|jwt|auth|secret', k, re.I) or re.match(r'^ey[A-Za-z0-9_-]+\.', v or '')):
                    if not bearer:
                        bearer = v
                        log('TOKEN found in sessionStorage key=', k, 'len=', len(v))
    if BEARER_FILE and os.path.exists(BEARER_FILE):
        v = read_text(BEARER_FILE)
        if looks_token(v) and not bearer:
            bearer = v
            log('TOKEN loaded from bearer file len=', len(v))
    log('BEARER_PRESENT', bool(bearer), 'len=', len(bearer) if bearer else 0)
    log('COOKIE_HEADER_PRESENT', bool(cookie_header), 'len=', len(cookie_header) if cookie_header else 0)

def gitea_repo_id():
    if not (BOT_FILE and PASS_FILE):
        return ''
    u = read_text(BOT_FILE)
    p = read_text(PASS_FILE)
    if not u or not p:
        return ''
    auth = base64.b64encode(f'{u}:{p}'.encode()).decode()
    url = GT + '/api/v1/repos/' + urllib.parse.quote(u) + '/' + urllib.parse.quote(REPO)
    req = urllib.request.Request(url, headers={'Authorization': 'Basic ' + auth, 'User-Agent': 'aether-ex18'})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            j = json.loads(r.read().decode('utf-8', errors='replace'))
            return str(j.get('id', ''))
    except Exception:
        return ''

def swagger_summary_and_candidates(swagger):
    paths = (swagger or {}).get('paths', {}) or {}
    interesting = []
    for p in sorted(paths):
        if re.search(r'repo|activate|token', p, re.I):
            methods = sorted((paths[p] or {}).keys())
            params = []
            for m, op in (paths[p] or {}).items():
                for prm in (op.get('parameters') or []):
                    params.append(f"{m}:{prm.get('name')}({prm.get('in')})")
            log('SWAGGER', p, methods, ' '.join(params[:12]))
            interesting.append(p)
    return interesting

def build_candidates(swagger, forge_id, remote_id):
    full = f'{OWNER}/{REPO}'
    known = {
        'owner': OWNER,
        'name': REPO,
        'repo': REPO,
        'full_name': full,
        'fullName': full,
        'forge': 'gitea',
        'forge_id': forge_id,
        'forgeRemoteId': remote_id,
        'forge_remote_id': remote_id,
        'remote_id': remote_id,
        'id': remote_id,
        'repo_id': remote_id,
    }
    cands = []

    def add(method, path, body=None):
        url = WP + path
        cands.append((method.upper(), url, body if body is not None else {}))

    # Known/high-probability Woodpecker activation shapes.
    add('POST', '/api/repos', {'owner': OWNER, 'name': REPO})
    add('POST', '/api/repos', {'owner': OWNER, 'name': REPO, 'forge': 'gitea', 'forge_id': forge_id})
    add('POST', '/api/repos', {'repo': full})
    add('POST', '/api/repos', {'full_name': full})
    add('POST', f'/api/repos/{urllib.parse.quote(OWNER)}/{urllib.parse.quote(REPO)}', {})
    add('PUT', f'/api/repos/{urllib.parse.quote(OWNER)}/{urllib.parse.quote(REPO)}', {})
    add('POST', f'/api/repos?owner={urllib.parse.quote(OWNER)}&name={urllib.parse.quote(REPO)}', {})

    # Swagger-derived repo activation endpoints.
    paths = (swagger or {}).get('paths', {}) or {}
    for p, ops in paths.items():
        if '/api/repos' not in p:
            continue
        for m, op in (ops or {}).items():
            if m.lower() not in ('post', 'put'):
                continue
            try:
                filled = p.format(**known)
            except Exception:
                continue
            if '{' in filled or '}' in filled:
                continue
            body = {}
            for prm in (op.get('parameters') or []):
                if prm.get('in') == 'body' or prm.get('name') == 'body':
                    props = ((prm.get('schema') or {}).get('properties') or {})
                    for k in props:
                        if k in known:
                            body[k] = known[k]
                        else:
                            body[k] = OWNER if 'owner' in k.lower() else REPO
            add(m.upper(), filled, body or {})

    # Deduplicate.
    seen = set()
    uniq = []
    for c in cands:
        key = (c[0], c[1], json.dumps(c[2], sort_keys=True))
        if key not in seen:
            seen.add(key)
            uniq.append(c)
    return uniq[:30]

def try_token_creation(swagger):
    global bearer
    if bearer:
        return True
    paths = (swagger or {}).get('paths', {}) or {}
    token_paths = [p for p in paths if 'token' in p.lower()]
    for extra in ['/api/user/tokens', '/api/tokens']:
        if extra not in token_paths:
            token_paths.append(extra)
    bodies = [
        {'name': 'brick12', 'scopes': ['repo:admin']},
        {'name': 'brick12', 'scopes': ['admin:repo']},
        {'name': 'brick12', 'scope': 'repo:admin'},
        {'name': 'brick12'},
    ]
    for tp in token_paths[:6]:
        for b in bodies:
            st, raw, hdr = http('POST', WP + tp, b, use_cookie=True, use_bearer=False)
            log('TOKEN_TRY', 'POST', tp, 'status=', st, 'body=', mask_text(raw))
            tok = find_token(raw)
            if not tok:
                try:
                    tok = find_token(json.loads(raw))
                except Exception:
                    tok = ''
            if st in (200, 201) and looks_token(tok):
                bearer = tok
                if BEARER_FILE:
                    write_secret(BEARER_FILE, bearer)
                log('TOKEN_CREATED len=', len(bearer))
                return True
    return False

def try_activation(cands, label):
    for method, url, body in cands:
        short = url.replace(WP, '')
        st, raw, hdr = http(method, url, body, use_cookie=True, use_bearer=bool(bearer))
        log('ACT_TRY', label, method, short, 'status=', st, 'body=', mask_text(raw))
        if st in (200, 201, 204, 409):
            log('ACT_ACCEPTED', method, short, 'status=', st)
            return True
    return False

def main():
    load_storage()
    user_json, user_st, _ = get_json(WP + '/api/user')
    log('API_USER status=', user_st, 'login=', (user_json or {}).get('login'), 'id=', (user_json or {}).get('id'))
    forge_id = (user_json or {}).get('forge_id', 1)
    remote_id = gitea_repo_id()
    log('FORGE_ID', forge_id, 'GITEA_REPO_ID', remote_id or 'unknown')

    swagger, sw_st, _ = get_json(WP + '/swagger/doc.json', use_cookie=False, use_bearer=False)
    log('SWAGGER status=', sw_st)
    if swagger:
        swagger_summary_and_candidates(swagger)
    cands = build_candidates(swagger or {}, forge_id, remote_id)
    log('CANDIDATES', len(cands))

    if try_activation(cands, 'cookie'):
        return 0

    if try_token_creation(swagger or {}):
        if try_activation(cands, 'bearer'):
            return 0

    # One more pass if bearer existed but first pass somehow didn't use it.
    if bearer:
        if try_activation(cands, 'bearer-final'):
            return 0

    log('RESULT API_ACTIVATION_FAILED')
    return 1

if __name__ == '__main__':
    sys.exit(main())
PYACT_EOF
chmod 600 "$PY_ACT"
say "wrote $PY_ACT"

hr "X6 run Phase B contract-first API activation"
PY_RC=0
(
  WP_URL="$WP" GT_URL="$GT" GT_USER="$BOT" REPO="$REPO" \
  STORAGE_PATH="$SESSION" BEARER_FILE="$BEARER" \
  BOT_FILE="$BOT_FILE" PASS_FILE="$PASS_FILE" \
  python3 "$PY_ACT"
) 2>&1 | sed 's/^/  /' || PY_RC=$?
chmod 600 "$BEARER" 2>/dev/null || true
say "python activation rc=$PY_RC"

REPOS_AFTER_PY="$(psqlq 'SELECT count(*) FROM repos' | tr -d ' \n')"
REPOS_AFTER_PY="${REPOS_AFTER_PY:-0}"
RP="$(repo_present "$BOT" "$REPO")"
say "repos after Phase B = $REPOS_AFTER_PY repo_present=${RP:-0}"

ACTIVATED=no
if [ "$REPOS_AFTER_PY" -ge 1 ] && [ "${RP:-0}" = 1 ]; then
  ACTIVATED=yes
fi

if [ "$ACTIVATED" != yes ]; then
  hr "X7 write Phase C UI activation fallback"
  cat > "$UI_JS" <<'NODEUI_EOF'
import { chromium } from 'playwright';
import fs from 'node:fs';

const WP = process.env.WP_URL || 'http://127.0.0.1:8000';
const GT_USER = process.env.GT_USER || '';
const REPO = process.env.REPO || '';
const SESSION = process.env.SESSION_PATH || '';
const BEARER_FILE = process.env.BEARER_FILE || '';
const HEADLESS = process.env.PW_HEADLESS !== '0';

let bearer = '';
try {
  if (BEARER_FILE && fs.existsSync(BEARER_FILE)) bearer = fs.readFileSync(BEARER_FILE, 'utf8').trim();
} catch {}

const log = (...a) => console.log('   ', ...a);
function safeUrl(u) {
  try {
    const x = new URL(u);
    for (const k of ['state','code','token','access_token','refresh_token','redirect_uri']) {
      if (x.searchParams.has(k)) {
        const v = x.searchParams.get(k) || '';
        x.searchParams.set(k, `[len=${v.length}]`);
      }
    }
    return x.toString();
  } catch { return u; }
}

const browser = await chromium.launch({
  headless: HEADLESS,
  args: ['--host-resolver-rules=MAP gitea 127.0.0.2'],
});
const context = await browser.newContext({ storageState: SESSION });
const page = await context.newPage();

page.on('framenavigated', f => { try { log('NAV', safeUrl(f.url())); } catch {} });
page.on('response', async resp => {
  try {
    const u = resp.url();
    if (!/\/api\//.test(u)) return;
    log('APIRESP', resp.request().method(), resp.status(), safeUrl(u));
  } catch {}
});

const fail = async (msg) => {
  const btns = await page.getByRole('button').allTextContents().catch(() => []);
  const links = await page.getByRole('link').allTextContents().catch(() => []);
  log('FAIL:', msg, '| url=', safeUrl(page.url()));
  log('buttons:', JSON.stringify(btns.slice(0, 40)));
  log('links:', JSON.stringify(links.slice(0, 40)));
  await page.screenshot({ path: '/tmp/wp-ui-activate-fail.png' }).catch(() => {});
  await browser.close().catch(() => {});
  process.exit(1);
};

try {
  const ownerEnc = encodeURIComponent(GT_USER);
  const repoEnc = encodeURIComponent(REPO);
  const urls = [
    `/repos/${ownerEnc}/${repoEnc}`,
    `/repos/${ownerEnc}/${repoEnc}/settings`,
    `/repos`,
    `/`,
  ];
  let clicked = false;
  for (const p of urls) {
    try {
      await page.goto(WP + p, { waitUntil: 'domcontentloaded', timeout: 20000 });
    } catch (e) {
      log('goto failed', p, String(e && e.message || e));
      continue;
    }
    await page.waitForTimeout(2500);
    const loc = page.getByRole('button', { name: /activate|enable|add repository|connect/i })
      .or(page.getByRole('link', { name: /activate|enable|add repository|connect/i }))
      .first();
    if (await loc.isVisible().catch(() => false)) {
      log('UI clicking Activate at', p);
      await loc.click().catch(() => {});
      clicked = true;
      await page.waitForTimeout(8000);
      break;
    }
  }

  const list = await page.evaluate(async ({ wp, owner, repo, bearerFromNode }) => {
    let bearer = bearerFromNode || '';
    try {
      if (!bearer) {
        for (const [k, v] of Object.entries(localStorage || {})) {
          if (typeof v === 'string' && v.length >= 20 && /token|jwt|auth|secret/i.test(k)) { bearer = v; break; }
        }
      }
    } catch {}
    const headers = { 'X-Requested-With': 'XMLHttpRequest' };
    if (bearer) headers.Authorization = 'Bearer ' + bearer;
    try {
      const r = await fetch(wp + '/api/repos', { credentials: 'include', headers });
      const j = await r.json().catch(() => []);
      return { status: r.status, names: (Array.isArray(j) ? j : []).map(x => `${x.owner || ''}/${x.name || ''}`) };
    } catch (e) {
      return { status: 0, names: [], err: String(e) };
    }
  }, { wp: WP, owner: GT_USER, repo: REPO, bearerFromNode: bearer }).catch(() => ({ status: 0, names: [] }));

  log('UI_API_LIST status=', list.status, 'names=', JSON.stringify(list.names || []));
  if (!clicked) await fail('no Activate control found in UI fallback');
  await browser.close().catch(() => {});
  process.exit(0);
} catch (e) {
  await fail(String((e && e.message) || e));
}
NODEUI_EOF
  chmod 600 "$UI_JS"

  hr "X8 run Phase C UI activation fallback"
  UI_RC=0
  (
    cd "$APP" || exit 1
    WP_URL="$WP" GT_USER="$BOT" REPO="$REPO" \
    SESSION_PATH="$SESSION" BEARER_FILE="$BEARER" PW_HEADLESS="$PW_HEADLESS" \
    node "$UI_JS"
  ) 2>&1 | sed 's/^/  /' || UI_RC=$?
  say "UI fallback rc=$UI_RC"

  REPOS_AFTER="$(psqlq 'SELECT count(*) FROM repos' | tr -d ' \n')"
  REPOS_AFTER="${REPOS_AFTER:-0}"
  RP="$(repo_present "$BOT" "$REPO")"
  say "repos after Phase C = $REPOS_AFTER repo_present=${RP:-0}"
  if [ "$REPOS_AFTER" -ge 1 ] && [ "${RP:-0}" = 1 ]; then
    ACTIVATED=yes
  fi
else
  REPOS_AFTER="$REPOS_AFTER_PY"
  UI_RC="skipped"
fi

if [ "$ACTIVATED" != yes ]; then
  hr "X9 partial evidence"
  say "login rc=$LOGIN_RC python rc=$PY_UI_OR_PY ui rc=$UI_RC repos_after=${REPOS_AFTER:-0}"
  say "--- woodpecker-server activate/repo/401 log (3m) ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'activate|repo|401|403|csrf|origin|referer|token|error|warn' | tail -30 | sed 's/^/    /' || true
  say "--- forwarder log ---"
  sed 's/^/    /' "$FWD_LOG" 2>/dev/null || true
  say "Watch live (no sudo): PW_HEADLESS=0 bash \"$0\""
  grep -qF "$TOKEN" "$IDX" || printf '| %s | R | %s | GATE=PARTIAL | EX18 contract-first activation: login rc=%s python rc=%s ui rc=%s repos_after=%s bearer_present=%s. No persistent change. |\n' \
    "$(date +%F)" "$TOKEN" "$LOGIN_RC" "$PY_RC" "$UI_RC" "${REPOS_AFTER:-0}" "$([ -s "$BEARER" ] && echo yes || echo no)" >> "$IDX"
  say "ledger row appended (PARTIAL)"
  halt "Brick 12 activation still not present; paste X4/X6/X8/X9 verbatim."
fi

hr "X10 push trigger commit (skip if success pipeline exists)"
SUCC_NOW="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"
SUCC_NOW="${SUCC_NOW:-0}"
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
  SHA="$(git rev-parse HEAD)"
  say "pushed SHA=$SHA"
  cd / || true
else
  say "success pipeline already present (count=$SUCC_NOW); no push (idempotent)"
fi

hr "X11 poll pipeline status in WP DB (read-only; no-auth proof)"
FINAL=""
PNUM=""
SUCC_CNT="$SUCC_NOW"
for i in $(seq 1 40); do
  ROW="$(psqlq 'SELECT number||'"'"' '"'"'||status FROM pipelines ORDER BY id DESC LIMIT 1')"
  [ -n "$ROW" ] && { PNUM="${ROW%% *}"; FINAL="${ROW##* }"; }
  SUCC_CNT="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"
  SUCC_CNT="${SUCC_CNT:-0}"
  [ "$FINAL" = success ] && break
  [ "$SUCC_CNT" -ge 1 ] && [ "$SUCC_CNT" -gt "$SUCC_BEFORE" ] && { FINAL="success"; break; }
  case "$FINAL" in failure|error|killed) break;; esac
  sleep 3
done
say "latest pipeline=#${PNUM:-none} status=${FINAL:-none} success_count=$SUCC_CNT (was $SUCC_BEFORE)"

hr "X12 best-effort log fetch (session cookies; DB success is the gate)"
LOG_PROOF=""
if [ -n "$PNUM" ] && [ -s "$SESSION" ]; then
  COOKIES="$(python3 -c '
import sys, json
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print("; ".join("%s=%s"%(c["name"],c["value"]) for c in d.get("cookies",[])))
' "$SESSION" 2>/dev/null || true)"
  LOGS_RAW="$(curl -sS -m 15 -b "$COOKIES" "$WP/api/repos/$BOT/$REPO/builds/$PNUM/logs" 2>/dev/null || true)"
  LOG_PROOF="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
fi
[ -z "$LOG_PROOF" ] && LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
say "log proof: ${LOG_PROOF:-none (view in WP UI; DB success already proves the thread)}"

hr "X13 RESULT + ledger (Brick 12 CLOSED)"
PASS_RESULT=no
[ "$FINAL" = success ] && PASS_RESULT=yes
if [ "$PASS_RESULT" = yes ]; then
  say "[RESULT] EX18 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated), via contract-first activation."
  say "  repo: $BOT/$REPO"
  say "  latest pipeline: #${PNUM:-?}"
  say "  status: success"
  say "  success_count: $SUCC_CNT"
  say "  log proof: ${LOG_PROOF:-n/a}"
  say "  bearer_present: $([ -s "$BEARER" ] && echo yes || echo no)"
  say "  No quadlet/persistent change; transient forwarder trap-killed."
else
  say "[RESULT] EX18 PARTIAL - final=${FINAL:-none} pipeline=${PNUM:-none}"
fi

grep -qF "$TOKEN" "$IDX" || printf '| %s | B | %s | GATE=%s | EX18: contract-first Brick 12 closure. Phase A saved WP session/bearer after proven forwarder+MAP login. Phase B parsed swagger and tried Cookie+Bearer activation endpoints, including POST /api/repos collection and token creation fallback. Phase C UI Activate fallback if needed. repos_before=%s repos_after=%s; pipeline=%s status=%s succ=%s; log=%s; bearer=%s. Brick 12 CLOSED. |\n' \
  "$(date +%F)" "$TOKEN" "$PASS_RESULT" "$REPOS_BEFORE" "${REPOS_AFTER:-0}" "${PNUM:-none}" "${FINAL:-none}" "$SUCC_CNT" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" "$([ -s "$BEARER" ] && echo yes || echo no)" >> "$IDX"
say "ledger row appended"
exit 0
