#!/usr/bin/env bash
# 20261030-AZ — heal AY:
#   1) insert missing SFX="$$" before AY candidate naming;
#   2) replace risky N8N_HOST=127.0.0.1 with N8N_HOST=0.0.0.0;
#   3) bash -n gate before installing patched AY;
#   4) append guarded correction ledger row;
#   5) rerun patched AY;
#   6) require AY success sentinel before declaring green.
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

TMPD="$(mktemp -d)"

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
FY="$CD/20261030-AY-n8n-userfolder-heal.sh"
FY_BAK="$FY.pre-AZ.bak"

TOKEN="az-ay-sfx-unbound-n8n-host-defect"
AY_TOKEN="ay-n8n-userfolder-heal-green-v2"

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

if [ ! -f "$FY" ]; then
  halt "missing AY script: $FY"
fi

# ===================== [Z0] prepare patched AY candidate =====================
say "=== [Z0] prepare patched AY candidate ==="
CAND="$TMPD/ay.candidate"
PY="$TMPD/patch_ay.py"

cp -p "$FY" "$CAND" || halt "could not copy AY to candidate"

cat > "$PY" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
changed = False

# Insert SFX="$$" if absent.
if not any(line.strip().startswith("SFX=") for line in lines):
    inserted = False

    for i, line in enumerate(lines):
        if line.strip() == 'TMPD="$(mktemp -d)"':
            lines.insert(i + 1, 'SFX="$$"\n')
            inserted = True
            changed = True
            break

    if not inserted:
        for i, line in enumerate(lines):
            if line.startswith("set -uo pipefail"):
                lines.insert(i + 1, 'SFX="$$"\n')
                inserted = True
                changed = True
                break

    if not inserted:
        sys.stderr.write("missing AY insertion anchor for SFX\n")
        sys.exit(2)

# Replace risky container-local n8n host bind with all-interfaces bind.
out = []
for line in lines:
    if "-e N8N_HOST=127.0.0.1" in line:
        line = line.replace("-e N8N_HOST=127.0.0.1", "-e N8N_HOST=0.0.0.0")
        changed = True
    out.append(line)
lines = out

if changed:
    p.write_text("".join(lines), encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "AY patcher failed on candidate; original AY untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched AY candidate failed bash -n; original AY untouched"
fi

chmod +x "$CAND" 2>/dev/null || true
say "[Z0] candidate patched; bash -n OK"

# ===================== [Z1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[Z1] dry-run diff current AY -> patched candidate:"
  diff -u "$FY" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no AY write, no ledger row, no AY rerun."
  exit 0
fi

# ===================== [Z2] install patched AY =====================
say "=== [Z2] install patched AY ==="

if [ ! -f "$FY_BAK" ]; then
  cp -p "$FY" "$FY_BAK"
  say "[Z2] AY backup -> $FY_BAK"
fi

if ! install -D -m 755 "$CAND" "$FY"; then
  halt "could not install patched AY"
fi

if ! bash -n "$FY"; then
  cp -p "$FY_BAK" "$FY" 2>/dev/null || true
  halt "installed patched AY failed bash -n; restored backup"
fi

say "[Z2] installed patched AY -> $FY"

# ===================== [Z3] guarded correction ledger row =====================
say "=== [Z3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AY failed before candidate proof because SFX was referenced but never assigned. AZ inserts SFX="$$" and also replaces risky N8N_HOST=127.0.0.1 with N8N_HOST=0.0.0.0 so n8n can bind inside the container while host access remains loopback-only through published port. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[Z3] AY SFX/host correction row appended."
else
  say "[Z3] AY SFX/host correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[Z3] suppression proof: correction sentinel present." || say "[Z3] WARNING: correction sentinel missing."

# ===================== [Z4] rerun patched AY =====================
say "=== [Z4] rerun patched AY ==="
bash "$FY"
AY_RC=$?
say "[Z4] AY rc=$AY_RC"

if ! grep -qF "$AY_TOKEN" "$IDX" 2>/dev/null; then
  say "[Z4] AY success sentinel missing; inspect AY output above."
  halt "patched AY did not produce ay-n8n-userfolder-heal-green-v2"
fi

say "[Z4] AY success sentinel present."
say "[RESULT] AY HEALED + N8N BRICK 7 GREEN — patched AY completed; next: build grafana; still no Ollama/OpenWebUI/chat-model."
exit 0
