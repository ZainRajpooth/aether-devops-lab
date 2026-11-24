#!/usr/bin/env bash
# 20261112-EX60d — regenerate blocklist with current file set (includes EX55-EX60c), push, gate.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex60d-regenerate-blocklist-ci-gate-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
BL="$A/infra/publish-blocklist.txt"; AL="$A/infra/publish-allowlist.toml"
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

hr "X0 stage raw + scan"
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

python3 - "$TMP/rep/leaks.json" "$A" "$TMP/classes.tsv" "$TMP/exclude.new" <<'PY'
import json, sys, re, os, collections
rep, A, cls, ex = sys.argv[1:5]
d = json.load(open(rep))
LED = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*="[a-z0-9]+(?:-[a-z0-9]+)*-v[0-9]+"')
rows = []; bad = set(); cnt = collections.Counter()
for f in d:
    rel = f["File"].replace("/src/", "", 1).lstrip("./")
    p = os.path.join(A, rel); line = ""
    try: line = open(p, encoding="utf-8", errors="replace").readlines()[f["StartLine"]-1].strip()
    except Exception: pass
    k = "TRUE" if (f["RuleID"]=="private-key" or rel.endswith(".pem") or rel=="infra/zitadel/config.yaml") else ("LEDGER" if LED.match(line) else "OTHER")
    cnt[k] += 1
    if k in ("TRUE", "OTHER"): bad.add(rel)
    rows.append((k, rel, f["StartLine"], f["RuleID"]))
open(cls, "w").write("".join("\t".join(map(str, r))+"\n" for r in sorted(rows)))
open(ex, "w").write("".join(x+"\n" for x in sorted(bad)))
print("  findings:", len(d), " classes:", dict(cnt), " exclude files:", len(bad))
PY

: > "$TMP/bl.old"; [ -f "$BL" ] && cp "$BL" "$TMP/bl.old"
sort -u "$TMP/bl.old" "$TMP/exclude.new" | sed '/^$/d' > "$TMP/bl.union"
say "union blocklist: $(wc -l < "$TMP/bl.union") files (was $(wc -l < "$TMP/bl.old"))"

GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
if [ "$MODE" = check ]; then
  say "plan: write union blocklist -> push -> 15-min gate -> sha gate -> docs+ledger"
  say "[RESULT] EX60d CHECK - nothing written."; exit 0
fi

hr "X1 write union blocklist"
if [ -f "$BL" ] && cmp -s "$TMP/bl.union" "$BL"; then say "blocklist unchanged (no-op)"; else
  [ -f "$BL" ] && cp -p "$BL" "$BL.pre-ex60d.$STAMP.bak"
  install -m 600 "$TMP/bl.union" "$BL"; say "blocklist written: $(wc -l < "$BL") files"
fi

hr "X2 push + 15-min success gate"
cd "$A" || halt "cd failed"
git add "$BL"
if git diff --cached --quiet; then say "nothing to commit (no-op)"; PUSHED=no; else
  git commit -q -m "ci: ex60d regenerate blocklist (EX55-EX60c files) $STAMP" || halt "commit failed"
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push failed"
  PUSHED=yes; say "pushed blocklist update"
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
    ledger "FAIL" "EX60d event=$EVT status=$ST"; halt "push pipeline not success"
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
if ! grep -q "Blocklist regeneration (EX60d)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat >> "$DOCS/publish-runbook.md" <<'MD'

## Blocklist regeneration (EX60d)
- Run EX60d after adding new codemod files to exclude them from public publish
- Blocklist is union(existing, new TRUE/OTHER files); never replace
- Each new brick may add files that trigger gitleaks; regenerate before closing the brick
MD
fi
say "docs updated"
hr "X4 RESULT"
say "[RESULT] EX60d COMPLETE - A CLOSED: blocklist regenerated, push->scan->publish green end-to-end."
ledger "PASS" "EX60d: blocklist=$(wc -l < "$BL"); push pipeline success; github=$GH1"
exit 0
