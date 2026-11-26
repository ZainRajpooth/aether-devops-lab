#!/usr/bin/env bash
set -uo pipefail
P="$HOME/DevOps/pixorb"
[ -f "$P/.woodpecker.yml" ] && echo "  pipeline file: PASS" || { echo "[HALT] missing"; exit 1; }
grep -q 'flutter build web' "$P/.woodpecker.yml" && echo "  web-build step: PASS" || { echo "[HALT] web-build"; exit 1; }
grep -q 'python -m pytest' "$P/.woodpecker.yml" && echo "  test step: PASS" || { echo "[HALT] test"; exit 1; }
grep -q 'ruff check' "$P/.woodpecker.yml" && echo "  lint step: PASS" || { echo "[HALT] lint"; exit 1; }
echo "[RESULT] EX77 VERIFY PASS"
