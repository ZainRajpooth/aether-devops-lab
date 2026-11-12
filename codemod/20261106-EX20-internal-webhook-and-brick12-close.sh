#!/usr/bin/env bash
# 20261106-EX20 — closes Brick 12 after EX19 proved activation.
# Defect now: push creates no pipeline. Cause: Gitea must call Woodpecker via container DNS
# http://woodpecker-server:8000, not browser-only http://127.0.0.1:8000.
# This script enforces one correct internal Gitea webhook, retriggers push, polls Woodpecker
# Postgres for pipelines.status=success, and only conditionally heals agent addressing if pending.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
SESSION="$SEC/woodpecker-session.json"
UDIR="$HOME_/.config/containers/systemd"

TOKEN="ex20-internal-webhook-and-brick12-close-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"
PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"
PW_HEADLESS="${PW_HEADLESS:-1}"
MODE="${1:-run}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

psqlq(){
  podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true
}

code(){
  curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true
}

envval(){
  podman inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    awk -F= -v k="$2" '$1==k { sub(/^[^=]+=/, ""); print; exit }'
}

mask_env(){
  awk -F= '
    NF {
      k=$1
      v=substr($0, length(k)+2)
      if (k ~ /(SECRET|TOKEN|PASSWORD|PASSWD|KEY|DSN|DATASOURCE|CLIENT_SECRET)/)
        print k "=***"
      else
        print k "=" v
    }
  '
}

cookies_from_session(){
  python3 - "$SESSION" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
parts = []
for c in d.get("cookies", []) or []:
    dom = (c.get("domain") or "").lstrip(".")
    if dom in ("127.0.0.1", "localhost", ""):
        parts.append(f"{c.get('name')}={c.get('value')}")
print("; ".join(parts))
PY
}

ledger(){
  local gate="$1"
  local desc="$2"
  printf '| %s | B | %s | GATE=%s | %s |\n' \
    "$(date +%F)" "${TOKEN}-$(date +%s)" "$gate" "$desc" >> "$IDX"
  say "ledger row appended"
}

hr "Z0 preflight"
for c in python3 curl git podman base64 awk sed grep node; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"
done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
mkdir -p "$CD" "$SEC" "$APP"
touch "$IDX"

BOT="$(cat "$BOT_FILE")"
PASS="$(cat "$PASS_FILE")"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port for container port 3000"
GT="http://127.0.0.1:$GT_HOST_PORT"

REPOS_BEFORE="$(psqlq 'SELECT count(*) FROM repos' | tr -d ' \n')"
REPOS_BEFORE="${REPOS_BEFORE:-0}"
SUCC_BEFORE="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"
SUCC_BEFORE="${SUCC_BEFORE:-0}"

say "bot=$BOT"
say "Gitea URL=$GT"
say "Woodpecker URL=$WP"
say "repos_before=$REPOS_BEFORE success_before=$SUCC_BEFORE"

hr "Z1 confirm Woodpecker repo row exists"
REPO_JSON="$(psqlq "SELECT json_build_object('id', id, 'owner', owner, 'name', name, 'active', active, 'forge_remote_id', forge_remote_id, 'forge_url', forge_url, 'config_path', config_path) FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1")"
printf '  repo_row: %s\n' "${REPO_JSON:-null}"

if ! printf '%s' "$REPO_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("id") else 1)
' 2>/dev/null; then
  halt "Woodpecker repo row is absent; EX19 activation did not persist"
fi

if [ "$MODE" = check ]; then
  hr "Z2 plan (check mode)"
  say "  1) delete any Gitea hooks pointing to Woodpecker via 127.0.0.1/localhost"
  say "  2) create/enforce hook URL: http://woodpecker-server:8000/hook?source=gitea&owner=$BOT&repo=$REPO"
  say "  3) push empty trigger commit"
  say "  4) poll Woodpecker Postgres pipelines.status"
  say "  5) if pending and agent stale, conditionally heal quadlets with backups"
  say "[RESULT] EX20 CHECK - nothing written."
  exit 0
fi

