#!/usr/bin/env bash
set -uo pipefail
SEC="$HOME/DevOps/aether/secrets"; CD="$HOME/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex48-plugin-remote-secret-brick12-close-v1"
WP="http://127.0.0.1:8000"; PGU=devops; PGDB=woodpecker
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
psql_wp(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }

BOT="$(tr -d '\n\r' < "$SEC/gitea-wp-bot.user")"
PASS="$(tr -d '\n\r' < "$SEC/gitea-wp-bot.pass")"
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"
PASS_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PASS")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"

hr "X1 secret with URL-encoded password"
curl -sS -X DELETE -H "Authorization: Bearer $PAT" "$WP/api/repos/1/secrets/GITEA_BOT_PASS_ENC" >/dev/null 2>&1 || true
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
  -d "{\"name\":\"GITEA_BOT_PASS_ENC\",\"value\":\"$PASS_ENC\",\"events\":[\"push\",\"pull_request\",\"manual\",\"deployment\"]}" \
  "$WP/api/repos/1/secrets")"
say "create secret GITEA_BOT_PASS_ENC -> $CODE"
[ "$CODE" = 200 ] || [ "$CODE" = 201 ] || halt "secret create failed"

hr "X2 push pipeline with PLUGIN_REMOTE override"
BEFORE="$(psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=1" | tr -d ' \n')"
W="$TMP/git"; rm -rf "$W"
git clone -q "http://$BOT:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" "$W" || halt "clone failed"
cd "$W" || halt "cd failed"
git config user.email "$BOT@local"; git config user.name "Woodpecker Proof"
cat > .woodpecker.yml <<'YML'
clone:
  - name: git
    image: woodpeckerci/plugin-git
    environment:
      PLUGIN_REMOTE: http://wp-ci-bot-1793813218:${GITEA_BOT_PASS_ENC}@gitea:3000/wp-ci-bot-1793813218/woodpecker-proof.git

steps:
  - name: hello-world
    image: docker.io/alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
YML
git add .woodpecker.yml
git commit -q --allow-empty -m "ci: ex48 PLUGIN_REMOTE override $(date -Is)" || halt "commit failed"
git push -q "http://$BOT:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" HEAD:main || halt "push failed"
SHA="$(git rev-parse HEAD)"; say "pushed $SHA"; cd / || true

hr "X3 DB gate"
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

if [ "$OK" = yes ]; then
  hr "X4 RESULT"
  say "[RESULT] EX48 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
  say "  pipeline=#$NUM status=success push=$SHA"
  ledger "PASS" "EX48: PLUGIN_REMOTE + encoded secret; pipeline #$NUM success. Brick 12 CLOSED."
else
  say "UI: pipeline #$NUM -> git step -> paste last 6 lines"
  ledger "PARTIAL" "EX48 pipeline=#${NUM:-none} status=${ST:-none}"
  halt "not success yet"
fi
exit 0
