#!/usr/bin/env bash
# 20261112-EX54 — login window helper + long session; contribution identity; publish entrypoint; docs.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex54-login-ergonomics-identity-entrypoint-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
WE="$SEC/woodpecker.env"; LW="$A/infra/scripts/aether-login-window.sh"; PS="$A/infra/scripts/aether-publish.sh"
GH_EMAIL="z4xebot1@gmail.com"; GH_USER="ZainRajpooth"
GT="http://127.0.0.1:3001"; WP="http://127.0.0.1:8000"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS" "$A/infra/scripts"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"
BOT="$(tr -d '\n\r' < "$SEC/gitea-wp-bot.user")"; BPASS="$(tr -d '\n\r' < "$SEC/gitea-wp-bot.pass")"
BENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$BPASS")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"
upsert(){ python3 - "$WE" "$@" <<'PY'
import os,sys,tempfile
p=sys.argv[1]; upd=dict(x.split("=",1) for x in sys.argv[2:] if "=" in x)
lines=open(p,encoding="utf-8",errors="replace").readlines() if os.path.exists(p) else []
out=[];seen=set()
for l in lines:
    s=l.strip()
    if s and not s.startswith("#") and "=" in s:
        k=s.split("=",1)[0].strip()
        if k in upd:
            if k not in seen: out.append(f"{k}={upd[k]}\n"); seen.add(k)
            continue
    out.append(l)
for k,v in upd.items():
    if k not in seen: out.append(f"{k}={v}\n")
fd,t=tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd,"".join(out).encode()); os.fchmod(fd,0o600); os.close(fd); os.replace(t,p)
PY
}
hr "X0 probes"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' && say "bridge: listening" || halt "permanent bridge not listening"
say "hosts gitea lines: $(grep -cE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || true)"
say "session expires now: $(awk -F= '/^WOODPECKER_SESSION_EXPIRES=/{print $2}' "$WE" || echo unset)"
[ -f "$PS" ] && say "entrypoint: present" || say "entrypoint: MISSING (will create)"
if [ "$MODE" = check ]; then
  say "plan: login-window helper -> session 720h + gated restart -> adminX email/identity -> authored commit + heatmap gate ->"
  say "      entrypoint -> docs -> ledger ; prints GitHub email-verification instruction"
  say "[RESULT] EX54 CHECK - nothing written."; exit 0
fi

hr "X1 login-window helper (open|close|status)"
cat > "$TMP/lw.sh" <<'LW'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-status}" in
  open)
    sudo -v || exit 1
    sudo cp -p /etc/hosts "/etc/hosts.pre-login.$(date +%Y%m%d-%H%M%S).bak"
    grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
    echo "login window OPEN — browser: http://127.0.0.1:8000 -> Login with Gitea; run '$0 close' after login" ;;
  close)
    sudo -v || exit 1
    sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
    echo "login window CLOSED (hosts clean)" ;;
  status)
    grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts && echo "OPEN" || echo "CLOSED" ;;
  *) echo "usage: $0 open|close|status"; exit 2 ;;
esac
LW
if [ -f "$LW" ] && cmp -s "$TMP/lw.sh" "$LW"; then say "helper unchanged (no-op)"; else
  [ -f "$LW" ] && cp -p "$LW" "$LW.pre-ex54.$STAMP.bak"
  install -m 700 "$TMP/lw.sh" "$LW"; say "helper written: $LW"
fi
bash -n "$LW" || halt "helper syntax"

hr "X2 long session + gated restart"
CUR="$(awk -F= '/^WOODPECKER_SESSION_EXPIRES=/{print $2}' "$WE" || true)"
if [ "$CUR" = 720h ]; then say "session already 720h (no-op)"; else
  cp -p "$WE" "$WE.pre-ex54.$STAMP.bak"; chmod 600 "$WE.pre-ex54.$STAMP.bak"
  upsert "WOODPECKER_SESSION_EXPIRES=720h"
  systemctl --user restart woodpecker-server.service 2>/dev/null || true
  ok=no; for i in $(seq 1 45); do [ "$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)" = 200 ] && { ok=yes; break; }; sleep 2; done
  [ "$ok" = yes ] || halt "server not ready after session change"
  say "session=720h; server api=200"
