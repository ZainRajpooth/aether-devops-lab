#!/usr/bin/env bash
# EX66 - Restic restore drill: proves backup restorability, net-zero disk, recorded.
set -uo pipefail
A="$HOME/DevOps/aether"; IDX="$A/codemod/INDEX.md"
TOKEN="ex66-restic-restore-drill-v1"; MODE="${1:-run}"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

# Source restic env
set -a; . "$A/secrets/restic.env"; set +a
[ -n "${RESTIC_REPOSITORY:-}" ] || halt "RESTIC_REPOSITORY unset"
[ -n "${RESTIC_PASSWORD:-}" ] || export RESTIC_PASSWORD_FILE="$A/secrets/restic-repo.pass"

hr "X0 probes"
LATEST=$(restic snapshots --latest 1 --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
say "latest snapshot: $LATEST"
TARGET_FILE="docs/adr-index.md"
[ -f "$A/$TARGET_FILE" ] || halt "target file missing: $TARGET_FILE"

if [ "$MODE" = check ]; then
  say "plan: dump $TARGET_FILE from $LATEST to /tmp/restic-drill-<ts>/ -> diff -> cleanup -> ledger"
  say "[RESULT] EX66 CHECK - nothing written."; exit 0
fi

hr "X1 restore drill"
DRILL_DIR="/tmp/restic-drill-$(date +%s)"
mkdir -p "$DRILL_DIR"
OUT_FILE="$DRILL_DIR/adr-index.md"
say "dumping $TARGET_FILE from latest snapshot ..."
restic dump latest "$TARGET_FILE" > "$OUT_FILE" 2>/dev/null || halt "dump failed"

hr "X2 integrity gate"
if cmp -s "$A/$TARGET_FILE" "$OUT_FILE"; then
  say "integrity gate: PASS (byte-identical)"
else
  say "integrity gate: FAIL (files differ)"
  halt "restore content mismatch"
fi

hr "X3 cleanup"
rm -rf "$DRILL_DIR"
say "drill directory cleaned up (net-zero disk)"

hr "X4 ledger"
grep -qF "$TOKEN:PASS" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "$TOKEN:PASS" "dumped $TARGET_FILE from $LATEST, byte-identical, net-zero cleanup" >> "$IDX"
say "ledger: $TOKEN:PASS"
say "[RESULT] EX66 COMPLETE (record + idempotent replay)."
exit 0
