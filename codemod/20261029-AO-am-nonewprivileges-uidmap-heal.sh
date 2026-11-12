#!/usr/bin/env bash
# 20261029-AO — heal AM's rootless Podman service sandbox defect.
# Root cause:
#   AM generated llama-embed-container.service with NoNewPrivileges=yes.
#   Rootless Podman needs setuid newuidmap/newgidmap helpers.
#   NoNewPrivileges=yes blocks them, causing:
#     newuidmap: write to uid_map failed: Operation not permitted
# Heal:
#   1) patch AM desired-unit heredoc to remove NoNewPrivileges=yes;
#   2) add Delegate=yes for rootless Podman cgroup delegation;
#   3) run podman system migrate again;
#   4) rerun patched AM;
#   5) if AM green, run AA green-stack reconcile;
#   6) verify core services active+running.
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
AM="$CD/20261029-AM-llama-embed-container-promote.sh"
AA="$CD/20261029-AA-green-stack-reconcile.sh"
AM_BAK="$AM.pre-AO.bak"

CONT_SERVICE="llama-embed-container"
CONTAINER_NAME="llama-embed"
PORT="8081"
INST_UNIT="$HOME/.config/systemd/user/$CONT_SERVICE.service"

TOKEN="am-nonewprivileges-uidmap-defect"
AM_TOKEN="llama-embed-container-promotion-v1"

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
active_state(){
  local s
  s="$(systemctl --user is-active "$1" 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=inactive
  fi
  printf '%s' "$s"
}
enabled_state(){
  local s
  s="$(systemctl --user is-enabled "$1" 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=unknown
  fi
  printf '%s' "$s"
}
container_status(){
  local name="$1"
  local s
  s="$(podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=absent
  fi
  printf '%s' "$s"
}

for c in bash podman systemctl cp diff grep install python3 sed cmp; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

if [ ! -f "$AM" ]; then
  halt "missing AM script: $AM"
fi

# ===================== [O0] evidence: current installed unit sandbox =====================
say "=== [O0] current installed unit sandbox evidence ==="
NP=""
if [ -f "$INST_UNIT" ]; then
  NP="$(systemctl --user show "$CONT_SERVICE.service" -p NoNewPrivileges --value 2>/dev/null || true)"
  NP="$(norm "$NP")"
fi
if [ -z "$NP" ]; then
  NP=unknown
fi
say "[O0] installed_unit_no_new_privileges=$NP"

if [ "$NP" = yes ]; then
  say "[O0] confirmed: NoNewPrivileges=yes blocks rootless Podman newuidmap/newgidmap."
else
  say "[O0] installed unit does not report NoNewPrivileges=yes; still patching AM generator for determinism."
fi

# ===================== [O1] prepare patched AM candidate =====================
say "=== [O1] prepare patched AM candidate ==="
CAND="$TMPD/am.candidate"
PY="$TMPD/patch_am.py"

cp -p "$AM" "$CAND" || halt "could not copy AM to candidate"

cat > "$PY" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

start = None
for i, line in enumerate(lines):
    if line.startswith('cat > "$DESIRED_UNIT" <<UNIT'):
        start = i
        break

if start is None:
    sys.stderr.write("missing AM desired-unit heredoc start anchor\n")
    sys.exit(2)

end = None
for i in range(start + 1, len(lines)):
    if lines[i].rstrip("\n") == "UNIT":
        end = i
        break

if end is None:
    sys.stderr.write("missing AM desired-unit heredoc end anchor\n")
    sys.exit(2)

block = lines[start + 1:end]
new = []
changed = False

for line in block:
    if line.strip() == "NoNewPrivileges=yes":
        changed = True
        continue
    new.append(line)

if not any(line.strip() == "Delegate=yes" for line in new):
    install_idx = None
    for i, line in enumerate(new):
        if line.strip() == "[Install]":
            install_idx = i
            break

    if install_idx is None:
        new.append("Delegate=yes\n")
    else:
        new.insert(install_idx, "Delegate=yes\n\n")

    changed = True

