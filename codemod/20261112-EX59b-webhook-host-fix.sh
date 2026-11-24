#!/usr/bin/env bash
# 20261112-EX59b — Fix WOODPECKER_WEBHOOK_HOST so Gitea can reach Woodpecker internally.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex59b-webhook-host-fix-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
WE="$SEC/woodpecker.env"
WP="http://127.0.0.1:8000"; GT="http://127.0.0.1:3001"
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

hr "X0 probe"
grep -q '^WOODPECKER_WEBHOOK_HOST=' "$WE" && say "WEBHOOK_HOST already set" || say "WEBHOOK_HOST MISSING (root cause)"
GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
BEFORE="$(wpr "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=2;" | tr -d ' \n')"
if [ "$MODE" = check ]; then
  say "plan: add WOODPECKER_WEBHOOK_HOST=http://woodpecker-server:8000 -> restart server -> repair webhook -> trigger push -> gate"
  say "[RESULT] EX59b CHECK - nothing written."; exit 0
fi

hr "X1 fix env + restart"
if ! grep -q '^WOODPECKER_WEBHOOK_HOST=' "$WE"; then
  cp -p "$WE" "$WE.pre-ex59b.$STAMP.bak"; chmod 600 "$WE.pre-ex59b.$STAMP.bak"
  echo "WOODPECKER_WEBHOOK_HOST=http://woodpecker-server:8000" >> "$WE"
  say "added WOODPECKER_WEBHOOK_HOST"
  systemctl --user restart woodpecker-server.service
  ok=no; for i in $(seq 1 30); do [ "$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)" = 200 ] && { ok=yes; break; }; sleep 2; done
  [ "$ok" = yes ] || halt "server not ready after restart"
  say "server restarted and ready"
else
  say "already fixed (no-op)"
fi

hr "X2 repair webhook"
C="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/2/repair" || echo 000)"
[ "$C" = 200 ] || C="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/$AUSER/aether/repair" || echo 000)"
say "repair -> $C"

hr "X3 trigger push"
cd "$A" || halt "cd failed"
printf '\n- webhook host fixed %s (EX59b).\n' "$STAMP" >> docs/ci-note.md
git add docs/ci-note.md
if git diff --cached --quiet; then
  say "nothing to commit (no-op)"; PUSHED=no
else
  git commit -q -m "ci: ex59b webhook host fix $STAMP" || halt "commit failed"
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push failed"
  PUSHED=yes; say "pushed trigger"
fi

hr "X4 success gate + sha gate"
if [ "$PUSHED" = yes ]; then
  OK=no; ST=""
  for i in $(seq 1 90); do
    R="$(wpr "SELECT number||' '||status FROM pipelines WHERE repo_id=2 ORDER BY id DESC LIMIT 1")"
    if [ -n "$R" ]; then read -r N ST <<<"$R"; say "pipeline #$N status=$ST"
      [ "$ST" = success ] && { OK=yes; break; }
      case "$ST" in failure|error|killed) break;; esac
    fi
    sleep 3
  done
  [ "$OK" = yes ] || { podman logs --tail 25 woodpecker-agent 2>&1 | tail -12 | sed 's/^/    /'; ledger "FAIL" "EX59b pipeline=$ST"; halt "pipeline not success"; }
  GH1="$(ghsha)"; say "github HEAD after: ${GH1:-<none>}"
  [ -n "$GH1" ] && [ "$GH1" != "$GH0" ] || halt "github sha did not advance"
  say "GITHUB SHA-ADVANCE GATE PASS: $GH1"
else
  ST="$(wpr "SELECT status FROM pipelines WHERE repo_id=2 ORDER BY id DESC LIMIT 1")"; GH1="$(ghsha)"
  [ "$ST" = success ] && [ "$GH1" = "$GH0" ] || halt "no-op path inconsistent"
  say "NO-OP GATE PASS"
fi

hr "X5 RESULT"
say "[RESULT] EX59b COMPLETE - A CLOSED: Webhook host fixed, CI publish gated end-to-end."
ledger "PASS" "EX59b: webhook_host set; pipeline=$ST github=$GH1"
exit 0
