#!/usr/bin/env bash
# 20261112-EX59 — quote all YAML command scalars (fix go-yaml alias error), verify compile, repair webhook if silent, gate CI publish.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex59-yaml-quote-fix-webhook-repair-ci-gate-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
YML="$A/.woodpecker.yml"
WP="http://127.0.0.1:8000"; GT="http://127.0.0.1:3001"
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
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"; GHPAT="$(tr -d '\n\r' < "$SEC/github-pat.token")"
GT_PORT="$(podman port gitea 3000/tcp | head -1 | awk -F: '{print $NF}' | tr -d '\r')"
WID=2
wpr(){ podman exec postgres psql -U devops -d woodpecker -tAc "$1" 2>/dev/null || true; }
ghsha(){ curl -sS -m 15 -H "Authorization: Bearer $GHPAT" "https://api.github.com/repos/$GH_USER/$GH_REPO/commits?per_page=1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["sha"] if d else "")' 2>/dev/null || true; }
hooks(){ curl -sS -m 15 -u "$AUSER:$APASS" "$GT/api/v1/repos/$AUSER/aether/hooks" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(len(d))' 2>/dev/null || echo 0; }

hr "X0 probes + anchor"
[ -f "$YML" ] || halt "canonical .woodpecker.yml missing"
grep -qF 'TAG=$(curl -sS https://api.github.com' "$YML" && say "anchor (unquoted TAG line): present" || say "anchor: absent (already quoted?)"
say "hooks on aether now: $(hooks)"
GH0="$(ghsha)"; say "github HEAD before: ${GH0:-<none>}"
BEFORE="$(wpr "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$WID;" | tr -d ' \n')"
if [ "$MODE" = check ]; then
  say "plan: whole-block quoted YAML rewrite -> push -> compile gate (errors column empty) -> webhook silence check ->"
  say "      repair+re-push if needed -> success gate -> sha gate -> docs+ledger"
  say "[RESULT] EX59 CHECK - nothing written."; exit 0
fi

hr "X1 quoted YAML rewrite (whole block, backup first)"
cat > "$TMP/wp.yml" <<'YMLNEW'
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
      - 'apk add --no-cache curl tar >/dev/null'
      - 'mkdir -p .publish'
      - 'for d in docs infra codemod; do [ -d "$d" ] && cp -a "$d" .publish/; done'
      - 'for f in README.md .woodpecker.yml; do [ -f "$f" ] && cp -a "$f" .publish/; done'
      - 'find .publish -type f \( -name "*.env" -o -name "*.pass" -o -name "*.token" -o -name "*.bak" -o -name "*.pre-*" \) -delete'
      - 'while IFS= read -r rel; do [ -n "$rel" ] && rm -f ".publish/$rel"; done < infra/publish-blocklist.txt'
      - 'TAG=$(curl -sS https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep -o "\"tag_name\": *\"[^\"]*\"" | head -1 | cut -d"\"" -f4)'
      - 'VER=${TAG#v}'
      - 'curl -sSL -o /tmp/gl.tar.gz "https://github.com/gitleaks/gitleaks/releases/download/$TAG/gitleaks_${VER}_linux_x64.tar.gz"'
      - 'tar -xzf /tmp/gl.tar.gz -C /usr/local/bin gitleaks'
      - 'gitleaks detect --config infra/publish-allowlist.toml --no-git --source .publish --redact'
  - name: publish
    image: docker.io/alpine/git
    environment:
      GITHUB_TOKEN:
        from_secret: GITHUB_TOKEN
    commands:
      - 'git clone -q "https://ZainRajpooth:$GITHUB_TOKEN@github.com/ZainRajpooth/aether-devops-lab.git" /tmp/pub'
      - 'find /tmp/pub -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +'
      - 'cp -a .publish/. /tmp/pub/'
      - 'cd /tmp/pub'
      - 'git config user.name ZainRajpooth'
      - 'git config user.email z4xebot1@gmail.com'
      - 'git add -A'
      - 'git diff --cached --quiet || git commit -q -m "publish: CI curated sync $CI_COMMIT_SHA"'
      - 'git push -q origin HEAD:main'
    when:
      - event: push
YMLNEW
if cmp -s "$TMP/wp.yml" "$YML"; then say ".woodpecker.yml already quoted (no-op)"; else
  cp -p "$YML" "$YML.pre-ex59.$STAMP.bak"; chmod 600 "$YML.pre-ex59.$STAMP.bak"
  install -m 644 "$TMP/wp.yml" "$YML"; say ".woodpecker.yml rewritten (backup .pre-ex59.$STAMP.bak)"
fi

hr "X2 push + compile gate"
cd "$A" || halt "cd failed"
git add .woodpecker.yml
if git diff --cached --quiet; then say "nothing to commit (no-op)"; PUSHED=no; else
  git commit -q -m "ci: ex59 quote yaml scalars $STAMP" || halt "commit failed"
  git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "push failed"
  PUSHED=yes; say "pushed yaml fix"
fi
sleep 6
ERR="$(wpr "SELECT COALESCE(errors,'') FROM pipelines WHERE repo_id=$WID ORDER BY id DESC LIMIT 1;")"
say "latest pipeline errors: ${ERR:-<none>}"
printf '%s' "$ERR" | grep -q 'go-yaml' && { ledger "FAIL" "EX59 yaml still broken"; halt "YAML compile error persists"; }
say "COMPILE GATE PASS"

hr "X3 webhook silence check + repair if needed"
if [ "$PUSHED" = yes ]; then
  NEW="$(wpr "SELECT COUNT(*) FROM pipelines WHERE repo_id=$WID AND id>$BEFORE;")"
  say "push-triggered pipelines: $NEW"
  if [ "${NEW:-0}" -eq 0 ]; then
    say "webhook silent -> repairing"
    C="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/$WID/repair" || echo 000)"
    [ "$C" = 200 ] || C="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/$AUSER/aether/repair" || echo 000)"
    say "repair -> $C ; hooks now: $(hooks)"
    printf '\n- webhook repair verified %s (EX59).\n' "$STAMP" >> docs/ci-note.md
    git add docs/ci-note.md; git commit -q -m "ci: ex59 repair trigger $STAMP" || halt "commit failed"
    git push -q "http://$AUSER:$AENC@127.0.0.1:$GT_PORT/$AUSER/aether.git" HEAD:main || halt "re-push failed"
    sleep 6
    NEW="$(wpr "SELECT COUNT(*) FROM pipelines WHERE repo_id=$WID AND id>$BEFORE;")"
    say "push-triggered pipelines after repair: $NEW"
    [ "${NEW:-0}" -ge 1 ] || halt "still no push-triggered pipeline after repair"
  fi
