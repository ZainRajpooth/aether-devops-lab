#!/usr/bin/env bash
set -uo pipefail
umask 077
HOME_="$HOME"; CD="$HOME_/DevOps/aether/codemod"; SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"; TOKEN="ex42b-continue-repair-v1"
PAT_FILE="$SEC/woodpecker-pat.token"
BOT_FILE="$SEC/gitea-wp-bot.user"; PASS_FILE="$SEC/gitea-wp-bot.pass"
REPO="woodpecker-proof"; WP="http://127.0.0.1:8000"
INTERNAL_WP="http://woodpecker-server:8000"
PGU="devops"; PGDB="woodpecker"; GTDB="gitea"

TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

psql_wp(){ podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true; }
psql_gt(){ podman exec postgres psql -U "$PGU" -d "$GTDB" -tAc "$1" 2>/dev/null || true; }
http_code(){ local c; c="$(curl -sS -m "${2:-6}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true)"; printf '%s\n' "${c:-000}"; }
mask(){ PAT_MASK="${PAT:-}" python3 -c '
import os,re,sys
p=os.environ.get("PAT_MASK","")
for line in sys.stdin:
    if p: line=line.replace(p,"[REDACTED]")
    line=re.sub(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}","[JWT]",line)
    sys.stdout.write(line)'; }

ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"
  say "ledger: $t"; }

[ -s "$PAT_FILE" ] || halt "missing PAT file"
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing bot creds"
PAT="$(tr -d '\n\r' < "$PAT_FILE")"
BOT="$(tr -d '\n\r' < "$BOT_FILE")"; PASS="$(tr -d '\n\r' < "$PASS_FILE")"
BOT_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$BOT")"
PASS_ENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PASS")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"

REPO_ID="$(psql_wp "SELECT id FROM repos WHERE lower(name)=lower('$REPO')" | tr -d ' \n')"
ROW="$(psql_wp "SELECT hash||'|'||forge_remote_id FROM repos WHERE id=$REPO_ID")"
REPO_HASH="${ROW%%|*}"; GITEA_REPO_ID="${ROW##*|}"
[ -n "$REPO_HASH" ] || halt "no repo hash"

hr "X2 (retry) wait for Woodpecker API — up to 4 minutes"
up=no
for i in $(seq 1 120); do
  c="$(http_code "$WP/api/version" 3)"
  if [ "$c" = 200 ]; then up=yes; say "WP API ready (iteration $i)"; break; fi
  case "$i" in 1|10|20|30|60|90|120) say "waiting... iter=$i code=$c" ;; esac
  sleep 2
done
[ "$up" = yes ] || { podman ps --filter name=woodpecker-server; podman logs --tail 30 woodpecker-server 2>&1 | tail -30; halt "woodpecker not reachable after 4min"; }

hr "X3 repair via PAT"
CODE="$(curl -sS -m 20 -o "$TMP/repair.json" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
  --data '{}' "$WP/api/repos/$REPO_ID/repair" 2>/dev/null || echo 000)"
say "POST /api/repos/$REPO_ID/repair -> $CODE"
mask < "$TMP/repair.json" | head -c 300 | sed 's/^/    /' || true
case "$CODE" in 2*) ;; *)
  CODE="$(curl -sS -m 20 -o "$TMP/repair2.json" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $PAT" --data '{}' \
    "$WP/api/repos/$BOT/$REPO/repair" 2>/dev/null || echo 000)"
  say "POST /api/repos/$BOT/$REPO/repair -> $CODE"
  mask < "$TMP/repair2.json" | head -c 300 | sed 's/^/    /' || true
  ;; esac
case "$CODE" in 2*) say "repair accepted";; *) ledger "FAIL" "repair rejected http=$CODE"; halt "repair rejected";; esac

hr "X4 verify + rewrite webhook host"
sleep 2
HURL="$(psql_gt "SELECT url FROM webhook WHERE repo_id=$GITEA_REPO_ID ORDER BY id DESC LIMIT 1")"
[ -n "$HURL" ] || { ledger "FAIL" "no webhook after repair"; halt "no webhook row"; }
say "hook url: $(printf '%s' "$HURL" | mask)"
case "$HURL" in
  *woodpecker-server:8000*) say "host already internal" ;;
  *)
    NEW="$(printf '%s' "$HURL" | python3 -c '
import sys,urllib.parse
u=urllib.parse.urlparse(sys.stdin.read().strip())
print("http://woodpecker-server:8000"+u.path+(("?"+u.query) if u.query else ""))')"
    psql_gt "UPDATE webhook SET url='$NEW' WHERE repo_id=$GITEA_REPO_ID;" >/dev/null
    say "rewrote host -> $(printf '%s' "$NEW" | mask)"
    HURL="$NEW" ;;
esac

hr "X5 push + DB gate"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BEFORE="$(psql_wp "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n')"
W="$TMP/git"; rm -rf "$W"
git clone -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/$REPO.git" "$W" || halt "clone failed"
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
if [ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ]; then
  git commit -q -m "ci: ex42b $(date -Is)" || halt "commit failed"
else
  git commit -q --allow-empty -m "ci: ex42b retrigger $(date -Is)" || halt "commit failed"
fi
git push -q "http://$BOT_ENC:$PASS_ENC@127.0.0.1:$GT_PORT/$BOT/$REPO.git" HEAD:main || halt "push failed"
SHA="$(git rev-parse HEAD)"; say "pushed $SHA"; cd / || true

OK=no; NUM=""; ST=""
for i in $(seq 1 60); do
  R="$(psql_wp "SELECT id||' '||number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1")"
  if [ -n "$R" ]; then
    read -r ID NUM ST <<<"$R"
    if [ "${ID:-0}" -gt "${BEFORE:-0}" ]; then
      say "pipeline #$NUM status=$ST"
      [ "$ST" = success ] && { OK=yes; break; }
      case "$ST" in failure|error|killed) break ;; esac
    fi
  fi
  sleep 3
done

hr "X6 delivery evidence"
psql_gt "SELECT is_delivered, is_succeed, LEFT(response_content,200) FROM hook_task ORDER BY id DESC LIMIT 1;" | mask | sed 's/^/    /' || true

if [ "$OK" = yes ]; then
  hr "X7 RESULT"
  say "[RESULT] EX42B COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
  say "  pipeline=#$NUM status=success push=$SHA"
  ledger "PASS" "EX42B: PAT repair + internal hook rewrite; pipeline #$NUM success. Brick 12 CLOSED."
else
  say "--- WP server logs since $SINCE ---"
  podman logs --since "$SINCE" woodpecker-server 2>&1 | mask | tail -25 | sed 's/^/    /' || true
  say "--- WP agent logs since $SINCE ---"
  podman logs --since "$SINCE" woodpecker-agent 2>&1 | mask | tail -15 | sed 's/^/    /' || true
  ledger "PARTIAL" "EX42B pipeline=#${NUM:-none} status=${ST:-none}"
  halt "pipeline not success"
fi
