#!/usr/bin/env bash
# 20261031-CD — Brick 12 secure bootstrap + Woodpecker diagnosis.
# Mutates only:
#   $HOME/DevOps/aether/secrets/gitea-api-token  (0600, never echoed)
#   Gitea repo aether-admin/aether-ci-proof
#   .woodpecker.yml inside that repo via Gitea Contents API
# Diagnoses Woodpecker server/agent with sanitized logs and whitelisted env only.
# Does NOT restart Woodpecker, does NOT pull images, does NOT echo secrets.
set -uo pipefail

TMPD="$(mktemp -d)"
cleanup(){ rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
SEC="$A/secrets"
GITEA_ENV="$SEC/gitea.env"
WP_ENV="$SEC/woodpecker.env"
GITEA_DIRECT="http://127.0.0.1:3001"
EDGE="http://127.0.0.1:8888"
NET="aether"
ALPINE="docker.io/library/alpine:latest"

OWNER=""
REPO="aether-ci-proof"
TOKEN_NAME="aether-ci-proof"
GITEA_TOKEN_FILE="$SEC/gitea-api-token"
WP_TOKEN_FILE="$SEC/woodpecker-token"

TOKEN="cd-gitea-ci-bootstrap-and-woodpecker-diagnosis-v1"

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n========== %s ==========\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }
need_cmd(){ if ! command -v "$1" >/dev/null 2>&1; then halt "missing required command: $1"; fi; }

for c in bash podman curl awk sed grep python3 base64 stat sha256sum sort uniq head tr printf timeout chmod cp rm mktemp; do
  need_cmd "$c"
done

mkdir -p "$CD" "$SEC"
touch "$IDX"

make_cfg_from_file(){
  local src="$1"
  local dst="$2"
  umask 077
  {
    printf 'header = "Authorization: token '
    tr -d '\n' < "$src"
    printf '"\n'
  } > "$dst"
  chmod 600 "$dst"
}

hdr_code(){
  local url="$1"
  local cfg="$2"
  local c
  c="$(curl -s --config "$cfg" -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)"
  c="$(norm "$c")"
  if [ -z "$c" ]; then c=000; fi
  printf '%s' "$c"
}

hdr_req(){
  local method="$1"
  local url="$2"
  local cfg="$3"
  local data="$4"
  local out="$5"
  local c
  : > "$out"
  if [ -n "$data" ]; then
    c="$(curl -s --config "$cfg" -X "$method" -H 'Content-Type: application/json' --data "$data" -o "$out" -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)"
  else
    c="$(curl -s --config "$cfg" -X "$method" -o "$out" -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)"
  fi
  c="$(norm "$c")"
  if [ -z "$c" ]; then c=000; fi
  printf '%s' "$c"
}

verify_token_file(){
  local f="$1"
  local cfg="$TMPD/verify.cfg"
  local c
  make_cfg_from_file "$f" "$cfg"
  c="$(hdr_code "$GITEA_DIRECT/api/v1/user" "$cfg")"
  printf '%s' "$c"
}

mint_with_scopes(){
  local scopes="$1"
  local out="$TMPD/cli.out"
  local err="$TMPD/cli.err"
  local tok
  : > "$out"
  : > "$err"
  if podman exec gitea gitea admin user generate-access-token --username "$OWNER" --token-name "$TOKEN_NAME" --scopes "$scopes" </dev/null >"$out" 2>"$err"; then
    tok="$(awk '/Token:/{print $2; exit}' "$out" 2>/dev/null || true)"
    tok="$(norm "$tok")"
    if [ -z "$tok" ]; then
      tok="$(awk '/Token:/{print $2; exit}' "$err" 2>/dev/null || true)"
      tok="$(norm "$tok")"
    fi
    if [ -z "$tok" ]; then
      tok="$(tail -n 1 "$out" 2>/dev/null | tr -d '[:space:]' || true)"
      tok="$(norm "$tok")"
    fi
    if [ "${#tok}" -ge 20 ]; then
      umask 077
      printf '%s' "$tok" > "$TMPD/minted.token"
      chmod 600 "$TMPD/minted.token"
      return 0
    fi
  fi
  return 1
}

