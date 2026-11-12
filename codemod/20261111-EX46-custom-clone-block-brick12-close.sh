#!/usr/bin/env bash
set -uo pipefail
HOME_="$HOME"; CD="$HOME_/DevOps/aether/codemod"; SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"; TOKEN="ex46-custom-clone-block-brick12-close-v1"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
PGU="devops"; PGDB="woodpecker"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
psql_wp(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
mask(){ python3 -c '
import re,sys
u,p=sys.argv[1],sys.argv[2]
for l in sys.stdin:
    l=l.replace(u,"[BOT]").replace(p,"[PASS]")
    sys.stdout.write(l)' "$BOT" "$PASS"; }

hr "X0 preflight"
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "bot creds missing"
BOT="$(tr -d '\n\r' < "$BOT_FILE")"; PASS="$(tr -d '\n\r' < "$PASS_FILE")"
BOT_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PASS")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"

hr "X1 push custom clone block"
BEFORE="$(psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=1" | tr -d ' \n')"
W="$TMP/git"; rm -rf "$W"
git clone -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" "$W" || halt "clone failed"
cd "$W" || halt "cd failed"
git config user.email "$BOT@local"; git config user.name "Woodpecker Proof"

cat > .woodpecker.yml <<'YML'
clone:
  - name: git
    image: docker.io/alpine/git
    commands:
      - git config --global --add safe.directory /woodpecker/src/127.0.0.1/wp-ci-bot-1793813218/woodpecker-proof
      - git clone http://gitea:3000/wp-ci-bot-1793813218/woodpecker-proof.git .
      - git checkout $CI_COMMIT_SHA

steps:
  - name: hello-world
    image: docker.io/alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
YML

git add .woodpecker.yml
git commit -q --allow-empty -m "ci: ex46 custom clone block $(date -Is)" || halt "commit failed"
git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" HEAD:main 2>&1 | mask || halt "push failed"
SHA="$(git rev-parse HEAD)"; say "pushed $SHA"; cd / || true

hr "X2 poll for success"
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
  hr "X3 RESULT"
  say "[RESULT] EX46 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
  say "  pipeline=#$NUM status=success push=$SHA"
  ledger "PASS" "EX46: custom clone block bypassed split-brain DNS; pipeline #$NUM success. Brick 12 CLOSED."
else
  say "STEP LOGS (UI): open pipeline #$NUM -> git -> paste last 5 lines"
  podman logs --tail 25 woodpecker-agent 2>&1 | mask | tail -12 | sed 's/^/  /' || true
  ledger "PARTIAL" "EX46 pipeline=#${NUM:-none} status=${ST:-none}"
  halt "pipeline not success yet"
fi
exit 0
