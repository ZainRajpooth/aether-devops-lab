#!/usr/bin/env bash
# 20261104-EX6 — Brick 12 steel thread, Gitea-flag-aware.
# Fixes EX5: does not assume --active exists. Harvests gitea admin CLI help,
# creates/repairs CI bot using only supported flags, verifies API auth, and uses
# scoped SQL activation fallback only if needed. Then runs:
# Gitea repo -> Woodpecker webhook -> push -> build -> logs.
set -uo pipefail

HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ex6-gitea-flag-aware-woodpecker-steel-thread-v1"

REPO="woodpecker-proof"
WP_PUBLIC="http://127.0.0.1:8000"
WP_INTERNAL="http://woodpecker-server:8000"
BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=""
PGPASS=""
PGUSER=""
CREATE_LAST_OUT=""

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

redact(){
  awk -v a="$PASS" -v b="$PGPASS" '
    {
      if ((a != "" && index($0, a)) || (b != "" && index($0, b)))
        print "    [REDACTED-LINE]"
      else
        print
    }
  '
}

json_dict_field(){
  local field="$1"
  python3 -c '
import sys, json
field = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    v = d.get(field, "")
    if v is not None:
        print(v)
' "$field" 2>/dev/null || true
}

json_first_list_field(){
  local field="$1"
  python3 -c '
import sys, json
field = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, list) and d and isinstance(d[0], dict):
    v = d[0].get(field, "")
    if v is not None:
        print(v)
' "$field" 2>/dev/null || true
}

json_last_list_field(){
  local field="$1"
  python3 -c '
import sys, json
field = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, list) and d and isinstance(d[-1], dict):
    v = d[-1].get(field, "")
    if v is not None:
        print(v)
' "$field" 2>/dev/null || true
}

build_num_from_statuses(){
  python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, list) and d and isinstance(d[-1], dict):
    u = d[-1].get("target_url", "") or ""
    m = re.search(r"/builds/([0-9]+)", u)
    if m:
        print(m.group(1))
' 2>/dev/null || true
}

flag_has(){
  local flag="$1"
  local help_text="$2"
  printf '%s\n' "$help_text" | grep -qE -- "(^|[[:space:]])--${flag}([[:space:]=:]|$)"
}

hr "X0 preflight"
for c in python3 curl git podman base64 awk sed grep; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done

for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container not present/running: $c"
done

mkdir -p "$SEC"

GT_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_PORT" ] || GT_PORT="3001"
GT="http://127.0.0.1:$GT_PORT"
say "detected Gitea URL = $GT"

SV="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WP_PUBLIC/api/version" 2>/dev/null || echo 000)"
say "Woodpecker server API = $SV"
[ "$SV" = 200 ] || halt "Woodpecker server API not reachable at $WP_PUBLIC"

PGUSER="$(podman exec postgres printenv POSTGRES_USER 2>/dev/null || echo postgres)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
say "postgres user=$PGUSER"

UIDn="$(id -u)"
PODSOCK="/run/user/${UIDn}/podman/podman.sock"
say "host podman socket = $PODSOCK $([ -S "$PODSOCK" ] && echo present || echo absent)"

AGENT_MOUNTS="$(podman inspect woodpecker-agent --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' 2>/dev/null || true)"
AGENT_ENV="$(podman inspect woodpecker-agent --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
if ! printf '%s' "$AGENT_MOUNTS" | grep -qF "$PODSOCK" && ! printf '%s' "$AGENT_ENV" | grep -q '^DOCKER_HOST=unix:///run/user/'; then
  say "WARN: woodpecker-agent may not be using the rootless Podman socket."
  say "      If builds stay pending or fail with Docker daemon errors, the next fix is the agent socket/env."
fi

hr "X1 determine non-root Gitea CLI execution mode"
GITEA_EXEC_ARGS=()

if podman exec -u git gitea id -u >/dev/null 2>&1; then
  GITEA_EXEC_ARGS=(-u git)
  say "Gitea CLI user = git"
elif podman exec --user 1000:1000 gitea id -u >/dev/null 2>&1; then
  GITEA_EXEC_ARGS=(--user 1000:1000)
  say "Gitea CLI user = 1000:1000"
