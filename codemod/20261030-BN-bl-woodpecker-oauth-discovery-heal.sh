#!/usr/bin/env bash
# 20261030-BN — heal BL/BM Woodpecker brick 10A Gitea OAuth endpoint discovery.
# Evidence:
#   BM failed with:
#     oauth-create: 404 page not found
#     [L4] OAuth state=create-failed:404
#   Cause:
#     BM still guessed OAuth2 application endpoints.
#   Fix:
#     Replace ensure_gitea_oauth_app() with OpenAPI/Swagger discovery:
#       - fetch /api/swagger/json, /api/v1/swagger.json, /api/swagger.json, /api/v1/openapi.json
#       - parse paths containing oauth2/application/apps
#       - derive list/create/delete paths using basePath/servers prefix
#       - fallback to known variants
#       - try both uris and redirect_uris payloads
#       - reuse existing client_id if present
#       - delete stale same-name OAuth app before recreation
#       - store client/secret in woodpecker.env without echoing values
#   Then BN installs patched BL, appends guarded correction row, reruns BL,
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
FL_BAK="$FL.pre-BN.bak"

TOKEN="bn-bl-woodpecker-gitea-oauth-discovery-defect"
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

# ===================== [N0] prepare patched BL candidate =====================
say "=== [N0] prepare patched BL candidate ==="
CAND="$TMPD/bl.candidate"
PY="$TMPD/patch_bl.py"

cp -p "$FL" "$CAND" || halt "could not copy BL to candidate"

cat > "$PY" <<'PATCHPY'
import sys
import pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

start_marker = "ensure_gitea_oauth_app(){"
patch_marker = "oauth_discover.py"

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

  local client secret list_base create_base del_code create_code code id ep dep template body done_create
  local -a list_candidates create_candidates delete_templates swagger_ep
  local sw_list sw_create sw_delete

  client="$(read_env_value WOODPECKER_GITEA_CLIENT)"
  secret="$(read_env_value WOODPECKER_GITEA_SECRET)"

  list_candidates=()
  create_candidates=()
  delete_templates=()
  swagger_ep=()

  for ep in /api/swagger/json /api/v1/swagger.json /api/swagger.json /api/v1/openapi.json; do
    : > "$TMPD/oauth-swagger.out"
    code="$(curl -s -o "$TMPD/oauth-swagger.out" -w '%{http_code}' --max-time 15 "http://127.0.0.1:3001$ep" 2>/dev/null || true)"
    code="$(norm "$code")"
    if [ "$code" = 200 ] && python3 -c 'import sys,json; json.load(open(sys.argv[1]))' "$TMPD/oauth-swagger.out" >/dev/null 2>&1; then
      swagger_ep+=("$ep")
      break
    fi
  done

  if [ "${#swagger_ep[@]}" -gt 0 ]; then
    cat > "$TMPD/oauth_discover.py" <<'PYEOF'
import sys, json
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

prefix = data.get("basePath", "")
if not prefix:
    servers = data.get("servers", [])
    if servers and isinstance(servers[0], dict):
        url = servers[0].get("url", "")
        if "://" in url:
            rest = url.split("://", 1)[1]
            if "/" in rest:
                prefix = "/" + rest.split("/", 1)[1]
        elif url.startswith("/"):
            prefix = url

prefix = prefix.rstrip("/")
paths = data.get("paths", {})
cands = []

def full(path):
    if not path:
        return ""
    if prefix and not path.startswith(prefix):
        return prefix + path
    return path

for path, item in paths.items():
    if not isinstance(item, dict):
        continue
    low = path.lower()
    if "oauth2" not in low and "oauth" not in low:
        continue
    if "application" not in low and "applications" not in low and "apps" not in low:
        continue
    methods = set(item.keys())
    score = 0
    if "user" in low:
        score += 20
    if "applications" in low:
        score += 8
    if "oauth2" in low:
        score += 6
    if "get" in methods:
        score += 3
    if "post" in methods:
        score += 4
    if "delete" in methods:
        score += 2
    cands.append((score, path, methods))

cands.sort(reverse=True)

list_path = ""
create_path = ""
delete_template = ""

for score, path, methods in cands:
    if not list_path and "get" in methods:
        list_path = path
    if not create_path and "post" in methods and "{" not in path:
        create_path = path
    if not delete_template and "delete" in methods and "{" in path:
        delete_template = path.replace("{client_id}", "{id}").replace("{application_id}", "{id}").replace("{appId}", "{id}")

if not delete_template and list_path:
    delete_template = list_path.rstrip("/") + "/{id}"

