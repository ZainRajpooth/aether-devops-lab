#!/usr/bin/env bash
# 20261112-EX50f — complete the Woodpecker (NOT MinIO) OAuth re-login, then smoke + ledger.
set -uo pipefail
H="$HOME"; SEC="$H/DevOps/aether/secrets"; CD="$H/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex50f-complete-woodpecker-login-smoke-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"; WP="http://127.0.0.1:8000"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"

hr "X0 health gate"
c="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)"
if [ "$c" != 200 ]; then
  systemctl --user restart woodpecker-server.service 2>/dev/null || true
  for i in $(seq 1 45); do c="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)"; [ "$c" = 200 ] && break; sleep 2; done
fi
[ "$c" = 200 ] || halt "woodpecker api not 200 (got $c)"
say "server api=200"
a="$(systemctl --user is-active woodpecker-agent.service 2>/dev/null | head -1)"
if [ "$a" != active ]; then systemctl --user restart woodpecker-agent.service 2>/dev/null || true; sleep 6; a="$(systemctl --user is-active woodpecker-agent.service 2>/dev/null | head -1)"; fi
say "agent=$a"
[ "$a" = active ] || halt "agent not active"
if [ "$MODE" = check ]; then say "[RESULT] EX50f CHECK - nothing written."; exit 0; fi

hr "X1 open temporary login window"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' || halt "permanent bridge 127.0.0.2:3000 not listening"
sudo -v || halt "sudo needed"
sudo cp -p /etc/hosts "/etc/hosts.pre-ex50f.$STAMP.bak"
grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
say "hosts window OPEN"

hr "X2 WOODPECKER login (this is NOT MinIO)"
say "1) Browser -> $WP   (Woodpecker CI, port 8000)"
say "2) Click 'Login with Gitea' (or sign out first if a stale session shows)"
say "3) Gitea username: $AUSER"
say "4) Gitea password: cat $SEC/gitea-admin.pass"
say "   (MinIO console passwords will NOT work here; MinIO is a separate system)"
say "5) Wait until Woodpecker UI shows your repos / dashboard"
printf '  Type DONE only after Woodpecker (port 8000) shows you logged in: ' > /dev/tty
IFS= read -r ACK < /dev/tty
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts window CLOSED"

hr "X3 verify forge access via PAT"
R="$(curl -sS -m 10 -H "Authorization: Bearer $PAT" "$WP/api/user/repos" 2>/dev/null || true)"
printf '%s' "$R" | grep -q woodpecker-proof || { printf '%s\n' "$R" | head -c 300 | sed 's/^/    /'; halt "forge access still not restored; repeat X2 login"; }
say "forge access verified (woodpecker-proof present)"

hr "X4 pipeline smoke"
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

hr "X5 RESULT"
say "[RESULT] EX50f COMPLETE - Woodpecker login verified, smoke green. LANE 1 CLOSED."
ledger "PASS" "EX50f: Woodpecker OAuth re-login completed; forge verified; pipeline #$N success; Lane 1 closed"
exit 0
