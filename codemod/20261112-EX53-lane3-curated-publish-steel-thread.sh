#!/usr/bin/env bash
# 20261112-EX53 — Lane 3 steel thread: curated allowlist -> gitleaks gate -> GitHub public push -> API gate.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex53-lane3-curated-publish-steel-thread-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
GH_USER="ZainRajpooth"; GH_REPO="aether-devops-lab"; GH_EMAIL="z4xebot1@gmail.com"
PT="$SEC/github-pat.token"
PS="$A/infra/scripts/aether-publish.sh"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS" "$A/infra/scripts"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
red(){ python3 -c 'import sys;p=sys.argv[1]
for l in sys.stdin: sys.stdout.write(l.replace(p,"***") if p else l)' "${PAT:-}"; }

hr "X0 probes"
[ -d "$A/docs" ] || [ -d "$A/infra" ] || [ -d "$A/codemod" ] || halt "no allowlist dirs present"
say "allowlist inventory: docs=$(find "$A/docs" -type f 2>/dev/null | wc -l) infra=$(find "$A/infra" -type f 2>/dev/null | wc -l) codemod=$(find "$A/codemod" -type f 2>/dev/null | wc -l)"
[ -s "$PT" ] && say "PAT file: present" || say "PAT file: absent (will prompt hidden)"
podman image exists docker.io/zricethezav/gitleaks:latest && say "gitleaks image: cached" || say "gitleaks image: will pull"
if [ "$MODE" = check ]; then
  say "plan: PAT intake(0600) -> GitHub repo/scope gate -> curated staging+exclusions -> gitleaks gate ->"
  say "      clone public repo -> sync -> commit -> push -> GitHub commit-sha gate -> runbook+ledger"
  say "[RESULT] EX53 CHECK - nothing written."; exit 0
fi

hr "X1 PAT intake + GitHub gates"
if [ ! -s "$PT" ]; then
  [ -e /dev/tty ] || halt "no tty for hidden PAT intake"
  printf '  Paste fine-grained GitHub PAT (hidden): ' > /dev/tty
  IFS= read -rs PAT < /dev/tty; printf '\n' > /dev/tty
  [ -n "$PAT" ] || halt "empty PAT"
  printf '%s' "$PAT" > "$PT"; chmod 600 "$PT"; say "PAT stored 0600"
else
  PAT="$(tr -d '\n\r' < "$PT")"; say "reusing PAT file"
fi
C="$(curl -sS -m 15 -o "$TMP/repo.json" -w '%{http_code}' -H "Authorization: Bearer $PAT" "https://api.github.com/repos/$GH_USER/$GH_REPO" || echo 000)"
[ "$C" = 200 ] || halt "GitHub repo gate http=$C (repo missing or PAT scope wrong)"
VIS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("visibility",""))' "$TMP/repo.json")"
say "repo visibility: $VIS"
[ "$VIS" = public ] || halt "repo is not public; refusing to publish"

hr "X2 curated staging + hard exclusions"
STG="$TMP/stage"; mkdir -p "$STG"
for d in docs infra codemod; do [ -d "$A/$d" ] && cp -a "$A/$d" "$STG/"; done
for f in README.md .woodpecker.yml; do [ -f "$A/$f" ] && cp -a "$A/$f" "$STG/"; done
find "$STG" -type d -name .git -prune -exec rm -rf {} + 2>/dev/null || true
find "$STG" -type f \( -name '*.env' -o -name '*.pass' -o -name '*.token' -o -name '*.bak' -o -name '*.pre-*' \) -delete
find "$STG" -type d \( -name secrets -o -name data -o -name backups \) -prune -exec rm -rf {} + 2>/dev/null || true
if [ ! -f "$STG/LICENSE" ]; then
cat > "$STG/LICENSE" <<'LIC'
MIT License

Copyright (c) 2026 ZainRajpooth

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LIC
fi
if [ ! -f "$STG/README.md" ]; then
cat > "$STG/README.md" <<'RD'
# aether-devops-lab

Single-node, zero-budget DevOps platform lab (Kubuntu, rootless Podman, systemd user units).

