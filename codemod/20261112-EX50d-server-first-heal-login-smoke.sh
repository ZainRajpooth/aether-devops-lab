#!/usr/bin/env bash
# 20261112-EX50d — server-first heal: evidence, hosts clean, env dedupe, server gate, agent, login, smoke.
set -uo pipefail
H="$HOME"; SEC="$H/DevOps/aether/secrets"; CD="$H/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex50d-server-first-heal-login-smoke-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"; WP="http://127.0.0.1:8000"; WE="$SEC/woodpecker.env"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"

hr "X0 evidence (read-only)"
for u in postgres gitea minio woodpecker-server woodpecker-agent; do
  say "$u: $(systemctl --user is-active "$u.service" 2>/dev/null | head -1)"
done
podman ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -E 'woodpecker|gitea|postgres|minio' | sed 's/^/    /' || true
say "--- server unit status ---"
systemctl --user status woodpecker-server.service --no-pager -l 2>&1 | head -14 | sed 's/^/    /' || true
say "--- server journal tail 25 ---"
journalctl --user -u woodpecker-server.service -n 25 --no-pager 2>&1 | tail -25 | sed 's/^/    /' || true
say "--- server container logs tail 25 ---"
podman logs --tail 25 woodpecker-server 2>&1 | tail -25 | sed 's/^/    /' || true
say "--- env duplicate keys ---"
DUPS="$(awk -F= '/^[A-Za-z_]+=/ {c[$1]++} END {for (k in c) if (c[k]>1) print k"="c[k]}' "$WE" 2>/dev/null || true)"
say "${DUPS:-none}"
say "--- hosts gitea lines ---"
grep -nE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts | sed 's/^/    /' || say "    clean"
ss -ltn 2>/dev/null | grep -E ':(8000|9000|3000|3001)\b' | sed 's/^/    /' || true
if [ "$MODE" = check ]; then say "[RESULT] EX50d CHECK - nothing written."; exit 0; fi

hr "X1 hosts normalize (remove pollution)"
sudo -v || halt "sudo needed"
sudo cp -p /etc/hosts "/etc/hosts.pre-ex50d.$STAMP.bak"
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts gitea lines now: $(grep -cE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || true)"

hr "X2 env duplicate-key guard (keep last value)"
if [ -n "$DUPS" ]; then
  cp -p "$WE" "$WE.pre-ex50d.$STAMP.bak"; chmod 600 "$WE.pre-ex50d.$STAMP.bak"
  python3 - "$WE" <<'PY'
import sys,os,tempfile
p=sys.argv[1]; lines=open(p,encoding="utf-8",errors="replace").readlines()
last={}; order=[]
for l in lines:
    s=l.strip()
    if s and not s.startswith("#") and "=" in s:
        k=s.split("=",1)[0].strip()
        if k not in last: order.append(k)
        last[k]=l
out=[]; done=set()
for l in lines:
    s=l.strip()
    if s and not s.startswith("#") and "=" in s:
        k=s.split("=",1)[0].strip()
        if k in done: continue
        out.append(last[k]); done.add(k)
    else: out.append(l)
fd,t=tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd,"".join(out).encode()); os.fchmod(fd,0o600); os.close(fd); os.replace(t,p)
PY
  say "deduped woodpecker.env (backup .pre-ex50d.$STAMP.bak)"
else
  say "no duplicates; env untouched"
fi

hr "X3 server-first readiness gate"
systemctl --user reset-failed woodpecker-server.service 2>/dev/null || true
systemctl --user restart woodpecker-server.service 2>/dev/null || true
ok=no
for i in $(seq 1 60); do
  st="$(podman inspect woodpecker-server --format '{{.State.Status}}' 2>/dev/null || echo missing)"
  c="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)"
  if [ "$st" = running ] && [ "$c" = 200 ]; then ok=yes; say "server running + api=200 (iter $i)"; break; fi
  sleep 2
done
if [ "$ok" != yes ]; then
  say "--- server journal tail 40 ---"
  journalctl --user -u woodpecker-server.service -n 40 --no-pager 2>&1 | tail -40 | sed 's/^/    /'
  say "--- server container logs tail 40 ---"
  podman logs --tail 40 woodpecker-server 2>&1 | tail -40 | sed 's/^/    /'
  ledger "FAIL" "EX50d server not ready; evidence dumped"
  halt "server not ready; paste X3 evidence"
fi

hr "X4 agent heal (now that server is up)"
systemctl --user reset-failed woodpecker-agent.service 2>/dev/null || true
systemctl --user restart woodpecker-agent.service 2>/dev/null || true
ok=no; for i in $(seq 1 30); do [ "$(systemctl --user is-active woodpecker-agent.service 2>/dev/null | head -1)" = active ] && { ok=yes; break; }; sleep 2; done
[ "$ok" = yes ] || { journalctl --user -u woodpecker-agent.service -n 25 --no-pager | tail -20 | sed 's/^/    /'; halt "agent still failed"; }
say "agent active"

hr "X5 single OAuth re-login via permanent bridge"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' || halt "permanent bridge not listening"
echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
say "OPEN http://127.0.0.1:8000 -> Login with Gitea -> user=$AUSER"
say "  password: cat $SEC/gitea-admin.pass   (Gitea password, NOT OS, NOT MinIO)"
printf '  Type DONE after login: ' > /dev/tty; IFS= read -r ACK < /dev/tty
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts cleaned again"
curl -sS -H "Authorization: Bearer $PAT" "$WP/api/user/repos" | grep -q woodpecker-proof || halt "forge access not restored"
say "forge access verified"

hr "X6 pipeline smoke"
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

hr "X7 RESULT"
say "[RESULT] EX50d COMPLETE - server+agent active, hosts clean, login verified, smoke green."
ledger "PASS" "EX50d: server-first heal; agent active; re-login verified; pipeline #$N success"
exit 0
