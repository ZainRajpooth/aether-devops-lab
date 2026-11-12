#!/usr/bin/env bash
# 20261030-AV — heal AU's unbound TMPD variable defect and rerun LiteLLM brick 6.
# Root cause:
#   AU referenced $TMPD in CONFIG_DESIRED_TMP before TMPD was assigned.
#   With set -u, this aborts before side effects.
# Heal:
#   1) patch AU candidate by moving TMPD assignment earlier;
#   2) remove unused CONFIG_DESIRED_TMP line;
#   3) bash -n candidate before install;
#   4) append guarded correction ledger row;
#   5) rerun patched AU;
#   6) require litellm-brick6-v1 sentinel before success.
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
# Hard rules:
#   - multi-line if/then/fi only
#   - bash -n mandatory before run
#   - no heredoc inside $( )
#   - no backticks
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
FU="$CD/20261030-AU-litellm-brick6.sh"
FU_BAK="$FU.pre-AV.bak"

TOKEN="au-tmpd-unbound-variable-defect"
AU_TOKEN="litellm-brick6-v1"

TMPD="$(mktemp -d)"
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

if [ ! -f "$FU" ]; then
  halt "missing AU script: $FU"
fi

# ===================== [V0] prepare patched AU candidate =====================
say "=== [V0] prepare patched AU candidate ==="
CAND="$TMPD/au.candidate"
PY="$TMPD/patch_au.py"

cp -p "$FU" "$CAND" || halt "could not copy AU to candidate"

cat > "$PY" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

out = []
tmpd_line = None

for line in lines:
    # Remove the bad unused variable assignment.
    if line.startswith("CONFIG_DESIRED_TMP="):
        continue

    # Remove existing TMPD assignment from its late position.
    if line.strip() == 'TMPD="$(mktemp -d)"':
        tmpd_line = line
        continue

    out.append(line)

if tmpd_line is None:
    tmpd_line = 'TMPD="$(mktemp -d)"\n'

# Insert TMPD immediately after the first set -uo pipefail line.
insert_idx = 0
for i, line in enumerate(out):
    if line.startswith("set -uo pipefail"):
        insert_idx = i + 1
        break

out.insert(insert_idx, tmpd_line)

p.write_text("".join(out), encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "AU patcher failed on candidate; original AU untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched AU candidate failed bash -n; original AU untouched"
fi

chmod +x "$CAND" 2>/dev/null || true
say "[V0] candidate patched; bash -n OK"

# ===================== [V1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[V1] dry-run diff current AU -> patched candidate:"
  diff -u "$FU" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no AU write, no ledger row, no AU rerun."
  exit 0
fi

# ===================== [V2] install patched AU =====================
say "=== [V2] install patched AU ==="

if [ ! -f "$FU_BAK" ]; then
  cp -p "$FU" "$FU_BAK"
  say "[V2] AU backup -> $FU_BAK"
fi

if ! install -D -m 755 "$CAND" "$FU"; then
  halt "could not install patched AU"
fi

if ! bash -n "$FU"; then
  cp -p "$FU_BAK" "$FU" 2>/dev/null || true
  halt "installed patched AU failed bash -n; restored backup"
fi

say "[V2] installed patched AU -> $FU"

# ===================== [V3] guarded correction ledger row =====================
say "=== [V3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AU failed before side effects because CONFIG_DESIRED_TMP referenced $TMPD before TMPD was assigned. AV moves TMPD assignment earlier and removes the unused CONFIG_DESIRED_TMP line, then reruns patched AU for LiteLLM brick 6. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[V3] AU TMPD correction row appended."
else
  say "[V3] AU TMPD correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[V3] suppression proof: correction sentinel present." || say "[V3] WARNING: correction sentinel missing."

# ===================== [V4] rerun patched AU =====================
say "=== [V4] rerun patched AU ==="
bash "$FU"
AU_RC=$?
say "[V4] AU rc=$AU_RC"

if ! grep -qF "$AU_TOKEN" "$IDX" 2>/dev/null; then
  say "[V4] LiteLLM promotion sentinel missing; inspect AU output above."
  halt "patched AU did not produce litellm-brick6-v1"
fi

say "[V4] LiteLLM promotion sentinel present."
say "[RESULT] AU TMPD DEFECT HEALED + LITELLM BRICK 6 GREEN — patched AU completed; next: build n8n or rag pilot; still no Ollama/OpenWebUI/chat-model."
exit 0
