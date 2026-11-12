#!/usr/bin/env bash
# 20261111-EX45 — final Brick 12 heal: valid step network + clean DNS + correct clone_url.
set -uo pipefail
HOME_="$HOME"; CD="$HOME_/DevOps/aether/codemod"; SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"; TOKEN="ex45-final-clone-fix-brick12-close-v1"
AF="$HOME_/.config/systemd/user/woodpecker-agent.service"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
PGU="devops"; PGDB="woodpecker"
CLONE="http://gitea:3000/wp-ci-bot-1793813218/woodpecker-proof.git"
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
[ -f "$AF" ] || halt "agent service file missing"
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "bot creds missing"
BOT="$(tr -d '\n\r' < "$BOT_FILE")"; PASS="$(tr -d '\n\r' < "$PASS_FILE")"
BOT_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PASS")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"

hr "X1 revert step network to aether (valid podman network name)"
sed -i 's/WOODPECKER_BACKEND_DOCKER_NETWORK=host/WOODPECKER_BACKEND_DOCKER_NETWORK=aether/' "$AF"
grep -o 'WOODPECKER_BACKEND_DOCKER_NETWORK=[a-z]*' "$AF"
systemctl --user daemon-reload && systemctl --user restart woodpecker-agent.service
sleep 5
podman ps --filter name=woodpecker-agent --format 'agent: {{.Status}}'

hr "X2 remove gitea pollution from host /etc/hosts (needs sudo)"
if grep -qE '^[^#]*[[:space:]]gitea([[:space:]]|$)' /etc/hosts; then
  sudo -v || halt "sudo auth failed; run: sudo sed -i '/[[:space:]]gitea$/d' /etc/hosts  then rerun"
  sudo cp -p /etc/hosts "/etc/hosts.pre-ex45.bak"
  sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
  say "removed gitea line; backup at /etc/hosts.pre-ex45.bak"
else
  say "no gitea line present; nothing to do"
fi
grep -c gitea /etc/hosts | sed 's/^/  gitea lines remaining: /'

hr "X3 fix stored clone_url in Woodpecker DB"
psql_wp "UPDATE repos SET clone_url='$CLONE' WHERE id=1;" >/dev/null
psql_wp "SELECT clone_url FROM repos WHERE id=1;" | sed 's/^/  clone_url now: /'

hr "X4 prove step-container path: aether + clean hosts -> gitea:3000"
podman run --rm --network aether docker.io/library/alpine:latest \
  sh -c 'wget -qO- -T 8 http://gitea:3000/api/v1/version || wget -qO- -T 8 -o /dev/null http://gitea:3000/ && echo REACHABLE' \
  2>&1 | tail -2 | sed 's/^/  /' || halt "gitea unreachable from aether container"

hr "X5 real push -> webhook -> pipeline -> DB gate"
BEFORE="$(psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=1" | tr -d ' \n')"
W="$TMP/git"; rm -rf "$W"
git clone -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" "$W" || halt "clone failed"
cd "$W" || halt "cd failed"
git config user.email "$BOT@local"; git config user.name "Woodpecker Proof"
cat > .woodpecker.yml <<'YML'
steps:
  - name: hello-world
    image: alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
YML
git add .woodpecker.yml
git commit -q --allow-empty -m "ci: ex45 steel thread $(date -Is)" || halt "commit failed"
git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" HEAD:main 2>&1 | mask || halt "push failed"
SHA="$(git rev-parse HEAD)"; say "pushed $SHA"; cd / || true

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

hr "X6 evidence"
psql_wp "SELECT s.name||' '||s.state||' exit='||COALESCE(s.exit_code::text,'?') FROM steps s JOIN pipelines p ON p.id=s.pipeline_id WHERE p.id=(SELECT MAX(id) FROM pipelines WHERE repo_id=1) ORDER BY s.step_id;" 2>/dev/null | sed 's/^/  /' || \
podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "SELECT name||' '||state FROM steps WHERE pipeline_id=(SELECT MAX(id) FROM pipelines WHERE repo_id=1) ORDER BY step_id;" | sed 's/^/  /' || true
podman logs --tail 12 woodpecker-agent 2>&1 | tail -6 | sed 's/^/  /' || true

if [ "$OK" = yes ]; then
  hr "X7 RESULT"
  say "[RESULT] EX45 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
  say "  pipeline=#$NUM status=success push=$SHA"
  ledger "PASS" "EX45: aether net + hosts de-pollution + clone_url fix; pipeline #$NUM success. Brick 12 CLOSED."
else
  say "STEP LOGS (UI): open pipeline #$NUM -> clone -> paste last 5 lines"
  podman logs --tail 25 woodpecker-agent 2>&1 | mask | tail -12 | sed 's/^/  /' || true
  ledger "PARTIAL" "EX45 pipeline=#${NUM:-none} status=${ST:-none}"
  halt "pipeline not success yet"
fi
exit 0
