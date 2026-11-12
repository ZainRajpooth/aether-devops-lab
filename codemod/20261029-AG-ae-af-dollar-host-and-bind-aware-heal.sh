#!/usr/bin/env bash
# 20261029-AG — heal AE/FF dollar-host defects, make AE bind-aware, then resolve LiteLLM path.
# Owns:
#   1) AE [E3] label had unescaped $host (already patched by AF, but AG makes AE standalone-safe).
#   2) AF correction-row payload had unescaped $host and crashed under set -u.
#   3) AE [E0] was loopback-only and would falsely halt after a legitimate internal-only rebind.
# Then reruns patched AE to produce the measured LiteLLM UPSTREAM_URL.
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
FF="$CD/20261029-AF-ae-dollar-host-label-heal.sh"
AE_BAK="$AE.pre-AG.bak"
FF_BAK="$FF.pre-AG.bak"

TOKEN_AE_LABEL="ae-dollar-host-label-defect"
TOKEN_AE_E0="ae-e0-loopback-only-idempotence-defect"
TOKEN_FF_PAYLOAD="ff-dollar-host-payload-defect"
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
if [ ! -f "$FF" ]; then
  halt "missing FF script: $FF"
fi

# ===================== [G0] patch AE candidate =====================
say "=== [G0] prepare patched AE candidate ==="
CAND_AE="$TMPD/ae.candidate"
PY_AE="$TMPD/patch_ae.py"

cp -p "$AE" "$CAND_AE" || halt "could not copy AE to candidate"

cat > "$PY_AE" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
changed = False

# 1) Fix the unescaped $host label defect in AE [E3].
bad_label = 'say "=== [E3] container->$host reachability (throwaway alpine on $NET) ==="'
good_label = 'say "=== [E3] container->host reachability (throwaway alpine on $NET) ==="'

if good_label in s and bad_label not in s:
    pass
elif bad_label in s:
    s = s.replace(bad_label, good_label, 1)
    changed = True
else:
    sys.stderr.write("missing AE label anchor\n")
    sys.exit(2)

# 2) Make AE [E0] bind-aware so it remains idempotent after an internal-only rebind.
start_old = "# ===================== [E0] host-side llama-embed sanity (loopback) ====================="
start_new = "# ===================== [E0] host-side llama-embed sanity (bind-aware) ====================="
end_anchor = "# ===================== [E1] rootless network backend + version ====================="

if start_new in s and start_old not in s:
    pass
elif start_old in s:
    try:
        i = s.index(start_old)
        j = s.index(end_anchor, i)
    except ValueError as e:
        sys.stderr.write("AE E0 anchor error: %s\n" % e)
        sys.exit(2)

    new_block = r"""# ===================== [E0] host-side llama-embed sanity (bind-aware) =====================
say "=== [E0] host-side llama-embed sanity (bind-aware) ==="
H_BIND="$(sed -n 's/.*--host \([^ ]*\).*/\1/p' "$SRCU" 2>/dev/null | head -n1)"
H_BIND="$(norm "$H_BIND")"
if [ -z "$H_BIND" ]; then
  H_BIND="127.0.0.1"
fi
H_HEALTH="$(norm "$(http_code "http://$H_BIND:$PORT/health")")"
H_ACT="$(norm "$(systemctl --user is-active llama-embed.service 2>/dev/null || true)")"
if [ -z "$H_ACT" ]; then
  H_ACT=inactive
fi
say "[E0] llama-embed unit_active=$H_ACT bind=$H_BIND health=$H_HEALTH"
if [ "$H_HEALTH" != 200 ]; then
  halt "llama-embed not healthy on bind $H_BIND (health=$H_HEALTH); fix brick 5 before probing."
fi

"""
    s = s[:i] + new_block + s[j:]
    changed = True
else:
    sys.stderr.write("missing AE E0 anchor\n")
    sys.exit(2)

if changed:
    p.write_text(s, encoding="utf-8")
PYEOF

if ! python3 "$PY_AE" "$CAND_AE"; then
  halt "AE patcher failed on candidate; original AE untouched"
fi

if ! bash -n "$CAND_AE"; then
  halt "patched AE candidate failed bash -n; original AE untouched"
fi

say "[G0] AE candidate patched; bash -n OK"

# ===================== [G1] patch FF candidate =====================
say "=== [G1] prepare patched FF candidate ==="
CAND_FF="$TMPD/ff.candidate"
PY_FF="$TMPD/patch_ff.py"

cp -p "$FF" "$CAND_FF" || halt "could not copy FF to candidate"

cat > "$PY_FF" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

bad_payload = "unescaped '$host' under set -u"
good_payload = r"unescaped '\$host' under set -u"

if good_payload in s and bad_payload not in s:
    sys.exit(0)

if bad_payload not in s:
    sys.stderr.write("missing FF payload anchor\n")
    sys.exit(2)

