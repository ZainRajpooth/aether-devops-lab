#!/usr/bin/env bash
# 20261112-EX55 — A: private Gitea aether repo + Woodpecker activation + CI curate->scan->publish steel thread.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex55-ci-triggered-publish-steel-thread-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
GT="http://127.0.0.1:3001"; WP="http://127.0.0.1:8000"
GH_USER="ZainRajpooth"; GH_REPO="aether-devops-lab"; GH_EMAIL="z4xebot1@gmail.com"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"
AENC="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$APASS")"
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"; GHPAT="$(tr -d '\n\r' < "$SEC/github-pat.token")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"
ghsha(){ curl -sS -m 15 -H "Authorization: Bearer $GHPAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true; }
wp_repo_id(){ curl -sS -m 15 -H "Authorization: Bearer $PAT" "$WP/api/repos/lookup/$AUSER/aether" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")' 2>/dev/null || true; }

hr "X0 probes"
[ -d "$A/.git" ] && say "local git: present" || say "local git: absent (will init)"
GR="$(curl -sS -m 15 -o "$TMP/gr.json" -w '%{http_code}' -u "$AUSER:$APASS" "$GT/api/v1/repos/$AUSER/aether" || echo 000)"
say "gitea aether repo http=$GR"
WID="$(wp_repo_id)"; say "woodpecker repo id: ${WID:-<none>}"
GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
if [ "$MODE" = check ]; then
  say "plan: .gitignore+.woodpecker.yml -> gitea private repo -> push -> activate -> secrets -> push trigger ->"
  say "      pipeline success gate -> github sha-advance gate -> docs+ledger"
  say "[RESULT] EX55 CHECK - nothing written."; exit 0
fi

hr "X1 local git hygiene + pipeline definition"
cd "$A" || halt "cd aether failed"
if [ ! -d .git ]; then git init -q -b main; say "git init -b main"; fi
cat > "$TMP/gitignore" <<'GI'
secrets/
data/
backups/
.publish/
*.env
*.pass
*.token
*.bak
*.pre-*
infra/traefik/tls/*-key.pem
infra/zitadel/config.yaml
__pycache__/
.venv/
node_modules/
GI
if [ -f .gitignore ] && cmp -s "$TMP/gitignore" .gitignore; then say ".gitignore unchanged (no-op)"; else
  [ -f .gitignore ] && cp -p .gitignore ".gitignore.pre-ex55.$STAMP.bak"
  install -m 600 "$TMP/gitignore" .gitignore; say ".gitignore written"
fi
cat > "$TMP/wp.yml" <<'YML'
clone:
  - name: git
    image: woodpeckerci/plugin-git
    environment:
      PLUGIN_REMOTE:
        from_secret: GITEA_CLONE_URL
steps:
  - name: curate-scan
    image: docker.io/alpine:latest
    commands:
      - apk add --no-cache curl tar >/dev/null
      - mkdir -p .publish
      - for d in docs infra codemod; do [ -d "$d" ] && cp -a "$d" .publish/; done
      - for f in README.md .woodpecker.yml; do [ -f "$f" ] && cp -a "$f" .publish/; done
      - find .publish -type f \( -name '*.env' -o -name '*.pass' -o -name '*.token' -o -name '*.bak' -o -name '*.pre-*' \) -delete
      - while IFS= read -r rel; do [ -n "$rel" ] && rm -f ".publish/$rel"; done < infra/publish-blocklist.txt
      - TAG=$(curl -sS https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
      - VER=${TAG#v}
      - curl -sSL -o /tmp/gl.tar.gz "https://github.com/gitleaks/gitleaks/releases/download/$TAG/gitleaks_${VER}_linux_x64.tar.gz"
      - tar -xzf /tmp/gl.tar.gz -C /usr/local/bin gitleaks
      - gitleaks detect --config infra/publish-allowlist.toml --no-git --source .publish --redact
  - name: publish
    image: docker.io/alpine/git
    environment:
      GITHUB_TOKEN:
        from_secret: GITHUB_TOKEN
    commands:
      - git clone -q "https://ZainRajpooth:$GITHUB_TOKEN@github.com/ZainRajpooth/aether-devops-lab.git" /tmp/pub
      - find /tmp/pub -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
      - cp -a .publish/. /tmp/pub/
      - cd /tmp/pub
      - git config user.name ZainRajpooth
      - git config user.email z4xebot1@gmail.com
      - git add -A
      - git diff --cached --quiet || git commit -q -m "publish: CI curated sync $CI_COMMIT_SHA"
      - git push -q origin HEAD:main
    when:
      - event: push
YML
if [ -f .woodpecker.yml ] && cmp -s "$TMP/wp.yml" .woodpecker.yml; then say ".woodpecker.yml unchanged (no-op)"; else
  [ -f .woodpecker.yml ] && cp -p .woodpecker.yml ".woodpecker.yml.pre-ex55.$STAMP.bak"
  install -m 600 "$TMP/wp.yml" .woodpecker.yml; say ".woodpecker.yml written"
fi
git add -A
if git diff --cached --quiet; then say "nothing to commit (no-op)"; PUSHED=no; else
  git commit -q -m "ci: ex55 publish pipeline + git hygiene $STAMP" || halt "commit failed"
  PUSHED=yes
fi

hr "X2 private Gitea repo + push"
if [ "$GR" != 200 ]; then
  C="$(curl -sS -m 20 -o "$TMP/mk.json" -w '%{http_code}' -X POST -u "$AUSER:$APASS" -H 'Content-Type: application/json' \
    -d '{"name":"aether","private":true,"auto_init":false,"default_branch":"main"}' "$GT/api/v1/user/repos" || echo 000)"
  say "create gitea repo -> $C"; [ "$C" = 201 ] || halt "gitea repo create failed"
fi
if [ "$PUSHED" = yes ]; then
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push to gitea failed"
  say "pushed to gitea"
fi
GID="$(curl -sS -m 15 -u "$AUSER:$APASS" "$GT/api/v1/repos/$AUSER/aether" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
say "gitea repo id: $GID"

hr "X3 Woodpecker activation + secrets"
WID="$(wp_repo_id)"
if [ -z "$WID" ]; then
  C="$(curl -sS -m 20 -o "$TMP/act.json" -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/$GID" || echo 000)"
  say "activate -> $C"; [ "$C" = 200 ] || halt "activation failed"
  WID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$TMP/act.json")"
fi
say "woodpecker repo id: $WID"
CLONE_URL="http://$AUSER:$AENC@gitea:3000/$AUSER/aether.git"
for pair in "GITEA_CLONE_URL:$CLONE_URL" "GITHUB_TOKEN:$GHPAT"; do
  n="${pair%%:*}"; v="${pair#*:}"
  curl -sS -m 15 -o /dev/null -X DELETE -H "Authorization: Bearer $PAT" "$WP/api/repos/$WID/secrets/$n" || true
  C="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$n\",\"value\":\"$v\",\"events\":[\"push\"]}" "$WP/api/repos/$WID/secrets" || echo 000)"
  say "secret $n -> $C"; [ "$C" = 200 ] || [ "$C" = 201 ] || halt "secret $n failed"
done

hr "X4 trigger + pipeline gate + github sha gate"
if [ "$PUSHED" = yes ]; then
  OK=no; ST=""
  for i in $(seq 1 90); do
    R="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT number||' '||status FROM pipelines WHERE repo_id=$WID ORDER BY id DESC LIMIT 1" 2>/dev/null || true)"
    if [ -n "$R" ]; then read -r N ST <<<"$R"; say "pipeline #$N status=$ST"
      [ "$ST" = success ] && { OK=yes; break; }
      case "$ST" in failure|error|killed) break;; esac
    fi
    sleep 3
  done
  [ "$OK" = yes ] || { podman logs --tail 25 woodpecker-agent 2>&1 | tail -12 | sed 's/^/    /'; ledger "FAIL" "EX55 pipeline status=$ST"; halt "pipeline not success"; }
  GH1="$(ghsha)"; say "github HEAD after: ${GH1:-<none>}"
  [ -n "$GH1" ] && [ "$GH1" != "$GH0" ] || halt "github sha did not advance"
  say "GITHUB SHA-ADVANCE GATE PASS: $GH1"
else
  ST="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT status FROM pipelines WHERE repo_id=$WID ORDER BY id DESC LIMIT 1" 2>/dev/null || true)"
  GH1="$(ghsha)"
  say "no new commit; last pipeline=$ST github unchanged=$([ "$GH1" = "$GH0" ] && echo yes || echo no)"
  [ "$ST" = success ] && [ "$GH1" = "$GH0" ] || halt "no-op path inconsistent"
  say "NO-OP GATE PASS"
fi

hr "X5 docs + ledger"
if ! grep -q "CI-triggered publish (EX55)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat >> "$DOCS/publish-runbook.md" <<'MD'

## CI-triggered publish (EX55)
- Private Gitea repo adminX/aether = source of truth; .gitignore excludes secrets/data/backups/key material
- Woodpecker pipeline: clone(PLUGIN_REMOTE from_secret) -> curate-scan(alpine+gitleaks binary, proven allowlist) -> publish(alpine/git, GITHUB_TOKEN from_secret)
- Trigger: push to Gitea main; gates: pipeline success + GitHub sha advance
- Re-run manual: infra/scripts/aether-publish.sh (host-side, same gates)
MD
fi
say "docs updated"
hr "X6 RESULT"
say "[RESULT] EX55 COMPLETE - A closed: Gitea push -> Woodpecker -> scan -> GitHub publish, gated."
ledger "PASS" "EX55: wp repo=$WID pipeline=$ST github=$GH1"
exit 0