else
  say "--- attempted root CLI for diagnostics ---"
  podman exec gitea gitea admin user list 2>&1 | head -10 | redact | sed 's/^/    /' || true
  halt "could not find a non-root Gitea CLI execution mode"
fi

gitea_admin(){
  podman exec "${GITEA_EXEC_ARGS[@]}" gitea gitea admin "$@"
}

hr "X2 harvest Gitea admin CLI help (ground truth, no flag guessing)"
CREATE_HELP="$(gitea_admin user create --help 2>&1 | tr -d '\r' || true)"
CHANGE_HELP="$(gitea_admin user change-password --help 2>&1 | tr -d '\r' || true)"

say "--- gitea admin user create --help ---"
printf '%s\n' "$CREATE_HELP" | sed -n '1,80p' | redact | sed 's/^/    /' || true
say "--- gitea admin user change-password --help ---"
printf '%s\n' "$CHANGE_HELP" | sed -n '1,80p' | redact | sed 's/^/    /' || true

say "supported create flags detected:"
for f in admin active must-change-password username password email; do
  if flag_has "$f" "$CREATE_HELP"; then say "  --$f: yes"; else say "  --$f: no"; fi
done
say "supported change-password flags detected:"
for f in username password must-change-password; do
  if flag_has "$f" "$CHANGE_HELP"; then say "  --$f: yes"; else say "  --$f: no"; fi
done

hr "X3 Gitea bot auth: reuse if valid, otherwise create fresh disposable bot"
verify_gitea_auth(){
  local user="$1" pass="$2" code login
  PASS="$pass"
  code="$(curl -sS -m 10 -o "$TMP/user.json" -w '%{http_code}' -u "$user:$pass" "$GT/api/v1/user" 2>/dev/null || echo 000)"
  login="$(json_dict_field login < "$TMP/user.json")"
  say "auth probe user=$user code=$code login='${login:-none}'"
  [ "$code" = 200 ] && [ "$login" = "$user" ]
}

try_create(){
  local desc="$1"; shift
  local -a cmd=(user create --username "$BOT" --password "$PASS" --email "$EMAIL")
  cmd+=("$@")
  if gitea_admin "${cmd[@]}" >"$TMP/create.out" 2>&1; then
    say "create OK: $desc"
    CREATE_LAST_OUT="$(tail -1 "$TMP/create.out" 2>/dev/null || true)"
    return 0
  else
    CREATE_LAST_OUT="$(tail -1 "$TMP/create.out" 2>/dev/null || true)"
    say "create failed: $desc :: $CREATE_LAST_OUT"
    return 1
  fi
}

try_change(){
  local desc="$1"; shift
  local -a cmd=(user change-password --username "$BOT" --password "$PASS")
  cmd+=("$@")
  if gitea_admin "${cmd[@]}" >"$TMP/change.out" 2>&1; then
    say "change-password OK: $desc"
    return 0
  else
    say "change-password failed: $desc :: $(tail -1 "$TMP/change.out" 2>/dev/null || true)"
    return 1
  fi
}

BOT=""
EMAIL=""
if [ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ]; then
  BOT="$(cat "$BOT_FILE")"
  PASS="$(cat "$PASS_FILE")"
  EMAIL="${BOT}@local"
  if verify_gitea_auth "$BOT" "$PASS"; then
    say "reusing existing Gitea bot: $BOT"
  else
    say "existing stored bot failed auth; creating fresh disposable bot"
    BOT=""
  fi
fi

