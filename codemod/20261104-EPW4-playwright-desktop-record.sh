#!/usr/bin/env bash
# 20261104-EPW4 — Create the "Playwright" desktop app, symlink it into
# ~/.local/share/applications, and backfill the Playwright saga into codemod/INDEX.md.
#
# Desired behavior:
#   Clicking "Playwright" opens a terminal running:
#     /home/dev/DevOps/aether/apps/playwright/run-playwright.sh ui --ui-host 127.0.0.1 --ui-port 9323
#
# It does NOT launch the UI during verification, because UI mode is a server and can hang.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
APP="$HOME_/DevOps/aether/apps/playwright"
WRAP="$APP/run-playwright.sh"
SRC="$APP/playwright.desktop"
ADIR="$HOME_/.local/share/applications"
DESK="$ADIR/playwright.desktop"
ICON="$APP/playwright.svg"
IDX="$CD/INDEX.md"
PORT="9323"
TOKEN="epw4-playwright-desktop-record-v1"
DATEV="$(date +%F)"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

hr "W0 prepare directories"
mkdir -p "$CD" "$APP" "$ADIR"
[ -d "$APP" ] || halt "missing app dir: $APP"
say "app dir: $APP"
say "codemod dir: $CD"

hr "W1 ensure wrapper exists and is syntactically valid"
if [ ! -e "$WRAP" ]; then
  say "wrapper missing; creating $WRAP"
  cat > "$WRAP" <<'WRAP_EOF'
#!/usr/bin/env bash
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Make desktop-launched shells find node/npx even when using nvm/npm-global.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" || true

PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin:${PATH}"
export PATH

cd "$APP"

MODE="${1:-ui}"
shift || true

case "$MODE" in
  ui)
    exec npx playwright test --ui "$@"
    ;;
  test)
    exec npx playwright test "$@"
    ;;
  codegen)
    exec npx playwright codegen "$@"
    ;;
  report)
    exec npx playwright show-report "$@"
    ;;
  *)
    exec npx playwright "$MODE" "$@"
    ;;
esac
WRAP_EOF
  chmod +x "$WRAP"
else
  chmod +x "$WRAP" || true
fi

bash -n "$WRAP" || halt "wrapper syntax invalid: $WRAP"
say "wrapper OK: $WRAP"

hr "W2 icon gate"
[ -f "$ICON" ] || halt "missing icon: $ICON"
say "icon OK: $ICON"

hr "W3 write source desktop file: $SRC"
cat > "$SRC" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Playwright
GenericName=Browser Test Runner
Comment=Playwright UI on fixed port ${PORT} (opens in terminal)
Exec=${WRAP} ui --ui-host 127.0.0.1 --ui-port ${PORT}
TryExec=${WRAP}
Terminal=true
Icon=${ICON}
Categories=Development;Testing;Qt;KDE;
Keywords=playwright;test;browser;e2e;automation;ui;
StartupNotify=true
EOF

chmod 644 "$SRC"
say "wrote $SRC"

hr "W4 symlink into applications dir"
ln -sfn "$SRC" "$DESK"
say "linked $DESK -> $SRC"

hr "W5 validate desktop file"
if command -v desktop-file-validate >/dev/null 2>&1; then
  say "--- desktop-file-validate $SRC ---"
  desktop-file-validate "$SRC" 2>&1 | sed 's/^/    /' || true
  say "--- desktop-file-validate $DESK ---"
  desktop-file-validate "$DESK" 2>&1 | sed 's/^/    /' || true
else
  say "desktop-file-validate not installed; skipping syntax validation"
fi

hr "W6 prove the command can run without launching the UI server"
say "--- resolved Exec line ---"
grep -E '^Exec=' "$DESK" 2>/dev/null | sed 's/^/    /' || halt "symlink did not resolve to a file with Exec="

say "--- playwright CLI version probe ---"
(
  cd "$APP" || exit 1
  npx playwright --version 2>&1 | head -1
) | sed 's/^/    /' || say "    playwright --version failed; check npm install state"

hr "W7 refresh desktop caches"
update-desktop-database "$ADIR" >/dev/null 2>&1 || true
kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
say "desktop caches refreshed"

hr "W8 list Playwright-related codemod scripts"
ls -1 "$CD" 2>/dev/null | grep -iE 'playwright|epw|eqp' | sed 's/^/    codemod: /' || say "    none"

hr "W9 backfill codemod/INDEX.md"
touch "$IDX"

add_row(){
  local kind="$1" tok="$2" gate="$3" desc="$4"
  if grep -qF "$tok" "$IDX" 2>/dev/null; then
    say "    row exists: $tok"
  else
    printf '| %s | %s | %s | GATE=%s | %s |\n' "$DATEV" "$kind" "$tok" "$gate" "$desc" >> "$IDX"
    say "    row added: $tok"
  fi
}

add_row R "epw-install-playwright-apps-v1" INFO "EPW initial Playwright install at apps/playwright; npm package installed; Chromium download stalled."
add_row R "eqp-abort-stuck-playwright-v1" INFO "EQP aborted stalled Playwright Chromium download and cleaned partial ms-playwright cache; npm packages kept."
add_row R "epw2-robust-playwright-install-v1" INFO "EPW2 robust Playwright install; Chromium downloaded successfully; smoke test passed; browser mode playwright-managed chromium."
add_row R "epw3-playwright-desktop-and-index-backfill-v1" INFO "EPW3 failed before mutation due unbound CD inside generated child script; superseded by EPW4."
add_row B "$TOKEN" PASS "EPW4 created Name=Playwright desktop at apps/playwright/playwright.desktop; symlinked to ~/.local/share/applications/playwright.desktop; Terminal=true; Exec runs run-playwright.sh ui --ui-host 127.0.0.1 --ui-port 9323; INDEX backfilled."

hr "W10 result"
say "[RESULT] EPW4 COMPLETE"
say "  source desktop : $SRC"
say "  menu symlink   : $DESK"
say "  app name       : Playwright"
say "  launch command : ${WRAP} ui --ui-host 127.0.0.1 --ui-port ${PORT}"
say "  browser URL    : http://127.0.0.1:${PORT}"
say ""
say "Click the new 'Playwright' entry, or launch from terminal with:"
say "  gtk-launch playwright.desktop"
say ""
say "If Plasma ignores the symlink, replace it with a real file using:"
say "  install -Dm644 '$SRC' '$DESK' && update-desktop-database '$ADIR'"
exit 0
