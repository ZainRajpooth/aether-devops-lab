#!/usr/bin/env bash
# 20261029-G-secrets-step.sh — replayable: (re)seed secrets.env from the 13-capture, edit-safe.
# Re-run on an EXISTING non-empty secrets.env = validate-only (never clobbers your rotation).
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"
python3 "$CD/20261029-G-secrets-seeder.py" \
  "$A/legacy/compose/recovery-runtime.yml" "$HOME/.config/aether/secrets.env"
