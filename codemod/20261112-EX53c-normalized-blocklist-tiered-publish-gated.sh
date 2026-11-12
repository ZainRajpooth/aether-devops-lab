#!/usr/bin/env bash
# 20261112-EX53c — normalized blocklist + tiered policy (TRUE/OTHER exclude, LEDGER narrow allowlist) + gated publish.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex53c-normalized-blocklist-tiered-publish-gated-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
GH_USER="ZainRajpooth"; GH_REPO="aether-devops-lab"; GH_EMAIL="z4xebot1@gmail.com"
PT="$SEC/github-pat.token"; BL="$A/infra/publish-blocklist.txt"; AL="$A/infra/publish-allowlist.toml"
TRI="$A/backups/publish-triage"; PS="$A/infra/scripts/aether-publish.sh"
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
  N_BEFORE="$(find "$STG" -type f | wc -l)"
  if [ -f "$BL" ]; then while IFS= read -r rel; do [ -n "$rel" ] && rm -f "$STG/$rel"; done < "$BL"; fi
  N_AFTER="$(find "$STG" -type f | wc -l)"
}
raw_scan(){
  mkdir -p "$TMP/rep"
  podman run --rm -v "$STG:/src:ro" -v "$TMP/rep:/report" "$IMG" \
    detect --no-git --source /src --report-format json --report-path /report/leaks.json >/dev/null 2>&1 || true
  [ -f "$TMP/rep/leaks.json" ] || halt "gitleaks produced no report"
}
hr "X0 raw scan + tiered classification (normalized paths)"
[ -s "$PT" ] || halt "PAT file missing"
PAT="$(tr -d '\n\r' < "$PT")"
stage; raw_scan
python3 - "$TMP/rep/leaks.json" "$A" "$TMP/classes.tsv" "$TMP/blocklist.new" <<'PY'
import json,sys,re,os,collections
rep,A,cls,bl=sys.argv[1:5]
d=json.load(open(rep))
LED=re.compile(r'^[A-Za-z_][A-Za-z0-9_]*="[a-z0-9]+(?:-[a-z0-9]+)*-v[0-9]+"')
rows=[];bad=set();cnt=collections.Counter()
for f in d:
    rel=f["File"].replace("/src/","",1).lstrip("./")
    p=os.path.join(A,rel); line=""
    try: line=open(p,encoding="utf-8",errors="replace").readlines()[f["StartLine"]-1].strip()
    except Exception: pass
    if f["RuleID"]=="private-key" or rel.endswith(".pem") or rel=="infra/zitadel/config.yaml":
        k="TRUE"
    elif LED.match(line):
        k="LEDGER"
    else:
        k="OTHER"
    cnt[k]+=1
    if k in ("TRUE","OTHER"): bad.add(rel)
    rows.append((k,rel,f["StartLine"],f["RuleID"]))
open(cls,"w").write("".join("\t".join(map(str,r))+"\n" for r in sorted(rows)))
open(bl,"w").write("".join(x+"\n" for x in sorted(bad)))
print("  classes:",dict(cnt)," total:",len(d))
print("  exclude files:",len(bad))
for r in sorted(rows):
    if r[0]!="LEDGER": print("   ",r[0],f"{r[1]}:{r[2]}",r[3])
PY
say "staged raw: $N_BEFORE"
if [ "$MODE" = check ]; then
  say "plan: persist sanitized report + normalized blocklist + narrow allowlist -> rebuild (removal proven) ->"
  say "      re-scan with allowlist (0) -> push -> sha gate -> repoint publish script -> docs+ledger"
  say "[RESULT] EX53c CHECK - nothing written."; exit 0
fi

hr "X1 persist report + blocklist + narrow allowlist"
python3 - "$TMP/rep/leaks.json" "$TRI/gitleaks-$STAMP.sanitized.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
json.dump([{k:f.get(k) for k in ("RuleID","File","StartLine","EndLine","Description","Entropy","Tags")} for f in d],open(sys.argv[2],"w"),indent=1)
PY
chmod 600 "$TRI/gitleaks-$STAMP.sanitized.json"
for pair in "$TMP/blocklist.new:$BL" ; do
  src="${pair%%:*}"; dst="${pair##*:}"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then say "blocklist unchanged (no-op)"; else
    [ -f "$dst" ] && { cp -p "$dst" "$dst.pre-ex53c.$STAMP.bak"; chmod 600 "$dst.pre-ex53c.$STAMP.bak"; }
    install -m 600 "$src" "$dst"; say "blocklist written: $(wc -l < "$dst") files (normalized)"
  fi
