#!/usr/bin/env bash
# 20261104-EX2 — Brick 12 steel thread, syntax-safe.
# Gitea repo -> .woodpecker.yml push -> Gitea webhook -> Woodpecker server -> agent -> green build -> logs.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ex2-woodpecker-steel-thread-fixed-v1"

REPO="woodpecker-proof"
BOT="wp-bot"
EMAIL="wp-bot@local"
WP_PUBLIC="http://127.0.0.1:8000"
WP_INTERNAL="http://woodpecker-server:8000"
GT="http://127.0.0.1:3000"
UIDn="$(id -u)"
PODSOCK="/run/user/${UIDn}/podman/podman.sock"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || halt "missing required command: $1"; }

hr "X0 preflight"
need python3; need git; need curl; need podman; need base64; need awk; need sed; need grep
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container not present/running: $c"
done
mkdir -p "$SEC"
SV="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WP_PUBLIC/api/version" 2>/dev/null || echo 000)"
say "woodpecker server public API=$SV"
[ "$SV" = 200 ] || halt "Woodpecker server API not reachable on $WP_PUBLIC"

# Soft check: agent should be able to reach a Docker/Podman-compatible socket.
AGENT_MOUNTS="$(podman inspect woodpecker-agent --format '{{range .Mounts}}{{.Destination}}{{println}}{{end}}' 2>/dev/null || true)"
AGENT_ENV="$(podman inspect woodpecker-agent --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
say "podman socket on host: $([ -S "$PODSOCK" ] && echo yes || echo no) ($PODSOCK)"
if ! printf '%s' "$AGENT_MOUNTS" | grep -qxF "$PODSOCK" && ! printf '%s' "$AGENT_ENV" | grep -q '^DOCKER_HOST=unix://'; then
  say "WARN: agent does not visibly mount $PODSOCK or set DOCKER_HOST. If builds fail with Docker daemon errors, we patch the agent next."
fi

hr "X1 Gitea bot user + local password store"
PASS_FILE="$SEC/gitea-wp-bot.pass"
if [ -s "$PASS_FILE" ]; then
  PASS="$(cat "$PASS_FILE")"
else
  PASS="WpCi$(date +%s)!"
  printf '%s\n' "$PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"
  say "generated Gitea bot password -> $PASS_FILE"
fi
AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"

podman exec gitea gitea admin user create --username "$BOT" --password "$PASS" --email "$EMAIL" --admin >/dev/null 2>&1 \
  || podman exec gitea gitea admin user change-password --username "$BOT" --password "$PASS" >/dev/null 2>&1 \
  || true

USER_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/user" 2>/dev/null || echo '{}')"
printf '%s' "$USER_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); raise SystemExit(0 if d.get("login") else 1)' 2>/dev/null \
  || halt "Gitea auth failed for $BOT. Check: podman logs gitea"
say "Gitea bot auth OK"

hr "X2 Gitea repo"
REPO_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" 2>/dev/null || echo '{}')"
if ! printf '%s' "$REPO_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); raise SystemExit(0 if d.get("id") else 1)' 2>/dev/null; then
  python3 - "$REPO" > "$TMP/repo.json" <<'PYREPO'
import json, sys
print(json.dumps({"name": sys.argv[1], "private": False, "auto_init": True, "default_branch": "main"}))
PYREPO
  REPO_JSON="$(curl -sS -m 15 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d @"$TMP/repo.json" -X POST "$GT/api/v1/user/repos" 2>/dev/null || echo '{}')"
  printf '%s' "$REPO_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); raise SystemExit(0 if d.get("id") else 1)' 2>/dev/null \
    || { say "repo create response: $REPO_JSON"; halt "could not create repo"; }
  say "created repo $BOT/$REPO"
else
  say "repo already exists $BOT/$REPO"
fi
DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("default_branch") or "main")' 2>/dev/null || echo main)"
say "default branch=$DEFAULT_BRANCH"

hr "X3 Woodpecker webhook in Gitea"
HOOK_URL="$WP_INTERNAL/hook?source=gitea&owner=$BOT&repo=$REPO"
HOOKS_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '[]')"
if printf '%s' "$HOOKS_JSON" | grep -qF "$HOOK_URL"; then
  say "webhook already present"
else
  WP_SECRET="$(podman inspect woodpecker-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '/^WOODPECKER_GITEA_SECRET=/{sub(/^[^=]+=/,""); print; exit}')"
  python3 - "$HOOK_URL" "$WP_SECRET" > "$TMP/hook.json" <<'PYHOOK'
import json, sys
url, secret = sys.argv[1], sys.argv[2]
cfg = {"url": url, "content_type": "json"}
if secret:
    cfg["secret"] = secret
print(json.dumps({"type": "gitea", "active": True, "events": ["push"], "config": cfg}))
PYHOOK
  HOOK_RESP="$(curl -sS -m 15 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d @"$TMP/hook.json" -X POST "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '{}')"
  say "webhook create response code: $(printf '%s' "$HOOK_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("ok" if d.get("id") else d)' 2>/dev/null || echo unknown)"
fi

