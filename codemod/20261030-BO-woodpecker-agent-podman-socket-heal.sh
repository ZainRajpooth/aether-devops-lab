#!/usr/bin/env bash
# 20261030-BO — heal BL Woodpecker agent crash-loop.
# Evidence:
#   BN fixed Gitea OAuth discovery and Woodpecker server became healthy.
#   Agent keeps restarting after:
#     [L9] agent unit_active=active container_status=running
#   Likely cause:
#     BL configured agent with WOODPECKER_BACKEND=local.
#     That is not the proven backend for this rootless Podman environment.
# Fix:
#   1) Enable user-level rootless Podman socket:
#        systemctl --user enable --now podman.socket
#   2) Patch BL agent container to use:
#        WOODPECKER_BACKEND=docker
#        DOCKER_HOST=unix:///var/run/docker.sock
#        mount Podman socket as /var/run/docker.sock
#   3) Rerun patched BL.
#   4) Require BL green sentinel.
#   5) Extra 15s agent stability watch:
#        active, running, NRestarts=0, no fatal backend logs.
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
#   - --check is pure except read-only evidence dump
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
FL="$CD/20261030-BL-woodpecker-brick10.sh"
FL_BAK="$FL.pre-BO.bak"

TOKEN="bo-woodpecker-agent-backend-local-crashloop"
BL_TOKEN="bl-woodpecker-brick10-green-v1"

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
to_int(){
  local v
  v="$(norm "${1:-0}")"
  case "$v" in
    ''|*[!0-9]*)
      printf '0'
      ;;
    *)
      printf '%s' "$v"
      ;;
  esac
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
nrestarts(){
  local v
  v="$(systemctl --user show "$1" -p NRestarts --value 2>/dev/null || true)"
  printf '%s' "$(to_int "$v")"
}

for c in bash python3 cp diff grep install chmod systemctl podman journalctl awk sed grep id seq sleep mktemp tr head tail; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

if [ ! -f "$FL" ]; then
  halt "missing BL script: $FL"
fi

# ===================== [O0] current agent evidence, read-only =====================
say "=== [O0] current Woodpecker agent evidence ==="

if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx woodpecker-agent; then
  say "[O0] dumping last woodpecker-agent logs"
  podman logs --tail 80 woodpecker-agent 2>&1 | sed 's/^/    agent-log: /' || true
else
  say "[O0] woodpecker-agent container absent"
fi

say "[O0] unit status"
systemctl --user status --no-pager woodpecker-agent.service 2>/dev/null | sed 's/^/    unit: /' || true

say "[O0] server status"
systemctl --user status --no-pager woodpecker-server.service 2>/dev/null | sed 's/^/    unit: /' || true

# ===================== [O1] prepare patched BL candidate =====================
say "=== [O1] prepare patched BL candidate ==="
CAND="$TMPD/bl.candidate"
PY="$TMPD/patch_bl.py"

cp -p "$FL" "$CAND" || halt "could not copy BL to candidate"

cat > "$PY" <<'PATCHPY'
import sys
import pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t

head_old = 'build_agent_exec(){\n  local -a args\n  local exe="" part\n  args=(\n'
head_new = 'build_agent_exec(){\n  local -a args\n  local exe="" part\n  local podman_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"\n  args=(\n'

if 'local podman_socket=' not in t:
    if head_old in t:
        t = t.replace(head_old, head_new, 1)
    else:
        sys.stderr.write("missing anchor: build_agent_exec head\n")
        sys.exit(2)

block_old = '    -e "WOODPECKER_BACKEND=local"\n    -v "$VOL_AGENT:/var/lib/woodpecker"\n'
block_new = '    -e "WOODPECKER_BACKEND=docker"\n    -e "DOCKER_HOST=unix:///var/run/docker.sock"\n    -v "$podman_socket:/var/run/docker.sock"\n    -v "$VOL_AGENT:/var/lib/woodpecker"\n'

if 'WOODPECKER_BACKEND=docker' not in t:
    if block_old in t:
        t = t.replace(block_old, block_new, 1)
    else:
        sys.stderr.write("missing anchor: agent backend local block\n")
        sys.exit(2)

comment_old = '# BL: connects to woodpecker-server:9000; backend=local for install proof.'
comment_new = '# BO: connects to woodpecker-server:9000; backend=docker via rootless Podman socket.'
if comment_old in t:
    t = t.replace(comment_old, comment_new, 1)

ledger_old = 'backend=local for install proof'
ledger_new = 'backend=docker via rootless Podman socket'
if ledger_old in t:
    t = t.replace(ledger_old, ledger_new, 1)

if t != orig:
    p.write_text(t, encoding="utf-8")
PATCHPY

if ! python3 "$PY" "$CAND"; then
  halt "BL patcher failed on candidate; original BL untouched"
fi

if ! bash -n "$CAND"; then
  halt "patched BL candidate failed bash -n; original BL untouched"
fi

chmod +x "$CAND" 2>/dev/null || true
say "[O1] candidate patched; bash -n OK"

# ===================== [O2] dry-run gate =====================
if [ "$DRY" = 1 ]; then
  say "[O2] dry-run diff current BL -> patched candidate:"
  diff -u "$FL" "$CAND" | sed 's/^/    /' || true
  say "[O2] planned apply-side effects:"
  say "    - enable/start user podman.socket"
  say "    - install patched BL"
  say "    - append guarded correction ledger row"
  say "    - rerun patched BL"
  say "    - extra 15s woodpecker-agent stability watch"
  say "[RESULT] DRY-RUN complete; no BL write, no socket enable, no ledger row, no BL rerun."
  exit 0
fi

