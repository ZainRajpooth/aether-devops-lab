#!/usr/bin/env bash
# 20261029-AF — heal AE literal "$host" label defect, then rerun AE.
# Root cause: AE contained:
#   say "=== [E3] container->$host reachability ..."
# Under set -u, Bash expanded $host and crashed before [E3].
# This patch replaces that literal label with:
#   say "=== [E3] container->host reachability ..."
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks; no sudo.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
AE="$CD/20261029-AE-litellm-path-probe-netavark-fix.sh"
AE_BAK="$AE.pre-AF.bak"
TOKEN="ae-dollar-host-label-defect"
RESOLVED_TOKEN="litellm-path-resolved-v2"

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

for c in bash cp diff grep install python3 sed; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

if [ ! -f "$AE" ]; then
  halt "missing AE script: $AE"
fi

# ===================== [F0] build candidate =====================
say "=== [F0] prepare patched AE candidate ==="
CAND="$TMPD/ae.candidate"
PY="$TMPD/patch_ae.py"

cp -p "$AE" "$CAND" || halt "could not copy AE to candidate"

cat > "$PY" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

bad = 'say "=== [E3] container->$host reachability (throwaway alpine on $NET) ==="'
good = 'say "=== [E3] container->host reachability (throwaway alpine on $NET) ==="'

if good in s and bad not in s:
    sys.exit(0)

if bad not in s:
    sys.stderr.write("missing bad AE anchor\n")
    sys.exit(2)

s2 = s.replace(bad, good, 1)
p.write_text(s2, encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "AE patcher failed on candidate; original AE untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched AE candidate failed bash -n; original AE untouched"
fi

say "[F0] candidate patched; bash -n OK"

# ===================== [F1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[F1] dry-run diff current AE -> patched candidate:"
  diff -u "$AE" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no AE write, no ledger row, no AE rerun."
  exit 0
fi

# ===================== [F2] install patched AE =====================
say "=== [F2] install patched AE ==="
if [ ! -f "$AE_BAK" ]; then
  cp -p "$AE" "$AE_BAK"
  say "[F2] AE backup -> $AE_BAK"
fi

if ! cp -p "$CAND" "$AE"; then
  halt "could not install patched AE"
fi

if ! bash -n "$AE"; then
  cp -p "$AE_BAK" "$AE" 2>/dev/null || true
  halt "installed patched AE failed bash -n; restored backup"
fi

say "[F2] installed patched AE -> $AE"

# ===================== [F3] guarded correction ledger row =====================
say "=== [F3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $TOKEN | APPEND-ONLY | AE parsed netavark successfully but crashed before [E3] because a human-readable label contained unescaped '$host' under set -u. Gate held: no container run, no rebind, no mutation. AF replaces the label with literal 'container->host' and reruns AE. |" >> "$IDX"
  say "[F3] AE label correction row appended."
else
  say "[F3] AE label correction row already present."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[F3] suppression proof: correction sentinel present." || say "[F3] WARNING: correction sentinel missing."

# ===================== [F4] rerun patched AE =====================
say "=== [F4] rerun patched AE ==="
bash "$AE"
AERC=$?
if [ "$AERC" != 0 ]; then
  halt "patched AE returned nonzero rc=$AERC"
fi

if grep -qF "$RESOLVED_TOKEN" "$IDX" 2>/dev/null; then
  say "[F4] AE resolved sentinel present."
else
  halt "patched AE did not produce litellm-path-resolved-v2; inspect AE output above."
fi

say "[RESULT] AE LABEL HEAL COMPLETE — LiteLLM path probe can now run past [E3]; next brick uses the measured UPSTREAM_URL emitted by AE."
exit 0