s2 = s.replace(bad_payload, good_payload, 1)
p.write_text(s2, encoding="utf-8")
PYEOF

if ! python3 "$PY_FF" "$CAND_FF"; then
  halt "FF patcher failed on candidate; original FF untouched"
fi

if ! bash -n "$CAND_FF"; then
  halt "patched FF candidate failed bash -n; original FF untouched"
fi

say "[G1] FF candidate patched; bash -n OK"

# ===================== [G2] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[G2] dry-run diff current AE -> patched candidate:"
  diff -u "$AE" "$CAND_AE" | sed 's/^/    /' || true

  say "[G2] dry-run diff current FF -> patched candidate:"
  diff -u "$FF" "$CAND_FF" | sed 's/^/    /' || true

  say "[RESULT] DRY-RUN complete; no AE/FF write, no ledger row, no AE rerun."
  exit 0
fi

# ===================== [G3] install patched AE + FF =====================
say "=== [G3] install patched AE + FF ==="

if [ ! -f "$AE_BAK" ]; then
  cp -p "$AE" "$AE_BAK"
  say "[G3] AE backup -> $AE_BAK"
fi

if ! cp -p "$CAND_AE" "$AE"; then
  halt "could not install patched AE"
fi

if ! bash -n "$AE"; then
  cp -p "$AE_BAK" "$AE" 2>/dev/null || true
  halt "installed patched AE failed bash -n; restored AE backup"
fi

say "[G3] installed patched AE -> $AE"

if [ ! -f "$FF_BAK" ]; then
  cp -p "$FF" "$FF_BAK"
  say "[G3] FF backup -> $FF_BAK"
fi

if ! cp -p "$CAND_FF" "$FF"; then
  halt "could not install patched FF"
fi

if ! bash -n "$FF"; then
  cp -p "$FF_BAK" "$FF" 2>/dev/null || true
  halt "installed patched FF failed bash -n; restored FF backup"
fi

say "[G3] installed patched FF -> $FF"

# ===================== [G4] guarded correction ledger rows =====================
say "=== [G4] ledger correction rows ==="

if ! grep -qF "$TOKEN_AE_LABEL" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AE contained an unescaped $host in an [E3] say label and crashed under set -u before [E3]. Gate held: no container run, no rebind, no mutation. AG patches AE label to literal container->host. |\n' \
    "$(date +%F)" "$TOKEN_AE_LABEL" >> "$IDX"
  say "[G4] AE label correction row appended."
else
  say "[G4] AE label correction row already present."
fi
grep -qF "$TOKEN_AE_LABEL" "$IDX" 2>/dev/null && say "[G4] suppression proof: AE label sentinel present." || say "[G4] WARNING: AE label sentinel missing."

if ! grep -qF "$TOKEN_AE_E0" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AE [E0] sanity was loopback-only, which would falsely halt after a legitimate internal-only rebind to the aether gateway. AG makes [E0] bind-aware by reading --host from the unit and probing that bind. |\n' \
    "$(date +%F)" "$TOKEN_AE_E0" >> "$IDX"
  say "[G4] AE bind-aware correction row appended."
else
  say "[G4] AE bind-aware correction row already present."
fi
grep -qF "$TOKEN_AE_E0" "$IDX" 2>/dev/null && say "[G4] suppression proof: AE bind-aware sentinel present." || say "[G4] WARNING: AE bind-aware sentinel missing."

if ! grep -qF "$TOKEN_FF_PAYLOAD" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | FF crashed at its own correction-row echo because the payload contained unescaped $host under set -u. Gate partial: AE had already been patched before the crash; no AE rerun and no FF correction row. AG repairs FF payload escaping. |\n' \
    "$(date +%F)" "$TOKEN_FF_PAYLOAD" >> "$IDX"
  say "[G4] FF payload correction row appended."
else
  say "[G4] FF payload correction row already present."
fi
grep -qF "$TOKEN_FF_PAYLOAD" "$IDX" 2>/dev/null && say "[G4] suppression proof: FF payload sentinel present." || say "[G4] WARNING: FF payload sentinel missing."

# ===================== [G5] run patched AE =====================
say "=== [G5] run patched AE to resolve LiteLLM path ==="
bash "$AE"
AERC=$?
if [ "$AERC" != 0 ]; then
  halt "patched AE returned nonzero rc=$AERC"
fi

if grep -qF "$RESOLVED_TOKEN" "$IDX" 2>/dev/null; then
  say "[G5] AE resolved sentinel present."
else
  halt "patched AE did not produce litellm-path-resolved-v2; inspect AE output above."
fi

say "[RESULT] AE/AF DOLLAR-HOST HEAL COMPLETE — LiteLLM path resolved by patched AE; next brick uses the measured UPSTREAM_URL emitted by AE."
exit 0
