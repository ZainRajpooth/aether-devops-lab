#!/usr/bin/env bash
set -uo pipefail
CACHE="$HOME/.cache/aether"; R="$CACHE/pip-audit.json"
podman image exists localhost/audit:latest && echo "  audit image cached: PASS" || { echo "[HALT] image"; exit 1; }
[ -s "$R" ] && echo "  report present: PASS" || { echo "[HALT] report"; exit 1; }
AGE=$(( $(date +%s) - $(stat -c %Y "$R") )); [ "$AGE" -le 86400 ] && echo "  report fresh (${AGE}s): PASS" || { echo "[HALT] stale"; exit 1; }
python3 - "$R" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
deps = d.get("dependencies", d) if isinstance(d, dict) else d
n = len(deps); f = sum(len(x.get("vulns", [])) for x in deps)
print("  audited=%d findings=%d" % (n, f))
sys.exit(0 if n >= 10 else 1)
PY
[ $? = 0 ] && echo "  non-vacuous input: PASS" || { echo "[HALT] vacuous"; exit 1; }
echo "[RESULT] EX82 VERIFY PASS"
