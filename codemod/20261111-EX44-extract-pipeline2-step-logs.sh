#!/usr/bin/env bash
# 20261111-EX44 — read-only extraction of pipeline #2 step states, errors, and logs.
set -uo pipefail
WP="http://127.0.0.1:8000"
PAT="$(tr -d '\n\r' < "$HOME/DevOps/aether/secrets/woodpecker-pat.token")"
PIPE="${1:-2}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "E1 pipeline detail (steps, states, errors)"
curl -sS -m 15 -H "Authorization: Bearer $PAT" "$WP/api/repos/1/pipelines/$PIPE" -o "$TMP/pipe.json"
python3 - "$TMP/pipe.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("pipeline:", d.get("number"), d.get("status"), d.get("event"), "started:", d.get("started"), "finished:", d.get("finished"))
for w in d.get("workflows",[]) or []:
    print(" workflow:", w.get("name"), w.get("state"))
    for s in w.get("children",[]) or w.get("steps",[]) or []:
        print("   step id=%s name=%s state=%s exit=%s err=%s" % (
            s.get("id"), s.get("name"), s.get("state"), s.get("exit_code"), s.get("error")))
PY

hr "E2 step logs (decoded)"
python3 - "$TMP/pipe.json" > "$TMP/stepids.txt" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for w in d.get("workflows",[]) or []:
    for s in w.get("children",[]) or w.get("steps",[]) or []:
        if s.get("id"): print(s["id"])
PY
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  say "--- logs for step $sid ---"
  curl -sS -m 15 -H "Authorization: Bearer $PAT" "$WP/api/repos/1/pipelines/$PIPE/logs/$sid" |
    python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    items = d if isinstance(d,list) else d.get("logs",[])
    for it in items:
        print("   ", it.get("out","").rstrip())
except Exception as e:
    print("    [no logs / parse error]", e)
' || true
done < "$TMP/stepids.txt"

hr "E3 agent backend logs (last 40)"
podman logs --tail 40 woodpecker-agent 2>&1 | tail -40 | sed 's/^/    /' || true

hr "E4 server logs (last 20)"
podman logs --tail 20 woodpecker-server 2>&1 | tail -20 | sed 's/^/    /' || true
exit 0
