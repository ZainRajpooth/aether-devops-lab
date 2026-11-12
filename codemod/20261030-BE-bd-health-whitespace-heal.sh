#!/usr/bin/env bash
# 20261030-BE — heal BD:
#   1) BD health parser falsely required compact JSON: "database":"ok"
#      Grafana returned whitespace JSON: "database": "ok"
#      Evidence: [GATE DETAIL] health=no code=200 but health-body had database ok.
#   2) Disable Grafana plugin auto-update to avoid multi-minute plugin churn during candidate proof.
#   3) Patch BD candidate, bash -n gate, install patched BD, rerun BD.
#   4) Require BD success sentinel before declaring green.
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
FB="$CD/20261030-BD-grafana-observable-gate-heal.sh"
FB_BAK="$FB.pre-BE.bak"

TOKEN="be-bd-health-whitespace-defect"
BD_TOKEN="bd-grafana-brick8-green-v2"

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

if [ ! -f "$FB" ]; then
  halt "missing BD script: $FB"
fi

# ===================== [E0] prepare patched BD candidate =====================
say "=== [E0] prepare patched BD candidate ==="
CAND="$TMPD/bd.candidate"
PY="$TMPD/patch_bd.py"

cp -p "$FB" "$CAND" || halt "could not copy BD to candidate"

cat > "$PY" <<'PYEOF'
import sys
import pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

# 1) Heal main BD health parser.
health_body_old = "  grep -q '\"database\":\"ok\"' \"$body\" 2>/dev/null\n"
health_body_new = "  tr -d '[:space:]' < \"$body\" 2>/dev/null | grep -q '\"database\":\"ok\"' 2>/dev/null\n"

if health_body_old in t:
    t = t.replace(health_body_old, health_body_new, 1)
elif health_body_new not in t:
    sys.stderr.write("missing anchor: health_body_old\n")
    sys.exit(2)

# 2) Heal replay health parser inside BD.
replay_old = "  if printf '%s' \"$B\" | grep -q '\"database\":\"ok\"'; then\n"
replay_new = "  if printf '%s' \"$B\" | tr -d '[:space:]' | grep -q '\"database\":\"ok\"'; then\n"

if replay_old in t:
    t = t.replace(replay_old, replay_new, 1)
elif replay_new not in t:
    sys.stderr.write("missing anchor: replay_old\n")
    sys.exit(2)

# 3) Disable plugin auto-update in generated container args and env file.
if "GF_PLUGINS_AUTO_UPDATE=false" not in t:
    plugin_exec_old = "    -e GF_PLUGINS_PLUGIN_ADMIN_ENABLED=false\n"
    plugin_exec_new = (
        "    -e GF_PLUGINS_PLUGIN_ADMIN_ENABLED=false\n"
        "    -e GF_PLUGINS_AUTO_UPDATE=false\n"
    )

    if plugin_exec_old in t:
        t = t.replace(plugin_exec_old, plugin_exec_new, 1)
    else:
        sys.stderr.write("missing anchor: plugin_exec_old\n")
        sys.exit(2)

    plugin_env_old = "ensure_env GF_PLUGINS_PLUGIN_ADMIN_ENABLED false\n"
    plugin_env_new = (
        "ensure_env GF_PLUGINS_PLUGIN_ADMIN_ENABLED false\n"
        "ensure_env GF_PLUGINS_AUTO_UPDATE false\n"
    )

    if plugin_env_old in t:
        t = t.replace(plugin_env_old, plugin_env_new, 1)
    else:
        sys.stderr.write("missing anchor: plugin_env_old\n")
        sys.exit(2)

if t != orig:
    p.write_text(t, encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "BD patcher failed on candidate; original BD untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched BD candidate failed bash -n; original BD untouched"
fi

chmod +x "$CAND" 2>/dev/null || true
say "[E0] candidate patched; bash -n OK"

# ===================== [E1] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[E1] dry-run diff current BD -> patched candidate:"
  diff -u "$FB" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no BD write, no ledger row, no BD rerun."
  exit 0
fi

# ===================== [E2] install patched BD =====================
say "=== [E2] install patched BD ==="

if [ ! -f "$FB_BAK" ]; then
  cp -p "$FB" "$FB_BAK"
  say "[E2] BD backup -> $FB_BAK"
fi

if ! install -D -m 755 "$CAND" "$FB"; then
  halt "could not install patched BD"
fi

if ! bash -n "$FB"; then
  cp -p "$FB_BAK" "$FB" 2>/dev/null || true
  halt "installed patched BD failed bash -n; restored backup"
fi

say "[E2] installed patched BD -> $FB"

# ===================== [E3] guarded correction ledger row =====================
say "=== [E3] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BD failed Grafana candidate proof because its health parser required compact JSON "database":"ok" while Grafana returned whitespace JSON "database": "ok". Evidence: health=no code=200 but health-body contained database ok. BE strips whitespace before matching and disables GF_PLUGINS_AUTO_UPDATE to avoid plugin-update churn. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[E3] BD health-parser correction row appended."
else
  say "[E3] BD health-parser correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[E3] suppression proof: correction sentinel present." || say "[E3] WARNING: correction sentinel missing."

# ===================== [E4] rerun patched BD =====================
say "=== [E4] rerun patched BD ==="
bash "$FB"
BD_RC=$?
say "[E4] BD rc=$BD_RC"

if ! grep -qF "$BD_TOKEN" "$IDX" 2>/dev/null; then
  say "[E4] BD success sentinel missing; inspect BD output above."
  halt "patched BD did not produce bd-grafana-brick8-green-v2"
fi

say "[E4] BD success sentinel present."
say "[RESULT] BD HEALED + GRAFANA BRICK 8 GREEN — patched BD completed; next: build rag pilot; still no Ollama/OpenWebUI/chat-model."
exit 0
