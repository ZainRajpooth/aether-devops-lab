#!/usr/bin/env bash
# 20261112-EX50g — set Gitea OAuth app confidential=true (PKCE fix), then login window + smoke.
set -uo pipefail
H="$HOME"; SEC="$H/DevOps/aether/secrets"; CD="$H/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex50g-oauth-confidential-fix-login-smoke-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"; WP="http://127.0.0.1:8000"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
gt(){ podman exec postgres psql -U devops -d gitea -tAc "$1" 2>/dev/null || true; }
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"

hr "X0 evidence: oauth app flags"
gt "SELECT id||' name='||name||' confidential='||confidential FROM oauth2_application ORDER BY id;" | sed 's/^/    /'
gt "SELECT column_name FROM information_schema.columns WHERE table_name='oauth2_application' AND column_name='confidential';" | sed 's/^/    col: /'
if [ "$MODE" = check ]; then
  say "plan: UPDATE oauth2_application SET confidential=true WHERE name='woodpecker'; verify;"
  say "      hosts window -> Woodpecker Gitea OAuth login -> close window -> PAT verify -> smoke -> ledger"
  say "[RESULT] EX50g CHECK - nothing written."; exit 0
fi

hr "X1 flip confidential=true (single boolean)"
OLD="$(gt "SELECT confidential FROM oauth2_application WHERE name='woodpecker';" | tr -d ' \n')"
say "old confidential=$OLD"
gt "UPDATE oauth2_application SET confidential=true WHERE name='woodpecker';" >/dev/null
NEW="$(gt "SELECT confidential FROM oauth2_application WHERE name='woodpecker';" | tr -d ' \n')"
say "new confidential=$NEW"
[ "$NEW" = t ] || [ "$NEW" = true ] || halt "confidential flag not set"

hr "X2 login window (Woodpecker, NOT MinIO)"
c="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)"
[ "$c" = 200 ] || halt "woodpecker api not 200"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' || halt "permanent bridge not listening"
sudo -v || halt "sudo needed"
sudo cp -p /etc/hosts "/etc/hosts.pre-ex50g.$STAMP.bak"
grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
say "hosts window OPEN"
say "Browser -> $WP -> 'Login with Gitea' -> user=$AUSER"
say "  password: cat $SEC/gitea-admin.pass   (Gitea password)"
say "  PKCE error must be GONE; wait for Woodpecker dashboard/repos"
printf '  Type DONE after Woodpecker shows logged in: ' > /dev/tty; IFS= read -r ACK < /dev/tty
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts window CLOSED"

hr "X3 verify forge access"
R="$(curl -sS -m 10 -H "Authorization: Bearer $PAT" "$WP/api/user/repos" 2>/dev/null || true)"
printf '%s' "$R" | grep -q woodpecker-proof || { printf '%s\n' "$R" | head -c 300 | sed 's/^/    /'; halt "forge access not restored"; }
say "forge access verified"

hr "X4 smoke"
NUM="$(gt "SELECT 1;" >/dev/null; podman exec postgres psql -U devops -d woodpecker -tAc "SELECT MAX(number) FROM pipelines WHERE repo_id=1" 2>/dev/null | tr -d ' \n')"
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

hr "X5 RESULT"
say "[RESULT] EX50g COMPLETE - OAuth confidential fixed, login verified, smoke green. LANE 1 CLOSED."
ledger "PASS" "EX50g: oauth confidential=true; Woodpecker login verified; pipeline #$N success; Lane 1 closed"
exit 0
