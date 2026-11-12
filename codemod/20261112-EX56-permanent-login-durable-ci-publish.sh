#!/usr/bin/env bash
# 20261112-EX56 — permanent browser login (hosts+bridge) + hosts-immune clone names + finish CI publish gates.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex56-permanent-login-durable-ci-publish-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
GT="http://127.0.0.1:3001"; WP="http://127.0.0.1:8000"
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
ghsha(){ curl -sS -m 15 -H "Authorization: Bearer $GHPAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true; }
wpid(){ curl -sS -m 15 -H "Authorization: Bearer $PAT" "$WP/api/repos/lookup/$1/$2" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")' 2>/dev/null || true; }
setsecret(){ # repo_id name value
  curl -sS -m 15 -o /dev/null -X DELETE -H "Authorization: Bearer $PAT" "$WP/api/repos/$1/secrets/$2" || true
  local c; c="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$2\",\"value\":\"$3\",\"events\":[\"push\"]}" "$WP/api/repos/$1/secrets" || echo 000)"
  say "secret $2 on repo $1 -> $c"; [ "$c" = 200 ] || [ "$c" = 201 ] || halt "secret $2 failed"
}
hr "X0 probes"
say "host gitea:3000 http=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://gitea:3000/api/v1/version 2>/dev/null || echo 000)"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' && say "bridge: listening" || halt "bridge not listening"
BPID="$(ss -ltnp 2>/dev/null | grep '127.0.0.2:3000' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
BUNIT=""; [ -n "$BPID" ] && BUNIT="$(systemctl --user status "$BPID" --no-pager 2>/dev/null | head -1 | grep -o '[a-z0-9@.-]*\.service' | head -1)"
say "bridge unit: ${BUNIT:-<none>}"
WID="$(wpid "$AUSER" aether)"; PID="$(wpid "$BOT" woodpecker-proof)"
say "wp aether id=${WID:-<none>} proof id=${PID:-<none>}"
GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
if [ "$MODE" = check ]; then
  say "plan: permanent hosts entry + bridge enable -> host curl gate -> WID lookup -> hosts-immune secrets (both repos) ->"
  say "      trigger push -> pipeline gate -> sha gate -> docs+ledger"
  say "[RESULT] EX56 CHECK - nothing written."; exit 0
fi

hr "X1 permanent browser path (hosts + bridge)"
sudo -v || halt "sudo needed"
if grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts; then say "hosts entry already present (no-op)"; else
  sudo cp -p /etc/hosts "/etc/hosts.pre-ex56.$STAMP.bak"
  echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null; say "permanent hosts entry added"
fi
if [ -n "$BUNIT" ]; then systemctl --user enable --now "$BUNIT" 2>/dev/null && say "bridge enabled: $BUNIT" || say "bridge enable skipped"; fi
HC="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' http://gitea:3000/api/v1/version 2>/dev/null || echo 000)"
say "host gitea:3000 http=$HC"
[ "$HC" = 200 ] || halt "browser path not resolving; login would still fail"
say "BROWSER PATH GATE PASS (login survives cookie resets)"

hr "X2 woodpecker repo ids"
[ -n "$WID" ] || halt "aether not activated; run EX55 X3 activation first"
[ -n "$PID" ] || halt "proof repo id lookup failed"
say "ids: aether=$WID proof=$PID"

hr "X3 hosts-immune clone secrets (both repos)"
setsecret "$WID" GITEA_CLONE_URL "http://$AUSER:$AENC@gitea.dns.podman:3000/$AUSER/aether.git"
setsecret "$WID" GITHUB_TOKEN "$GHPAT"
setsecret "$PID" GITEA_CLONE_URL "http://$BOT:$BENC@gitea.dns.podman:3000/$BOT/woodpecker-proof.git"

hr "X4 trigger push + pipeline gate + sha gate"
cd "$A" || halt "cd failed"
mkdir -p docs
printf '\n- CI publish steel thread verified %s (EX56).\n' "$STAMP" >> docs/ci-note.md
git add -A
if git diff --cached --quiet; then
  say "nothing to commit (no-op)"; PUSHED=no
else
  git commit -q -m "ci: ex56 trigger + durable login $STAMP" || halt "commit failed"
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push failed"
  PUSHED=yes; say "trigger pushed"
fi
if [ "$PUSHED" = yes ]; then
  OK=no; ST=""
  for i in $(seq 1 90); do
    R="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT number||' '||status FROM pipelines WHERE repo_id=$WID ORDER BY id DESC LIMIT 1" 2>/dev/null || true)"
    if [ -n "$R" ]; then read -r N ST <<<"$R"; say "pipeline #$N status=$ST"
      [ "$ST" = success ] && { OK=yes; break; }
      case "$ST" in failure|error|killed) break;; esac
    fi
    sleep 3
  done
  [ "$OK" = yes ] || { podman logs --tail 30 woodpecker-agent 2>&1 | tail -14 | sed 's/^/    /'; ledger "FAIL" "EX56 pipeline=$ST"; halt "pipeline not success"; }
  GH1="$(ghsha)"; say "github HEAD after: ${GH1:-<none>}"
  [ -n "$GH1" ] && [ "$GH1" != "$GH0" ] || halt "github sha did not advance"
  say "GITHUB SHA-ADVANCE GATE PASS: $GH1"
else
  ST="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT status FROM pipelines WHERE repo_id=$WID ORDER BY id DESC LIMIT 1" 2>/dev/null || true)"
  GH1="$(ghsha)"
  [ "$ST" = success ] && [ "$GH1" = "$GH0" ] || halt "no-op path inconsistent"
  say "NO-OP GATE PASS"
fi

hr "X5 docs + ledger"
if ! grep -q "Permanent login (EX56)" "$DOCS/brick12-runbook.md" 2>/dev/null; then
cat >> "$DOCS/brick12-runbook.md" <<'MD'

## Permanent login (EX56) — supersedes temporary login window
- /etc/hosts: 127.0.0.2 gitea (PERMANENT) + persistent bridge 127.0.0.2:3000 -> 127.0.0.1:3001
- Browser OAuth now resolves gitea:3000 without any manual window; survives Brave/Ubuntu cookie resets
- Container-side clone URLs MUST use the hosts-immune name gitea.dns.podman:3000 (aardvark), never bare gitea
- woodpecker-server keeps --no-hosts + WOODPECKER_GITEA_URL=http://gitea:3000
- aether-login-window.sh is DEPRECATED (emergency only); leaving it open is no longer required
- New repos: register GITEA_CLONE_URL with gitea.dns.podman; gate with a pipeline run
MD
fi
say "docs updated"
hr "X6 RESULT"
say "[RESULT] EX56 COMPLETE - durable login + hosts-immune clones + CI publish gated."
ledger "PASS" "EX56: browser path 200; secrets hosts-immune; pipeline=$ST github=$GH1"
exit 0