mint_api(){
  local netrc="$TMPD/netrc"
  local resp="$TMPD/token.json"
  local code
  local tok
  umask 077
  awk -F= -v user="$OWNER" '$1=="GITEA_ADMIN_PASSWORD"{print "machine 127.0.0.1"; print "login " user; print "password " substr($0,index($0,"=")+1)}' "$GITEA_ENV" > "$netrc"
  chmod 600 "$netrc"
  code="$(curl -s --netrc-file "$netrc" -o "$resp" -w '%{http_code}' --max-time 15 -X POST -H 'Content-Type: application/json' --data '{"name":"aether-ci-proof","permissions":{"repo":true,"admin:repo_hook":true}}' "$GITEA_DIRECT/api/v1/user/tokens" 2>/dev/null || true)"
  code="$(norm "$code")"
  if [ "$code" = 200 ] || [ "$code" = 201 ]; then
    tok="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("sha1") or d.get("token") or "")' "$resp" 2>/dev/null || true)"
    tok="$(norm "$tok")"
    if [ "${#tok}" -ge 20 ]; then
      umask 077
      printf '%s' "$tok" > "$TMPD/minted.token"
      chmod 600 "$TMPD/minted.token"
      return 0
    fi
  fi
  return 1
}

install_minted(){
  umask 077
  cp -f "$TMPD/minted.token" "$GITEA_TOKEN_FILE"
  chmod 600 "$GITEA_TOKEN_FILE"
  rm -f "$TMPD/minted.token"
}

get_env_val(){
  local cont="$1"
  local key="$2"
  podman inspect "$cont" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1); exit}' \
    | sed 's/[[:space:]]*$//'
}

say_env(){
  local cont="$1"
  say "--- $cont whitelisted env (non-secret keys only) ---"
  podman inspect "$cont" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -E '^(WOODPECKER_ADMIN|WOODPECKER_OPEN|WOODPECKER_HOST|WOODPECKER_SERVER|WOODPECKER_GRPC_ADDR|WOODPECKER_BACKEND|DOCKER_HOST|WOODPECKER_GITEA_URL)=' \
    | sed 's/^/    /' || say "    (none)"
}

log_sanitize(){
  local cont="$1"
  local f="$TMPD/log-$cont.txt"
  : > "$f"
  podman logs --tail 200 "$cont" >"$f" 2>&1 || true
  grep -Ei 'grpc|agent|server|register|connect|error|fatal|panic|listen|ready|started|version|forge|gitea|oauth|webhook|pipeline|backend|docker|podman|socket|timeout|refused|denied' "$f" 2>/dev/null \
    | grep -Eiv 'secret|token|password|client_secret|authorization|bearer|dsn|datasource|credential|access_key|api_key' 2>/dev/null \
    | sed -E 's#(https?://)[^/@[:space:]]+@#\1***@#g' 2>/dev/null \
    | tail -30 \
    | sed 's/^/    /' || say "    (no sanitized lines)"
}

err_count(){
  local cont="$1"
  podman logs --tail 300 "$cont" 2>/dev/null | grep -Eic 'error|fatal|panic' || printf '0'
}

# ===================== [D0] resolve owner =====================
hr "CD0 resolve Gitea admin username (not a secret)"
if [ ! -f "$GITEA_ENV" ]; then
  halt "missing $GITEA_ENV"
fi
OWNER="$(grep -m1 '^GITEA_ADMIN_USER=' "$GITEA_ENV" 2>/dev/null | cut -d= -f2- | tr -d ' \r' || true)"
OWNER="$(norm "$OWNER")"
if [ -z "$OWNER" ]; then
  halt "cannot resolve GITEA_ADMIN_USER from $GITEA_ENV"
fi
say "owner=$OWNER repo=$REPO"

# ===================== [D1] mint/verify Gitea CI token =====================
hr "CD1 Gitea CI token (stored 0600, never echoed)"
TOKEN_OK=no
if [ -f "$GITEA_TOKEN_FILE" ]; then
  vc="$(verify_token_file "$GITEA_TOKEN_FILE")"
  if [ "$vc" = 200 ]; then
    TOKEN_OK=yes
    say "existing token valid -> $GITEA_TOKEN_FILE"
  else
    say "existing token invalid (http=$vc); minting new"
  fi
