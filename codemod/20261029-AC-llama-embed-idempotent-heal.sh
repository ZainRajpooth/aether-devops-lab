#!/usr/bin/env bash
# 20261029-AC — heal AB idempotence and complete llama-embed brick 5.
# Root cause: AB B3 port precheck halted on rerun because the first aborted run had already started llama-embed.service.
# This script patches AB B3 to allow only an own-service listener on 127.0.0.1:8081, verified via MainPID/cmdline.
# Then it reruns patched AB to append the missing green ledger row and replay archive.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks; no sudo; no secret echo.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
AB="$CD/20261029-AB-llama-embed-brick.sh"
AB_BAK="$AB.pre-AC.bak"
TOKEN="ab-port-precheck-not-idempotent"
GREEN_TOKEN="llama-embed brick5 GREEN"

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

for c in bash cp diff grep python3 sed; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

if [ ! -f "$AB" ]; then
  halt "missing AB script: $AB"
fi

# ===================== [C0] build candidate patch =====================
say "=== [C0] prepare patched AB candidate ==="
CAND="$TMPD/ab.candidate"
PY="$TMPD/patch_ab.py"

cp -p "$AB" "$CAND" || halt "could not copy AB to candidate"

cat > "$PY" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

start_old = "# ===================== [B3] port occupancy precheck ====================="
start_new = "# ===================== [B3] port occupancy precheck (idempotent) ====================="
end_anchor = "if [ \"$DRY\" = 1 ]; then"

if start_new in s:
    sys.exit(0)

if start_old not in s:
    sys.stderr.write("missing old B3 anchor\n")
    sys.exit(2)

try:
    i = s.index(start_old)
    j = s.index(end_anchor, i)
except ValueError as e:
    sys.stderr.write("anchor error: %s\n" % e)
    sys.exit(2)

new_block = """# ===================== [B3] port occupancy precheck (idempotent) =====================
say "=== [B3] port $PORT occupancy precheck ==="
PRE_CODE="$(http_code "http://$HOST:$PORT/health")"
PRE_CODE="$(norm "$PRE_CODE")"
PRE_ACT="$(systemctl --user is-active llama-embed.service 2>/dev/null || true)"
PRE_ACT="$(norm "$PRE_ACT")"
if [ -z "$PRE_ACT" ]; then
  PRE_ACT=inactive
fi
PRE_PID="$(systemctl --user show llama-embed.service -p MainPID --value 2>/dev/null || true)"
PRE_PID="$(norm "$PRE_PID")"
PRE_CMD=""
if [ -n "$PRE_PID" ] && [ "$PRE_PID" != 0 ] && [ -r "/proc/$PRE_PID/cmdline" ]; then
  PRE_CMD="$(tr '\\0' ' ' < "/proc/$PRE_PID/cmdline" 2>/dev/null || true)"
  PRE_CMD="$(norm "$PRE_CMD")"
fi
PRE_OURS=no
if [ "$PRE_ACT" = active ] && [ -n "$PRE_CMD" ]; then
  PRE_OURS=yes
  for needle in llama-server "$MODEL" "--host $HOST" "--port $PORT" "$EMBED_FLAG"; do
    if ! printf '%s' "$PRE_CMD" | grep -qF -- "$needle"; then
      PRE_OURS=no
    fi
  done
fi
if [ "$PRE_CODE" = 200 ] && [ "$PRE_OURS" != yes ]; then
  halt "foreign service already answers on $HOST:$PORT/health; refuse to collide."
fi
if [ "$PRE_CODE" = 200 ] && [ "$PRE_OURS" = yes ]; then
  say "[B3] port $PORT already owned by llama-embed.service; continuing idempotently"
else
  say "[B3] port $PORT free or not healthy (pre-code=${PRE_CODE:-000}); will start/restart unit"
fi

"""

s2 = s[:i] + new_block + s[j:]
p.write_text(s2, encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "AB patcher failed on candidate; original AB untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched AB candidate failed bash -n; original AB untouched"
fi

say "[C0] candidate patched; bash -n OK"

# ===================== [C1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[C1] dry-run diff current AB -> patched candidate:"
  diff -u "$AB" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no AB write, no ledger row, no AB rerun."
  exit 0
fi

# ===================== [C2] install patched AB =====================
say "=== [C2] install patched AB ==="
if [ ! -f "$AB_BAK" ]; then
  cp -p "$AB" "$AB_BAK"
  say "[C2] AB backup -> $AB_BAK"
fi

if ! cp -p "$CAND" "$AB"; then
  halt "could not install patched AB"
fi

if ! bash -n "$AB"; then
  cp -p "$AB_BAK" "$AB" 2>/dev/null || true
  halt "installed patched AB failed bash -n; restored backup"
fi

say "[C2] installed patched AB -> $AB"

# ===================== [C3] guarded correction ledger row =====================
say "=== [C3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $TOKEN | APPEND-ONLY | AB B3 port precheck halted on idempotent rerun because the first aborted run had already started llama-embed.service and bound 127.0.0.1:8081/health. Patient was healthy; instrument lacked own-service detection. AC patches AB B3 to verify llama-embed.service MainPID/cmdline before allowing port 200. |" >> "$IDX"
  say "[C3] AB port-precheck correction row appended."
else
  say "[C3] AB port-precheck correction row already present."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[C3] suppression proof: correction sentinel present." || say "[C3] WARNING: correction sentinel missing."

# ===================== [C4] rerun patched AB =====================
say "=== [C4] rerun patched AB to complete brick 5 ==="
bash "$AB"
ABC=$?
if [ "$ABC" != 0 ]; then
  halt "patched AB returned nonzero rc=$ABC"
fi

if grep -qF "$GREEN_TOKEN" "$IDX" 2>/dev/null; then
  say "[C4] green sentinel present."
else
  halt "patched AB did not produce green ledger row; inspect AB output above."
fi

say "[RESULT] LLAMA-EMBED BRICK 5 COMPLETED — AB instrument healed for idempotent reruns; llama-embed native service green on 127.0.0.1:8081; next brick LiteLLM pointed at llama.cpp; still no Ollama/OpenWebUI."
exit 0
