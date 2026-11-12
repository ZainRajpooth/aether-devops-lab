#!/usr/bin/env bash
# 20261104-EPW — install Playwright (latest) at /home/dev/DevOps/aether/apps/playwright
# next to n8n/neo-cortex. Greenfield install: npm pkg (@playwright/test pulls playwright
# lib+CLI), chromium browser, minimal real config + hermetic smoke spec = steel thread.
# Idempotent (run twice == run once); --check = dry-run; no sudo by default.
set -uo pipefail
APP="$HOME/DevOps/aether/apps"
PW="$APP/playwright"
MODE="${1:-run}"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "P0 location + toolchain gates"
[ -d "$APP" ] || { say "[HALT] $APP missing"; exit 1; }
for sib in n8n neo-cortex; do [ -d "$APP/$sib" ] && say "sibling present: $sib" || say "WARN sibling missing: $sib"; done
command -v node >/dev/null 2>&1 || { say "[HALT] node missing. Install (pick one): sudo apt-get install -y nodejs npm   OR   curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && nvm install --lts"; exit 1; }
command -v npm  >/dev/null 2>&1 || { say "[HALT] npm missing (same fix as node)"; exit 1; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
say "node=$(node -v 2>/dev/null) npm=$(npm -v 2>/dev/null) major=$NODE_MAJOR"
[ "$NODE_MAJOR" -ge 18 ] || { say "[HALT] node >=18 required for current Playwright"; exit 1; }

hr "P1 plan (MODE=$MODE)"
say "target: $PW"
say "steps: mkdir -> npm init (if absent) -> npm i -D @playwright/test@latest -> npx playwright install chromium -> write config+smoke spec -> verify"
if [ "$MODE" = check ]; then say "[RESULT] EPW CHECK - nothing written."; exit 0; fi

hr "P2 create dir + safety copies of any pre-existing manifests"
mkdir -p "$PW/tests"
for mf in package.json package-lock.json; do
  [ -f "$PW/$mf" ] && { cp -p "$PW/$mf" "$PW/$mf.pre-EPW.bak"; say "safety copy: $mf.pre-EPW.bak"; }
done
cd "$PW" || exit 1
[ -f package.json ] || npm init -y >/dev/null 2>&1

hr "P3 install packages (latest) — idempotent"
npm install --save-dev --no-fund --no-audit @playwright/test@latest 2>&1 | tail -3 | sed 's/^/    /'
say "installed: $(npm ls @playwright/test playwright --depth=0 2>/dev/null | tr '\n' ' ')"

hr "P4 install chromium browser (idempotent; no sudo)"
npx playwright install chromium 2>&1 | tail -3 | sed 's/^/    /' || true

hr "P5 write config + hermetic smoke spec (fixed-point content)"
cat > playwright.config.mjs <<'CFGEOF'
import { defineConfig, devices } from '@playwright/test';
export default defineConfig({
  testDir: './tests',
  timeout: 30000,
  retries: 0,
  reporter: [['line']],
  use: { ...devices['Desktop Chrome'], headless: true },
});
CFGEOF
cat > tests/smoke.spec.mjs <<'SPECEOF'
import { test, expect } from '@playwright/test';
test('chromium launches, renders and evaluates JS', async ({ page }) => {
  await page.goto('data:text/html,<title>pw-smoke</title><h1>ok</h1>');
  await expect(page).toHaveTitle('pw-smoke');
  await expect(page.locator('h1')).toHaveText('ok');
  const ua = await page.evaluate(() => navigator.userAgent);
  expect(ua).toContain('Chrome');
});
SPECEOF
say "wrote playwright.config.mjs + tests/smoke.spec.mjs"

hr "P6 verify: CLI version + library import + steel-thread test"
npx playwright --version 2>&1 | sed 's/^/    /'
node -e "import('playwright').then(m=>console.log('    library import OK:',typeof m.chromium.launch))" 2>&1 | sed 's/^/    /' || say "    library import FAILED"
set +e
npx playwright test --reporter=line 2>&1 | tail -6 | sed 's/^/    /'
TRC=$?
set -e
if [ "$TRC" -ne 0 ]; then
  say "[HALT] smoke failed. If the error mentions missing shared libraries, run ONCE:"
  say "    cd $PW && sudo npx playwright install-deps chromium"
  say "  then re-run this script (idempotent)."
  exit 1
fi
say "tree:"; ls -1 "$PW" | sed 's/^/    /'
say "[RESULT] EPW COMPLETE - Playwright latest installed at $PW; chromium smoke test passed."
exit 0