print(full(list_path))
print(full(create_path))
print(full(delete_template))
PYEOF

    python3 "$TMPD/oauth_discover.py" "$TMPD/oauth-swagger.out" > "$TMPD/oauth-discovered.txt" 2>/dev/null || true
    sw_list="$(sed -n '1p' "$TMPD/oauth-discovered.txt" 2>/dev/null || true)"
    sw_create="$(sed -n '2p' "$TMPD/oauth-discovered.txt" 2>/dev/null || true)"
    sw_delete="$(sed -n '3p' "$TMPD/oauth-discovered.txt" 2>/dev/null || true)"
    sw_list="$(norm "$sw_list")"
    sw_create="$(norm "$sw_create")"
    sw_delete="$(norm "$sw_delete")"

    if [ -n "$sw_list" ]; then
      list_candidates+=("$sw_list")
      say "[L4] swagger list path=$sw_list"
    fi
    if [ -n "$sw_create" ]; then
      create_candidates+=("$sw_create")
      say "[L4] swagger create path=$sw_create"
    fi
    if [ -n "$sw_delete" ]; then
      delete_templates+=("$sw_delete")
      say "[L4] swagger delete template=$sw_delete"
    fi
  else
    say "[L4] swagger discovery unavailable; using endpoint variants"
  fi

  list_candidates+=(
    "/api/v1/user/applications/oauth2"
    "/api/v1/user/oauth2/applications"
    "/api/v1/applications/oauth2"
    "/api/v1/oauth2/applications"
    "/api/v1/admin/oauth2/apps"
  )

  create_candidates+=(
    "/api/v1/user/applications/oauth2"
    "/api/v1/user/oauth2/applications"
    "/api/v1/applications/oauth2"
    "/api/v1/oauth2/applications"
    "/api/v1/admin/oauth2/apps"
  )

  delete_templates+=(
    "/api/v1/user/applications/oauth2/{id}"
    "/api/v1/user/oauth2/applications/{id}"
    "/api/v1/applications/oauth2/{id}"
    "/api/v1/oauth2/applications/{id}"
    "/api/v1/admin/oauth2/apps/{id}"
  )

  list_base=""
  for ep in "${list_candidates[@]}"; do
    : > "$TMPD/oauth-list.out"
    code="$(curl -s -o "$TMPD/oauth-list.out" -w '%{http_code}' --max-time 15 --netrc-file "$TMPD/gitea-netrc" "http://127.0.0.1:3001$ep" 2>/dev/null || true)"
    code="$(norm "$code")"
    if [ "$code" = 200 ] && grep -Eq '^[[:space:]]*(\[|\{)' "$TMPD/oauth-list.out" 2>/dev/null; then
      list_base="$ep"
      break
    fi
  done

  if [ -n "$list_base" ]; then
    say "[L4] Gitea OAuth list endpoint=$list_base"

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
      del_code="000"
      for template in "${delete_templates[@]}"; do
        case "$template" in
          *'{id}'*)
            dep="$(printf '%s' "$template" | sed "s/{id}/$id/g")"
            : > "$TMPD/oauth-del.out"
            code="$(curl -s -o "$TMPD/oauth-del.out" -w '%{http_code}' --max-time 15 --netrc-file "$TMPD/gitea-netrc" -X DELETE "http://127.0.0.1:3001$dep" 2>/dev/null || true)"
            code="$(norm "$code")"
            del_code="$code"
            if [ "$code" = 200 ] || [ "$code" = 204 ]; then
              break
            fi
            ;;
        esac
      done

      if [ "$del_code" != 200 ] && [ "$del_code" != 204 ]; then
        OAUTH_STATE="delete-existing-failed:$del_code"
        head -c 300 "$TMPD/oauth-del.out" 2>/dev/null | sed 's/^/    oauth-delete: /' || true
        return 1
      fi

      say "[L4] deleted stale Gitea OAuth app id=$id"
    fi
  else
    if [ -n "$client" ] && [ -n "$secret" ]; then
      OAUTH_STATE="assumed-existing-list-unavailable"
      say "[L4] Gitea OAuth list unavailable; reusing existing client/secret from env"
      return 0
    fi
    say "[L4] Gitea OAuth list unavailable; attempting create variants"
  fi

  printf '{"name":"%s","uris":["%s"],"confidential_client":true}' "$OAUTH_APP_NAME" "$OAUTH_REDIRECT" > "$TMPD/oauth-body-uris.json"
  printf '{"name":"%s","redirect_uris":["%s"],"confidential_client":true}' "$OAUTH_APP_NAME" "$OAUTH_REDIRECT" > "$TMPD/oauth-body-redirect-uris.json"
  chmod 600 "$TMPD/oauth-body-uris.json" 2>/dev/null || true
  chmod 600 "$TMPD/oauth-body-redirect-uris.json" 2>/dev/null || true

  create_base=""
  create_code="000"
  done_create=no

  for body in "$TMPD/oauth-body-uris.json" "$TMPD/oauth-body-redirect-uris.json"; do
    if [ "$done_create" = yes ]; then
      break
    fi

    for ep in "${create_candidates[@]}"; do
      : > "$TMPD/oauth-create.out"
      code="$(curl -s -o "$TMPD/oauth-create.out" -w '%{http_code}' --max-time 20 --netrc-file "$TMPD/gitea-netrc" -X POST "http://127.0.0.1:3001$ep" -H 'Content-Type: application/json' --data @"$body" 2>/dev/null || true)"
      code="$(norm "$code")"
      create_code="$code"

      if [ "$code" = 200 ] || [ "$code" = 201 ]; then
        create_base="$ep"
        done_create=yes
        break
      fi
    done
  done

  if [ -z "$create_base" ]; then
    OAUTH_STATE="create-failed:$create_code"
    head -c 500 "$TMPD/oauth-create.out" 2>/dev/null | sed 's/^/    oauth-create: /' || true
    return 1
  fi

  cat > "$TMPD/oauth_parse2.py" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

