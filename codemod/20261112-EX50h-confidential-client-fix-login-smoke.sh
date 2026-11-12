#!/usr/bin/env bash
# 20261112-EX50h — set Gitea OAuth app confidential_client=true (PKCE fix), login window, smoke.
set -uo pipefail
H="$HOME"; SEC="$H/DevOps/aether/secrets"; CD="$H/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex50h-confidential-client-fix-login-smoke-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"; WP="http://127.0.0.1:8000"; GT="http://127.0.0.1:3001"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
red(){ sed -E 's/"client_secret"[[:space:]]*:[[:space:]]*"[^"]*"/"client_secret":"***"/g'; }
gt(){ podman exec postgres psql -U devops -d gitea -tAc "$1" 2>/dev/null || true; }
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"

app_flag(){ curl -sS -m 10 -u "$AUSER:$APASS" "$GT/api/v1/user/applications/oauth2" 2>/dev/null \
  | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
a=[x for x in d if x.get("name")=="woodpecker"]
print((str(a[0].get("id"))+" "+str(a[0].get("confidential_client")).lower()) if a else "")'; }

hr "X0 evidence (read-only)"
BEFORE="$(app_flag)"; say "app(id confidential_client) = ${BEFORE:-<none>}"
[ -n "$BEFORE" ] || halt "woodpecker OAuth app not found via API"
AID="${BEFORE%% *}"; FLAG="${BEFORE##* }"
say "column check: $(gt "SELECT column_name FROM information_schema.columns WHERE table_name='oauth2_application' AND column_name='confidential_client';")"
if [ "$MODE" = check ]; then
  if [ "$FLAG" = true ]; then say "already confidential_client=true -> mutation would be a NO-OP"; else
    say "plan: PATCH /user/applications/oauth2/$AID {confidential_client:true}; fallback DB UPDATE; verify via API"; fi
  say "then: hosts window -> Woodpecker Gitea login -> close window -> PAT verify -> smoke -> ledger"
  say "[RESULT] EX50h CHECK - nothing written."; exit 0
fi

hr "X1 set confidential_client=true (API first, DB fallback)"
if [ "$FLAG" = true ]; then
  say "already true; no mutation (idempotent)"
else
  C="$(curl -sS -m 15 -o "$TMP/patch.json" -w '%{http_code}' -X PATCH -u "$AUSER:$APASS" \
    -H 'Content-Type: application/json' \
    -d '{"name":"woodpecker","redirect_uris":["http://127.0.0.1:8000/authorize"],"confidential_client":true}' \
    "$GT/api/v1/user/applications/oauth2/$AID" || echo 000)"
  say "API PATCH -> $C"; red < "$TMP/patch.json" | head -c 200 | sed 's/^/    /' || true
  NOW="$(app_flag)"; say "after API: ${NOW:-<none>}"
  if [ "${NOW##* }" != true ]; then
    say "API did not apply flag -> schema-proven DB fallback"
    gt "UPDATE oauth2_application SET confidential_client=true WHERE id=$AID;" >/dev/null
    say "db value: $(gt "SELECT confidential_client FROM oauth2_application WHERE id=$AID;")"
    NOW="$(app_flag)"; say "after DB: ${NOW:-<none>}"
  fi
  if [ "${NOW##* }" != true ]; then
    say "Gitea may cache; restarting gitea"
    systemctl --user restart gitea.service 2>/dev/null || podman restart gitea >/dev/null 2>&1 || true
    for i in $(seq 1 45); do [ "$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$GT/api/v1/version" 2>/dev/null || echo 000)" = 200 ] && break; sleep 2; done
    NOW="$(app_flag)"; say "after restart: ${NOW:-<none>}"
  fi
  [ "${NOW##* }" = true ] || halt "confidential_client still false; aborting"
fi
say "confidential_client=true CONFIRMED via API"

hr "X2 health gate"
c="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)"
[ "$c" = 200 ] || { systemctl --user restart woodpecker-server.service 2>/dev/null || true
  for i in $(seq 1 45); do c="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)"; [ "$c" = 200 ] && break; sleep 2; done; }
[ "$c" = 200 ] || halt "woodpecker api not 200"
a="$(systemctl --user is-active woodpecker-agent.service 2>/dev/null | head -1)"
[ "$a" = active ] || { systemctl --user restart woodpecker-agent.service 2>/dev/null || true; sleep 6; a="$(systemctl --user is-active woodpecker-agent.service 2>/dev/null | head -1)"; }
say "server=200 agent=$a"

hr "X3 login window (Woodpecker port 8000, Gitea creds)"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' || halt "permanent bridge not listening"
sudo -v || halt "sudo needed"
sudo cp -p /etc/hosts "/etc/hosts.pre-ex50h.$STAMP.bak"
grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
say "hosts window OPEN"
say "Browser -> $WP -> 'Login with Gitea' -> user=$AUSER"
say "  password: cat $SEC/gitea-admin.pass"
say "  PKCE banner must be GONE; wait for the Woodpecker dashboard"
printf '  Type DONE after Woodpecker shows logged in: ' > /dev/tty; IFS= read -r ACK < /dev/tty
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts window CLOSED"

hr "X4 verify forge access"
R="$(curl -sS -m 10 -H "Authorization: Bearer $PAT" "$WP/api/user/repos" 2>/dev/null || true)"
printf '%s' "$R" | grep -q woodpecker-proof || { printf '%s\n' "$R" | head -c 300 | sed 's/^/    /'; halt "forge access not restored"; }
say "forge access verified"

hr "X5 smoke"
NUM="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT MAX(number) FROM pipelines WHERE repo_id=1" 2>/dev/null | tr -d ' \n')"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/1/pipelines/$NUM" || echo 000)"
say "restart pipeline #$NUM -> $CODE"
OK=no; ST=""
for i in $(seq 1 40); do
  R="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT number||' '||status FROM pipelines WHERE repo_id=1 ORDER BY id DESC LIMIT 1" 2>/dev/null || true)"
  if [ -n "$R" ]; then read -r N ST <<<"$R"; say "pipeline #$N status=$ST"
    [ "$ST" = success ] && { OK=yes; break; }
    case "$ST" in failure|error|killed) break;; esac
  fi
  sleep 3
done
[ "$OK" = yes ] || halt "smoke not success"

hr "X6 RESULT"
say "[RESULT] EX50h COMPLETE - confidential_client=true, login verified, smoke green. LANE 1 CLOSED."
ledger "PASS" "EX50h: oauth confidential_client=true (PKCE fix); login verified; pipeline #$N success; Lane 1 closed"
exit 0
