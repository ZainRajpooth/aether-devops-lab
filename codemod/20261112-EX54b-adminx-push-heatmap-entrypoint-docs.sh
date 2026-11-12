#!/usr/bin/env bash
# 20261112-EX54b — adminX-authenticated push for heatmap credit; finish entrypoint + corrected docs.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex54b-adminx-push-heatmap-entrypoint-docs-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
PS="$A/infra/scripts/aether-publish.sh"
GH_EMAIL="z4xebot1@gmail.com"; GH_USER="ZainRajpooth"
GT="http://127.0.0.1:3001"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS" "$A/infra/scripts"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"
BOT="$(tr -d '\n\r' < "$SEC/gitea-wp-bot.user")"
AENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$APASS")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"
heat(){ curl -sS -m 15 -u "$AUSER:$APASS" "$GT/api/v1/users/$AUSER/heatmap" 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(sum(x.get("contributions",0) for x in d))' 2>/dev/null || echo 0; }

hr "X0 probes"
HM0="$(heat)"; say "adminX heatmap before: $HM0"
[ -f "$PS" ] && say "entrypoint: present" || say "entrypoint: MISSING (will create)"
say "session: $(awk -F= '/^WOODPECKER_SESSION_EXPIRES=/{print $2}' "$SEC/woodpecker.env" || echo unset)"
if [ "$MODE" = check ]; then
  say "plan: if heatmap==0 -> real commit pushed AS adminX -> heatmap gate; entrypoint; corrected docs; ledger"
  say "[RESULT] EX54b CHECK - nothing written."; exit 0
fi

hr "X1 adminX-authenticated push (pusher credit)"
if [ "$HM0" -ge 1 ]; then
  say "heatmap already credited (no-op)"
else
  W="$TMP/repo"
  git clone -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" "$W" || halt "clone as adminX failed"
  cd "$W" || halt "cd failed"
  git config user.name "$GH_USER"; git config user.email "$GH_EMAIL"
  printf '\n- Contributions: pushes authenticated as %s credit the Gitea heatmap (%s).\n' "$AUSER" "$STAMP" >> README.md
  git add README.md
  git commit -q -m "docs: contribution credit note (pushed as $AUSER)" || halt "commit failed"
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$BOT/woodpecker-proof.git" HEAD:main || halt "push as adminX failed"
  say "pushed as $AUSER (pusher credit)"
  cd / || true
  sleep 3
  HM1="$(heat)"; say "adminX heatmap after: $HM1"
  [ "$HM1" -ge 1 ] || halt "heatmap still 0 after adminX push"
  say "HEATMAP GATE PASS"
fi

hr "X2 publish entrypoint (gap closure)"
cat > "$TMP/ps.sh" <<'PSE'
#!/usr/bin/env bash
# re-runnable curated publish entrypoint (EX54b); delegates to gated EX53e
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261112-EX53e-union-blocklist-monotonic-gated-publish.sh" run
PSE
if [ -f "$PS" ] && cmp -s "$TMP/ps.sh" "$PS"; then say "entrypoint unchanged (no-op)"; else
  [ -f "$PS" ] && cp -p "$PS" "$PS.pre-ex54b.$STAMP.bak"
  install -m 700 "$TMP/ps.sh" "$PS"; say "entrypoint written: $PS"
fi
bash -n "$PS" || halt "entrypoint syntax"

hr "X3 corrected docs + manual step + ledger"
if ! grep -q "Login window helper (EX54b)" "$DOCS/brick12-runbook.md" 2>/dev/null; then
cat >> "$DOCS/brick12-runbook.md" <<'MD'

## Login window helper (EX54b)
- infra/scripts/aether-login-window.sh open|close|status
- open: temporary hosts entry (backup taken) -> browser login at :8000 -> close immediately after
- session expiry 720h (woodpecker.env) reduces re-login frequency
- Never leave the window open: hosts entry leaks into Podman containers and breaks step DNS
## Contribution graphs — corrected (EX54b)
- Gitea heatmap credits the PUSHER (action table): push authenticated as adminX to credit adminX;
  bot-authenticated CI pushes credit the bot regardless of commit author email.
- GitHub credits verified AUTHOR email: add+verify z4xebot1@gmail.com at github.com/settings/emails (one-time, manual).
MD
fi
say "MANUAL (one-time): github.com/settings/emails -> add $GH_EMAIL -> verify"
hr "X4 RESULT"
say "[RESULT] EX54b COMPLETE - heatmap credited, entrypoint closed, docs corrected."
ledger "PASS" "EX54b: heatmap=$(heat); entrypoint present; docs corrected"
exit 0