client = d.get("client_id") or d.get("clientId") or ""
secret = d.get("client_secret") or d.get("clientSecret") or ""

print(client)
print(secret)
PYEOF

  python3 "$TMPD/oauth_parse2.py" "$TMPD/oauth-create.out" > "$TMPD/oauth-parsed.txt" 2>/dev/null || true
  chmod 600 "$TMPD/oauth-parsed.txt" 2>/dev/null || true

  client="$(sed -n '1p' "$TMPD/oauth-parsed.txt" 2>/dev/null || true)"
  secret="$(sed -n '2p' "$TMPD/oauth-parsed.txt" 2>/dev/null || true)"
  client="$(norm "$client")"
  secret="$(norm "$secret")"

  if [ -z "$client" ] || [ -z "$secret" ]; then
    OAUTH_STATE="create-parse-failed"
    head -c 500 "$TMPD/oauth-create.out" 2>/dev/null | sed 's/^/    oauth-create: /' || true
    return 1
  fi

  set_env WOODPECKER_GITEA_CLIENT "$client"
  set_env WOODPECKER_GITEA_SECRET "$secret"
  OAUTH_STATE="created"
  say "[L4] created Gitea OAuth app name=$OAUTH_APP_NAME redirect=$OAUTH_REDIRECT base=$create_base (client/secret not echoed)"
  return 0
}
"""

lines[start:end+1] = [new_func]
t = "".join(lines)

if t != orig:
    p.write_text(t, encoding="utf-8")
PATCHPY

if ! python3 "$PY" "$CAND"; then
  halt "BL patcher failed on candidate; original BL untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched BL candidate failed bash -n; original BL untouched"
fi

chmod +x "$CAND" 2>/dev/null || true
say "[N0] candidate patched; bash -n OK"

# ===================== [N1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[N1] dry-run diff current BL -> patched candidate:"
  diff -u "$FL" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no BL write, no ledger row, no BL rerun."
  exit 0
fi

# ===================== [N2] install patched BL =====================
say "=== [N2] install patched BL ==="

if [ ! -f "$FL_BAK" ]; then
  cp -p "$FL" "$FL_BAK"
  say "[N2] BL backup -> $FL_BAK"
fi

if ! install -D -m 755 "$CAND" "$FL"; then
  halt "could not install patched BL"
fi

if ! bash -n "$FL"; then
  cp -p "$FL_BAK" "$FL" 2>/dev/null || true
  halt "installed patched BL failed bash -n; restored backup"
fi

say "[N2] installed patched BL -> $FL"

# ===================== [N3] guarded correction ledger row =====================
say "=== [N3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BM failed Woodpecker brick 10A because it still guessed Gitea OAuth2 application endpoints and received 404 page not found. BN replaces ensure_gitea_oauth_app() with OpenAPI/Swagger discovery: it fetches Gitea swagger/json metadata, derives basePath/servers prefix, extracts OAuth2 list/create/delete paths, falls back to known variants, and tries both uris and redirect_uris payload shapes. It reuses existing client_id when present, deletes stale same-name OAuth apps before recreation, and stores client/secret in woodpecker.env without echoing values. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[N3] BN OAuth discovery correction row appended."
else
  say "[N3] BN OAuth discovery correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[N3] suppression proof: correction sentinel present." || say "[N3] WARNING: correction sentinel missing."

# ===================== [N4] rerun patched BL =====================
say "=== [N4] rerun patched BL ==="
bash "$FL"
BL_RC=$?
say "[N4] BL rc=$BL_RC"

if ! grep -qF "$BL_TOKEN" "$IDX" 2>/dev/null; then
  say "[N4] BL success sentinel missing; inspect BL output above."
  halt "patched BL did not produce bl-woodpecker-brick10-green-v1"
fi

say "[N4] BL success sentinel present."
say "[RESULT] BN HEALED + WOODPECKER BRICK 10A GREEN — patched BL completed; next: build traefik; still no Ollama/OpenWebUI/chat-model."
exit 0
