#!/usr/bin/env bash
# 20261112-EX59c — Surgical Gitea API webhook patch to fix internal routing without breaking OAuth.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex59c-surgical-webhook-patch-ci-gate-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
GT="http://127.0.0.1:3001"; WP="http://127.0.0.1:8000"
GH_USER="ZainRajpooth"; GH_REPO="aether-devops-lab"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }

AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"
AENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$APASS")"
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"; GHPAT="$(tr -d '\n\r' < "$SEC/github-pat.token")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"
wpr(){ podman exec postgres psql -U devops -d woodpecker -tAc "$1" 2>/dev/null || true; }
ghsha(){ curl -sS -m 15 -H "Authorization: Bearer $GHPAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true; }

hr "X0 probes"
HOOK_ID=$(curl -sS -u "$AUSER:$APASS" "$GT/api/v1/repos/$AUSER/aether/hooks" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["id"] if d else "")' 2>/dev/null)
[ -n "$HOOK_ID" ] || halt "no webhook found in Gitea"
say "hook id: $HOOK_ID"
GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
if [ "$MODE" = check ]; then
  say "plan: fetch hook -> patch URL via Gitea API (127.0.0.1 -> woodpecker-server) -> push -> gate"
  say "[RESULT] EX59c CHECK - nothing written."; exit 0
fi

hr "X1 surgical Gitea webhook patch"
# Extract current config, replace 127.0.0.1 with woodpecker-server, format as JSON
curl -sS -u "$AUSER:$APASS" "$GT/api/v1/repos/$AUSER/aether/hooks/$HOOK_ID" > "$TMP/hook.json"
NEW_CONFIG=$(python3 - "$TMP/hook.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))
cfg = h["config"]
cfg["url"] = cfg["url"].replace("127.0.0.1", "woodpecker-server")
print(json.dumps({"type": h["type"], "active": True, "config": cfg}))
PY
)
C=$(curl -sS -o "$TMP/patch.out" -w '%{http_code}' -X PATCH -u "$AUSER:$APASS" -H 'Content-Type: application/json' \
  -d "$NEW_CONFIG" "$GT/api/v1/repos/$AUSER/aether/hooks/$HOOK_ID" || echo 000)
say "patch -> $C"
[ "$C" = 200 ] || { cat "$TMP/patch.out" | sed 's/^/    /'; halt "Gitea webhook patch failed"; }

NEW_URL=$(curl -sS -u "$AUSER:$APASS" "$GT/api/v1/repos/$AUSER/aether/hooks" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["config"]["url"] if d else "")')
say "new url: $NEW_URL"
echo "$NEW_URL" | grep -q 'woodpecker-server:8000' || halt "URL patch did not apply"
say "WEBHOOK URL GATE PASS"

hr "X2 trigger push"
cd "$A" || halt "cd failed"
printf '\n- surgical webhook patch verified %s (EX59c).\n' "$STAMP" >> docs/ci-note.md
git add docs/ci-note.md
git commit -q -m "ci: ex59c webhook url surgical patch $STAMP" || halt "commit failed"
git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push failed"
say "pushed trigger"

hr "X3 success gate + sha gate"
OK=no; ST=""; EVT=""
for i in $(seq 1 90); do
  R=$(wpr "SELECT event||' '||status FROM pipelines WHERE repo_id=2 ORDER BY id DESC LIMIT 1")
  if [ -n "$R" ]; then read -r EVT ST <<<"$R"; say "latest pipeline event=$EVT status=$ST"
    if [ "$EVT" = push ] && [ "$ST" = success ]; then OK=yes; break; fi
    if [ "$EVT" = push ] && [ "$ST" != running ] && [ "$ST" != pending ]; then break; fi
  fi
  sleep 3
done
if [ "$OK" != yes ]; then
  L=$(wpr "SELECT MAX(id) FROM pipelines WHERE repo_id=2;")
  wpr "SELECT errors FROM pipelines WHERE id=$L;" | sed 's/^/    errors: /'
  podman logs --tail 25 woodpecker-agent 2>&1 | tail -12 | sed 's/^/    /'
  ledger "FAIL" "EX59c event=$EVT status=$ST"
  halt "push event pipeline not success"
fi

GH1="$(ghsha)"; say "github HEAD after: ${GH1:-<none>}"
[ -n "$GH1" ] && [ "$GH1" != "$GH0" ] || halt "github sha did not advance"
say "GITHUB SHA-ADVANCE GATE PASS: $GH1"

hr "X4 ledger"
say "[RESULT] EX59c COMPLETE - A CLOSED: Webhook surgically patched, CI publish gated end-to-end."
ledger "PASS" "EX59c: webhook=woodpecker-server; event=push; status=success; github=$GH1"
exit 0
