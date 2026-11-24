#!/usr/bin/env bash
# 20261112-EX60c — pin gitleaks to v8.21.2 (stable, no dynamic resolution).
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex60c-pin-gitleaks-version-ci-gate-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
YML="$A/.woodpecker.yml"
GH_USER="ZainRajpooth"; GH_REPO="aether-devops-lab"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"
AENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$APASS")"
GHPAT="$(tr -d '\n\r' < "$SEC/github-pat.token")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"
wpr(){ podman exec postgres psql -U devops -d woodpecker -tAc "$1" 2>/dev/null || true; }
ghsha(){ curl -sS -m 15 -H "Authorization: Bearer $GHPAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true; }

hr "X0 probes"
[ -f "$YML" ] || halt "canonical .woodpecker.yml missing"
grep -q 'v8.21.2' "$YML" && APPLIED=yes || APPLIED=no
say "pinned version already applied: $APPLIED"
GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
if [ "$MODE" = check ]; then
  say "plan: Python patcher to replace TAG/VER/download with pinned v8.21.2 -> push -> 15-min gate -> sha gate -> docs+ledger"
  say "[RESULT] EX60c CHECK - nothing written."; exit 0
fi

hr "X1 Python patcher (pinned version)"
if [ "$APPLIED" = yes ]; then say "already pinned (no-op)"; else
  cp -p "$YML" "$YML.pre-ex60c.$STAMP.bak"; chmod 600 "$YML.pre-ex60c.$STAMP.bak"
  python3 - "$YML" <<'PY'
import sys, os, tempfile
p = sys.argv[1]
lines = open(p, encoding="utf-8").readlines()
out = []
skip = 0
for i, line in enumerate(lines):
    if skip > 0:
        skip -= 1
        continue
    # Replace TAG line + next 3 lines (VER, guard, curl, guard) with single pinned download
    if "api.github.com/repos/gitleaks/gitleaks/releases/latest" in line or "url_effective" in line:
        indent = "      "
        out.append(indent + "- 'curl -sSL -o /tmp/gl.tar.gz \"https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_linux_x64.tar.gz\"'\n")
        out.append(indent + "- 'tar -tzf /tmp/gl.tar.gz >/dev/null 2>&1 || { echo \"FATAL: gitleaks asset invalid\"; exit 1; }'\n")
        # Skip next 3 lines (VER, guard, curl)
        skip = 3
        continue
    out.append(line)
fd, tt = tempfile.mkstemp(dir=os.path.dirname(p))
os.write(fd, "".join(out).encode())
os.fchmod(fd, 0o644)
os.close(fd)
os.replace(tt, p)
print("  replaced TAG/VER/download with pinned v8.21.2")
PY
  [ $? -eq 0 ] || halt "patcher failed"
fi

hr "X2 push + 15-min success gate"
cd "$A" || halt "cd failed"
git add .woodpecker.yml
if git diff --cached --quiet; then say "nothing to commit (no-op)"; PUSHED=no; else
  git commit -q -m "ci: ex60c pin gitleaks v8.21.2 $STAMP" || halt "commit failed"
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push failed"
  PUSHED=yes; say "pushed heal"
fi
if [ "$PUSHED" = yes ]; then
  OK=no; ST=""; EVT=""
  for i in $(seq 1 300); do
    R="$(wpr "SELECT event||' '||status FROM pipelines WHERE repo_id=2 ORDER BY id DESC LIMIT 1")"
    if [ -n "$R" ]; then read -r EVT ST <<<"$R"
      if [ "$EVT" = push ] && [ "$ST" = success ]; then OK=yes; say "pipeline event=push status=success (iter $i)"; break; fi
      if [ "$EVT" = push ] && { [ "$ST" = failure ] || [ "$ST" = error ] || [ "$ST" = killed ]; }; then say "pipeline event=push status=$ST"; break; fi
    fi
    sleep 3
  done
  if [ "$OK" != yes ]; then
    L="$(wpr "SELECT MAX(id) FROM pipelines WHERE repo_id=2;")"
    wpr "SELECT name||':'||state||' exit='||COALESCE(exit_code::text,'?') FROM steps WHERE pipeline_id=$L ORDER BY id;" | sed 's/^/    /'
    ledger "FAIL" "EX60c event=$EVT status=$ST"; halt "push pipeline not success"
  fi
  GH1="$(ghsha)"; say "github HEAD after: ${GH1:-<none>}"
  [ -n "$GH1" ] && [ "$GH1" != "$GH0" ] || halt "github sha did not advance"
  say "GITHUB SHA-ADVANCE GATE PASS: $GH1"
else
  ST="$(wpr "SELECT status FROM pipelines WHERE repo_id=2 AND event='push' ORDER BY id DESC LIMIT 1")"; GH1="$(ghsha)"
  [ "$ST" = success ] && [ "$GH1" = "$GH0" ] || halt "no-op path inconsistent"
  say "NO-OP GATE PASS"
fi

hr "X3 docs + ledger"
if ! grep -q "CI hardening (EX60c)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat >> "$DOCS/publish-runbook.md" <<'MD'

## CI hardening (EX60c)
- gitleaks pinned to v8.21.2 (stable, no dynamic resolution)
- Each Woodpecker commands line runs in separate shell; variables don't persist across lines
- Pinned versions more reliable for CI than dynamic latest
MD
fi
say "docs updated"
hr "X4 RESULT"
say "[RESULT] EX60c COMPLETE - A CLOSED: push->scan->publish green end-to-end."
ledger "PASS" "EX60c: push pipeline success; github=$GH1"
exit 0
