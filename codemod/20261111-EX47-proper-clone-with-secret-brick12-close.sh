#!/usr/bin/env bash
set -uo pipefail
HOME_="$HOME"; CD="$HOME_/DevOps/aether/codemod"; SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"; TOKEN="ex47-proper-clone-with-secret-brick12-close-v1"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
PAT_FILE="$SEC/woodpecker-pat.token"
PGU="devops"; PGDB="woodpecker"
WP="http://127.0.0.1:8000"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
psql_wp(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }

hr "X0 preflight"
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] && [ -s "$PAT_FILE" ] || halt "missing creds"
BOT="$(tr -d '\n\r' < "$BOT_FILE")"
PASS="$(tr -d '\n\r' < "$PASS_FILE")"
PAT="$(tr -d '\n\r' < "$PAT_FILE")"
BOT_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PASS")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"

hr "X1 create Woodpecker secret for bot password"
# Check if secret exists
EXISTING="$(curl -sS -H "Authorization: Bearer $PAT" "$WP/api/repos/1/secrets" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(s["name"] for s in d if s["name"]=="GITEA_BOT_PASS"))' 2>/dev/null || echo "")"

if [ "$EXISTING" != "GITEA_BOT_PASS" ]; then
  curl -sS -X POST -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" \
    -d "{\"name\":\"GITEA_BOT_PASS\",\"value\":\"$PASS\",\"images\":[],\"events\":[\"push\",\"pull_request\",\"deployment\",\"manual\"]}" \
    "$WP/api/repos/1/secrets" >/dev/null
  say "created secret GITEA_BOT_PASS"
else
  say "secret GITEA_BOT_PASS already exists"
fi

hr "X2 push pipeline with proper clone plugin + secret"
BEFORE="$(psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=1" | tr -d ' \n')"
W="$TMP/git"; rm -rf "$W"
git clone -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" "$W" || halt "clone failed"
cd "$W" || halt "cd failed"
git config user.email "$BOT@local"; git config user.name "Woodpecker Proof"

cat > .woodpecker.yml <<YML
clone:
  - name: git
    image: woodpeckerci/plugin-git
    environment:
      CI_REPO_REMOTE: http://${BOT}:\${GITEA_BOT_PASS}@gitea:3000/wp-ci-bot-1793813218/woodpecker-proof.git

steps:
  - name: hello-world
    image: docker.io/alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
      - pwd
YML

git add .woodpecker.yml
git commit -q --allow-empty -m "ci: ex47 proper clone with secret $(date -Is)" || halt "commit failed"
git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" HEAD:main || halt "push failed"
SHA="$(git rev-parse HEAD)"; say "pushed $SHA"; cd / || true

hr "X3 poll for success"
OK=no; NUM=""; ST=""
for i in $(seq 1 60); do
  R="$(psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=1 ORDER BY id DESC LIMIT 1")"
  if [ -n "$R" ]; then read -r ID NUM ST <<<"$R"
    if [ "${ID:-0}" -gt "${BEFORE:-0}" ]; then
      say "pipeline #$NUM status=$ST"
      [ "$ST" = success ] && { OK=yes; break; }
      case "$ST" in failure|error|killed) break;; esac
    fi
  fi
  sleep 3
done

hr "X4 verify pipeline details"
psql_wp "SELECT s.name||' state='||s.state||' exit='||COALESCE(s.exit_code::text,'?') FROM steps s JOIN pipelines p ON p.id=s.pipeline_id WHERE p.id=(SELECT MAX(id) FROM pipelines WHERE repo_id=1) ORDER BY s.step_id;" 2>/dev/null | sed 's/^/  /' || true

if [ "$OK" = yes ]; then
  hr "X5 RESULT"
  say "[RESULT] EX47 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
  say "  pipeline=#$NUM status=success push=$SHA"
  say "  Clone: woodpeckerci/plugin-git (allowed) + CI_REPO_REMOTE override + secret injection"
  ledger "PASS" "EX47: proper clone plugin + secret injection; pipeline #$NUM success. Brick 12 CLOSED."
else
  say "STEP LOGS (UI): open pipeline #$NUM -> git -> paste last 10 lines"
  podman logs --tail 30 woodpecker-agent 2>&1 | tail -15 | sed 's/^/  /' || true
  ledger "PARTIAL" "EX47 pipeline=#${NUM:-none} status=${ST:-none}"
  halt "pipeline not success yet"
fi
exit 0