hr "X4 commit .woodpecker.yml and push"
WORK="$TMP/git"; mkdir -p "$WORK"; cd "$WORK" || halt "cd work failed"
git init -q
git remote add origin "$GT/$BOT/$REPO.git"
git -c http.extraHeader="Authorization: Basic $AUTH_B64" pull -q origin "$DEFAULT_BRANCH" --rebase >/dev/null 2>&1 || true

printf '%s\n' \
  "# woodpecker-proof $(date -Is)" \
  "steps:" \
  "  hello-world:" \
  "    image: alpine:latest" \
  "    commands:" \
  "      - echo \"Hello from Woodpecker CI!\"" \
  "      - date" \
  "      - whoami" > .woodpecker.yml

git add .woodpecker.yml
git -c user.email="$EMAIL" -c user.name="Woodpecker Proof" commit -q -m "ci: woodpecker steel thread $(date -Is)" >/dev/null 2>&1 || halt "git commit failed"
git -c http.extraHeader="Authorization: Basic $AUTH_B64" push -q origin "HEAD:$DEFAULT_BRANCH" || halt "git push failed"
SHA="$(git rev-parse HEAD)"
say "pushed SHA=$SHA"

hr "X5 poll for build/status"
WP_TOKEN=""
[ -s "$SEC/woodpecker-token" ] && WP_TOKEN="$(cat "$SEC/woodpecker-token")"
WP_AUTH=()
[ -n "$WP_TOKEN" ] && WP_AUTH=(-H "Authorization: Bearer $WP_TOKEN")
wp_api() { curl -sS -m 10 ${WP_AUTH[@]+"${WP_AUTH[@]}"} "$@" 2>/dev/null || echo ''; }

BUILD_NUM=""
FINAL=""
GSTATE=""
for i in $(seq 1 40); do
  BLIST="$(wp_api "$WP_PUBLIC/api/repos/$BOT/$REPO/builds")"
  BUILD_NUM="$(printf '%s' "$BLIST" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
if isinstance(d,list):
  if d: print(d[0].get("number",""))
elif isinstance(d,dict):
  print(d.get("number",""))
' 2>/dev/null || true)"

  if [ -n "$BUILD_NUM" ]; then
    DET="$(wp_api "$WP_PUBLIC/api/repos/$BOT/$REPO/builds/$BUILD_NUM")"
    FINAL="$(printf '%s' "$DET" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
if isinstance(d,dict): print(d.get("status",""))
' 2>/dev/null || true)"
  fi

  ST="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/commits/$SHA/statuses" 2>/dev/null || echo '[]')"
  GSTATE="$(printf '%s' "$ST" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
if isinstance(d,list) and d:
  print(d[-1].get("status",""))
elif isinstance(d,dict):
  print(d.get("status",""))
' 2>/dev/null || true)"

  [ -z "$FINAL" ] && FINAL="$GSTATE"
  case "$FINAL" in success|failure|error) break;; esac
  sleep 3
done

say "woodpecker build number=${BUILD_NUM:-none}"
say "final status=${FINAL:-unknown}"
say "gitea commit status=${GSTATE:-none}"

hr "X6 retrieve logs / proof"
LOG_PROOF=""
if [ "$FINAL" = success ]; then
  if [ -n "$BUILD_NUM" ]; then
    LOGS_RAW="$(wp_api "$WP_PUBLIC/api/repos/$BOT/$REPO/builds/$BUILD_NUM/logs")"
    LOG_PROOF="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
  fi
  if [ -z "$LOG_PROOF" ]; then
    LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
  fi
fi

if [ -z "$BUILD_NUM" ] && [ -z "$GSTATE" ]; then
  say "--- woodpecker-server recent hook/error logs ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'hook|gitea|error|warn' | tail -15 | sed 's/^/    /' || true
  say "--- woodpecker-agent recent logs ---"
  podman logs --since 3m woodpecker-agent 2>&1 | tail -15 | sed 's/^/    /' || true
fi

hr "X7 result"
PASS_RESULT=no
[ "$FINAL" = success ] && [ -n "$LOG_PROOF" ] && PASS_RESULT=yes
if [ "$PASS_RESULT" = yes ]; then
  say "[RESULT] EX2 COMPLETE - Brick 12 steel thread PASSED."
  say "  repo:  $GT/$BOT/$REPO"
  say "  build: $WP_PUBLIC/$BOT/$REPO/builds/${BUILD_NUM:-?}"
  say "  log proof: $LOG_PROOF"
else
  say "[RESULT] EX2 PARTIAL - final=$FINAL build=${BUILD_NUM:-none} log_proof=${LOG_PROOF:-none}"
  if [ "$FINAL" = success ] && [ -z "$LOG_PROOF" ]; then
    say "  Build is green, but logs are not retrievable anonymously."
    say "  One-time fix: log into Woodpecker UI, create an API token, save it to:"
    say "    $SEC/woodpecker-token"
    say "  then re-run EX2."
  fi
fi

hr "X8 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EX2: corrected EX syntax; Gitea repo/webhook/push steel thread. build=%s final=%s gitea_status=%s log_proof=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$PASS_RESULT" "${BUILD_NUM:-none}" "${FINAL:-unknown}" "${GSTATE:-none}" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
  say "ledger row appended"
fi
exit 0
