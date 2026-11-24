#!/usr/bin/env bash
# 20261112-EX60e — exhaustive blocklist (exclude ALL gitleaks findings, bypass allowlist reliance).
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex60e-exhaustive-blocklist-ci-gate-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
BL="$A/infra/publish-blocklist.txt"
GH_USER="ZainRajpooth"; GH_REPO="aether-devops-lab"
IMG="docker.io/zricethezav/gitleaks:latest"
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

hr "X0 stage raw + scan ALL findings"
STG="$TMP/stage"; mkdir -p "$STG"
for d in docs infra codemod; do [ -d "$A/$d" ] && cp -a "$A/$d" "$STG/"; done
for f in README.md .woodpecker.yml; do [ -f "$A/$f" ] && cp -a "$A/$f" "$STG/"; done
find "$STG" -type d -name .git -prune -exec rm -rf {} + 2>/dev/null || true
find "$STG" -type f \( -name '*.env' -o -name '*.pass' -o -name '*.token' -o -name '*.bak' -o -name '*.pre-*' \) -delete
find "$STG" -type d \( -name secrets -o -name data -o -name backups \) -prune -exec rm -rf {} + 2>/dev/null || true
N_RAW="$(find "$STG" -type f | wc -l)"
say "staged raw: $N_RAW files"

mkdir -p "$TMP/rep"
podman run --rm -v "$STG:/src:ro" -v "$TMP/rep:/report" "$IMG" \
  detect --no-git --source /src --report-format json --report-path /report/leaks.json >/dev/null 2>&1 || true
[ -f "$TMP/rep/leaks.json" ] || halt "gitleaks produced no report"

python3 - "$TMP/rep/leaks.json" "$A" "$TMP/exclude.new" <<'PY'
import json, sys, os
rep, A, ex = sys.argv[1:4]
d = json.load(open(rep))
bad = set()
for f in d:
    rel = f["File"].replace("/src/", "", 1).lstrip("./")
    # EXHAUSTIVE: exclude ALL files with ANY finding (LEDGER, TRUE, OTHER)
    bad.add(rel)
open(ex, "w").write("".join(x+"\n" for x in sorted(bad)))
print("  findings:", len(d), " exclude files:", len(bad))
PY

: > "$TMP/bl.old"; [ -f "$BL" ] && cp "$BL" "$TMP/bl.old"
sort -u "$TMP/bl.old" "$TMP/exclude.new" | sed '/^$/d' > "$TMP/bl.union"
say "union blocklist: $(wc -l < "$TMP/bl.union") files (was $(wc -l < "$TMP/bl.old"))"

GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
if [ "$MODE" = check ]; then
  say "plan: write exhaustive union blocklist -> push -> 15-min gate -> sha gate -> docs+ledger"
  say "[RESULT] EX60e CHECK - nothing written."; exit 0
fi

hr "X1 write exhaustive blocklist"
if [ -f "$BL" ] && cmp -s "$TMP/bl.union" "$BL"; then say "blocklist unchanged (no-op)"; else
  [ -f "$BL" ] && cp -p "$BL" "$BL.pre-ex60e.$STAMP.bak"
  install -m 600 "$TMP/bl.union" "$BL"; say "blocklist written: $(wc -l < "$BL") files"
fi

hr "X2 push + 15-min success gate"
cd "$A" || halt "cd failed"
git add "$BL"
if git diff --cached --quiet; then say "nothing to commit (no-op)"; PUSHED=no; else
  git commit -q -m "ci: ex60e exhaustive blocklist (bypass allowlist) $STAMP" || halt "commit failed"
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push failed"
  PUSHED=yes; say "pushed exhaustive blocklist"
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
    ledger "FAIL" "EX60e event=$EVT status=$ST"; halt "push pipeline not success"
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
if ! grep -q "Exhaustive blocklist (EX60e)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat >> "$DOCS/publish-runbook.md" <<'MD'

## Exhaustive blocklist (EX60e)
- Blocklist now excludes ALL files with ANY gitleaks finding (LEDGER, TRUE, OTHER)
- Bypasses reliance on the allowlist regex in the CI environment
- Guarantees 0 files with findings reach the `gitleaks` scan in CI
MD
fi
say "docs updated"
hr "X4 RESULT"
say "[RESULT] EX60e COMPLETE - A CLOSED: exhaustive blocklist, push->scan->publish green end-to-end."
ledger "PASS" "EX60e: blocklist=$(wc -l < "$BL"); push pipeline success; github=$GH1"
exit 0