hr "Z3 measure Woodpecker server/agent topology"
SRV_HOST="$(envval woodpecker-server WOODPECKER_HOST)"
SRV_GITEA_URL="$(envval woodpecker-server WOODPECKER_GITEA_URL)"
SRV_GRPC_ADDR="$(envval woodpecker-server WOODPECKER_GRPC_ADDR)"
SRV_BACKEND="$(envval woodpecker-server WOODPECKER_BACKEND)"
AG_SERVER="$(envval woodpecker-agent WOODPECKER_SERVER)"
AG_NETMODE="$(podman inspect woodpecker-agent --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo unknown)"
SRV_PORT_9000="$(podman port woodpecker-server 9000/tcp 2>/dev/null | head -1 || true)"
LAST_CONTACT="$(psqlq 'SELECT COALESCE(max(last_contact),0) FROM agents' | tr -d ' \n')"
LAST_CONTACT="${LAST_CONTACT:-0}"
NOW="$(date +%s)"
AGENT_AGE="$((NOW - LAST_CONTACT))"

say "server WOODPECKER_HOST=${SRV_HOST:-unset}"
say "server WOODPECKER_GITEA_URL=${SRV_GITEA_URL:-unset}"
say "server WOODPECKER_GRPC_ADDR=${SRV_GRPC_ADDR:-unset}"
say "server WOODPECKER_BACKEND=${SRV_BACKEND:-unset}"
say "server 9000 publish=${SRV_PORT_9000:-none}"
say "agent WOODPECKER_SERVER=${AG_SERVER:-unset}"
say "agent NetworkMode=${AG_NETMODE:-unknown}"
say "agent last_contact_age=${AGENT_AGE}s"

hr "Z4 enforce correct internal Gitea webhook"
GOOD_URL="http://woodpecker-server:8000/hook?source=gitea&owner=${BOT}&repo=${REPO}"
say "desired hook URL=$GOOD_URL"

WP_SECRET="$(envval woodpecker-server WOODPECKER_GITEA_SECRET)"
say "WOODPECKER_GITEA_SECRET present_len=${#WP_SECRET}"

HOOKS_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '[]')"
printf '%s' "$HOOKS_JSON" > "$TMP/hooks_before.json"

say "--- existing Woodpecker-related hooks (secret masked) ---"
python3 - "$TMP/hooks_before.json" <<'PY' | sed 's/^/    /'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    hooks = []
if not isinstance(hooks, list):
    hooks = []
for h in hooks:
    if not isinstance(h, dict):
        continue
    cfg = h.get("config") or {}
    url = cfg.get("url") or ""
    if "woodpecker" in url.lower() or "/hook?" in url:
        print(json.dumps({
            "id": h.get("id"),
            "active": h.get("active"),
            "events": h.get("events"),
            "url": url,
            "has_secret": bool(cfg.get("secret")),
        }))
PY

python3 - "$TMP/hooks_before.json" > "$TMP/delete_ids.txt" <<'PY'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    hooks = []
if not isinstance(hooks, list):
    hooks = []
ids = []
for h in hooks:
    if not isinstance(h, dict):
        continue
    cfg = h.get("config") or {}
    url = (cfg.get("url") or "").lower()
    if "woodpecker" in url or "/hook?" in url:
        hid = h.get("id")
        if hid is not None:
            ids.append(str(hid))
print("\n".join(ids))
PY

DELETE_COUNT="$(wc -l < "$TMP/delete_ids.txt" | tr -d ' \n')"
say "deleting $DELETE_COUNT existing Woodpecker hook(s) to avoid loopback/duplicate ambiguity"
while IFS= read -r hid; do
  [ -n "$hid" ] || continue
  curl -sS -m 10 -u "$BOT:$PASS" -X DELETE "$GT/api/v1/repos/$BOT/$REPO/hooks/$hid" >/dev/null 2>&1 || true
done < "$TMP/delete_ids.txt"

python3 - "$GOOD_URL" "$WP_SECRET" > "$TMP/hook_create.json" <<'PY'
import json, sys
url = sys.argv[1]
secret = sys.argv[2]
cfg = {"url": url, "content_type": "json"}
if secret:
    cfg["secret"] = secret
print(json.dumps({
    "type": "gitea",
    "active": True,
    "events": ["push"],
    "config": cfg
}))
PY

