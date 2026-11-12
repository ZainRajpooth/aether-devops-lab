#!/usr/bin/env bash
# 20261031-CB — Brick 12 READ-ONLY integration discovery. Mutates NOTHING. Echoes NO secret.
# Maps the Gitea<->Woodpecker<->agent<->git-push surfaces CC (the pipeline proof) needs, so CC
# is precise instead of assumption-driven. Every probe is bounded; secrets are reduced to
# key-name + value-length (awk length, value never held in a bash var) or file path+size+hash-prefix.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks;
#             every `local` on its own line. --check is identical (CB is already pure).
set -uo pipefail

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
SEC="$A/secrets"
GITEA_ENV="$SEC/gitea.env"
WP_ENV="$SEC/woodpecker.env"
ALPINE="docker.io/library/alpine:latest"
NET="aether"
EDGE="http://127.0.0.1:8888"
GITEA_OWNER=""            # filled from gitea.env key name only if present
CANDIDATE_REPOS="aether-ci-proof ci-proof hello-aether test"
TOKEN_FILE_CANDIDATES="$SEC/gitea-api-token $SEC/gitea-token $SEC/gitea-admin-token $HOME/.config/gitea-token $HOME/.gitea-token"
WP_TOKEN_FILE_CANDIDATES="$SEC/woodpecker-token $SEC/wp-token $SEC/woodpecker-admin-token $HOME/.config/woodpecker/token"
SSH_DIR="$HOME/.ssh"
GIT_PLANNED_YML="$CD/planned-woodpecker.yml"   # written to /tmp-backed path? no: write under CD is a WRITE.
# CB must not write outside /tmp. Redirect the planned-yml to TMPD instead.
TMPD="$(mktemp -d)"
GIT_PLANNED_YML="$TMPD/planned-woodpecker.yml"

cleanup(){ rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n========== %s ==========\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
need_cmd(){ if ! command -v "$1" >/dev/null 2>&1; then printf '[HALT] missing command: %s\n' "$1" >&2; exit 0; fi; }

# value-length WITHOUT holding the value: awk prints length of the part after first '='
klen(){
  local f="$1"
  local k="$2"
  local n
  n="$(awk -F= -v key="$k" '$1==key{v=substr($0,index($0,"=")+1); print length(v); exit}' "$f" 2>/dev/null || true)"
  n="$(norm "$n")"
  if [ -z "$n" ]; then printf 'absent'; else printf 'present(len=%s)' "$n"; fi
}
# list secret-ish key NAMES present in an env file (names only, never values)
knames(){
  local f="$1"
  if [ ! -f "$f" ]; then printf '    (file missing: %s)\n' "$f"; return; fi
  printf '    file: %s (mode=%s)\n' "$f" "$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
  grep -oE '^[A-Z0-9_]+' "$f" 2>/dev/null | sort -u | sed 's/^/      key: /' || printf '      (no KEY= lines)\n'
}
# token FILE presence: path + size + sha256 prefix (contents NEVER printed)
tfile(){
  local f="$1"
  if [ -f "$f" ]; then
    printf '    PRESENT %s size=%s sha=%s…\n' "$f" "$(stat -c '%s' "$f" 2>/dev/null || echo '?')" "$(sha256sum "$f" 2>/dev/null | cut -c1-12 || echo '?')"
  else
    printf '    absent  %s\n' "$f"
  fi
}
code(){
  local url="$1"
  local host="${2:-}"
  local c
  if [ -n "$host" ]; then
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $host" "$url" 2>/dev/null || true)"
  else
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)"
  fi
  c="$(norm "$c")"; if [ -z "$c" ]; then c=000; fi; printf '%s' "$c"
}
body1(){
  # trimmed, NON-secret body for version/health endpoints only
  local url="$1"
  local host="${2:-}"
  local b
  if [ -n "$host" ]; then
    b="$(curl -s --max-time 8 -H "Host: $host" "$url" 2>/dev/null || true)"
  else
    b="$(curl -s --max-time 8 "$url" 2>/dev/null || true)"
  fi
  b="$(norm "$b")"
  printf '%s' "${b:0:120}"
}
img_cached(){
  local ref="$1"
  if podman image exists "$ref" 2>/dev/null; then printf 'CACHED'; else printf 'MISSING(would pull)'; fi
}
safe_marker(){
  # boolean presence of a safe phrase in container logs; prints NO raw line
  local cont="$1"
  local pat="$2"
  if podman logs --tail 300 "$cont" 2>/dev/null | grep -Eiq "$pat"; then printf 'yes'; else printf 'no'; fi
}
err_count(){
  local cont="$1"
  podman logs --tail 300 "$cont" 2>/dev/null | grep -Eic 'error|fatal|panic' || printf '0'
}

