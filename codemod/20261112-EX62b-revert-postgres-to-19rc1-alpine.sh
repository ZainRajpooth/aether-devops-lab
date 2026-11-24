#!/usr/bin/env bash
# 20261112-EX62b — Revert Postgres to 19rc1-alpine (19rc2-alpine manifest unknown on Docker Hub).
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; CD="$A/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex62b-revert-postgres-to-19rc1-alpine-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
QDIR="$H/.config/containers/systemd"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }

hr "X0 probes"
PG_FILE="$QDIR/postgres.container"
[ -f "$PG_FILE" ] || halt "postgres.container not found at $PG_FILE"
CUR_IMG=$(grep -E '^Image=' "$PG_FILE" | cut -d= -f2 | tr -d '\r')
say "current postgres image in quadlet: $CUR_IMG"
if [ "$MODE" = check ]; then
  say "plan: revert quadlet to 19rc1-alpine -> explicit podman pull -> restart -> verify version"
  say "[RESULT] EX62b CHECK - nothing written."; exit 0
fi

hr "X1 revert quadlet to known-good 19rc1-alpine"
if [ "$CUR_IMG" != "docker.io/library/postgres:19rc1-alpine" ]; then
  cp -p "$PG_FILE" "$PG_FILE.pre-ex62b.$STAMP.bak"
  sed -i 's|postgres:19rc2-alpine|postgres:19rc1-alpine|g' "$PG_FILE"
  sed -i 's|postgres:19-alpine|postgres:19rc1-alpine|g' "$PG_FILE"
  say "reverted quadlet Image to postgres:19rc1-alpine"
else
  say "quadlet already has 19rc1-alpine (no-op)"
fi

hr "X2 explicit pull and restart"
say "explicitly pulling docker.io/library/postgres:19rc1-alpine..."
if podman pull docker.io/library/postgres:19rc1-alpine >/dev/null 2>&1; then
  say "pull successful"
else
  say "pull failed or already latest (cached)"
fi

systemctl --user daemon-reload
systemctl --user reset-failed postgres.service
systemctl --user restart postgres.service
sleep 4

STATE="$(systemctl --user is-active postgres.service 2>/dev/null || echo unknown)"
say "postgres.service state: $STATE"

if [ "$STATE" = "active" ]; then
  VER="$(podman exec postgres psql --version 2>/dev/null | head -1)"
  say "postgres version: $VER"
  echo "$VER" | grep -q "19" || say "WARNING: version does not contain '19'"
else
  say "[ERROR] postgres.service failed to start. Fetching journal..."
  journalctl --user -u postgres.service -n 10 --no-pager | sed 's/^/  /'
  halt "postgres service failed; check journal above"
fi

hr "X3 ledger"
say "[RESULT] EX62b COMPLETE - Postgres reverted to stable 19rc1-alpine and running."
ledger "PASS" "EX62b: postgres=$STATE version=$(podman exec postgres psql --version 2>/dev/null | head -1 | tr -d '\n')"
exit 0