fi

if [ "$TOKEN_OK" != yes ]; then
  if mint_with_scopes "repo,admin:repo_hook"; then
    install_minted
    vc="$(verify_token_file "$GITEA_TOKEN_FILE")"
    if [ "$vc" = 200 ]; then
      TOKEN_OK=yes
      say "minted least-privilege token via Gitea CLI"
    fi
  fi
fi

if [ "$TOKEN_OK" != yes ]; then
  if mint_with_scopes "all"; then
    install_minted
    vc="$(verify_token_file "$GITEA_TOKEN_FILE")"
    if [ "$vc" = 200 ]; then
      TOKEN_OK=yes
      say "minted all-scope token via Gitea CLI"
    fi
  fi
fi

if [ "$TOKEN_OK" != yes ]; then
  if mint_api; then
    install_minted
    vc="$(verify_token_file "$GITEA_TOKEN_FILE")"
    if [ "$vc" = 200 ]; then
      TOKEN_OK=yes
      say "minted token via Gitea API fallback"
    fi
  fi
fi

if [ "$TOKEN_OK" != yes ]; then
  halt "could not mint/verify a Gitea API token without echoing secrets"
fi

say "token file: $GITEA_TOKEN_FILE"
say "token sha256 prefix: $(sha256sum "$GITEA_TOKEN_FILE" 2>/dev/null | cut -c1-12 || echo '?')"

CFG="$TMPD/gitea.cfg"
make_cfg_from_file "$GITEA_TOKEN_FILE" "$CFG"

# ===================== [D2] ensure repo =====================
hr "CD2 ensure Gitea repo $OWNER/$REPO"
REPO_URL="$GITEA_DIRECT/api/v1/repos/$OWNER/$REPO"
rc="$(hdr_code "$REPO_URL" "$CFG")"

if [ "$rc" = 403 ]; then
  say "repo probe got 403; retrying with all-scope token"
  if mint_with_scopes "all"; then
    install_minted
    make_cfg_from_file "$GITEA_TOKEN_FILE" "$CFG"
    rc="$(hdr_code "$REPO_URL" "$CFG")"
  fi
fi

if [ "$rc" = 200 ]; then
  say "repo already exists"
elif [ "$rc" = 404 ]; then
  body='{"name":"aether-ci-proof","private":true,"auto_init":true,"default_branch":"main"}'
  cc="$(hdr_req POST "$GITEA_DIRECT/api/v1/user/repos" "$CFG" "$body" "$TMPD/repo.json")"
  if [ "$cc" = 403 ] || [ "$cc" = 401 ]; then
    say "repo create got http=$cc; retrying with all-scope token"
    if mint_with_scopes "all"; then
      install_minted
      make_cfg_from_file "$GITEA_TOKEN_FILE" "$CFG"
      cc="$(hdr_req POST "$GITEA_DIRECT/api/v1/user/repos" "$CFG" "$body" "$TMPD/repo.json")"
    fi
  fi
  if [ "$cc" = 200 ] || [ "$cc" = 201 ] || [ "$cc" = 409 ]; then
    say "repo created/already present (http=$cc)"
  else
    say "repo create response head: $(head -c 200 "$TMPD/repo.json" 2>/dev/null || true)"
    halt "could not create repo (http=$cc)"
  fi
else
  say "repo probe http=$rc"
  halt "unexpected repo probe status"
fi

# ===================== [D3] write .woodpecker.yml via Contents API =====================
hr "CD3 write .woodpecker.yml into repo (no git push, no credential helper)"
YML="$TMPD/woodpecker.yml"
cat > "$YML" <<'YMLEOF'
# Aether Brick 12 CI steel-thread proof. Free/open-source only.
# Steps use the already-cached alpine image; clone is performed by Woodpecker.
steps:
  - name: greet
    image: docker.io/library/alpine:latest
    commands:
      - echo "AETHER CI PROOF $(date -u +%FT%TZ)"
      - uname -a
      - head -2 /etc/os-release
  - name: selfcheck
    image: docker.io/library/alpine:latest
    commands:
      - test -f .woodpecker.yml && echo "pipeline file present in clone"
      - ls -la
