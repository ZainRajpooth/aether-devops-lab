#!/usr/bin/env bash
# 20261112-EX58 — query-param activation (POST /api/repos?forge_remote_id=N) + CI publish gates.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex58-query-param-activation-ci-publish-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
WP="http://127.0.0.1:8000"; GT="http://127.0.0.1:3001"
GH_USER="ZainRajpooth"; GH_REPO="aether-devops-lab"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"
AENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$APASS")"
BOT="$(tr -d '\n\r' < "$SEC/gitea-wp-bot.user")"; BPASS="$(tr -d '\n\r' < "$SEC/gitea-wp-bot.pass")"
BENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$BPASS")"
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"; GHPAT="$(tr -d '\n\r' < "$SEC/github-pat.token")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"
wpr(){ podman exec postgres psql -U devops -d woodpecker -tAc "$1" 2>/dev/null || true; }
ghsha(){ curl -sS -m 15 -H "Authorization: Bearer $GHPAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true; }
setsecret(){ curl -sS -m 15 -o /dev/null -X DELETE -H "Authorization: Bearer $PAT" "$WP/api/repos/$1/secrets/$2" || true
  local c; c="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$2\",\"value\":\"$3\",\"events\":[\"push\"]}" "$WP/api/repos/$1/secrets")"
  say "secret $2 repo $1 -> $c"; [ "$c" = 200 ] || [ "$c" = 201 ] || halt "secret $2 failed"; }

hr "X0 probes"
GID="$(curl -sS -m 15 -u "$AUSER:$APASS" "$GT/api/v1/repos/$AUSER/aether" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
say "gitea aether id=$GID"
WID="$(wpr "SELECT id FROM repos WHERE forge_remote_id='$GID';" | tr -d ' \n')"
say "woodpecker aether (forge_remote_id) = ${WID:-<none>}"
GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
if [ "$MODE" = check ]; then
  say "plan: POST /api/repos/sync -> POST /api/repos?forge_remote_id=$GID -> DB verify -> secrets -> trigger -> gates"
  say "[RESULT] EX58 CHECK - nothing written."; exit 0
fi

hr "X1 sync + query-param activation"
curl -sS -m 15 -o /dev/null -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/sync" || true
say "sync called"
if [ -z "$WID" ]; then
  C="$(curl -sS -m 25 -o "$TMP/act.json" -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos?forge_remote_id=$GID")"
  say "activate http=$C body_bytes=$(wc -c < "$TMP/act.json")"
  WID="$(wpr "SELECT id FROM repos WHERE forge_remote_id='$GID';" | tr -d ' \n')"
fi
[ -n "$WID" ] || halt "aether still not in Woodpecker DB after query-param activation"
ACT="$(wpr "SELECT active FROM repos WHERE id=$WID;" | tr -d ' \n')"
say "aether id=$WID active=$ACT"
[ "$ACT" = t ] || halt "aether row not active"
PID="$(wpr "SELECT id FROM repos WHERE full_name='$BOT/woodpecker-proof';" | tr -d ' \n')"
[ -n "$PID" ] || halt "proof repo id missing"
say "proof id=$PID"

hr "X2 hosts-immune secrets"
setsecret "$WID" GITEA_CLONE_URL "http://$AUSER:$AENC@gitea.dns.podman:3000/$AUSER/aether.git"
setsecret "$WID" GITHUB_TOKEN "$GHPAT"
setsecret "$PID" GITEA_CLONE_URL "http://$BOT:$BENC@gitea.dns.podman:3000/$BOT/woodpecker-proof.git"

hr "X3 trigger + pipeline gate + sha gate"
cd "$A" || halt "cd failed"
mkdir -p docs
printf '\n- A closed: query-param activation + durable login + CI publish verified %s (EX58).\n' "$STAMP" >> docs/ci-note.md
git add -A
if git diff --cached --quiet; then say "nothing to commit (no-op)"; PUSHED=no; else
  git commit -q -m "ci: ex58 close A (query-param activation) $STAMP" || halt "commit failed"
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push failed"
  PUSHED=yes; say "trigger pushed"
fi
if [ "$PUSHED" = yes ]; then
  OK=no; ST=""
  for i in $(seq 1 90); do
    R="$(wpr "SELECT number||' '||status FROM pipelines WHERE repo_id=$WID ORDER BY id DESC LIMIT 1")"
    if [ -n "$R" ]; then read -r N ST <<<"$R"; say "pipeline #$N status=$ST"
      [ "$ST" = success ] && { OK=yes; break; }
      case "$ST" in failure|error|killed) break;; esac
    fi
    sleep 3
  done
  [ "$OK" = yes ] || { podman logs --tail 30 woodpecker-agent 2>&1 | tail -14 | sed 's/^/    /'; ledger "FAIL" "EX58 pipeline=$ST"; halt "pipeline not success"; }
  GH1="$(ghsha)"; say "github HEAD after: ${GH1:-<none>}"
  [ -n "$GH1" ] && [ "$GH1" != "$GH0" ] || halt "github sha did not advance"
  say "GITHUB SHA-ADVANCE GATE PASS: $GH1"
else
  ST="$(wpr "SELECT status FROM pipelines WHERE repo_id=$WID ORDER BY id DESC LIMIT 1")"; GH1="$(ghsha)"
  [ "$ST" = success ] && [ "$GH1" = "$GH0" ] || halt "no-op path inconsistent"
  say "NO-OP GATE PASS"
fi

hr "X4 docs + ledger"
if ! grep -q "A closed (EX58)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat >> "$DOCS/publish-runbook.md" <<'MD'

## A closed (EX58)
- Activation: POST /api/repos?forge_remote_id=<ID> (query param, empty body) after POST /api/repos/sync
- Clone secrets use gitea.dns.podman:3000 (hosts-immune); permanent hosts entry + aether-gitea-loop-3000.service
- Next: B = k3d + Flux GitOps (EX59); C = portfolio polish (EX60)
MD
fi
say "docs updated"
hr "X5 RESULT"
say "[RESULT] EX58 COMPLETE - A CLOSED: query-param activation + durable login + CI publish gated."
ledger "PASS" "EX58: wp=$WID pipeline=$ST github=$GH1"
exit 0