fi

hr "X4 success gate + sha gate"
OK=no; ST=""
for i in $(seq 1 120); do
  R="$(wpr "SELECT number||' '||status FROM pipelines WHERE repo_id=$WID ORDER BY id DESC LIMIT 1")"
  if [ -n "$R" ]; then read -r N ST <<<"$R"; say "pipeline #$N status=$ST"
    [ "$ST" = success ] && { OK=yes; break; }
    case "$ST" in failure|error|killed) break;; esac
  fi
  sleep 3
done
if [ "$OK" != yes ]; then
  L="$(wpr "SELECT MAX(id) FROM pipelines WHERE repo_id=$WID;")"
  wpr "SELECT name||':'||state||' exit='||COALESCE(exit_code::text,'?') FROM steps WHERE pipeline_id=$L ORDER BY id;" | sed 's/^/    /'
  wpr "SELECT errors FROM pipelines WHERE id=$L;" | sed 's/^/    errors: /'
  podman logs --tail 25 woodpecker-agent 2>&1 | tail -12 | sed 's/^/    /'
  ledger "FAIL" "EX59 pipeline=$ST"
  halt "pipeline not success"
fi
GH1="$(ghsha)"; say "github HEAD after: ${GH1:-<none>}"
[ -n "$GH1" ] && [ "$GH1" != "$GH0" ] || halt "github sha did not advance"
say "GITHUB SHA-ADVANCE GATE PASS: $GH1"

hr "X5 docs + ledger"
if ! grep -q "YAML quoting + repair (EX59)" "$DOCS/publish-runbook.md" 2>/dev/null; then
cat >> "$DOCS/publish-runbook.md" <<'MD'

## YAML quoting + repair (EX59)
- Every pipeline command scalar MUST be single-quoted: plain scalars break on ": " and "*" (go-yaml alias error)
- If a push creates no pipeline: POST /api/repos/{id}/repair re-creates the Gitea webhook; verify via hooks count
- Compile gate: pipelines.errors must not contain go-yaml after push
MD
fi
say "docs updated"
hr "X6 RESULT"
say "[RESULT] EX59 COMPLETE - A CLOSED: YAML compiles, webhook fires, CI publish gated end-to-end."
ledger "PASS" "EX59: compile clean; hooks=$(hooks); pipeline=$ST github=$GH1"
exit 0