YMLEOF

B64="$(base64 -w0 "$YML")"
CONT_URL="$REPO_URL/contents/.woodpecker.yml"
FILE_OK=no
attempt=0

while [ "$attempt" -lt 3 ]; do
  attempt=$((attempt + 1))
  gc="$(hdr_req GET "$CONT_URL?ref=main" "$CFG" "" "$TMPD/cont.json")"
  SHA=""
  if [ "$gc" = 200 ]; then
    SHA="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d.get("content") or {}; print(c.get("sha") or "")' "$TMPD/cont.json" 2>/dev/null || true)"
    SHA="$(norm "$SHA")"
  fi

  if [ -n "$SHA" ]; then
    body="$(python3 -c 'import json,sys; print(json.dumps({"content":sys.argv[1],"branch":"main","message":"Update Aether CI proof pipeline","sha":sys.argv[2]}))' "$B64" "$SHA")"
  else
    body="$(python3 -c 'import json,sys; print(json.dumps({"content":sys.argv[1],"branch":"main","message":"Add Aether CI proof pipeline"}))' "$B64")"
  fi

  pc="$(hdr_req PUT "$CONT_URL" "$CFG" "$body" "$TMPD/put.json")"
  if [ "$pc" = 200 ] || [ "$pc" = 201 ]; then
    FILE_OK=yes
    break
  fi
  if [ "$pc" = 409 ] && [ -z "$SHA" ]; then
    continue
  fi
  if [ "$pc" = 422 ] && [ -z "$SHA" ]; then
    continue
  fi
  say "contents PUT http=$pc response head: $(head -c 200 "$TMPD/put.json" 2>/dev/null || true)"
  halt "could not write .woodpecker.yml"
done

if [ "$FILE_OK" != yes ]; then
  halt "could not confirm .woodpecker.yml write"
fi

vc="$(hdr_code "$CONT_URL?ref=main" "$CFG")"
if [ "$vc" != 200 ]; then
  halt "pipeline file not readable after write (http=$vc)"
fi
say "OK .woodpecker.yml present in $OWNER/$REPO on branch main"

# ===================== [D4] Woodpecker sanitized diagnosis =====================
hr "CD4 Woodpecker server/agent sanitized diagnosis"
say_env woodpecker-server
say_env woodpecker-agent

say "--- server ports ---"
podman port woodpecker-server 2>/dev/null | sed 's/^/    /' || say "    (no ports / container absent)"

say "--- agent mounts (paths only) ---"
podman inspect woodpecker-agent --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{println}}{{end}}' 2>/dev/null | sed 's/^/    /' || say "    (none)"

GRPC_ADDR="$(get_env_val woodpecker-server WOODPECKER_GRPC_ADDR)"
GRPC_PORT="$(printf '%s' "$GRPC_ADDR" | awk -F: '{print $NF}')"
case "$GRPC_PORT" in
  ''|*[!0-9]*) GRPC_PORT=9000 ;;
esac
say "server WOODPECKER_GRPC_ADDR=${GRPC_ADDR:-unset} inferred_port=$GRPC_PORT"

AGENT_SERVER="$(get_env_val woodpecker-agent WOODPECKER_SERVER)"
say "agent WOODPECKER_SERVER=${AGENT_SERVER:-unset}"
AGENT_SERVER_HINT="unknown"
case "$AGENT_SERVER" in
  '') AGENT_SERVER_HINT="missing" ;;
  *http*|*:8000*) AGENT_SERVER_HINT="suspect-http-or-8000" ;;
  *:9000*) AGENT_SERVER_HINT="looks-grpc-9000" ;;
  *) AGENT_SERVER_HINT="check-manually" ;;
esac
say "agent server hint: $AGENT_SERVER_HINT"

