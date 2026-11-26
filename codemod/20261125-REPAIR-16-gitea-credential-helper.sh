#!/usr/bin/env bash
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"
H="$A/infra/scripts/git-credential-gitea.sh"
[ -x "$H" ] && echo "  helper executable: PASS" || { echo "[HALT] helper"; exit 1; }
git config --global --get-all "credential.http://127.0.0.1:3001.helper" | grep -q 'git-credential-gitea.sh' && echo "  helper wired: PASS" || { echo "[HALT] wiring"; exit 1; }
git -C "$A" ls-remote origin main >/dev/null 2>&1 && echo "  aether auth (no prompt): PASS" || { echo "[HALT] aether auth"; exit 1; }
git -C "$P" ls-remote origin main >/dev/null 2>&1 && echo "  pixorb auth (no prompt): PASS" || { echo "[HALT] pixorb auth"; exit 1; }
echo "[RESULT] REPAIR-16 VERIFY PASS"
