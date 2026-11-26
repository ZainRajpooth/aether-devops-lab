#!/usr/bin/env bash
# EX-PIXORB-9 verifier. Read-only.
set -uo pipefail
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; D="$P/infra/db/dumps"
[ "$(git -C "$P" ls-files '*.bak' | wc -l)" = 0 ] && echo "  G1 no tracked backups: PASS" || { echo "[HALT] G1"; exit 1; }
N=$(ls -1t "$D"/pixorb-*.sql.gz 2>/dev/null | head -1)
[ -n "$N" ] && gzip -t "$N" && gunzip -c "$N" | tail -5 | grep -q 'dump complete' && echo "  G2 dump valid: PASS" || { echo "[HALT] G2"; exit 1; }
systemctl --user list-timers pixorb-pg-dump.timer --no-legend 2>/dev/null | grep -q pixorb-pg-dump && echo "  G3 timer armed: PASS" || { echo "[HALT] G3"; exit 1; }
[ "$(ls -1 "$D"/pixorb-*.sql.gz 2>/dev/null | wc -l)" -le 7 ] && echo "  G4 retention: PASS" || { echo "[HALT] G4"; exit 1; }
( set -a; . "$A/secrets/restic.env"; set +a
  restic snapshots --json | python3 -c '
import json,sys,os
A=os.path.expanduser("~/DevOps/aether"); P=os.path.expanduser("~/DevOps/pixorb")
p=sorted(json.load(sys.stdin),key=lambda x:x["time"])[-1]["paths"]
sys.exit(0 if any(x.rstrip("/")==A for x in p) and any(x.rstrip("/")==P for x in p) else 1)' ) \
  && echo "  G5 restic coverage: PASS" || { echo "[HALT] G5"; exit 1; }
echo "[RESULT] EX-PIXORB-9 VERIFY PASS"
