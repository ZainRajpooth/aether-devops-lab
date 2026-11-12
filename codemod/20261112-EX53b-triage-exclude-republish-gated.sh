#!/usr/bin/env bash
# 20261112-EX53b — triage gitleaks findings (sanitized), exclude offending files, re-scan clean, publish gated.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex53b-triage-exclude-republish-gated-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
GH_USER="ZainRajpooth"; GH_REPO="aether-devops-lab"; GH_EMAIL="z4xebot1@gmail.com"
PT="$SEC/github-pat.token"; BL="$A/infra/publish-blocklist.txt"; TRI="$A/backups/publish-triage"
PS="$A/infra/scripts/aether-publish.sh"
IMG="docker.io/zricethezav/gitleaks:latest"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS" "$TRI" "$A/infra/scripts"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
red(){ python3 -c 'import sys;p=sys.argv[1]
for l in sys.stdin: sys.stdout.write(l.replace(p,"***") if p else l)' "${PAT:-}"; }
stage(){
  STG="$TMP/stage"; rm -rf "$STG"; mkdir -p "$STG"
  for d in docs infra codemod; do [ -d "$A/$d" ] && cp -a "$A/$d" "$STG/"; done
  for f in README.md .woodpecker.yml; do [ -f "$A/$f" ] && cp -a "$A/$f" "$STG/"; done
  find "$STG" -type d -name .git -prune -exec rm -rf {} + 2>/dev/null || true
  find "$STG" -type f \( -name '*.env' -o -name '*.pass' -o -name '*.token' -o -name '*.bak' -o -name '*.pre-*' \) -delete
  find "$STG" -type d \( -name secrets -o -name data -o -name backups \) -prune -exec rm -rf {} + 2>/dev/null || true
  [ -f "$BL" ] && while IFS= read -r rel; do [ -n "$rel" ] && rm -f "$STG/$rel"; done < "$BL"
}
scan_json(){
  mkdir -p "$TMP/rep"
  podman run --rm -v "$STG:/src:ro" -v "$TMP/rep:/report" "$IMG" \
    detect --no-git --source /src --report-format json --report-path /report/leaks.json >/dev/null 2>&1 || true
  [ -f "$TMP/rep/leaks.json" ] || halt "gitleaks produced no report (image/scan error)"
}
hr "X0 staging + sanitized triage"
[ -s "$PT" ] || halt "PAT file missing; run EX53 intake first"
PAT="$(tr -d '\n\r' < "$PT")"
stage
scan_json
python3 - "$TMP/rep/leaks.json" "$TMP/triage.tsv" "$TMP/blocklist.txt" <<'PY'
import json,sys,collections
src,dst,bl=sys.argv[1:4]
d=json.load(open(src))
rows=[]
for f in d:
    rows.append((f.get("RuleID",""), f.get("File",""), f.get("StartLine",0), f.get("Description","")))
with open(dst,"w") as t:
    for r in sorted(rows): t.write("\t".join(map(str,r))+"\n")
files=sorted({r[1] for r in rows})
with open(bl,"w") as b:
    for f in files: b.write(f+"\n")
c=collections.Counter(r[0] for r in rows)
print("  findings:",len(rows)," files:",len(files))
for k,v in c.most_common(): print(f"    rule {k}: {v}")
PY
say "triage (rule / file:line, secrets stripped):"
head -40 "$TMP/triage.tsv" | sed 's/^/    /'
say "proposed exclusions: $(wc -l < "$TMP/blocklist.txt") files"
if [ "$MODE" = check ]; then
  say "plan: persist sanitized report + blocklist -> rebuild staging minus blocklist -> re-scan(0) -> push -> sha gate -> docs+ledger"
  say "[RESULT] EX53b CHECK - nothing written."; exit 0
fi

hr "X1 persist sanitized report + blocklist"
python3 - "$TMP/rep/leaks.json" "$TRI/gitleaks-$STAMP.sanitized.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
keep=[{k:f.get(k) for k in ("RuleID","File","StartLine","EndLine","Description","Entropy","Tags")} for f in d]
json.dump(keep,open(sys.argv[2],"w"),indent=1)
PY
chmod 600 "$TRI/gitleaks-$STAMP.sanitized.json"
if [ -f "$BL" ] && cmp -s "$BL" "$TMP/blocklist.txt"; then say "blocklist unchanged (no-op)"; else
  [ -f "$BL" ] && { cp -p "$BL" "$BL.pre-ex53b.$STAMP.bak"; chmod 600 "$BL.pre-ex53b.$STAMP.bak"; }
  install -m 600 "$TMP/blocklist.txt" "$BL"; say "blocklist written: $(wc -l < "$BL") files"
fi

hr "X2 rebuild + clean re-scan gate"
stage
say "staged after exclusions: $(find "$STG" -type f | wc -l)"
[ "$(find "$STG" -type f | wc -l)" -gt 0 ] || halt "exclusions emptied the publish set"
if podman run --rm -v "$STG:/src:ro" "$IMG" detect --no-git --source /src --redact > "$TMP/rescan.txt" 2>&1; then
  say "RE-SCAN GATE PASS: 0 findings"
else
  tail -15 "$TMP/rescan.txt" | red | sed 's/^/    /'
  ledger "FAIL" "EX53b re-scan still leaking"
  halt "re-scan failed; nothing published"
fi

hr "X3 publish + sha gate"
C="$(curl -sS -m 15 -o "$TMP/repo.json" -w '%{http_code}' -H "Authorization: Bearer $PAT" "https://api.github.com/repos/$GH_USER/$GH_REPO" || echo 000)"
[ "$C" = 200 ] || halt "repo gate http=$C"
W="$TMP/work"
git clone -q "https://$GH_USER:$PAT@github.com/$GH_USER/$GH_REPO.git" "$W" 2>&1 | red || halt "clone failed"
( cd "$STG" && tar cf - . ) | ( cd "$W" && tar xf - )
cd "$W" || halt "cd failed"
git config user.name "$GH_USER"; git config user.email "$GH_EMAIL"
git add -A
if git diff --cached --quiet; then
  say "no changes vs public HEAD (idempotent no-op)"; SHA="$(git rev-parse HEAD 2>/dev/null || echo none)"
else
  git commit -q -m "publish: curated aether sync (triaged) $STAMP" || halt "commit failed"
  git push -q origin HEAD:main 2>&1 | red || halt "push failed"
  SHA="$(git rev-parse HEAD)"; say "pushed $SHA"
fi
cd / || true
sleep 2
G="$(curl -sS -m 15 -H "Authorization: Bearer $PAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true)"
[ -n "$G" ] && [ "$G" = "$SHA" ] || halt "GitHub HEAD != local sha"
say "GITHUB GATE PASS: https://github.com/$GH_USER/$GH_REPO/commit/$SHA"

