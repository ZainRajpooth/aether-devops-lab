#!/usr/bin/env bash
# EX69 record/verifier (read-only): python 3.15.2 + helper v2 resolver + canon==live.
set -uo pipefail
H="$HOME"; NEW=3.15.2
[ -x "$H/.pyenv/versions/$NEW/bin/python" ] && echo "  pyenv $NEW: present" || { echo "[HALT] interpreter missing"; exit 1; }
[ "$(venv py)" = "$(tr -d '[:space:]' < "$H/.config/aether/python-version")" ] && echo "  resolver: matches version file" || { echo "[HALT] resolver mismatch"; exit 1; }
cmp -s "$H/DevOps/aether/infra/dotfiles/venv" "$H/.local/bin/venv" && echo "  helper canon==live" || { echo "[HALT] canon/live drift"; exit 1; }
venv ls | sed 's/^/    /'
echo "[RESULT] EX69 VERIFY PASS"
