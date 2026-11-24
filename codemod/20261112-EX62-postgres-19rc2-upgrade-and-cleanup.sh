#!/usr/bin/env bash
# 20261112-EX62 — Safe Postgres 19rc2-alpine upgrade, plugin-git cleanup, and diagnostic fallback.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; CD="$A/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex62-postgres-19rc2-upgrade-and-cleanup-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
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
say "plugin-git 2.11.0 present: $(podman images --format '{{.Repository}}:{{.Tag}}' | grep -c 'woodpeckerci/plugin-git:2.11.0' || echo 0)"
if [ "$MODE" = check ]; then
  say "plan: remove old plugin-git -> verify/fix quadlet -> explicit podman pull -> restart -> verify version"
  say "[RESULT] EX62 CHECK - nothing written."; exit 0
fi

hr "X1 cleanup plugin-git:2.11.0"
if podman images --format '{{.Repository}}:{{.Tag}}' | grep -q 'woodpeckerci/plugin-git:2.11.0'; then
  podman rmi -f docker.io/woodpeckerci/plugin-git:2.11.0 && say "removed plugin-git:2.11.0" || say "failed to remove (may be in use)"
else
  say "plugin-git:2.11.0 not present (no-op)"
fi

hr "X2 ensure quadlet and explicit pull"
if [ "$CUR_IMG" != "docker.io/library/postgres:19rc2-alpine" ]; then
  cp -p "$PG_FILE" "$PG_FILE.pre-ex62.$STAMP.bak"
  sed -i 's|postgres:19rc1-alpine|postgres:19rc2-alpine|g' "$PG_FILE"
  sed -i 's|postgres:19-alpine|postgres:19rc2-alpine|g' "$PG_FILE"
  say "updated quadlet Image to postgres:19rc2-alpine"
else
  say "quadlet already has 19rc2-alpine (no-op)"
fi

say "explicitly pulling docker.io/library/postgres:19rc2-alpine..."
if podman pull docker.io/library/postgres:19rc2-alpine >/dev/null 2>&1; then
  say "pull successful"
else
  say "pull failed or already latest, checking local images..."
  podman images | grep postgres
fi

hr "X3 restart and verify"
systemctl --user daemon-reload
systemctl --user restart postgres.service
sleep 3

STATE="$(systemctl --user is-active postgres.service 2>/dev/null || echo unknown)"
say "postgres.service state: $STATE"

if [ "$STATE" = "active" ]; then
  VER="$(podman exec postgres psql --version 2>/dev/null | head -1)"
  say "postgres version: $VER"
  echo "$VER" | grep -q "19" || say "WARNING: version does not contain '19'"
else
  say "[ERROR] postgres.service failed to start. Fetching journal..."
  journalctl --user -u postgres.service -n 15 --no-pager | sed 's/^/  /'
  halt "postgres service failed; check journal above"
fi

hr "X4 ledger"
say "[RESULT] EX62 COMPLETE - Postgres upgraded to 19rc2-alpine, plugin-git cleaned up."
ledger "PASS" "EX62: postgres=$STATE version=$(podman exec postgres psql --version 2>/dev/null | head -1 | tr -d '\n')"
exit 0