hr "X4 repoint publish script + docs + ledger"
if [ -f "$PS" ] && grep -q "EX53-lane3-curated-publish-steel-thread.sh" "$PS"; then
  cp -p "$PS" "$PS.pre-ex53b.$STAMP.bak"; chmod 600 "$PS.pre-ex53b.$STAMP.bak"
  sed -i 's|20261112-EX53-lane3-curated-publish-steel-thread.sh|20261112-EX53b-triage-exclude-republish-gated.sh|' "$PS"
  say "aether-publish.sh repointed to EX53b (backup taken)"
else
  say "publish script already repointed or absent (no-op)"
fi
{
  echo "# Publish exclusions (EX53b, $STAMP) — files dropped from public set (gitleaks findings)"
  echo "| file | rules |"
  python3 - "$TMP/triage.tsv" <<'PY'
import sys,collections
m=collections.defaultdict(set)
for l in open(sys.argv[1]):
    p=l.rstrip("\n").split("\t")
    if len(p)>=2: m[p[1]].add(p[0])
for f in sorted(m): print(f"| {f} | {', '.join(sorted(m[f]))} |")
PY
} > "$DOCS/publish-exclusions.md"
chmod 600 "$DOCS/publish-exclusions.md"
if ! grep -q "Triage + exclusions (EX53b)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat >> "$DOCS/publish-runbook.md" <<'MD'

## Triage + exclusions (EX53b)
- Sanitized reports: backups/publish-triage/gitleaks-*.sanitized.json (no Secret/Match fields)
- Blocklist: infra/publish-blocklist.txt (file-level exclusion; gate strength unchanged)
- Re-scan must be 0 findings before push; exclusions listed in docs/publish-exclusions.md
- To re-include a file: sanitize it locally, remove its line from the blocklist, re-run aether-publish.sh
MD
fi
say "docs: publish-exclusions.md + runbook amendment"
hr "X5 RESULT"
say "[RESULT] EX53b COMPLETE - triaged exclusions, clean re-scan, gated public publish."
ledger "PASS" "EX53b: exclusions=$(wc -l < "$BL"); re-scan 0; github sha=$SHA"
exit 0