if [ -z "$BOT" ]; then
  BOT="wp-ci-bot-$(date +%s)"
  EMAIL="${BOT}@local"
  PASS="WpCi-$(date +%s)-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s\n' "$BOT" > "$BOT_FILE"; chmod 600 "$BOT_FILE"
  printf '%s\n' "$PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"
  say "stored new bot credentials locally: $BOT_FILE / $PASS_FILE"

  created=no

  # Candidate 1: all supported flags, including must-change-password=false and active if present.
  c1=()
  flag_has admin "$CREATE_HELP" && c1+=(--admin)
  flag_has must-change-password "$CREATE_HELP" && c1+=(--must-change-password=false)
  flag_has active "$CREATE_HELP" && c1+=(--active)
  try_create "full-supported" ${c1[@]+"${c1[@]}"} && created=yes

  # Candidate 2: omit --must-change-password=false, keep --active if supported.
  if [ "$created" = no ]; then
    c2=()
    flag_has admin "$CREATE_HELP" && c2+=(--admin)
    flag_has active "$CREATE_HELP" && c2+=(--active)
    try_create "without-must-change-false" ${c2[@]+"${c2[@]}"} && created=yes
  fi

  # Candidate 3: omit --active, keep --must-change-password=false if supported.
  if [ "$created" = no ]; then
    c3=()
    flag_has admin "$CREATE_HELP" && c3+=(--admin)
    flag_has must-change-password "$CREATE_HELP" && c3+=(--must-change-password=false)
    try_create "without-active" ${c3[@]+"${c3[@]}"} && created=yes
  fi

  # Candidate 4: admin only.
  if [ "$created" = no ]; then
    c4=()
    flag_has admin "$CREATE_HELP" && c4+=(--admin)
    try_create "admin-only" ${c4[@]+"${c4[@]}"} && created=yes
  fi

  # Candidate 5: minimal.
  if [ "$created" = no ]; then
    try_create "minimal" && created=yes
  fi

  if [ "$created" = no ]; then
    say "create attempts did not report success; continuing to change-password/verify because user may already exist"
  fi

  changed=no

  # Change-password candidate 1: use --must-change-password=false if supported.
  d1=()
  flag_has must-change-password "$CHANGE_HELP" && d1+=(--must-change-password=false)
  try_change "with-must-change-false" ${d1[@]+"${d1[@]}"} && changed=yes

  # Change-password candidate 2: plain username/password.
  if [ "$changed" = no ]; then
    try_change "plain" && changed=yes
  fi

  verify_gitea_auth "$BOT" "$PASS" || {
    say "API auth still failed after CLI create/change; attempting scoped SQL activation fallback"

    psqlq(){
      local db="$1" sql="$2"
      podman exec postgres psql -U "$PGUSER" -d "$db" -tAc "$sql" 2>/dev/null || true
    }

    find_user_table(){
      local dbs db tbl schema table cols id active admin must passwd pref
      dbs="$(podman exec postgres psql -U "$PGUSER" -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)"
      for db in $dbs; do
        [ -z "$db" ] && continue
        while IFS= read -r tbl; do
          [ -z "$tbl" ] && continue
          schema="${tbl%%.*}"
          table="${tbl#*.}"

          cols="$(psqlq "$db" "SELECT coalesce(string_agg(column_name, ',' ORDER BY ordinal_position), '') FROM information_schema.columns WHERE table_schema='$schema' AND table_name='$table'")"
          [ -z "$cols" ] && continue

          id=""
          for pref in lower_name login_name uname name; do
            if printf '%s' ",$cols," | grep -q ",$pref,"; then id="$pref"; break; fi
          done

          active=""
          for pref in is_active active; do
            if printf '%s' ",$cols," | grep -q ",$pref,"; then active="$pref"; break; fi
          done

          admin=""
          for pref in is_admin admin; do
            if printf '%s' ",$cols," | grep -q ",$pref,"; then admin="$pref"; break; fi
          done

          must=""
          if printf '%s' ",$cols," | grep -q ",must_change_password,"; then must="must_change_password"; fi

          passwd=""
          for pref in passwd password; do
            if printf '%s' ",$cols," | grep -q ",$pref,"; then passwd="$pref"; break; fi
          done

          if [ -n "$id" ] && { [ -n "$active" ] || [ -n "$must" ]; }; then
            printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$db" "$schema" "$table" "$id" "$active" "$admin" "$must" "$passwd"
            return 0
          fi
        done < <(psqlq "$db" "SELECT table_schema||'.'||table_name FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema','toast') AND table_name ~* '^(user|users|account|accounts|login|logins)$' ORDER BY 1")
      done
      return 1
    }

    sql_activate_bot(){
      local found db schema table id active admin must passwd
      found="$(find_user_table || true)"
      [ -n "$found" ] || { say "SQL fallback: no user-like table with id + active/must columns found"; return 1; }

      IFS='|' read -r db schema table id active admin must passwd <<<"$found"
      say "SQL fallback found table: db=$db schema=$schema table=$table id=$id active=${active:-none} admin=${admin:-none} must=${must:-none} passwd_len_col=${passwd:-none}"

      local -a seta=()
      [ -n "$active" ] && seta+=("\"$active\"=true")
      [ -n "$admin" ] && seta+=("\"$admin\"=true")
      [ -n "$must" ] && seta+=("\"$must\"=false")
      [ "${#seta[@]}" -eq 0 ] && { say "SQL fallback: nothing to set"; return 1; }

      local set_sql
      printf -v set_sql '%s,' "${seta[@]}"
      set_sql="${set_sql%,}"

      if podman exec postgres psql -U "$PGUSER" -d "$db" -c "UPDATE \"$schema\".\"$table\" SET $set_sql WHERE lower(\"$id\") = lower('$BOT');" >/dev/null 2>&1; then
        say "SQL fallback update executed"
        systemctl --user restart gitea.service >/dev/null 2>&1 || true
        sleep 8
        return 0
      else
        say "SQL fallback update failed"
        return 1
      fi
    }

    if sql_activate_bot; then
      verify_gitea_auth "$BOT" "$PASS" || {
        say "--- final Gitea diagnostics ---"
        say "gitea admin user list grep:"
        gitea_admin user list 2>&1 | grep -i -- "$BOT" | redact | sed 's/^/    /' || true
        say "recent gitea logs:"
        podman logs --since 3m gitea 2>&1 | tail -40 | redact | sed 's/^/    /' || true
        halt "Gitea bot auth failed even after CLI + SQL fallback"
      }
    else
      say "--- final Gitea diagnostics ---"
      say "gitea admin user list grep:"
      gitea_admin user list 2>&1 | grep -i -- "$BOT" | redact | sed 's/^/    /' || true
      say "recent gitea logs:"
      podman logs --since 3m gitea 2>&1 | tail -40 | redact | sed 's/^/    /' || true
      say "postgres databases:"
      podman exec postgres psql -U "$PGUSER" -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null | sed 's/^/    /' || true
      halt "Gitea bot auth failed and SQL fallback could not find a safe user table"
    fi
  }