HOOK_CREATE_RESP="$(curl -sS -m 15 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d @"$TMP/hook_create.json" -X POST "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '{}')"
say "hook create response: $(printf '%s' "$HOOK_CREATE_RESP" | head -c 300)"

HOOKS_AFTER_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '[]')"
printf '%s' "$HOOKS_AFTER_JSON" > "$TMP/hooks_after.json"

if ! python3 - "$TMP/hooks_after.json" "$GOOD_URL" <<'PY'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
good = sys.argv[2]
if not isinstance(hooks, list):
    sys.exit(1)
for h in hooks:
    if not isinstance(h, dict):
        continue
    url = ((h.get("config") or {}).get("url") or "").replace("&amp;", "&")
    if url == good:
        sys.exit(0)
sys.exit(1)
PY
then
  say "--- hooks after create ---"
  cat "$TMP/hooks_after.json" | sed 's/^/    /'
  halt "correct internal Woodpecker hook was not present after enforcement"
fi
say "correct internal hook enforced"

hr "Z5 trigger push"
AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"
PUSH_SHA="$(
  WD="$TMP/git"
  mkdir -p "$WD"
  cd "$WD" || exit 1

  git -c init.defaultBranch=main init -q
  git remote add origin "$GT/$BOT/$REPO.git"
  git -c http.extraHeader="Authorization: Basic $AUTH_B64" pull -q origin main --rebase >/dev/null 2>&1 || true

  cat > .woodpecker.yml <<'YML'
steps:
  hello-world:
    image: alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
YML

  git add .woodpecker.yml
  if [ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ]; then
    git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q -m "ci: internal webhook steel thread $(date -Is)" || exit 1
  else
    git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q --allow-empty -m "ci: retrigger internal webhook $(date -Is)" || exit 1
  fi

  git -c http.extraHeader="Authorization: Basic $AUTH_B64" push -q origin HEAD:main || exit 1
  git rev-parse HEAD
)" || halt "push failed"

say "pushed SHA=$PUSH_SHA"

PIPE_NUM=""
PIPE_STATUS=""
PIPE_SUCC="0"

poll_pipelines(){
  local n="$1"
  local i row
  for i in $(seq 1 "$n"); do
    row="$(psqlq "SELECT number||' '||status FROM pipelines ORDER BY id DESC LIMIT 1")"
    if [ -n "$row" ]; then
      PIPE_NUM="${row%% *}"
      PIPE_STATUS="${row##* }"
    fi
    PIPE_SUCC="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"
    PIPE_SUCC="${PIPE_SUCC:-0}"

    case "$PIPE_STATUS" in
      success|failure|error|killed) return 0 ;;
    esac

    sleep 3
  done
}

dump_diagnostics(){
  say "--- woodpecker-server logs (5m) ---"
  podman logs --since 5m woodpecker-server 2>&1 |
    grep -iE 'hook|gitea|repo|pipeline|signature|401|403|404|error|warn' |
    tail -50 | sed 's/^/    /' || true

  say "--- gitea logs (5m) ---"
  podman logs --since 5m gitea 2>&1 |
    grep -iE 'hook|delivery|webhook|woodpecker|401|403|404|error|warn' |
    tail -50 | sed 's/^/    /' || true

  say "--- woodpecker-agent logs (5m) ---"
  podman logs --since 5m woodpecker-agent 2>&1 |
    tail -40 | sed 's/^/    /' || true

  say "--- current hooks ---"
  python3 - "$TMP/hooks_after.json" <<'PY' | sed 's/^/    /'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    hooks = []
if not isinstance(hooks, list):
    hooks = []
for h in hooks:
    if not isinstance(h, dict):
        continue
    cfg = h.get("config") or {}
    if "secret" in cfg:
        cfg["secret"] = "***"
    print(json.dumps({
        "id": h.get("id"),
        "active": h.get("active"),
        "events": h.get("events"),
        "config": cfg,
    }))
PY
}

hr "Z6 poll pipelines after internal webhook push"
poll_pipelines 30
say "pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none} success_count=${PIPE_SUCC:-0}"

