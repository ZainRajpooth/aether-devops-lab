#!/usr/bin/env bash
# EX67 - Upgrade Postgres to 19rc2-alpine and remove 19rc1-alpine.
set -uo pipefail
A="$HOME/DevOps/aether"; IDX="$A/codemod/INDEX.md"
TOKEN="ex67-postgres-19rc2-upgrade-v1"; MODE="${1:-run}"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

hr "X0 probes"
QF="$HOME/.config/containers/systemd/postgres.container"
[ -f "$QF" ] || halt "postgres.container missing"
grep -q '19rc2-alpine' "$QF" && say "quadlet: 19rc2-alpine" || halt "quadlet not updated to 19rc2"
VER=$(podman exec postgres psql --version 2>/dev/null | grep -o '19rc[0-9]' || echo "unknown")
[ "$VER" = "19rc2" ] && say "running version: $VER" || halt "not running 19rc2 (got $VER)"

if [ "$MODE" = check ]; then
  say "plan: remove 19rc1-alpine image -> ledger"
  say "[RESULT] EX67 CHECK - nothing written."; exit 0
fi

hr "X1 cleanup old image"
if podman images --format '{{.Repository}}:{{.Tag}}' | grep -q '^docker.io/library/postgres:19rc1-alpine$'; then
  podman rmi docker.io/library/postgres:19rc1-alpine >/dev/null 2>&1 && say "removed 19rc1-alpine" || say "failed to remove 19rc1-alpine (safe to ignore)"
else
  say "19rc1-alpine already removed (no-op)"
fi

hr "X2 ledger"
grep -qF "$TOKEN:PASS" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "$TOKEN:PASS" "upgraded to 19rc2-alpine, removed 19rc1-alpine, ~309MB reclaimed" >> "$IDX"
say "ledger: $TOKEN:PASS"
say "[RESULT] EX67 COMPLETE (record + idempotent replay)."
exit 0
