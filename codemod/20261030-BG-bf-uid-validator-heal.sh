#!/usr/bin/env bash
# 20261030-BG — heal BF: valid_ident (SQL rule, no hyphen) was wrongly applied to Grafana UIDs
# that legitimately contain '-' (prometheus-aether / aether-overview). BF halted pre-write, so the
# live Grafana + ledger are untouched. BG adds a URL/JSON-safe valid_uid (alnum + _.- , 1..190,
# reject '..'), repoints the two UID call-sites, bash -n gates, installs patched BF, appends a
# guarded correction row, re-runs BF, and requires BF's green sentinel before declaring green.
# Safety: no sudo; no pull; no model download; no ollama/open-webui; no secret echo; --check pure.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks.
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
FF="$CD/20261030-BF-grafana-dns-guard-reconcile.sh"
FF_BAK="$FF.pre-BG.bak"

TOKEN="bg-bf-valid-ident-hyphen-uid-defect"
BF_TOKEN="bf-grafana-brick8-green-v3"

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

if [ ! -f "$FF" ]; then
  halt "missing BF script: $FF"
fi

# ===================== [G0] prepare patched BF candidate =====================
say "=== [G0] prepare patched BF candidate ==="
CAND="$TMPD/bf.candidate"
PY="$TMPD/patch_bf.py"

cp -p "$FF" "$CAND" || halt "could not copy BF to candidate"

cat > "$PY" <<'PYEOF'
import sys
import pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

VALID_UID = (
    "valid_uid(){\n"
    "  local s=\"${1:-}\"\n"
    "  if [ -z \"$s\" ]; then\n"
    "    return 1\n"
    "  fi\n"
    "  case \"$s\" in\n"
    "    *..*)\n"
    "      return 1\n"
    "      ;;\n"
    "  esac\n"
    "  if printf '%s' \"$s\" | grep -Eq '^[A-Za-z0-9_.-]{1,190}$'; then\n"
    "    return 0\n"
    "  fi\n"
    "  return 1\n"
    "}\n"
)

# 1) Insert valid_uid() right after the valid_ident() function block, if absent.
if "valid_uid(){" not in t:
    lines = t.splitlines(keepends=True)
    start = None
    for i, ln in enumerate(lines):
        if ln.strip() == "valid_ident(){":
            start = i
            break
    if start is None:
        sys.stderr.write("missing anchor: valid_ident(){\n")
        sys.exit(2)
    close = None
    for j in range(start + 1, len(lines)):
        if lines[j].strip() == "}":
            close = j
            break
    if close is None:
        sys.stderr.write("missing anchor: valid_ident close brace\n")
        sys.exit(2)
    lines.insert(close + 1, VALID_UID)
    t = "".join(lines)

# 2) Repoint the two Grafana-UID call-sites from valid_ident to valid_uid.
pairs = [
    ('if ! valid_ident "$DATASOURCE_UID"; then', 'if ! valid_uid "$DATASOURCE_UID"; then'),
    ('if ! valid_ident "$DASHBOARD_UID"; then',  'if ! valid_uid "$DASHBOARD_UID"; then'),
]
for old, new in pairs:
    if old in t:
        t = t.replace(old, new, 1)
    elif new not in t:
        sys.stderr.write("missing anchor: " + old + "\n")
        sys.exit(2)

if t != orig:
    p.write_text(t, encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "BF patcher failed on candidate; original BF untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched BF candidate failed bash -n; original BF untouched"
fi

chmod +x "$CAND" 2>/dev/null || true
say "[G0] candidate patched; bash -n OK"

# ===================== [G1] dry-run gate (pure) =====================
if [ "$DRY" = 1 ]; then
  say "[G1] dry-run diff current BF -> patched candidate:"
  diff -u "$FF" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no BF write, no ledger row, no BF rerun."
  exit 0
fi

# ===================== [G2] install patched BF =====================
say "=== [G2] install patched BF ==="

if [ ! -f "$FF_BAK" ]; then
  cp -p "$FF" "$FF_BAK"
  say "[G2] BF backup -> $FF_BAK"
fi

if ! install -D -m 755 "$CAND" "$FF"; then
  halt "could not install patched BF"
fi

if ! bash -n "$FF"; then
  cp -p "$FF_BAK" "$FF" 2>/dev/null || true
  halt "installed patched BF failed bash -n; restored backup"
fi

say "[G2] installed patched BF -> $FF"

# ===================== [G3] guarded correction ledger row =====================
say "=== [G3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BF halted pre-write at [F0] unsafe datasource uid because valid_ident (Postgres SQL rule, no hyphen) was wrongly applied to Grafana UIDs prometheus-aether / aether-overview, which legitimately contain hyphens and are only interpolated into URL paths / JSON greps, never SQL. BG adds a URL/JSON-safe valid_uid (alnum + _.- , 1..190, reject ".." traversal) and repoints the two UID call-sites; valid_ident stays strict for SQL. No side-effects occurred before the halt (live Grafana + ledger untouched). |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[G3] BF UID-validator correction row appended."
else
  say "[G3] BF UID-validator correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[G3] suppression proof: correction sentinel present." || say "[G3] WARNING: correction sentinel missing."

# ===================== [G4] re-run patched BF =====================
say "=== [G4] re-run patched BF ==="
bash "$FF"
BF_RC=$?
say "[G4] BF rc=$BF_RC"

if ! grep -qF "$BF_TOKEN" "$IDX" 2>/dev/null; then
  say "[G4] BF success sentinel missing; inspect BF output above."
  halt "patched BF did not produce bf-grafana-brick8-green-v3"
fi

say "[G4] BF success sentinel present."
say "[RESULT] BG HEALED + GRAFANA BRICK 8 GREEN (HARDENED + RECONCILED) — patched BF completed; next: build rag pilot; still no Ollama/OpenWebUI/chat-model."
exit 0
