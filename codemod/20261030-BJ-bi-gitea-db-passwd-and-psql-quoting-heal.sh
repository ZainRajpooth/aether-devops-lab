#!/usr/bin/env bash
# 20261030-BJ — heal BI Gitea brick 9:
#   1) BI role.sql used psql :dbpass raw interpolation, causing PostgreSQL to parse the password
#      as an identifier. Correct form is :'dbpass' so psql emits a quoted SQL string literal.
#   2) BI generated GITEA_DB_PASSWORD for the heal script but did not map it into the Gitea
#      container env key GITEA__database__PASSWD. Without that, Gitea would fail DB auth next.
# BJ patches BI candidate, bash -n gates, installs patched BI, appends guarded correction row,
# reruns patched BI, and requires BI success sentinel before declaring green.
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
FI_BAK="$FI.pre-BJ.bak"

TOKEN="bj-bi-gitea-db-passwd-and-psql-quoting-defect"
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

# ===================== [J0] prepare patched BI candidate =====================
say "=== [J0] prepare patched BI candidate ==="
CAND="$TMPD/bi.candidate"
PY="$TMPD/patch_bi.py"

cp -p "$FI" "$CAND" || halt "could not copy BI to candidate"

cat > "$PY" <<'PYEOF'
import sys
import pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

# ---------------------------------------------------------------------------
# Fix 1: psql variable quoting.
# BI had:
#   format('... PASSWORD %L', '${DB_USER}', :dbpass)
# which interpolates the password as raw SQL text and makes PostgreSQL treat it
# as an identifier. Correct psql quoting is :'dbpass'.
# ---------------------------------------------------------------------------
old_quote = ", :dbpass)"
new_quote = ", :'dbpass')"

if old_quote in t:
    t = t.replace(old_quote, new_quote)
elif new_quote not in t:
    sys.stderr.write("missing anchor: psql :dbpass quoting\n")
    sys.exit(2)

# ---------------------------------------------------------------------------
# Fix 2: map the generated DB password into the Gitea container env key.
# Gitea Docker expects GITEA__database__PASSWD, not only custom GITEA_DB_PASSWORD.
# Insert immediately after BI validates DB_PASS/ADMIN_USER/ADMIN_PASS/ADMIN_EMAIL.
# ---------------------------------------------------------------------------
marker = 'set_env GITEA__database__PASSWD "$DB_PASS"'

if marker not in t:
    old_block = '''if [ -z "$DB_PASS" ] || [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ] || [ -z "$ADMIN_EMAIL" ]; then
  halt "could not read required values from $GITEA_ENV"
fi
'''

    new_block = old_block + '''set_env GITEA__database__PASSWD "$DB_PASS"
say "[I3] mapped DB password to GITEA__database__PASSWD (value not echoed)"
'''

    if old_block in t:
        t = t.replace(old_block, new_block, 1)
    else:
        sys.stderr.write("missing anchor: DB_PASS validation block\n")
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
say "[J0] candidate patched; bash -n OK"

# ===================== [J1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[J1] dry-run diff current BI -> patched candidate:"
  diff -u "$FI" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no BI write, no ledger row, no BI rerun."
  exit 0
fi

# ===================== [J2] install patched BI =====================
say "=== [J2] install patched BI ==="

if [ ! -f "$FI_BAK" ]; then
  cp -p "$FI" "$FI_BAK"
  say "[J2] BI backup -> $FI_BAK"
fi

if ! install -D -m 755 "$CAND" "$FI"; then
  halt "could not install patched BI"
fi

if ! bash -n "$FI"; then
  cp -p "$FI_BAK" "$FI" 2>/dev/null || true
  halt "installed patched BI failed bash -n; restored backup"
fi

say "[J2] installed patched BI -> $FI"

# ===================== [J3] guarded correction ledger row =====================
say "=== [J3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BI failed at Postgres role creation because psql variable :dbpass was interpolated unquoted into format(...%%L...), causing PostgreSQL to parse the password as an identifier. BI also omitted the required Gitea database password environment mapping GITEA__database__PASSWD, so the first Gitea start would have failed DB authentication after the Postgres role fix. BJ patches both and reruns BI. Prior BI side effects were limited to gitea.env, DNS guard, and correction ledger row; no Gitea container started and no Postgres role/db was created. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[J3] BI DB-passwd/psql-quoting correction row appended."
else
  say "[J3] BI DB-passwd/psql-quoting correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[J3] suppression proof: correction sentinel present." || say "[J3] WARNING: correction sentinel missing."

# ===================== [J4] rerun patched BI =====================
say "=== [J4] rerun patched BI ==="
bash "$FI"
BI_RC=$?
say "[J4] BI rc=$BI_RC"

if ! grep -qF "$BI_TOKEN" "$IDX" 2>/dev/null; then
  say "[J4] BI success sentinel missing; inspect BI output above."
  halt "patched BI did not produce bi-gitea-brick9-green-v1"
fi

say "[J4] BI success sentinel present."
say "[RESULT] BJ HEALED + GITEA BRICK 9 GREEN — patched BI completed; next: build woodpecker; still no Ollama/OpenWebUI/chat-model."
exit 0