for c in bash podman curl awk sed grep stat sha256sum sort uniq head tr printf; do
  need_cmd "$c"
done

hr "CB0 environment + env-file key inventory (names + lengths only)"
say "uid=$(id -u) user=$(id -un) net=$NET edge=$EDGE"
say "gitea.env:"; knames "$GITEA_ENV"
say "woodpecker.env:"; knames "$WP_ENV"
# resolve owner name only if the key exists (value length checked, value NOT printed; owner is
# a username, low-sensitivity, but we still only print it if the key is present and non-empty)
if [ -f "$GITEA_ENV" ]; then
  OWNER_LEN="$(awk -F= '$1=="GITEA_ADMIN_USER"{v=substr($0,index($0,"=")+1); print length(v); exit}' "$GITEA_ENV" 2>/dev/null || true)"
  OWNER_LEN="$(norm "$OWNER_LEN")"
  if [ -n "$OWNER_LEN" ] && [ "$OWNER_LEN" != 0 ]; then
    # safe to read the username (not a secret) for repo-path probing
    GITEA_OWNER="$(grep -m1 '^GITEA_ADMIN_USER=' "$GITEA_ENV" 2>/dev/null | cut -d= -f2- | tr -d ' \r' || true)"
    GITEA_OWNER="$(norm "$GITEA_OWNER")"
    say "gitea admin user (username, not a secret): ${GITEA_OWNER:-?}"
  else
    say "gitea admin user: key absent/empty"
  fi
fi

hr "CB1 Gitea forge reachability + token availability + candidate repo probe"
say "via edge  /api/v1 version : $(code "$EDGE/api/v1/version" gitea.aether.local)  body=$(body1 "$EDGE/api/v1/version" gitea.aether.local)"
say "via edge  /api/v1 settings: $(code "$EDGE/api/v1/settings" gitea.aether.local)  (code only; body not printed)"
say "direct    :3001 /api/v1/version: $(code http://127.0.0.1:3001/api/v1/version)"
say "gitea API token files (path+size+hash-prefix only):"
for f in $TOKEN_FILE_CANDIDATES; do tfile "$f"; done
say "gitea.env secret-ish keys (length only):"
for k in GITEA_ADMIN_PASSWORD GITEA_ADMIN_TOKEN GITEA_API_TOKEN; do say "  $k = $(klen "$GITEA_ENV" "$k")"; done
if [ -n "$GITEA_OWNER" ]; then
  say "candidate test repos (unauth public probe; 200=public-exists 404=absent/private 401=private-needs-auth):"
  for r in $CANDIDATE_REPOS; do
    say "  $GITEA_OWNER/$r -> $(code "$EDGE/api/v1/repos/$GITEA_OWNER/$r" gitea.aether.local)"
  done
else
  say "candidate repo probe: SKIPPED (no admin username resolvable without a token)"
fi

hr "CB2 Woodpecker server reachability + token + clone-image + forge connection (safe markers)"
say "via edge  /api/health        : $(code "$EDGE/api/health" woodpecker.aether.local)"
say "via edge  /api/version (if any): $(code "$EDGE/api/version" woodpecker.aether.local)"
say "direct    :8000 /api/health  : $(code http://127.0.0.1:8000/api/health)"
say "woodpecker API token files (path+size+hash-prefix only):"
for f in $WP_TOKEN_FILE_CANDIDATES; do tfile "$f"; done
say "woodpecker.env secret-ish keys (length only):"
for k in WOODPECKER_TOKEN WOODPECKER_ADMIN_TOKEN WOODPECKER_GITEA_SECRET WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET; do
  say "  $k = $(klen "$WP_ENV" "$k")"
done
# default clone image ref: an image reference is NOT a secret -> safe to print value
CLONE_IMG="$(grep -m1 '^WOODPECKER_GIT_CLONE_IMAGE=' "$WP_ENV" 2>/dev/null | cut -d= -f2- | tr -d ' \r' || true)"
CLONE_IMG="$(norm "$CLONE_IMG")"
if [ -z "$CLONE_IMG" ]; then
  CLONE_IMG="quay.io/woodpecker-ci/runner-git-clone:latest"   # common default; CB only CHECKS cache, never pulls
  say "clone image: not set in env; assuming default ref for cache-check = $CLONE_IMG"
else
  say "clone image (from env, value is an image ref not a secret): $CLONE_IMG"
fi
say "clone image cache status: $(img_cached "$CLONE_IMG")"
say "planned step image ($ALPINE) cache status: $(img_cached "$ALPINE")"
say "server->forge connected (safe marker, no raw line): $(safe_marker woodpecker-server 'gitea|forge|connected|oauth')"
say "server error/fatal/panic count (last 300 log lines): $(err_count woodpecker-server)"