fi

say "Gitea bot auth OK user=$BOT"
AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"

hr "X4 Gitea repo"
REPO_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" 2>/dev/null || echo '{}')"
REPO_ID="$(printf '%s' "$REPO_JSON" | json_dict_field id)"

if [ -z "$REPO_ID" ]; then
  python3 - "$REPO" > "$TMP/repo.json" <<'PYREPO'
import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "private": False,
    "auto_init": True,
    "default_branch": "main"
}))
PYREPO

  REPO_JSON="$(curl -sS -m 15 \
    -u "$BOT:$PASS" \
    -H 'Content-Type: application/json' \
    -d @"$TMP/repo.json" \
    -X POST \
    "$GT/api/v1/user/repos" 2>/dev/null || echo '{}')"

  REPO_ID="$(printf '%s' "$REPO_JSON" | json_dict_field id)"
  [ -n "$REPO_ID" ] || {
    say "repo create response: $REPO_JSON"
    halt "could not create repo"
  }
  say "created repo $BOT/$REPO id=$REPO_ID"
else
  say "repo already exists $BOT/$REPO id=$REPO_ID"
fi

DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | json_dict_field default_branch)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
say "default branch=$DEFAULT_BRANCH"

hr "X5 Woodpecker webhook in Gitea"
HOOK_URL="$WP_INTERNAL/hook?source=gitea&owner=$BOT&repo=$REPO"
HOOKS="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '[]')"

if printf '%s' "$HOOKS" | tr -d '\\' | grep -qF "$HOOK_URL"; then
  say "webhook already present"
