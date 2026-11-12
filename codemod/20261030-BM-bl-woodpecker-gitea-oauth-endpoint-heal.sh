#!/usr/bin/env bash
# 20261030-BM — heal BL Woodpecker brick 10A:
#   BL failed at Gitea OAuth app preparation with:
#     [L4] OAuth state=list-unavailable:404
#   Cause:
#     BL used /api/v1/applications/oauth2.
#     Gitea user OAuth2 endpoint is /api/v1/user/applications/oauth2.
#   BM replaces ensure_gitea_oauth_app() with a robust endpoint-aware implementation:
#     - tries /api/v1/user/applications/oauth2 first
#     - retains fallbacks for alternate Gitea deployments
#     - reuses existing OAuth app if client_id already stored
#     - deletes stale app by name before recreating
#     - stores client/secret in woodpecker.env without echoing values
#   Then BM installs patched BL, appends a guarded correction ledger row, reruns BL,
#   and requires BL success sentinel before declaring green.
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
#   - --check is pure
# Hard rules:
#   - multi-line if/then/fi only
#   - bash -n mandatory before run
#   - no heredoc inside $( )
#   - no backticks
set -uo pipefail

TMPD="$(mktemp -d)"

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
FL="$CD/20261030-BL-woodpecker-brick10.sh"
FL_BAK="$FL.pre-BM.bak"

TOKEN="bm-bl-woodpecker-gitea-oauth-endpoint-404-defect"
BL_TOKEN="bl-woodpecker-brick10-green-v1"