if [ -z "$PIPE_NUM" ]; then
  hr "Z7 no pipeline: diagnostics"
  dump_diagnostics
  ledger "PARTIAL" "EX20 internal hook enforced but no pipeline row appeared. Push SHA=$PUSH_SHA. Paste Z4-Z7."
  halt "no pipeline created; webhook/server issue remains"
fi

if [ "$PIPE_STATUS" = success ]; then
  :
else
  LAST_CONTACT="$(psqlq 'SELECT COALESCE(max(last_contact),0) FROM agents' | tr -d ' \n')"
  LAST_CONTACT="${LAST_CONTACT:-0}"
  NOW="$(date +%s)"
  AGENT_AGE="$((NOW - LAST_CONTACT))"
  say "agent last_contact_age=${AGENT_AGE}s"

  if { [ "$PIPE_STATUS" = pending ] || [ "$PIPE_STATUS" = running ]; } && [ "$AGENT_AGE" -ge 120 ]; then
    hr "Z8 conditional agent/addressing heal"

    find_unit(){
      local name="$1"
      local img="$2"
      local f="$UDIR/${name}.container"
      if [ -f "$f" ]; then
        printf '%s' "$f"
        return 0
      fi
      f="$(grep -rlE "ContainerName=${name}|^[[:space:]]*Image=.*${img}" "$UDIR" 2>/dev/null | head -1 || true)"
      if [ -n "$f" ]; then
        printf '%s' "$f"
        return 0
      fi
      return 1
    }

    SRV_Q="$(find_unit woodpecker-server woodpecker-server || true)"
    AG_Q="$(find_unit woodpecker-agent woodpecker-agent || true)"

    if [ -z "$SRV_Q" ] || [ -z "$AG_Q" ]; then
      say "could not uniquely locate both quadlets; refusing blind edit"
      say "server_candidate=${SRV_Q:-none}"
      say "agent_candidate=${AG_Q:-none}"
      dump_diagnostics
      ledger "PARTIAL" "EX20 pipeline created but pending/stale agent; quadlet locate failed. pipeline=$PIPE_NUM status=$PIPE_STATUS."
      halt "pipeline pending and agent heal source not found"
    fi

    say "server quadlet=$SRV_Q"
    say "agent quadlet=$AG_Q"

    cp -p "$SRV_Q" "$SRV_Q.pre-EX20.bak"
    cp -p "$AG_Q" "$AG_Q.pre-EX20.bak"

    python3 - "$SRV_Q" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()

def set_env(text, key, val):
    lines = text.splitlines(keepends=True)
    out = []
    replaced = False
    pat = re.compile(r'^\s*Environment=' + re.escape(key) + '=')
    for ln in lines:
        if pat.match(ln):
            out.append(f"Environment={key}={val}\n")
            replaced = True
        else:
            out.append(ln)
    if not replaced:
        out2 = []
        done = False
        for ln in out:
            out2.append(ln)
            if not done and re.match(r'^\s*Environment=', ln):
                out2.append(f"Environment={key}={val}\n")
                done = True
        if not done:
            out3 = []
            done = False
            for ln in out2:
                out3.append(ln)
                if not done and ln.strip() == "[Container]":
                    out3.append(f"Environment={key}={val}\n")
                    done = True
            out = out3
        else:
            out = out2
    return "".join(out)

t = set_env(t, "WOODPECKER_GRPC_ADDR", "0.0.0.0:9000")
p.write_text(t)
print("    server quadlet: WOODPECKER_GRPC_ADDR=0.0.0.0:9000")
PY

    python3 - "$AG_Q" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()

def set_env(text, key, val):
    lines = text.splitlines(keepends=True)
    out = []
    replaced = False
    pat = re.compile(r'^\s*Environment=' + re.escape(key) + '=')
    for ln in lines:
        if pat.match(ln):
            out.append(f"Environment={key}={val}\n")
            replaced = True
        else:
            out.append(ln)
    if not replaced:
        out2 = []
        done = False
        for ln in out:
            out2.append(ln)
            if not done and re.match(r'^\s*Environment=', ln):
                out2.append(f"Environment={key}={val}\n")
                done = True
        if not done:
            out3 = []
            done = False
            for ln in out2:
                out3.append(ln)
                if not done and ln.strip() == "[Container]":
                    out3.append(f"Environment={key}={val}\n")
                    done = True
            out = out3
        else:
            out = out2
    return "".join(out)