SRV_IP="$(podman inspect woodpecker-server --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')"
SRV_IP="$(norm "$SRV_IP")"
say "server aether IP=${SRV_IP:-none}"
TCP_OK=no
if [ -n "$SRV_IP" ]; then
  if timeout 3 bash -c "exec 3<>/dev/tcp/$SRV_IP/$GRPC_PORT" 2>/dev/null; then
    TCP_OK=yes
    say "TCP reachability to $SRV_IP:$GRPC_PORT = OK"
  else
    say "TCP reachability to $SRV_IP:$GRPC_PORT = FAIL"
  fi
else
  say "TCP reachability skipped (no server IP)"
fi

say "--- server error/fatal/panic count (last 300 lines) ---"
say "    $(err_count woodpecker-server)"
say "--- agent error/fatal/panic count (last 300 lines) ---"
say "    $(err_count woodpecker-agent)"

say "--- sanitized server log excerpt ---"
log_sanitize woodpecker-server
say "--- sanitized agent log excerpt ---"
log_sanitize woodpecker-agent

WP_TOKEN_PRESENT=no
if [ -f "$WP_TOKEN_FILE" ]; then
  WP_TOKEN_PRESENT=yes
fi

# ===================== [D5] ledger =====================
hr "CD5 ledger"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261031-CD-gitea-ci-bootstrap-and-woodpecker-diagnosis | GATE=PARTIAL | %s: securely minted/stored Gitea CI token (0600, no echo), ensured private repo %s/%s, wrote .woodpecker.yml via Contents API. Woodpecker diagnosis: agent_tcp=%s agent_server_hint=%s grpc_port=%s wp_token_present=%s. No Woodpecker mutation, no pull, no secret echo. Next: manual WP repo activation + API token, then CE pipeline proof. |\n' \
    "$(date +%F)" "$TOKEN" "$OWNER" "$REPO" "$TCP_OK" "$AGENT_SERVER_HINT" "$GRPC_PORT" "$WP_TOKEN_PRESENT" >> "$IDX"
  say "CD ledger row appended."
else
  say "CD row already present (guard suppressed)."
fi

# ===================== [D6] result + manual next =====================
hr "CD6 result"
say "[CD RESULT] GITEA BOOTSTRAP OK: token=$GITEA_TOKEN_FILE repo=$OWNER/$REPO pipeline=.woodpecker.yml"
say "[CD RESULT] WOODPECKER DIAG: agent_tcp=$TCP_OK agent_server_hint=$AGENT_SERVER_HINT grpc_port=$GRPC_PORT wp_token_present=$WP_TOKEN_PRESENT"
if [ "$WP_TOKEN_PRESENT" = yes ]; then
  say "[CD RESULT] Woodpecker token file exists; CE can verify agents/repo/pipeline after activation."
else
  say "[CD RESULT] Woodpecker token file missing; one manual UI step is required."
fi

hr "CD7 manual Woodpecker activation (do NOT paste token into chat)"
cat <<SNIP
  1) Open Woodpecker UI:
       http://127.0.0.1:8000
     or, if your browser resolves .aether.local:
       http://woodpecker.aether.local

  2) Sign in with Gitea user:
       $OWNER

  3) Repositories -> enable:
       $OWNER/$REPO

  4) Create a Woodpecker API token in user settings, then store it 0600 at:
       $WP_TOKEN_FILE

  5) Verify locally without pasting the token:
SNIP

cat <<SNIP
       WF="$WP_TOKEN_FILE"
       CFG="\$(mktemp)"
       umask 077
       {
         printf 'header = "Authorization: Bearer '
         tr -d '\\n' < "\$WF"
         printf '"\\n'
       } > "\$CFG"
       curl -s --config "\$CFG" -o /dev/null -w 'agents_http=%{http_code}\\n' http://127.0.0.1:8000/api/agents
       curl -s --config "\$CFG" -o /dev/null -w 'repo_http=%{http_code}\\n' "http://127.0.0.1:8000/api/repos/$OWNER/$REPO"
       rm -f "\$CFG"
SNIP

say "[RESULT] CD COMPLETE — Gitea CI bootstrap done; Woodpecker diagnosed; manual WP activation/token remains before CE pipeline proof."
exit 0