hr "CB3 Woodpecker agent registration (safe markers only)"
say "agent container status: $(norm "$(podman inspect woodpecker-agent --format '{{.State.Status}}' 2>/dev/null || echo absent)")"
say "agent connected to server (safe marker): $(safe_marker woodpecker-agent 'connect|register|grpc|ready')"
say "agent error/fatal/panic count (last 300 log lines): $(err_count woodpecker-agent)"

hr "CB4 git push auth surfaces (filenames/helper-name only; NO key/token content)"
say "ssh dir listing (names only):"
ls -1 "$SSH_DIR" 2>/dev/null | sed 's/^/    /' || say "    (no ~/.ssh)"
say "ssh private keys present (filename only):"
for k in id_ed25519 id_rsa id_ecdsa; do
  if [ -f "$SSH_DIR/$k" ]; then say "    PRESENT $SSH_DIR/$k"; else say "    absent  $SSH_DIR/$k"; fi
done
say "git global credential.helper (name only): $(git config --global --get credential.helper 2>/dev/null || echo '(unset)')"
say "git global user.name/email (config, not secret): name=$(git config --global --get user.name 2>/dev/null || echo '?') email=$(git config --global --get user.email 2>/dev/null || echo '?')"
say "https token files (path+size+hash-prefix only):"
for f in "$SEC/gitea-git-token" "$SEC/git-token" "$HOME/.config/gitea/credentials"; do tfile "$f"; done

hr "CB5 planned .woodpecker.yml CC WILL push (printed here, NOT pushed; uses only cached alpine)"
cat > "$GIT_PLANNED_YML" <<'YMLEOF'
# Aether Brick 12 CI steel-thread proof. Free/open-source only. Steps use the already-cached
# alpine image (no network in steps); the repo clone is performed by Woodpecker's clone step.
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
sed 's/^/    | /' "$GIT_PLANNED_YML"

hr "CB6 PREREQUISITE CHECKLIST for CC (PASS / UNKNOWN / MISSING + no-secret remediation)"
# Gitea token: PASS if a token file exists OR an admin-password key is present (CC can mint a token)
GT=MISSING
for f in $TOKEN_FILE_CANDIDATES; do if [ -f "$f" ]; then GT=PASS; break; fi; done
if [ "$GT" != PASS ] && [ "$(klen "$GITEA_ENV" GITEA_ADMIN_PASSWORD)" != absent ] && [ "$(klen "$GITEA_ENV" GITEA_ADMIN_PASSWORD)" != "present(len=0)" ]; then
  GT="PASS(via admin-password mint)"
fi
WT=MISSING
for f in $WP_TOKEN_FILE_CANDIDATES; do if [ -f "$f" ]; then WT=PASS; break; fi; done
GA=$(safe_marker woodpecker-agent 'connect|register|grpc|ready')
CI=$(img_cached "$CLONE_IMG")
say "  Gitea API token .............. $GT"
say "  Woodpecker admin token ....... $WT"
say "  Agent registered ............. $GA"
say "  Clone image cached ........... $CI"
say "  Step image (alpine) cached ... $(img_cached "$ALPINE")"
say "  Gitea reachable via edge ..... $(code "$EDGE/api/v1/version" gitea.aether.local)"
say "  WP reachable via edge ........ $(code "$EDGE/api/health" woodpecker.aether.local)"
cat <<'REM'
  Remediation for any MISSING/UNKNOWN (NEVER paste a secret into chat):
   - Gitea token MISSING & no admin-password key:
       create a token in the Gitea UI (Settings->Applications, scopes: repo + admin:hook),
       then store it 0600 at:  $HOME/DevOps/aether/secrets/gitea-api-token
   - Woodpecker token MISSING:
       mint via the WP CLI/UI (admin), store 0600 at: $HOME/DevOps/aether/secrets/woodpecker-token
   - Clone image MISSING: that is FINE — CC will pull it ONCE, deliberately, and disclose it
       (free open-source image, no account, no cost). CB only reports; it never pulls.
   - Agent NOT registered: CC halts before pushing and prints the agent/server grpc diagnosis.
  If every line above is PASS/cached/200, CC is a clean green-light build (no surprises).
REM

hr "CB7 verdict"
READY=yes
[ "$GT" = MISSING ] && READY=no
[ "$WT" = MISSING ] && READY=no
[ "$GA" = no ] && READY=no
if [ "$READY" = yes ]; then
  say "[CB RESULT] INTEGRATION MAP READY — CC can build the pipeline proof without discovery gaps."
else
  say "[CB RESULT] INTEGRATION MAP INCOMPLETE — see CB6 MISSING lines; supply via files (no chat secrets), then rerun CB."
fi
say "[CB RESULT] read-only complete; no repo created, no webhook, no push, no pull, no secret echoed."
exit 0
