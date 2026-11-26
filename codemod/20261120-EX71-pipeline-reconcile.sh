#!/usr/bin/env bash
# EX71/EX72 verifier: canonical pipeline, patched poll, CI success, EX6 record. Read-only.
set -uo pipefail
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; S=/tmp/EX-PIXORB-6.sh
U=$(cat "$A/secrets/gitea-admin.user"); GP=$(cat "$A/secrets/gitea-admin.pass")
grep -q '^when:' "$P/.woodpecker.yml" && ! grep -q 'disable: true' "$P/.woodpecker.yml" && echo "  canonical pipeline: PASS" || { echo "[HALT] pipeline"; exit 1; }
grep -q 'seq 1 50' "$S" && echo "  poll window: PASS" || { echo "[HALT] poll"; exit 1; }
SHA=$(git -C "$P" rev-parse HEAD)
curl -s -u "$U:$GP" "http://127.0.0.1:3001/api/v1/repos/$U/pixorb/statuses/$SHA" | grep -q '"success"' && echo "  CI success: PASS" || { echo "[HALT] CI"; exit 1; }
[ -f "$A/codemod/20261118-EX-PIXORB-6-ci-wire.sh" ] && echo "  EX6 record: PASS" || { echo "[HALT] EX6 record"; exit 1; }
echo "[RESULT] EX71 VERIFY PASS"