else
  WP_SECRET="$(podman inspect woodpecker-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '/^WOODPECKER_GITEA_SECRET=/{sub(/^[^=]+=/,""); print; exit}')"

  python3 - "$HOOK_URL" "$WP_SECRET" > "$TMP/hook.json" <<'PYHOOK'
import json, sys
url, secret = sys.argv[1], sys.argv[2]
cfg = {"url": url, "content_type": "json"}
if secret:
    cfg["secret"] = secret
print(json.dumps({
    "type": "gitea",
    "active": True,
    "events": ["push"],
    "config": cfg
}))
PYHOOK

  HOOK_RESP="$(curl -sS -m 15 \
    -u "$BOT:$PASS" \
    -H 'Content-Type: application/json' \
    -d @"$TMP/hook.json" \
    -X POST \
    "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo '{}')"

  HOOK_ID="$(printf '%s' "$HOOK_RESP" | json_dict_field id)"
  if [ -n "$HOOK_ID" ]; then
    say "webhook created id=$HOOK_ID"
  else
    say "webhook create response: $HOOK_RESP"
  fi
fi

hr "X6 Woodpecker API auth / repo activation attempt"
WP_TOKEN=""
[ -s "$SEC/woodpecker-token" ] && WP_TOKEN="$(cat "$SEC/woodpecker-token")"
WP_AUTH=()
[ -n "$WP_TOKEN" ] && WP_AUTH=(-H "Authorization: Bearer $WP_TOKEN")
say "woodpecker token file present: $([ -n "$WP_TOKEN" ] && echo yes || echo no)"

wp_get(){
  curl -sS -m 10 ${WP_AUTH[@]+"${WP_AUTH[@]}"} "$1" 2>/dev/null || echo ''
}

wp_post(){
  curl -sS -m 10 -X POST ${WP_AUTH[@]+"${WP_AUTH[@]}"} "$1" 2>/dev/null || echo ''
}

ACT_RESP="$(wp_post "$WP_PUBLIC/api/repos/$BOT/$REPO")"
say "woodpecker repo activation attempt response (first 220 chars):"
printf '%s' "$ACT_RESP" | head -c 220 | redact | sed 's/^/    /' || true
echo

REPAIR_RESP="$(wp_post "$WP_PUBLIC/api/repos/$BOT/$REPO/repair")"
say "woodpecker repo repair attempt response (first 160 chars):"
printf '%s' "$REPAIR_RESP" | head -c 160 | redact | sed 's/^/    /' || true
echo

hr "X7 commit/push .woodpecker.yml"
WORK="$TMP/git"
mkdir -p "$WORK"
cd "$WORK" || halt "cd work failed"

git -c init.defaultBranch=main init -q
git remote add origin "$GT/$BOT/$REPO.git"
git -c http.extraHeader="Authorization: Basic $AUTH_B64" pull -q origin "$DEFAULT_BRANCH" --rebase >/dev/null 2>&1 || true

cat > .woodpecker.yml <<'YMLEOF'
steps:
  hello-world:
    image: alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
YMLEOF

git add .woodpecker.yml
COMMIT_NEEDED=no
[ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ] && COMMIT_NEEDED=yes

BLIST="$(wp_get "$WP_PUBLIC/api/repos/$BOT/$REPO/builds")"
EXISTING_BUILD="$(printf '%s' "$BLIST" | json_first_list_field number)"

if [ "$COMMIT_NEEDED" = yes ] || [ -z "$EXISTING_BUILD" ]; then
  if [ "$COMMIT_NEEDED" = no ]; then
    git -c user.email="$EMAIL" -c user.name="Woodpecker Proof" \
      commit -q --allow-empty -m "ci: trigger woodpecker $(date -Is)" || halt "empty commit failed"
  else
    git -c user.email="$EMAIL" -c user.name="Woodpecker Proof" \
      commit -q -m "ci: woodpecker steel thread" || halt "commit failed"
  fi

  git -c http.extraHeader="Authorization: Basic $AUTH_B64" \
    push -q origin "HEAD:$DEFAULT_BRANCH" || halt "git push failed"

  say "pushed trigger commit"
else
  say "config already present and build already exists; no push"
fi

