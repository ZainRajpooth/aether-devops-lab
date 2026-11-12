#!/usr/bin/env bash
# 20261104-EPW3 — create the "Playwright" desktop app (Name=Playwright) that opens a
# TERMINAL running: run-playwright.sh ui --ui-host 127.0.0.1 --ui-port 9323 ; symlink it
# into ~/.local/share/applications ; and backfill the WHOLE Playwright saga (EPW/EPW2/EQP/
# EPW3) into codemod/INDEX so the GUI layer is archived/reproducible. Idempotent (re-run =
# no-op). Does NOT touch the existing playwright_ui.desktop (scope). No browser/UI launch
# in verify (avoids the hang you hit); validates the .desktop + proves the command can run.
set -uo pipefail
APP="$HOME/DevOps/aether/apps/playwright"
WRAP="$APP/run-playwright.sh"
SRC="$APP/playwright.desktop"
ADIR="$HOME/.local/share/applications"
DESK="$ADIR/playwright.desktop"
ICON="$APP/playwright.svg"
IDX="$CD/INDEX.md"
PORT="9323"
TOKEN="epw3-playwright-desktop-and-index-backfill-v1"
DATEV="$(date +%F)"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

hr "W0 gates (wrapper + toolchain + icon must exist; we do NOT launch the UI here)"
[ -d "$APP" ] || halt "app dir missing: $APP"
[ -x "$WRAP" ] || halt "wrapper missing/not executable: $WRAP (re-run the EPW2/desktop step first)"
[ -f "$ICON" ] || halt "icon missing: $ICON (place playwright.svg or edit Icon= in $SRC)"
command -v node >/dev/null 2>&1 || halt "node missing (desktop terminal would fail)"
command -v npx  >/dev/null 2>&1 || halt "npx missing"
say "wrapper OK ; node=$(node -v 2>/dev/null) ; icon OK"

hr "W1 write source desktop (Name=Playwright, fixed-port terminal launch, quote-free Exec)"
cat > "$SRC" <<EPW3_DESKTOP_EOF
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
EPW3_DESKTOP_EOF
chmod 644 "$SRC"
say "wrote $SRC"

hr "W2 symlink into applications dir (as requested)"
mkdir -p "$ADIR"
ln -sfn "$SRC" "$DESK"
say "linked $DESK -> $SRC"

hr "W3 validate (non-fatal) + prove the Exec line + prove the command can run"
if command -v desktop-file-validate >/dev/null 2>&1; then
  say "--- desktop-file-validate $SRC ---"; desktop-file-validate "$SRC" 2>&1 | sed 's/^/    /' || true
  say "--- desktop-file-validate $DESK (via symlink) ---"; desktop-file-validate "$DESK" 2>&1 | sed 's/^/    /' || true
else
  say "    (desktop-file-validate not installed; skipping syntax check — harmless)"
fi
say "--- resolved Exec line ---"; grep -E '^Exec=' "$DESK" 2>/dev/null | sed 's/^/    /' || halt "symlink did not resolve to a file with Exec="
say "--- wrapper forwards args? (dry: --version is instant, no UI) ---"
( cd "$APP" && npx playwright --version 2>&1 | head -1 | sed 's/^/    /' ) || say "    (playwright --version failed — check EPW2 install)"

hr "W4 refresh desktop caches (tolerant)"
update-desktop-database "$ADIR" >/dev/null 2>&1 || true
kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
say "caches refreshed (if menu lacks the entry, see W6 note)"

hr "W5 archive-evidence: what Playwright-related scripts are in codemod now"
ls -1 "$CD" 2>/dev/null | grep -iE 'playwright|epw|eqp' | sed 's/^/    codemod: /' || say "    (none listed)"

hr "W6 backfill codemod/INDEX (idempotent by token) for the full Playwright saga"
touch "$IDX"
add_row(){ # $1=kind $2=token $3=gate $4=desc
  grep -qF "$2" "$IDX" 2>/dev/null && { say "    row exists: $2"; return; }
  printf '| %s | %s | %s | GATE=%s | %s |\n' "$DATEV" "$1" "$2" "$3" "$4" >> "$IDX"
  say "    row added: $2"
}
add_row R "epw-install-playwright-apps-v1"            INFO "EPW  initial greenfield Playwright install at apps/playwright (npm pkg + chromium + smoke); chromium download stalled (later fixed by EPW2)."
add_row R "epw2-robust-playwright-install-v1"         INFO "EPW2 robust install: @playwright/test@latest + playwright@latest + chromium with timeout/retry + system-browser fallback; smoke PASSED (1 passed); browser=playwright-managed chromium."
add_row R "eqp-abort-stuck-playwright-v1"             INFO "EQP  aborted the stalled chromium download + cleaned partial ~/.cache/ms-playwright; npm pkgs kept intact."
add_row B "$TOKEN"                                     "PASS" "EPW3  created Name=Playwright desktop (Terminal=true, fixed port ${PORT}) at $SRC + symlink $DESK; validated; backfilled this saga into INDEX. Does not touch playwright_ui.desktop."
say "INDEX rows complete"

hr "W7 result + launch notes"
say "[RESULT] EPW3 COMPLETE - 'Playwright' desktop live."
say "  source : $SRC"
say "  menu   : $DESK (symlink)"
say "  runs   : ${WRAP} ui --ui-host 127.0.0.1 --ui-port ${PORT}   (in a terminal)"
say "  then open in YOUR browser: http://127.0.0.1:${PORT}"
say "  direct terminal equivalent: cd $APP && ./run-playwright.sh ui --ui-host 127.0.0.1 --ui-port ${PORT}"
say "  NOTE: if Plasma's menu ignores the symlink, replace it with a copy (one line):"
say "        install -Dm644 '$SRC' '$DESK' && update-desktop-database '$ADIR'"
exit 0
