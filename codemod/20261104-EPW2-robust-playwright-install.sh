#!/usr/bin/env bash
# 20261104-EPW2 — robust Playwright install at ~/DevOps/aether/apps/playwright.
# Installs @playwright/test + playwright, tries Chromium download with timeout/retry,
# falls back to system chromium/chrome if download fails, verifies with a smoke test.
set -uo pipefail
APP="$HOME/DevOps/aether/apps"
PW="$APP/playwright"
INSTALL_TIMEOUT="${PW_INSTALL_TIMEOUT:-900}"   # seconds per attempt
MODE="${1:-run}"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

hr "P0 location + toolchain gates"
[ -d "$APP" ] || halt "$APP missing"
command -v node >/dev/null 2>&1 || halt "node missing"
command -v npm  >/dev/null 2>&1 || halt "npm missing"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
say "node=$(node -v) npm=$(npm -v) major=$NODE_MAJOR target=$PW"
[ "$NODE_MAJOR" -ge 18 ] || halt "node >=18 required"
if [ "$MODE" = check ]; then say "[RESULT] EPW2 CHECK - nothing written."; exit 0; fi

hr "P1 npm packages (latest)"
mkdir -p "$PW/tests"
cd "$PW" || halt "cd failed"
[ -f package.json ] || npm init -y >/dev/null 2>&1
npm install --save-dev --no-fund --no-audit @playwright/test@latest playwright@latest 2>&1 | tail -3 | sed 's/^/    /'
say "installed: $(npm ls @playwright/test playwright --depth=0 2>/dev/null | tr '\n' ' ')"

hr "P2 Chromium download attempt (timeout + retry)"
BROWSER_OK=no
TIMEOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD="timeout $INSTALL_TIMEOUT"
# Optional mirror: PW_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright bash "$F" run
if [ -n "${PW_DOWNLOAD_HOST:-}" ]; then
  export PLAYWRIGHT_DOWNLOAD_HOST="$PW_DOWNLOAD_HOST"
  say "using PLAYWRIGHT_DOWNLOAD_HOST=$PLAYWRIGHT_DOWNLOAD_HOST"
fi
for attempt in 1 2; do
  say "attempt $attempt: npx playwright install chromium"
  if $TIMEOUT_CMD npx playwright install chromium; then
    BROWSER_OK=yes; break
  else
    say "attempt $attempt failed or timed out"
  fi
done
# Even if the command exited oddly, accept a completed browser tree if present.
if [ "$BROWSER_OK" != yes ] && ls "$HOME/.cache/ms-playwright"/chromium-*/chrome-linux/chrome >/dev/null 2>&1; then
  BROWSER_OK=yes
fi

hr "P3 system browser fallback if download failed"
SYSTEM_EXE=""
if [ "$BROWSER_OK" != yes ]; then
  for cand in google-chrome chromium chromium-browser microsoft-edge; do
    if command -v "$cand" >/dev/null 2>&1; then
      SYSTEM_EXE="$(command -v "$cand")"
      say "fallback system browser: $SYSTEM_EXE"
      break
    fi
  done
  [ -n "$SYSTEM_EXE" ] || say "no system chromium/chrome found either"
fi

hr "P4 write config + hermetic smoke spec"
cat > playwright.config.mjs <<'CFGEOF'
import { defineConfig, devices } from '@playwright/test';

const exe = process.env.PW_EXECUTABLE_PATH || undefined;

export default defineConfig({
  testDir: './tests',
  timeout: 30000,
  retries: 0,
  reporter: [['line']],
  use: {
    ...devices['Desktop Chrome'],
    headless: true,
    ...(exe ? { launchOptions: { executablePath: exe } } : {}),
  },
});
CFGEOF

cat > tests/smoke.spec.mjs <<'SPECEOF'
import { test, expect } from '@playwright/test';

test('chromium launches, renders and evaluates JS', async ({ page }) => {
  await page.goto('data:text/html,<title>pw-smoke</title><h1>ok</h1>');
  await expect(page).toHaveTitle('pw-smoke');
  await expect(page.locator('h1')).toHaveText('ok');
  const ua = await page.evaluate(() => navigator.userAgent);
  expect(ua).toMatch(/Chrome|Chromium/);
});
SPECEOF
say "wrote playwright.config.mjs + tests/smoke.spec.mjs"

hr "P5 verify"
npx playwright --version 2>&1 | sed 's/^/    /'
node -e "import('playwright').then(m=>console.log('    library import OK:',typeof m.chromium.launch))" 2>&1 | sed 's/^/    /' || say "    library import FAILED"

set +e
if [ "$BROWSER_OK" = yes ]; then
  say "verifying with Playwright-managed Chromium"
  npx playwright test --reporter=line 2>&1 | tail -8 | sed 's/^/    /'
  TRC=$?
elif [ -n "$SYSTEM_EXE" ]; then
  say "verifying with system browser: $SYSTEM_EXE"
  PW_EXECUTABLE_PATH="$SYSTEM_EXE" npx playwright test --reporter=line 2>&1 | tail -8 | sed 's/^/    /'
  TRC=$?
else
  TRC=1
fi
set -e

if [ "$TRC" -ne 0 ]; then
  say "smoke failed. If the error mentions missing shared libraries, run ONCE:"
  say "    cd $PW && sudo npx playwright install-deps chromium"
  say "  then re-run this script. If it was a download stall, retry with a mirror:"
  say "    PW_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright PW_INSTALL_TIMEOUT=1800 bash $F run"
  halt "Playwright verification failed"
fi

cat > "$PW/run-playwright.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -n "${PW_EXECUTABLE_PATH:-}" ]; then
  exec npx playwright "$@"
else
  # auto-use saved system exe if present
  if [ -f .pw-executable-path ]; then
    PW_EXECUTABLE_PATH="$(cat .pw-executable-path)" exec npx playwright "$@"
  fi
  exec npx playwright "$@"
fi
RUNEOF
chmod +x "$PW/run-playwright.sh"
[ -n "$SYSTEM_EXE" ] && printf '%s\n' "$SYSTEM_EXE" > "$PW/.pw-executable-path" || rm -f "$PW/.pw-executable-path"

say "tree:"; ls -1 "$PW" | sed 's/^/    /'
say "[RESULT] EPW2 COMPLETE - Playwright latest installed at $PW; smoke test passed."
say "  browser mode: $([ "$BROWSER_OK" = yes ] && echo 'playwright-managed chromium' || echo "system browser $SYSTEM_EXE")"
exit 0