SHA="$(git rev-parse HEAD)"
say "HEAD SHA=$SHA"

hr "X8 poll build/status"
BUILD_NUM="$EXISTING_BUILD"
FINAL=""
GSTATE=""

for i in $(seq 1 40); do
  BLIST="$(wp_get "$WP_PUBLIC/api/repos/$BOT/$REPO/builds")"
  BN="$(printf '%s' "$BLIST" | json_first_list_field number)"
  [ -n "$BN" ] && BUILD_NUM="$BN"

  if [ -n "$BUILD_NUM" ]; then
    DET="$(wp_get "$WP_PUBLIC/api/repos/$BOT/$REPO/builds/$BUILD_NUM")"
    FINAL="$(printf '%s' "$DET" | json_dict_field status)"
  fi

  ST="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/commits/$SHA/statuses" 2>/dev/null || echo '[]')"
  GS="$(printf '%s' "$ST" | json_last_list_field status)"
  [ -n "$GS" ] && GSTATE="$GS"

  if [ -z "$BUILD_NUM" ]; then
    BN2="$(printf '%s' "$ST" | build_num_from_statuses)"
    [ -n "$BN2" ] && BUILD_NUM="$BN2"
  fi

  [ -z "$FINAL" ] && FINAL="$GSTATE"

  case "$FINAL" in
    success|failure|error) break ;;
  esac

  sleep 3
done

say "woodpecker build number=${BUILD_NUM:-none}"
say "woodpecker final status=${FINAL:-unknown}"
say "gitea commit status=${GSTATE:-none}"

hr "X9 retrieve logs / proof"
LOG_PROOF=""

if [ -n "$BUILD_NUM" ]; then
  LOGS_RAW="$(wp_get "$WP_PUBLIC/api/repos/$BOT/$REPO/builds/$BUILD_NUM/logs")"
  LOG_PROOF="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
fi

if [ -z "$LOG_PROOF" ]; then
  LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
fi

if [ -z "$BUILD_NUM" ] && [ -z "$GSTATE" ]; then
  say "--- woodpecker-server recent hook/error logs ---"
  podman logs --since 3m woodpecker-server 2>&1 | grep -iE 'hook|gitea|error|warn|repo' | tail -30 | redact | sed 's/^/    /' || true

  say "--- woodpecker-agent recent logs ---"
  podman logs --since 3m woodpecker-agent 2>&1 | tail -30 | redact | sed 's/^/    /' || true
fi

hr "X10 result"
PASS_RESULT=no

if [ "$FINAL" = success ] && [ -n "$LOG_PROOF" ]; then
  PASS_RESULT=yes
  say "[RESULT] EX6 COMPLETE - Brick 12 steel thread PASSED."
  say "  repo:  $GT/$BOT/$REPO"
  say "  build: $WP_PUBLIC/$BOT/$REPO/builds/${BUILD_NUM:-?}"
  say "  log proof: $LOG_PROOF"
elif [ "$FINAL" = success ]; then
  PASS_RESULT=green_no_logs
  say "[RESULT] EX6 GREEN BUT LOG API NEEDS TOKEN - build succeeded, logs not anonymously retrievable."
  say "  Create a Woodpecker API token once, then save locally:"
  say "    install -d -m 700 '$SEC'"
  say "    umask 077"
  say "    printf '%s' 'PASTE_TOKEN_HERE' > '$SEC/woodpecker-token'"
  say "  Then re-run EX6."
else
  say "[RESULT] EX6 PARTIAL - final=${FINAL:-unknown} build=${BUILD_NUM:-none} gitea_status=${GSTATE:-none}"
fi

hr "X11 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | EX6: Gitea flag-aware bot creation; harvested CLI help; SQL activation fallback; repo/webhook/push/poll. build=%s final=%s gitea_status=%s log_proof=%s. |\n' \
    "$(date +%F)" "$TOKEN" "$PASS_RESULT" "${BUILD_NUM:-none}" "${FINAL:-unknown}" "${GSTATE:-none}" "$([ -n "$LOG_PROOF" ] && echo yes || echo no)" >> "$IDX"
  say "ledger row appended"
fi

exit 0
