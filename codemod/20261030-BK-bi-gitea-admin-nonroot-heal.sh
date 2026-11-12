#!/usr/bin/env bash
# 20261030-BK — heal BI Gitea brick 9 admin CLI root-user defect.
# Evidence:
#   BI successfully created Postgres role/db and Gitea probe healthz passed.
#   Failure was:
#     Gitea is not supposed to be run as root.
#   Cause:
#     podman exec for `gitea admin user create` inherited container root user.
# Fix:
#   Discover Gitea service uid/gid from the running container, normally git:git or 1000:1000.
#   Run admin CLI with podman exec --user "$service_uid:$service_gid".
#   Briefly normalize /data ownership from the container root context before the CLI call.
#   Do NOT use GITEA_I_AM_BEING_UNSAFE_RUNNING_AS_ROOT.
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
FI="$CD/20261030-BI-gitea-brick9-cached-ref.sh"
FI_BAK="$FI.pre-BK.bak"

TOKEN="bk-bi-gitea-admin-cli-root-user-defect"
BI_TOKEN="bi-gitea-brick9-green-v1"

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

if [ ! -f "$FI" ]; then
  halt "missing BI script: $FI"
fi

# ===================== [K0] prepare patched BI candidate =====================
say "=== [K0] prepare patched BI candidate ==="
CAND="$TMPD/bi.candidate"
PY="$TMPD/patch_bi.py"

cp -p "$FI" "$CAND" || halt "could not copy BI to candidate"

cat > "$PY" <<'PYEOF'
import sys
import pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

old_prefix = "  if podman exec -i --env-file \"$adminenv\" \"$cname\" sh -c"

new_prefix = """  local exec_user="1000:1000"
  local git_uid git_gid
  git_uid="$(podman exec "$cname" sh -c 'id -u git 2>/dev/null || true' 2>/dev/null || true)"
  git_gid="$(podman exec "$cname" sh -c 'id -g git 2>/dev/null || true' 2>/dev/null || true)"
  git_uid="$(norm "$git_uid")"
  git_gid="$(norm "$git_gid")"
  case "$git_uid" in
    ''|*[!0-9]*)
      git_uid=1000
      ;;
  esac
  case "$git_gid" in
    ''|*[!0-9]*)
      git_gid=1000
      ;;
  esac
  exec_user="$git_uid:$git_gid"
  say "[admin] using exec user=$exec_user (non-root service user)"
  podman exec "$cname" sh -c "chown -R $exec_user /data >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  if podman exec -i --user "$exec_user" --env-file "$adminenv" "$cname" sh -c"""

if old_prefix in t:
    t = t.replace(old_prefix, new_prefix, 1)
elif "using exec user=$exec_user" not in t:
    sys.stderr.write("missing anchor: admin podman exec root-user line\n")
    sys.exit(2)

if t != orig:
    p.write_text(t, encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "BI patcher failed on candidate; original BI untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched BI candidate failed bash -n; original BI untouched"
fi

chmod +x "$CAND" 2>/dev/null || true
say "[K0] candidate patched; bash -n OK"

# ===================== [K1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[K1] dry-run diff current BI -> patched candidate:"
  diff -u "$FI" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no BI write, no ledger row, no BI rerun."
  exit 0
fi

# ===================== [K2] install patched BI =====================
say "=== [K2] install patched BI ==="

if [ ! -f "$FI_BAK" ]; then
  cp -p "$FI" "$FI_BAK"
  say "[K2] BI backup -> $FI_BAK"
fi

if ! install -D -m 755 "$CAND" "$FI"; then
  halt "could not install patched BI"
fi

if ! bash -n "$FI"; then
  cp -p "$FI_BAK" "$FI" 2>/dev/null || true
  halt "installed patched BI failed bash -n; restored backup"
fi

say "[K2] installed patched BI -> $FI"

# ===================== [K3] guarded correction ledger row =====================
say "=== [K3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BI passed Postgres creation and Gitea probe healthz, but failed admin user creation because podman exec inherited the container root user and Gitea CLI refuses root. BK patches BI to discover the Gitea service uid/gid from the running container and run `gitea admin user create` with podman exec --user, with a brief root-context chown of /data to that service user. It does not use GITEA_I_AM_BEING_UNSAFE_RUNNING_AS_ROOT. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[K3] BI admin CLI root-user correction row appended."
else
  say "[K3] BI admin CLI root-user correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[K3] suppression proof: correction sentinel present." || say "[K3] WARNING: correction sentinel missing."

# ===================== [K4] rerun patched BI =====================
say "=== [K4] rerun patched BI ==="
bash "$FI"
BI_RC=$?
say "[K4] BI rc=$BI_RC"

if ! grep -qF "$BI_TOKEN" "$IDX" 2>/dev/null; then
  say "[K4] BI success sentinel missing; inspect BI output above."
  halt "patched BI did not produce bi-gitea-brick9-green-v1"
fi

say "[K4] BI success sentinel present."
say "[RESULT] BK HEALED + GITEA BRICK 9 GREEN — patched BI completed; next: build woodpecker; still no Ollama/OpenWebUI/chat-model."
exit 0
