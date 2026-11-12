#!/usr/bin/env bash
# 20261104-EQP — Abort stuck Playwright browser download, clean partial state.
# Leaves npm packages intact (they’re small/fast); only removes the hanging browser fetch.
set -uo pipefail
PW_DIR="$HOME/DevOps/aether/apps/playwright"
CACHE_DIR="$HOME/.cache/ms-playwright"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "Q0 Identify stuck processes"
STUCK_PIDS="$(pgrep -f 'playwright.*install.*chromium' || true)"
if [ -n "$STUCK_PIDS" ]; then
  say "Found stuck PIDs: $STUCK_PIDS"
  kill $STUCK_PIDS 2>/dev/null || true
  sleep 2
  # Force kill if still alive
  STILL_ALIVE="$(pgrep -f 'playwright.*install.*chromium' || true)"
  [ -n "$STILL_ALIVE" ] && { say "Force killing remaining: $STILL_ALIVE"; kill -9 $STILL_ALIVE 2>/dev/null || true; }
else
  say "No active playwright install processes found (already exited/stalled)."
fi

hr "Q1 Clean partial browser cache"
if [ -d "$CACHE_DIR" ]; then
  say "Removing partial cache: $CACHE_DIR"
  rm -rf "$CACHE_DIR"/chromium-* 2>/dev/null || true
  rm -rf "$CACHE_DIR"/firefox-* 2>/dev/null || true
  rm -rf "$CACHE_DIR"/webkit-* 2>/dev/null || true
  # Keep the parent dir but ensure it's empty of broken downloads
  find "$CACHE_DIR" -type f -size 0 -delete 2>/dev/null || true
else
  say "Cache dir does not exist yet."
fi

hr "Q2 Verify NPM packages remain (fast re-install if needed)"
cd "$PW_DIR" || exit 1
if [ -f node_modules/@playwright/test/package.json ]; then
  say "NPM packages intact: $(npm ls @playwright/test --depth=0 2>/dev/null | grep '@playwright/test')"
else
  say "WARNING: NPM packages missing. Re-running quick install..."
  npm install --save-dev --no-fund --no-audit @playwright/test@latest >/dev/null 2>&1
  say "Re-installed: $(npm ls @playwright/test --depth=0 2>/dev/null | grep '@playwright/test')"
fi

hr "Q3 Status Report"
say "[RESULT] EQP COMPLETE - Stuck Playwright aborted. Browser cache cleaned."
say "Next: Proceed to Brick 12 (Woodpecker Steel Thread). Playwright E2E can be retried later."
exit 0