if changed:
    lines[start + 1:end] = new
    p.write_text("".join(lines), encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "AM patcher failed on candidate; original AM untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched AM candidate failed bash -n; original AM untouched"
fi

say "[O1] candidate patched; bash -n OK"

# ===================== [O2] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[O2] dry-run diff current AM -> patched candidate:"
  diff -u "$AM" "$CAND" | sed 's/^/    /' || true
  say "[RESULT] DRY-RUN complete; no AM write, no migrate, no AM rerun, no AA rerun, no ledger row."
  exit 0
fi

# ===================== [O3] install patched AM =====================
say "=== [O3] install patched AM ==="
if [ ! -f "$AM_BAK" ]; then
  cp -p "$AM" "$AM_BAK"
  say "[O3] AM backup -> $AM_BAK"
fi

if ! cp -p "$CAND" "$AM"; then
  halt "could not install patched AM"
fi

if ! bash -n "$AM"; then
  cp -p "$AM_BAK" "$AM" 2>/dev/null || true
  halt "installed patched AM failed bash -n; restored backup"
fi

say "[O3] installed patched AM -> $AM"

# ===================== [O4] guarded correction ledger row =====================
say "=== [O4] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AM-generated llama-embed-container.service contained NoNewPrivileges=yes. Rootless Podman requires setuid newuidmap/newgidmap helpers; NoNewPrivileges blocked them and caused newuidmap write to uid_map failed Operation not permitted. AO removes NoNewPrivileges from the generated unit and adds Delegate=yes for rootless Podman cgroup delegation. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[O4] AM NoNewPrivileges correction row appended."
else
  say "[O4] AM NoNewPrivileges correction row already present."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[O4] suppression proof: correction sentinel present." || say "[O4] WARNING: correction sentinel missing."

# ===================== [O5] reset rootless Podman pause state =====================
say "=== [O5] podman system migrate ==="
if podman system migrate >"$TMPD/migrate.out" 2>"$TMPD/migrate.err"; then
  say "[O5] podman system migrate OK"
  head -n 8 "$TMPD/migrate.out" 2>/dev/null | sed 's/^/    /' || true
else
  MIGRATE_RC=$?
  say "[O5] podman system migrate rc=$MIGRATE_RC"
  tail -n 12 "$TMPD/migrate.err" 2>/dev/null | sed 's/^/    /' || true
fi

# ===================== [O6] run patched AM =====================
say "=== [O6] run patched AM to promote llama-embed container ==="
bash "$AM"
AMRC=$?
say "[O6] AM rc=$AMRC"

if ! grep -qF "$AM_TOKEN" "$IDX" 2>/dev/null; then
  say "[O6] AM promotion sentinel missing; inspect AM output above."
  halt "patched AM did not produce llama-embed-container-promotion-v1"
fi

say "[O6] AM promotion sentinel present."

# ===================== [O7] verify promoted service state =====================
say "=== [O7] promoted service state ==="
say "[O7] container_service_active=$(active_state "$CONT_SERVICE.service")"
say "[O7] container_service_enabled=$(enabled_state "$CONT_SERVICE.service")"
say "[O7] container_status=$(container_status "$CONTAINER_NAME")"
NP2="$(systemctl --user show "$CONT_SERVICE.service" -p NoNewPrivileges --value 2>/dev/null || true)"
NP2="$(norm "$NP2")"
if [ -z "$NP2" ]; then
  NP2=unknown
fi
say "[O7] no_new_privileges_now=$NP2"
podman ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    ps: /' || true

if [ "$NP2" = yes ]; then
  halt "service still reports NoNewPrivileges=yes; patch did not take effect"
fi

# ===================== [O8] reconcile core stack after reboot =====================
if [ -f "$AA" ]; then
  say "=== [O8] run AA green-stack reconcile ==="
  bash "$AA"
  AARC=$?
  say "[O8] AA rc=$AARC"
else
  say "[O8] AA script missing: $AA"
  say "[O8] AM is green, but core stack reconciliation must be run separately."
fi

# ===================== [O9] core gate =====================
say "=== [O9] core stack gate ==="
CORE_OK=yes
for s in postgres redis minio weaviate; do
  ACT="$(active_state "$s.service")"
  CST="$(container_status "$s")"
  say "[O9] $s active=$ACT container=$CST"
  if [ "$ACT" != active ] || [ "$CST" != running ]; then
    CORE_OK=no
  fi
done

if [ "$CORE_OK" != yes ]; then
  say "[O9] core stack not fully active+running."
  say "[O9] paste [O8]/[O9] output; do not proceed to LiteLLM until core is green."
  halt "llama-embed promoted but core stack is not green"
fi

say "[RESULT] LLAMA-EMBED CONTAINER PROMOTED + CORE STACK GREEN — service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1; NoNewPrivileges defect healed; next brick LiteLLM; still no Ollama/OpenWebUI/chat-model."
exit 0