## Stack
- Forge: Gitea (private) · CI: Woodpecker · Object store: MinIO · DB: PostgreSQL
- Backups: restic -> MinIO (encrypted, append-only, weekly bounded prune, restore-gated)
- Publish lane: curated allowlist -> gitleaks gate -> this public repo

## Layout
- `docs/` runbooks + ADRs · `infra/` scripts/units · `codemod/` gated patch programs

Secrets, data and backups never leave the private forge; every public commit passes a secret scan.
RD
fi
say "staged files: $(find "$STG" -type f | wc -l)"

hr "X3 gitleaks gate (redacted output)"
if podman run --rm -v "$STG:/src:ro" docker.io/zricethezav/gitleaks:latest \
     detect --no-git --source /src --redact > "$TMP/leaks.txt" 2>&1; then
  say "GITLEAKS GATE PASS: no secrets in curated set"
else
  tail -20 "$TMP/leaks.txt" | red | sed 's/^/    /'
  ledger "FAIL" "EX53 gitleaks detected leaks; publish refused"
  halt "gitleaks gate failed; nothing published"
fi

hr "X4 publish to GitHub (append history)"
W="$TMP/work"
git clone -q "https://$GH_USER:$PAT@github.com/$GH_USER/$GH_REPO.git" "$W" 2>&1 | red || halt "clone public repo failed"
( cd "$STG" && tar cf - . ) | ( cd "$W" && tar xf - )
cd "$W" || halt "cd work failed"
git config user.name "$GH_USER"; git config user.email "$GH_EMAIL"
git add -A
if git diff --cached --quiet; then
  say "no changes vs public HEAD (idempotent no-op)"
  SHA="$(git rev-parse HEAD 2>/dev/null || echo none)"
else
  git commit -q -m "publish: curated aether sync $STAMP" || halt "commit failed"
  git push -q origin HEAD:main 2>&1 | red || halt "push failed"
  SHA="$(git rev-parse HEAD)"
  say "pushed commit $SHA"
fi
cd / || true

hr "X5 GitHub commit-sha gate (telemetry)"
sleep 2
G="$(curl -sS -m 15 -H "Authorization: Bearer $PAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true)"
say "github HEAD: ${G:-<none>} ; local HEAD: ${SHA:-<none>}"
[ -n "$G" ] && [ "$G" = "$SHA" ] || halt "GitHub HEAD != pushed sha"
say "GITHUB GATE PASS: https://github.com/$GH_USER/$GH_REPO/commit/$SHA"

hr "X6 publish script + runbook + ledger"
if [ ! -f "$PS" ]; then
cat > "$PS" <<'PUB'
#!/usr/bin/env bash
# re-runnable curated publish (EX53); PAT read from secrets/github-pat.token
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261112-EX53-lane3-curated-publish-steel-thread.sh" run
PUB
chmod 700 "$PS"; say "written: $PS"
else say "publish script exists (no-op)"; fi
if ! grep -q "Publish lane (EX53)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat > "$DOCS/publish-runbook.md" <<'MD'
# Publish lane (EX53)
- Remote: github.com/ZainRajpooth/aether-devops-lab (public, curated only)
- Allowlist: docs/ infra/ codemod/ README.md .woodpecker.yml + MIT LICENSE
- Exclusions: secrets/ data/ backups/ *.env *.pass *.token *.bak *.pre-* nested .git
- Gate order: GitHub repo/scope -> gitleaks (podman image, --redact) -> push -> commit-sha API gate
- Re-run: infra/scripts/aether-publish.sh (idempotent; no-change => no-op)
- PAT: secrets/github-pat.token (0600, fine-grained, Contents:RW single repo, 90d expiry; rotate via GitHub UI then re-paste)
- Leak response: halt publish, rotate exposed credential, purge public history (GitHub support / filter-repo), re-scan
MD
say "written: $DOCS/publish-runbook.md"
else say "runbook exists (no-op)"; fi
hr "X7 RESULT"
say "[RESULT] EX53 COMPLETE - LANE 3 steel thread: curated publish gated by gitleaks + GitHub sha."
ledger "PASS" "EX53: curated publish steel thread; gitleaks PASS; github sha=$SHA"
exit 0