def set_simple(text, key, val):
    lines = text.splitlines(keepends=True)
    out = []
    replaced = False
    pat = re.compile(r'^\s*' + re.escape(key) + '=')
    for ln in lines:
        if pat.match(ln):
            out.append(f"{key}={val}\n")
            replaced = True
        else:
            out.append(ln)
    if not replaced:
        out2 = []
        done = False
        for ln in out:
            out2.append(ln)
            if not done and ln.strip() == "[Container]":
                out2.append(f"{key}={val}\n")
                done = True
        out = out2
    return "".join(out)

t = set_env(t, "WOODPECKER_SERVER", "woodpecker-server:9000")
t = set_simple(t, "Network", "aether")
p.write_text(t)
print("    agent quadlet: WOODPECKER_SERVER=woodpecker-server:9000, Network=aether")
PY

    SRV_SVC="$(basename "$SRV_Q" .container).service"
    AGT_SVC="$(basename "$AG_Q" .container).service"

    say "restarting user services: $SRV_SVC $AGT_SVC"
    systemctl --user daemon-reload
    systemctl --user restart "$SRV_SVC" "$AGT_SVC" || halt "systemctl restart failed"

    READY=no
    for i in $(seq 1 30); do
      if [ "$(code "$WP/api/version")" = 200 ]; then
        READY=yes
        break
      fi
      sleep 2
    done
    [ "$READY" = yes ] || halt "Woodpecker server did not return after restart"
    say "Woodpecker server API ready"

    FRESH=no
    for i in $(seq 1 30); do
      LAST_CONTACT="$(psqlq 'SELECT COALESCE(max(last_contact),0) FROM agents' | tr -d ' \n')"
      LAST_CONTACT="${LAST_CONTACT:-0}"
      NOW="$(date +%s)"
      AGENT_AGE="$((NOW - LAST_CONTACT))"
      if [ "$AGENT_AGE" -lt 30 ]; then
        FRESH=yes
        break
      fi
      sleep 2
    done
    say "agent fresh=$FRESH age=${AGENT_AGE:-unknown}s"

    hr "Z9 poll again after agent heal"
    poll_pipelines 30
    say "pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none} success_count=${PIPE_SUCC:-0}"
  fi
fi

fetch_log_proof(){
  LOG_PROOF=""
  if [ -n "$PIPE_NUM" ] && [ -s "$SESSION" ]; then
    CK="$(cookies_from_session)"
    if [ -n "$CK" ]; then
      LOGS_RAW="$(curl -sS -m 15 -b "$CK" "$WP/api/repos/$BOT/$REPO/builds/$PIPE_NUM/logs" 2>/dev/null || true)"
      LOG_PROOF="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
    fi
  fi
  if [ -z "$LOG_PROOF" ]; then
    LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
  fi
  printf '%s' "$LOG_PROOF"
}

hr "Z10 final result"
LOG_PROOF="$(fetch_log_proof)"
say "log proof: ${LOG_PROOF:-none}"

if [ "$PIPE_STATUS" = success ]; then
  say "[RESULT] EX20 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
  say "  repo: $BOT/$REPO"
  say "  pipeline: #${PIPE_NUM:-?}"
  say "  status: success"
  say "  success_count: ${PIPE_SUCC:-0}"
  say "  hook URL: $GOOD_URL"
  say "  push SHA: $PUSH_SHA"
  say "  log proof: ${LOG_PROOF:-n/a}"
  ledger "PASS" "EX20: enforced internal Gitea webhook woodpecker-server:8000; push created pipeline #$PIPE_NUM status=$PIPE_STATUS; log_proof=$([ -n "$LOG_PROOF" ] && echo yes || echo no). Brick 12 CLOSED."
  exit 0
else
  say "[RESULT] EX20 PARTIAL - pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none}"
  dump_diagnostics
  ledger "PARTIAL" "EX20: internal hook enforced; pipeline #$PIPE_NUM status=$PIPE_STATUS; log_proof=$([ -n "$LOG_PROOF" ] && echo yes || echo no)."
  exit 1
fi
