#!/usr/bin/env bash
# EX74 verifier. Read-only.
set -uo pipefail
SDK="$HOME/DevOps/SDK/flutter"; OLD="$HOME/DevOps/flutter/SDK/flutter"
FEH="$HOME/DevOps/pixorb/frontend"; IDE="$HOME/.config/Code/User/settings.json"
[ -x "$SDK/bin/flutter" ] && echo "  canonical SDK: PASS" || { echo "[HALT] SDK"; exit 1; }
{ grep -q 'DevOps/SDK/flutter' "$HOME/.zshrc" 2>/dev/null || grep -q 'DevOps/SDK/flutter' "$HOME/.bashrc" 2>/dev/null; } \
  && echo "  rc PATH export: PASS" || { echo "[HALT] rc"; exit 1; }
if [ -f "$IDE" ]; then grep -q "$OLD" "$IDE" && { echo "[HALT] IDE stale"; exit 1; } || echo "  IDE pin: PASS"; fi
PC="$FEH/.dart_tool/package_config.json"
[ -f "$PC" ] && ! grep -q "$OLD" "$PC" && grep -q "$SDK" "$PC" && echo "  package_config: PASS" || { echo "[HALT] package_config"; exit 1; }
curl -s --max-time 4 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health | grep -q '"db":true' && echo "  mesh: PASS" || { echo "[HALT] mesh"; exit 1; }
echo "  DEFERRED: frontend/web absent (EX-PIXORB-8); /home 96% full (cleanup brick)"
echo "[RESULT] EX74 VERIFY PASS"