# ===================== [O3] ensure rootless Podman socket =====================
say "=== [O3] ensure rootless Podman socket ==="
RUN_UID="$(id -u)"
PODMAN_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$RUN_UID}/podman/podman.sock"
say "[O3] expected Podman socket: $PODMAN_SOCKET"

if ! systemctl --user enable --now podman.socket >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if ! systemctl --user enable --now podman.socket >/dev/null 2>&1; then
    halt "could not enable/start user podman.socket"
  fi
fi

SOCK_OK=no
for i in $(seq 1 30); do
  if [ -S "$PODMAN_SOCKET" ]; then
    SOCK_OK=yes
    break
  fi
  sleep 1
done

if [ "$SOCK_OK" != yes ]; then
  halt "podman.socket started but socket file is not present at $PODMAN_SOCKET"
fi

say "[O3] podman.socket active and socket present"

# ===================== [O4] install patched BL =====================
say "=== [O4] install patched BL ==="

if [ ! -f "$FL_BAK" ]; then
  cp -p "$FL" "$FL_BAK"
  say "[O4] BL backup -> $FL_BAK"
fi

if ! install -D -m 755 "$CAND" "$FL"; then
  halt "could not install patched BL"
fi

if ! bash -n "$FL"; then
  cp -p "$FL_BAK" "$FL" 2>/dev/null || true
  halt "installed patched BL failed bash -n; restored backup"
fi

say "[O4] installed patched BL -> $FL"

# ===================== [O5] guarded correction ledger row =====================
say "=== [O5] ledger correction row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BL/BN proved Woodpecker server healthy and Gitea OAuth app created, but woodpecker-agent kept restarting because BL configured WOODPECKER_BACKEND=local. BO supersedes that by enabling the user-level rootless Podman socket and patching the agent to use WOODPECKER_BACKEND=docker with DOCKER_HOST=unix:///var/run/docker.sock, mounting the Podman socket as /var/run/docker.sock. This is the correct local rootless CI executor path for this environment. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[O5] BO agent-backend correction row appended."
else
  say "[O5] BO agent-backend correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[O5] suppression proof: correction sentinel present." || say "[O5] WARNING: correction sentinel missing."

# ===================== [O6] rerun patched BL =====================
say "=== [O6] rerun patched BL ==="
bash "$FL"
BL_RC=$?
say "[O6] BL rc=$BL_RC"

if ! grep -qF "$BL_TOKEN" "$IDX" 2>/dev/null; then
  say "[O6] BL success sentinel missing; inspect BL output above."
  halt "patched BL did not produce bl-woodpecker-brick10-green-v1"
fi

say "[O6] BL success sentinel present."

# ===================== [O7] extra agent stability proof =====================
say "=== [O7] extra woodpecker-agent stability proof ==="
systemctl --user reset-failed woodpecker-agent.service >/dev/null 2>&1 || true
sleep 15

AGENT_ACTIVE="$(active_state woodpecker-agent.service)"
AGENT_CONTAINER="$(container_status woodpecker-agent)"
SERVER_ACTIVE="$(active_state woodpecker-server.service)"
SERVER_CONTAINER="$(container_status woodpecker-server)"
NR_AGENT="$(nrestarts woodpecker-agent.service)"
NR_SERVER="$(nrestarts woodpecker-server.service)"

say "[O7] server_active=$SERVER_ACTIVE server_container=$SERVER_CONTAINER server_nrestarts=$NR_SERVER"
say "[O7] agent_active=$AGENT_ACTIVE agent_container=$AGENT_CONTAINER agent_nrestarts=$NR_AGENT"

AGENT_LOGS="$(podman logs --tail 120 woodpecker-agent 2>&1 || true)"

if [ "$AGENT_ACTIVE" != active ] ||
   [ "$AGENT_CONTAINER" != running ] ||
   [ "$NR_AGENT" -gt 0 ]; then
  printf '%s\n' "$AGENT_LOGS" | sed 's/^/    agent-log: /' || true
  systemctl --user status --no-pager woodpecker-agent.service 2>/dev/null | sed 's/^/    unit: /' || true
  if ! grep -qF "bo-woodpecker-agent-extra-stability-failed" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | bo-woodpecker-agent-extra-stability-failed | APPEND-ONLY | BL reported green, but BO extra 15s watch found woodpecker-agent unstable: active=%s container=%s nrestarts=%s. Do not proceed to Traefik. Inspect agent-log/unit above. |\n' \
      "$(date +%F)" "$AGENT_ACTIVE" "$AGENT_CONTAINER" "$NR_AGENT" >> "$IDX"
  fi
  halt "woodpecker-agent failed BO extra stability watch"
fi

if printf '%s' "$AGENT_LOGS" | grep -Eiq 'unsupported backend|unknown backend|invalid backend|fatal|panic|cannot connect to docker|permission denied.*docker|no such file.*docker.sock'; then
  printf '%s\n' "$AGENT_LOGS" | sed 's/^/    agent-log: /' || true
  if ! grep -qF "bo-woodpecker-agent-backend-log-error" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | bo-woodpecker-agent-backend-log-error | APPEND-ONLY | BL reported green, but BO found fatal-looking woodpecker-agent backend/socket log lines after 15s watch. Do not proceed to Traefik. Inspect agent-log above. |\n' \
      "$(date +%F)" >> "$IDX"
  fi
  halt "woodpecker-agent logs contain backend/socket fatal indicators"
fi

say "[O7] extra stability PASS: agent active, running, NRestarts=0, no fatal backend/socket log markers"

say "[RESULT] BO HEALED + WOODPECKER BRICK 10A GREEN — server=http://127.0.0.1:8000 agent stable via rootless Podman socket; next: build traefik; still no Ollama/OpenWebUI/chat-model."
exit 0