done
cat > "$TMP/allow.toml" <<'TOML'
title = "aether publish-only gitleaks config (EX53c)"
[extend]
useDefault = true
[[allowlists]]
description = "aether ledger change-ids: lowercase slug -vN assigned to a shell variable (non-secret)"
regexTarget = "line"
regexes = ['''^[A-Za-z_][A-Za-z0-9_]*="[a-z0-9]+(?:-[a-z0-9]+)*-v[0-9]+"''']
TOML
if [ -f "$AL" ] && cmp -s "$TMP/allow.toml" "$AL"; then say "allowlist unchanged (no-op)"; else
  [ -f "$AL" ] && { cp -p "$AL" "$AL.pre-ex53c.$STAMP.bak"; chmod 600 "$AL.pre-ex53c.$STAMP.bak"; }
  install -m 600 "$TMP/allow.toml" "$AL"; say "allowlist written: $AL"
fi

hr "X2 rebuild + removal proof + clean re-scan"
stage
say "staged: $N_BEFORE -> $N_AFTER (blocklist $(wc -l < "$BL") files)"
if [ "$(wc -l < "$BL")" -gt 0 ] && [ "$N_AFTER" -ge "$N_BEFORE" ]; then
  halt "removal no-op regression: blocklist paths not applying"
fi
[ "$N_AFTER" -gt 0 ] || halt "publish set empty"
if podman run --rm -v "$STG:/src:ro" -v "$AL:/cfg/allow.toml:ro" "$IMG" \
     detect --config /cfg/allow.toml --no-git --source /src --redact > "$TMP/rescan.txt" 2>&1; then
  say "RE-SCAN GATE PASS: 0 findings (tiered policy)"
else
  tail -15 "$TMP/rescan.txt" | red | sed 's/^/    /'
  ledger "FAIL" "EX53c re-scan leaking"
  halt "re-scan failed; nothing published"
fi

hr "X3 publish + sha gate"
C="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $PAT" "https://api.github.com/repos/$GH_USER/$GH_REPO" || echo 000)"
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
  git commit -q -m "publish: curated aether sync (tiered triage) $STAMP" || halt "commit failed"
  git push -q origin HEAD:main 2>&1 | red || halt "push failed"
  SHA="$(git rev-parse HEAD)"; say "pushed $SHA"
fi
cd / || true
sleep 2
G="$(curl -sS -m 15 -H "Authorization: Bearer $PAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true)"
[ -n "$G" ] && [ "$G" = "$SHA" ] || halt "GitHub HEAD != local sha"
say "GITHUB GATE PASS: https://github.com/$GH_USER/$GH_REPO/commit/$SHA"

hr "X4 repoint publish script + docs + debt + ledger"
if [ -f "$PS" ] && ! grep -q "EX53c-normalized-blocklist-tiered-publish-gated.sh" "$PS"; then
  cp -p "$PS" "$PS.pre-ex53c.$STAMP.bak"; chmod 600 "$PS.pre-ex53c.$STAMP.bak"
  sed -i -E 's|20261112-EX53b?-[^"]*\.sh|20261112-EX53c-normalized-blocklist-tiered-publish-gated.sh|' "$PS"
  say "aether-publish.sh repointed to EX53c (backup taken)"
else say "publish script current (no-op)"; fi
{
  echo "# Publish exclusions (EX53c, $STAMP)"
  echo "| file | classes | rules |"
  python3 - "$TMP/classes.tsv" <<'PY'
import sys,collections
m=collections.defaultdict(lambda:[set(),set()])
for l in open(sys.argv[1]):
    p=l.rstrip("\n").split("\t")
    if len(p)>=4 and p[0]!="LEDGER":
        m[p[1]][0].add(p[0]); m[p[1]][1].add(p[3])
for f in sorted(m): print(f"| {f} | {','.join(sorted(m[f][0]))} | {','.join(sorted(m[f][1]))} |")
PY
} > "$DOCS/publish-exclusions.md"; chmod 600 "$DOCS/publish-exclusions.md"
if ! grep -q "Tiered triage (EX53c)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat >> "$DOCS/publish-runbook.md" <<'MD'

## Tiered triage (EX53c)
- Paths normalized (mount prefix stripped) so blocklist removals actually apply; removal proven by staged-count delta
- TRUE (private keys, zitadel config) and OTHER (unclassified) => file excluded
- LEDGER (slug -vN shell assignment) => narrow line-anchored allowlist infra/publish-allowlist.toml (publish-only)
- Re-scan uses --config; must be 0 findings before push
MD
fi
if ! grep -q "| 10 |" "$DOCS/debt-register.md" 2>/dev/null; then
cat >> "$DOCS/debt-register.md" <<'MD'
| 10 | TLS private keys under infra/traefik/tls/ | high | relocate to secrets/ + generate at deploy; excluded from publish |
| 11 | infra/zitadel/config.yaml holds live secrets | high | env-refactor; excluded from publish |
MD
fi
say "docs: exclusions + runbook + debt updated"
hr "X5 RESULT"
say "[RESULT] EX53c COMPLETE - normalized exclusions, tiered allowlist, clean re-scan, gated publish."
ledger "PASS" "EX53c: staged $N_BEFORE->$N_AFTER; re-scan 0; github sha=$SHA"
exit 0