cleanup(){
  rm -rf "$TMPD" 2>/dev/null || true
}
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
norm(){
  local s="${1:-}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}
halt(){
  printf '[HALT] %s\n' "$*" >&2
  exit 0
}
need_cmd(){
  if ! command -v "$1" >/dev/null 2>&1; then
    halt "missing required command: $1"
  fi
}

for c in bash python3 cp diff grep install chmod; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

if [ ! -f "$FL" ]; then
  halt "missing BL script: $FL"
fi

# ===================== [M0] prepare patched BL candidate =====================
say "=== [M0] prepare patched BL candidate ==="
CAND="$TMPD/bl.candidate"
PY="$TMPD/patch_bl.py"

cp -p "$FL" "$CAND" || halt "could not copy BL to candidate"

cat > "$PY" <<'PYEOF'
import sys
import pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

start_marker = "ensure_gitea_oauth_app(){"
patch_marker = "list_endpoints=("

if start_marker not in t:
    sys.stderr.write("missing anchor: ensure_gitea_oauth_app(){\n")
    sys.exit(2)

if patch_marker in t:
    if t != orig:
        p.write_text(t, encoding="utf-8")
    sys.exit(0)

lines = t.splitlines(keepends=True)
start = None
for i, ln in enumerate(lines):
    if ln.rstrip("\n") == start_marker:
        start = i
        break

if start is None:
    sys.stderr.write("missing anchor line: ensure_gitea_oauth_app(){\n")
    sys.exit(2)

end = None
for j in range(start + 1, len(lines)):
    if lines[j].rstrip("\n") == "}":
        end = j
        break

if end is None:
    sys.stderr.write("missing anchor: ensure_gitea_oauth_app close brace\n")
    sys.exit(2)

new_func = r"""ensure_gitea_oauth_app(){
  if ! setup_gitea_netrc; then
    OAUTH_STATE="missing-gitea-creds"
    return 1
  fi

  local client secret list_code id del_code create_code list_base ep dep code
  local -a list_endpoints delete_endpoints create_endpoints

  client="$(read_env_value WOODPECKER_GITEA_CLIENT)"
  secret="$(read_env_value WOODPECKER_GITEA_SECRET)"

  list_endpoints=(
    "/api/v1/user/applications/oauth2"
    "/api/v1/applications/oauth2"
    "/api/v1/admin/oauth2/apps"
  )

  list_base=""
  list_code="000"
  for ep in "${list_endpoints[@]}"; do
    : > "$TMPD/oauth-list.out"
    code="$(curl -s -o "$TMPD/oauth-list.out" -w '%{http_code}' --max-time 15 --netrc-file "$TMPD/gitea-netrc" "http://127.0.0.1:3001$ep" 2>/dev/null || true)"
    code="$(norm "$code")"
    list_code="$code"
    if [ "$code" = 200 ] && grep -Eq '^[[:space:]]*(\[|\{)' "$TMPD/oauth-list.out" 2>/dev/null; then
      list_base="$ep"
      break
    fi
  done

  if [ -z "$list_base" ]; then
    if [ -n "$client" ] && [ -n "$secret" ]; then
      OAUTH_STATE="assumed-existing-list-unavailable:$list_code"
      say "[L4] Gitea OAuth list unavailable ($list_code); reusing existing client/secret from env"
      return 0
    fi
    OAUTH_STATE="list-unavailable:$list_code"
    return 1
  fi

  if [ -n "$client" ] && [ -n "$secret" ]; then
    id="$(python3 "$TMPD/oauth_find.py" client "$client" "$TMPD/oauth-list.out" 2>/dev/null || true)"
    id="$(norm "$id")"
    if [ -n "$id" ]; then
      OAUTH_STATE="existing-valid"
      say "[L4] Gitea OAuth app already exists for client_id (secret not echoed)"
      return 0
    fi
  fi

  id="$(python3 "$TMPD/oauth_find.py" name "$OAUTH_APP_NAME" "$TMPD/oauth-list.out" 2>/dev/null || true)"
  id="$(norm "$id")"
  if [ -n "$id" ]; then
    delete_endpoints=(
      "$list_base/$id"
      "/api/v1/user/applications/oauth2/$id"
      "/api/v1/applications/oauth2/$id"
    )
    del_code="000"
    for dep in "${delete_endpoints[@]}"; do
      : > "$TMPD/oauth-del.out"
      code="$(curl -s -o "$TMPD/oauth-del.out" -w '%{http_code}' --max-time 15 --netrc-file "$TMPD/gitea-netrc" -X DELETE "http://127.0.0.1:3001$dep" 2>/dev/null || true)"
      code="$(norm "$code")"
      del_code="$code"
      if [ "$code" = 200 ] || [ "$code" = 204 ]; then
        break
      fi
    done
    if [ "$del_code" != 200 ] && [ "$del_code" != 204 ]; then
      OAUTH_STATE="delete-existing-failed:$del_code"
      head -c 300 "$TMPD/oauth-del.out" 2>/dev/null | sed 's/^/    oauth-delete: /' || true
      return 1
    fi
    say "[L4] deleted stale Gitea OAuth app id=$id"
  fi

  printf '{"name":"%s","uris":["%s"],"confidential_client":true}' "$OAUTH_APP_NAME" "$OAUTH_REDIRECT" > "$TMPD/oauth-body.json"
  chmod 600 "$TMPD/oauth-body.json" 2>/dev/null || true

  create_endpoints=(
    "$list_base"
    "/api/v1/user/applications/oauth2"
    "/api/v1/applications/oauth2"
    "/api/v1/admin/oauth2/apps"
  )
  create_code="000"
  for ep in "${create_endpoints[@]}"; do
    : > "$TMPD/oauth-create.out"
    code="$(curl -s -o "$TMPD/oauth-create.out" -w '%{http_code}' --max-time 20 --netrc-file "$TMPD/gitea-netrc" -X POST "http://127.0.0.1:3001$ep" -H 'Content-Type: application/json' --data @"$TMPD/oauth-body.json" 2>/dev/null || true)"
    code="$(norm "$code")"
    create_code="$code"
    if [ "$code" = 200 ] || [ "$code" = 201 ]; then
      break
    fi
  done

  if [ "$create_code" != 200 ] && [ "$create_code" != 201 ]; then
    OAUTH_STATE="create-failed:$create_code"
    head -c 400 "$TMPD/oauth-create.out" 2>/dev/null | sed 's/^/    oauth-create: /' || true
    return 1
  fi

  python3 "$TMPD/oauth_parse.py" "$TMPD/oauth-create.out" > "$TMPD/oauth-parsed.txt" 2>/dev/null || true
  chmod 600 "$TMPD/oauth-parsed.txt" 2>/dev/null || true
  client="$(sed -n '1p' "$TMPD/oauth-parsed.txt" 2>/dev/null || true)"
  secret="$(sed -n '2p' "$TMPD/oauth-parsed.txt" 2>/dev/null || true)"
  client="$(norm "$client")"
  secret="$(norm "$secret")"

  if [ -z "$client" ] || [ -z "$secret" ]; then
    OAUTH_STATE="create-parse-failed"
    head -c 400 "$TMPD/oauth-create.out" 2>/dev/null | sed 's/^/    oauth-create: /' || true
    return 1
  fi

  set_env WOODPECKER_GITEA_CLIENT "$client"
  set_env WOODPECKER_GITEA_SECRET "$secret"
  OAUTH_STATE="created"
  say "[L4] created Gitea OAuth app name=$OAUTH_APP_NAME redirect=$OAUTH_REDIRECT base=$list_base (client/secret not echoed)"
  return 0
}
"""

lines[start:end+1] = [new_func]
t = "".join(lines)

if t != orig:
    p.write_text(t, encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "BL patcher failed on candidate; original BL untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched BL candidate failed bash -n; original BL untouched"
fi

chmod +x "$CAND" 2>/dev/null || true
say "[M0] candidate patched; bash -n OK"

# ===================== [M1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[M1] dry-run diff current BL -> patched candidate:"
  diff -u "$FL" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no BL write, no ledger row, no BL rerun."
  exit 0
fi

# ===================== [M2] install patched BL =====================
say "=== [M2] install patched BL ==="

if [ ! -f "$FL_BAK" ]; then
  cp -p "$FL" "$FL_BAK"
  say "[M2] BL backup -> $FL_BAK"
fi

if ! install -D -m 755 "$CAND" "$FL"; then
  halt "could not install patched BL"
fi

if ! bash -n "$FL"; then
  cp -p "$FL_BAK" "$FL" 2>/dev/null || true
  halt "installed patched BL failed bash -n; restored backup"
fi

say "[M2] installed patched BL -> $FL"

# ===================== [M3] guarded correction ledger row =====================
say "=== [M3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BL failed Woodpecker brick 10A at Gitea OAuth preparation because it used /api/v1/applications/oauth2, which returned 404. Gitea user OAuth2 application endpoint is /api/v1/user/applications/oauth2. BM replaces ensure_gitea_oauth_app() with endpoint-aware logic that tries the correct user endpoint first, retains fallbacks, reuses existing client_id when present, deletes stale same-name OAuth apps before recreation, and stores client/secret in woodpecker.env without echoing values. Prior BL side effects were limited to woodpecker.env generation; no Woodpecker containers, units, Postgres db, or green ledger row were created. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[M3] BL Gitea OAuth endpoint correction row appended."
else
  say "[M3] BL Gitea OAuth endpoint correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[M3] suppression proof: correction sentinel present." || say "[M3] WARNING: correction sentinel missing."

# ===================== [M4] rerun patched BL =====================
say "=== [M4] rerun patched BL ==="
bash "$FL"
BL_RC=$?
say "[M4] BL rc=$BL_RC"

if ! grep -qF "$BL_TOKEN" "$IDX" 2>/dev/null; then
  say "[M4] BL success sentinel missing; inspect BL output above."
  halt "patched BL did not produce bl-woodpecker-brick10-green-v1"
fi

say "[M4] BL success sentinel present."
say "[RESULT] BM HEALED + WOODPECKER BRICK 10A GREEN — patched BL completed; next: build traefik; still no Ollama/OpenWebUI/chat-model."
exit 0