fi

hr "X3 contribution identity (Gitea author-email credit)"
C="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X PATCH -u "$AUSER:$APASS" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$GH_EMAIL\",\"full_name\":\"$GH_USER\"}" "$GT/api/v1/admin/users/$AUSER" || echo 000)"
say "adminX email set -> $C"
git config --global user.name "$GH_USER"
git config --global user.email "$GH_EMAIL"
say "global git identity: $GH_USER <$GH_EMAIL>"
W="$TMP/repo"
git clone -q "http://$BOT:$BENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" "$W" || halt "clone failed"
cd "$W" || halt "cd failed"
git config user.name "$GH_USER"; git config user.email "$GH_EMAIL"
if [ ! -f README.md ]; then
cat > README.md <<'RD'
# woodpecker-proof

Steel-thread proof repo for the Aether lab: Gitea push -> Woodpecker pipeline -> green run.
Clone remote is overridden per-pipeline via `PLUGIN_REMOTE` + `from_secret` (split-horizon DNS workaround).
RD
  git add README.md
  git commit -q -m "docs: proof repo readme (authored by $AUSER)" || halt "commit failed"
  git push -q origin HEAD:main || halt "push failed"
  say "authored commit pushed as $AUSER"
else
  say "README exists; no new commit (no-op)"
fi
cd / || true
sleep 2
HM="$(curl -sS -m 15 -u "$AUSER:$APASS" "$GT/api/v1/users/$AUSER/heatmap" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(sum(x.get("contributions",0) for x in d))' 2>/dev/null || echo 0)"
say "adminX heatmap contributions: $HM"
[ "$HM" -ge 1 ] || halt "heatmap still empty; author-email credit failed"
say "HEATMAP GATE PASS"

hr "X4 publish entrypoint (gap closure)"
cat > "$TMP/ps.sh" <<'PSE'
#!/usr/bin/env bash
# re-runnable curated publish entrypoint (EX54); delegates to gated EX53e
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261112-EX53e-union-blocklist-monotonic-gated-publish.sh" run
PSE
if [ -f "$PS" ] && cmp -s "$TMP/ps.sh" "$PS"; then say "entrypoint unchanged (no-op)"; else
  [ -f "$PS" ] && cp -p "$PS" "$PS.pre-ex54.$STAMP.bak"
  install -m 700 "$TMP/ps.sh" "$PS"; say "entrypoint written: $PS"
fi
bash -n "$PS" || halt "entrypoint syntax"

hr "X5 docs + manual step + ledger"
if ! grep -q "Login window helper (EX54)" "$DOCS/brick12-runbook.md" 2>/dev/null; then
cat >> "$DOCS/brick12-runbook.md" <<'MD'

## Login window helper (EX54)
- infra/scripts/aether-login-window.sh open|close|status
- open: temporary hosts entry (backup taken) -> browser login at :8000 -> close immediately after
- session expiry 720h (woodpecker.env) reduces re-login frequency
- Never leave the window open: hosts entry leaks into Podman containers and breaks step DNS
## Contribution graphs (EX54)
- Gitea heatmap credits commit AUTHOR email (adminX email = z4xebot1@gmail.com); bot-authored CI commits credit the bot
- GitHub graph requires the author email added+verified at github.com/settings/emails (manual, one-time)
MD
fi
say "MANUAL (one-time): github.com/settings/emails -> add $GH_EMAIL -> verify -> GitHub contribution graph credits publish commits"
hr "X6 RESULT"
say "[RESULT] EX54 COMPLETE - login ergonomics, identity credit, entrypoint closed."
ledger "PASS" "EX54: helper+720h session; heatmap=$HM; entrypoint present"
exit 0
