#!/usr/bin/env bash
# 20261029-AQ — isolate the real llama-embed-container failure by testing Podman flags under throwaway systemd user services.
# Owns AP result:
#   minimal default-userns podman works under systemd, so userns-host is NOT the proven bypass.
# Leading suspect:
#   podman run --security-opt=no-new-privileges conflicts with rootless newuidmap remapping in this environment.
# Method:
#   [Q0] safe floor: native llama-embed healthy.
#   [Q1] short-lived oneshot systemd A/B tests for flags.
#   [Q2] decision from short tests.
#   [Q3] if inconclusive, full temporary llama serving A/B with/without security-opt.
#   [Q4] if proven, patch AM to remove --security-opt=no-new-privileges and ensure no --userns=host.
#   [Q5] rerun AM.
#   [Q6] rerun AA core reconcile.
#   [Q7] core gate.
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
#   - throwaway units/containers cleaned by trap
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
AM_BAK="$AM.pre-AQ.bak"

NATIVE_SERVICE="llama-embed"
CONT_SERVICE="llama-embed-container"
CONTAINER_NAME="llama-embed"
PORT="8081"
NET="aether"

ALPINE="docker.io/library/alpine:latest"
RUNTIME_IMAGE="localhost/aether-llama-runtime:glibc-match-v2"
MODEL="/home/dev/DevOps/neocortex/models/embedded/nomic-embed-text-v1.5.Q8_0.gguf"
MODEL_DIR="/home/dev/DevOps/neocortex/models/embedded"
MODEL_BASE="nomic-embed-text-v1.5.Q8_0.gguf"
MODEL_CONTAINER="/models/$MODEL_BASE"

SFX="$$"
SYSU="$HOME/.config/systemd/user"

T_BASE="aether-q-base-$SFX"
T_SEC="aether-q-sec-$SFX"
T_SECHOST="aether-q-sechost-$SFX"
T_LLAMA_BASE="aether-q-llama-base-$SFX"
T_LLAMA_SEC="aether-q-llama-sec-$SFX"
T_LLAMA_SECHOST="aether-q-llama-sechost-$SFX"
T_NET="aether-q-net-$SFX"
T_MEM="aether-q-mem-$SFX"
T_VOL="aether-q-vol-$SFX"
T_PUB="aether-q-pub-$SFX"

T_FULL_BASE="aether-q-full-base-$SFX"
T_FULL_SEC="aether-q-full-sec-$SFX"
C_FULL_BASE="aether-q-full-base-$SFX"
C_FULL_SEC="aether-q-full-sec-$SFX"

TEST_UNITS=(
  "$T_BASE"
  "$T_SEC"
  "$T_SECHOST"
  "$T_LLAMA_BASE"
  "$T_LLAMA_SEC"
  "$T_LLAMA_SECHOST"
  "$T_NET"
  "$T_MEM"
  "$T_VOL"
  "$T_PUB"
  "$T_FULL_BASE"
  "$T_FULL_SEC"
)

CLEAN_CONTAINERS=(
  "$C_FULL_BASE"
  "$C_FULL_SEC"
)

mkdir -p "$CD" "$SYSU"

TMPD="$(mktemp -d)"
cleanup(){
  local u c
  for u in "${TEST_UNITS[@]}"; do
    systemctl --user disable --now "$u.service" >/dev/null 2>&1 || true
    rm -f "$SYSU/$u.service" 2>/dev/null || true
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  for c in "${CLEAN_CONTAINERS[@]}"; do
    podman rm -f "$c" >/dev/null 2>&1 || true
  done
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
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true
}
poll_http(){
  local url="$1"
  local want="$2"
  local tries="$3"
  local i c
  for i in $(seq 1 "$tries"); do
    c="$(norm "$(http_code "$url")")"
    if [ "$c" = "$want" ]; then
      printf 'ok'
      return 0
    fi
    sleep 2
  done
  printf 'fail(last=%s)' "${c:-000}"
  return 1
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
unit_prop(){
  local unit="$1"
  local prop="$2"
  local v
  v="$(systemctl --user show "$unit" -p "$prop" --value 2>/dev/null || true)"
  v="$(norm "$v")"
  if [ -z "$v" ]; then
    v=unknown
  fi
  printf '%s' "$v"
}
has_newuidmap(){
  local unit="$1"
  if journalctl --user -u "$unit.service" --no-pager 2>/dev/null | grep -q 'newuidmap'; then
    printf 'yes'
  else
    printf 'no'
  fi
}
pick_free_port_from(){
  local start="$1"
  local p c offset
  for offset in 0 1 2 3 4 5 6 7 8 9; do
    p=$((start + offset))
    c="$(norm "$(http_code "http://127.0.0.1:$p/")")"
    if [ "$c" = 000 ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf ''
}
make_oneshot_unit(){
  local file="$1"
  local desc="$2"
  local execline="$3"
  cat > "$file" <<UNIT
[Unit]
Description=$desc

[Service]
Type=oneshot
ExecStart=$execline
TimeoutStartSec=90
Delegate=yes

[Install]
WantedBy=default.target
UNIT
}
run_oneshot_test(){
  local unit="$1"
  local file="$2"
  install -D -m 644 "$file" "$SYSU/$unit.service" || return 90
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true

  local rc=0
  if ! systemctl --user start "$unit.service" >"$TMPD/$unit.start.out" 2>"$TMPD/$unit.start.err"; then
    rc=$?
  fi

  local i res status
  res="pending"
  status="unknown"
  for i in $(seq 1 30); do
    res="$(unit_prop "$unit.service" Result)"
    status="$(unit_prop "$unit.service" ExecMainStatus)"
    if [ "$res" != pending ] && [ "$res" != unknown ]; then
      break
    fi
    sleep 1
  done

  say "    journal($unit):"
  journalctl --user -u "$unit.service" -n 22 --no-pager 2>/dev/null | sed 's/^/      /' || true
  if [ -s "$TMPD/$unit.start.err" ]; then
    say "    start-err($unit):"
    tail -n 8 "$TMPD/$unit.start.err" 2>/dev/null | sed 's/^/      /' || true
  fi

  if [ "$rc" != 0 ]; then
    return "$rc"
  fi
  if [ "$res" = success ] && [ "$status" = 0 ]; then
    return 0
  fi
  return 1
}
make_serving_unit(){
  local file="$1"
  local desc="$2"
  local execline="$3"
  cat > "$file" <<UNIT
[Unit]
Description=$desc

[Service]
Type=simple
ExecStart=$execline
Restart=no
TimeoutStartSec=180
MemoryMax=2G
CPUQuota=50%
Nice=10
PrivateTmp=yes
Delegate=yes

[Install]
WantedBy=default.target
UNIT
}
run_serving_test(){
  local unit="$1"
  local file="$2"
  local cname="$3"
  local health="$4"

  install -D -m 644 "$file" "$SYSU/$unit.service" || return 90
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true

  local start_rc=0
  if ! systemctl --user start "$unit.service" >"$TMPD/$unit.start.out" 2>"$TMPD/$unit.start.err"; then
    start_rc=$?
  fi

  local ok=no i st cst hc
  for i in $(seq 1 90); do
    st="$(active_state "$unit.service")"
    cst="$(container_status "$cname")"
    hc="$(norm "$(http_code "$health")")"
    if [ "$st" = active ] && [ "$cst" = running ] && [ "$hc" = 200 ]; then
      ok=yes
      break
    fi
    if [ "$st" = failed ]; then
      break
    fi
    sleep 2
  done

  say "    journal($unit):"
  journalctl --user -u "$unit.service" -n 30 --no-pager 2>/dev/null | sed 's/^/      /' || true
  podman logs --tail 40 "$cname" 2>&1 | sed 's/^/      c: /' || true
  if [ -s "$TMPD/$unit.start.err" ]; then
    say "    start-err($unit):"
    tail -n 8 "$TMPD/$unit.start.err" 2>/dev/null | sed 's/^/      /' || true
  fi

  systemctl --user disable --now "$unit.service" >/dev/null 2>&1 || true
  podman rm -f "$cname" >/dev/null 2>&1 || true

  if [ "$ok" = yes ]; then
    return 0
  fi
  if [ "$start_rc" != 0 ]; then
    return "$start_rc"
  fi
  return 1
}

for c in bash podman systemctl journalctl curl awk sed grep python3 install cmp; do
  need_cmd "$c"
done

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

# ===================== [Q0] safe floor =====================
say "=== [Q0] safe floor: native llama-embed health ==="
if [ ! -f "$AM" ]; then
  halt "missing AM script: $AM"
fi
if [ ! -s "$MODEL" ]; then
  halt "missing embedding model: $MODEL"
fi
if ! podman image exists "$ALPINE" 2>/dev/null; then
  halt "missing Alpine image: $ALPINE"
fi
if ! podman image exists "$RUNTIME_IMAGE" 2>/dev/null; then
  halt "missing proven runtime image: $RUNTIME_IMAGE"
fi

NH="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
if [ "$NH" != 200 ]; then
  say "[Q0] native health=$NH; restarting native llama-embed.service"
  systemctl --user restart "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
  if [ "$(poll_http "http://127.0.0.1:$PORT/health" 200 30 || true)" != ok ]; then
    journalctl --user -u "$NATIVE_SERVICE.service" -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    halt "native llama-embed unhealthy; fix safe floor before flag isolation"
  fi
  NH=200
fi
say "[Q0] native llama-embed healthy on 127.0.0.1:$PORT health=$NH"

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no throwaway services, no AM patch, no AM/AA run, no ledger row."
  exit 0
fi

# ===================== [Q1] short-lived flag isolation =====================
say "=== [Q1] short-lived rootless Podman flag isolation under systemd ==="

EXEC_BASE="$PODMAN_BIN run --rm --network none $ALPINE /bin/echo BASE_OK"
make_oneshot_unit "$TMPD/$T_BASE.service" "AQ base $SFX" "$EXEC_BASE"
run_oneshot_test "$T_BASE" "$TMPD/$T_BASE.service"
BASE_RC=$?
BASE_NEWUID="$(has_newuidmap "$T_BASE")"
say "[Q1] base_rc=$BASE_RC newuidmap=$BASE_NEWUID"

EXEC_SEC="$PODMAN_BIN run --rm --security-opt=no-new-privileges --network none $ALPINE /bin/echo SEC_OK"
make_oneshot_unit "$TMPD/$T_SEC.service" "AQ security-opt $SFX" "$EXEC_SEC"
run_oneshot_test "$T_SEC" "$TMPD/$T_SEC.service"
SEC_RC=$?
SEC_NEWUID="$(has_newuidmap "$T_SEC")"
say "[Q1] security_opt_rc=$SEC_RC newuidmap=$SEC_NEWUID"

EXEC_SECHOST="$PODMAN_BIN run --rm --userns=host --security-opt=no-new-privileges --network none $ALPINE /bin/echo SECHOST_OK"
make_oneshort_unit_placeholder() {
  :
}
make_oneshot_unit "$TMPD/$T_SECHOST.service" "AQ security-opt userns-host $SFX" "$EXEC_SECHOST"
run_oneshot_test "$T_SECHOST" "$TMPD/$T_SECHOST.service"
SECHOST_RC=$?
SECHOST_NEWUID="$(has_newuidmap "$T_SECHOST")"
say "[Q1] security_opt_userns_host_rc=$SECHOST_RC newuidmap=$SECHOST_NEWUID"

EXEC_LLAMA_BASE="$PODMAN_BIN run --rm --network none --entrypoint /opt/llama/bin/llama-server $RUNTIME_IMAGE --version"
make_oneshot_unit "$TMPD/$T_LLAMA_BASE.service" "AQ llama base $SFX" "$EXEC_LLAMA_BASE"
run_oneshot_test "$T_LLAMA_BASE" "$TMPD/$T_LLAMA_BASE.service"
LLAMA_BASE_RC=$?
LLAMA_BASE_NEWUID="$(has_newuidmap "$T_LLAMA_BASE")"
say "[Q1] llama_base_rc=$LLAMA_BASE_RC newuidmap=$LLAMA_BASE_NEWUID"

EXEC_LLAMA_SEC="$PODMAN_BIN run --rm --security-opt=no-new-privileges --network none --entrypoint /opt/llama/bin/llama-server $RUNTIME_IMAGE --version"
make_oneshot_unit "$TMPD/$T_LLAMA_SEC.service" "AQ llama security-opt $SFX" "$EXEC_LLAMA_SEC"
run_oneshot_test "$T_LLAMA_SEC" "$TMPD/$T_LLAMA_SEC.service"
LLAMA_SEC_RC=$?
LLAMA_SEC_NEWUID="$(has_newuidmap "$T_LLAMA_SEC")"
say "[Q1] llama_security_opt_rc=$LLAMA_SEC_RC newuidmap=$LLAMA_SEC_NEWUID"

EXEC_LLAMA_SECHOST="$PODMAN_BIN run --rm --userns=host --security-opt=no-new-privileges --network none --entrypoint /opt/llama/bin/llama-server $RUNTIME_IMAGE --version"
make_oneshot_unit "$TMPD/$T_LLAMA_SECHOST.service" "AQ llama security-opt userns-host $SFX" "$EXEC_LLAMA_SECHOST"
run_oneshot_test "$T_LLAMA_SECHOST" "$TMPD/$T_LLAMA_SECHOST.service"
LLAMA_SECHOST_RC=$?
LLAMA_SECHOST_NEWUID="$(has_newuidmap "$T_LLAMA_SECHOST")"
say "[Q1] llama_security_opt_userns_host_rc=$LLAMA_SECHOST_RC newuidmap=$LLAMA_SECHOST_NEWUID"

NET_RC=0
NET_NEWUID=no
if podman network exists "$NET" 2>/dev/null; then
  EXEC_NET="$PODMAN_BIN run --rm --network $NET $ALPINE /bin/echo NET_OK"
  make_oneshot_unit "$TMPD/$T_NET.service" "AQ network $SFX" "$EXEC_NET"
  run_oneshot_test "$T_NET" "$TMPD/$T_NET.service"
  NET_RC=$?
  NET_NEWUID="$(has_newuidmap "$T_NET")"
  say "[Q1] network_rc=$NET_RC newuidmap=$NET_NEWUID"
else
  say "[Q1] network $NET missing; skipping network test"
fi

EXEC_MEM="$PODMAN_BIN run --rm --network none --memory 1536m $ALPINE /bin/echo MEM_OK"
make_oneshot_unit "$TMPD/$T_MEM.service" "AQ memory $SFX" "$EXEC_MEM"
run_oneshot_test "$T_MEM" "$TMPD/$T_MEM.service"
MEM_RC=$?
MEM_NEWUID="$(has_newuidmap "$T_MEM")"
say "[Q1] memory_rc=$MEM_RC newuidmap=$MEM_NEWUID"

EXEC_VOL="$PODMAN_BIN run --rm --network none -v $MODEL_DIR:/models:ro $ALPINE /bin/echo VOL_OK"
make_oneshot_unit "$TMPD/$T_VOL.service" "AQ volume $SFX" "$EXEC_VOL"
run_oneshot_test "$T_VOL" "$TMPD/$T_VOL.service"
VOL_RC=$?
VOL_NEWUID="$(has_newuidmap "$T_VOL")"
say "[Q1] volume_rc=$VOL_RC newuidmap=$VOL_NEWUID"

PUB_RC=0
PUB_NEWUID=no
PUB_SKIPPED=no
PUB_PORT="$(pick_free_port_from 18098)"
if [ -n "$PUB_PORT" ] && podman network exists "$NET" 2>/dev/null; then
  EXEC_PUB="$PODMAN_BIN run --rm --network $NET --publish 127.0.0.1:$PUB_PORT:80 $ALPINE /bin/echo PUB_OK"
  make_oneshot_unit "$TMPD/$T_PUB.service" "AQ publish $SFX" "$EXEC_PUB"
  run_oneshot_test "$T_PUB" "$TMPD/$T_PUB.service"
  PUB_RC=$?
  PUB_NEWUID="$(has_newuidmap "$T_PUB")"
  say "[Q1] publish_rc=$PUB_RC port=$PUB_PORT newuidmap=$PUB_NEWUID"
else
  PUB_SKIPPED=yes
  say "[Q1] publish test skipped (no free port or missing network)"
fi

# ===================== [Q2] short decision =====================
say "=== [Q2] short decision ==="
SECURITY_OPT_CULPRIT=no

if [ "$BASE_RC" = 0 ] && [ "$LLAMA_BASE_RC" = 0 ] && [ "$SEC_RC" != 0 ] && [ "$LLAMA_SEC_RC" != 0 ]; then
  SECURITY_OPT_CULPRIT=yes
fi
if [ "$SECURITY_OPT_CULPRIT" != yes ] && [ "$BASE_RC" = 0 ] && [ "$SEC_RC" != 0 ] && [ "$SEC_NEWUID" = yes ]; then
  SECURITY_OPT_CULPRIT=yes
fi
if [ "$SECURITY_OPT_CULPRIT" != yes ] && [ "$LLAMA_BASE_RC" = 0 ] && [ "$LLAMA_SEC_RC" != 0 ] && [ "$LLAMA_SEC_NEWUID" = yes ]; then
  SECURITY_OPT_CULPRIT=yes
fi

say "[Q2] security_opt_culprit=$SECURITY_OPT_CULPRIT"

FULL_BASE_RC=0
FULL_SEC_RC=0
FULL_BASE_NEWUID=no
FULL_SEC_NEWUID=no
FULL_CULPRIT=no

# ===================== [Q3] full serving A/B if short tests inconclusive =====================
if [ "$SECURITY_OPT_CULPRIT" != yes ]; then
  say "=== [Q3] full temporary llama serving A/B ==="
  OTHER_FAIL=""
  if [ "$NET_RC" != 0 ]; then
    OTHER_FAIL="$OTHER_FAIL net"
  fi
  if [ "$MEM_RC" != 0 ]; then
    OTHER_FAIL="$OTHER_FAIL mem"
  fi
  if [ "$VOL_RC" != 0 ]; then
    OTHER_FAIL="$OTHER_FAIL vol"
  fi
  if [ "$PUB_SKIPPED" = no ] && [ "$PUB_RC" != 0 ]; then
    OTHER_FAIL="$OTHER_FAIL pub"
  fi

  if [ -n "$OTHER_FAIL" ]; then
    say "[Q3] isolated non-security flag failure:$OTHER_FAIL"
    halt "flag isolation found a non-security-opt failure; paste [Q1]/[Q3] journals before promotion"
  fi

  FULL_PORT_BASE="$(pick_free_port_from 18110)"
  FULL_PORT_SEC="$(pick_free_port_from 18120)"
  if [ -z "$FULL_PORT_BASE" ] || [ -z "$FULL_PORT_SEC" ]; then
    halt "could not allocate temporary ports for full serving A/B"
  fi

  EXEC_FULL_BASE="$PODMAN_BIN run --rm \\
    --name $C_FULL_BASE \\
    --network $NET \\
    --publish 127.0.0.1:$FULL_PORT_BASE:8081 \\
    --memory 1536m \\
    -v $MODEL_DIR:/models:ro \\
    --entrypoint /opt/llama/bin/llama-server \\
    $RUNTIME_IMAGE \\
    --model $MODEL_CONTAINER \\
    --host 0.0.0.0 \\
    --port 8081 \\
    --embedding \\
    --pooling mean \\
    --ctx-size 2048 \\
    --threads 2 \\
    --parallel 1 \\
    --alias nomic-embed-text"

  make_serving_unit "$TMPD/$T_FULL_BASE.service" "AQ full llama base $SFX" "$EXEC_FULL_BASE"
  run_serving_test "$T_FULL_BASE" "$TMPD/$T_FULL_BASE.service" "$C_FULL_BASE" "http://127.0.0.1:$FULL_PORT_BASE/health"
  FULL_BASE_RC=$?
  FULL_BASE_NEWUID="$(has_newuidmap "$T_FULL_BASE")"
  say "[Q3] full_base_rc=$FULL_BASE_RC port=$FULL_PORT_BASE newuidmap=$FULL_BASE_NEWUID"

  if [ "$FULL_BASE_RC" != 0 ]; then
    halt "full llama serving without security-opt failed under systemd; do not promote. Paste [Q3] journal."
  fi

  EXEC_FULL_SEC="$PODMAN_BIN run --rm \\
    --name $C_FULL_SEC \\
    --network $NET \\
    --publish 127.0.0.1:$FULL_PORT_SEC:8081 \\
    --memory 1536m \\
    --security-opt=no-new-privileges \\
    -v $MODEL_DIR:/models:ro \\
    --entrypoint /opt/llama/bin/llama-server \\
    $RUNTIME_IMAGE \\
    --model $MODEL_CONTAINER \\
    --host 0.0.0.0 \\
    --port 8081 \\
    --embedding \\
    --pooling mean \\
    --ctx-size 2048 \\
    --threads 2 \\
    --parallel 1 \\
    --alias nomic-embed-text"

  make_serving_unit "$TMPD/$T_FULL_SEC.service" "AQ full llama security-opt $SFX" "$EXEC_FULL_SEC"
  run_serving_test "$T_FULL_SEC" "$TMPD/$T_FULL_SEC.service" "$C_FULL_SEC" "http://127.0.0.1:$FULL_PORT_SEC/health"
  FULL_SEC_RC=$?
  FULL_SEC_NEWUID="$(has_newuidmap "$T_FULL_SEC")"
  say "[Q3] full_security_opt_rc=$FULL_SEC_RC port=$FULL_PORT_SEC newuidmap=$FULL_SEC_NEWUID"

  if [ "$FULL_BASE_RC" = 0 ] && [ "$FULL_SEC_RC" != 0 ]; then
    FULL_CULPRIT=yes
  fi

  say "[Q3] full_culprit=$FULL_CULPRIT"
else
  say "=== [Q3] skipped full serving A/B because short tests already proved security-opt culprit ==="
fi

# ===================== [Q4] patch AM if proven =====================
if [ "$SECURITY_OPT_CULPRIT" != yes ] && [ "$FULL_CULPRIT" != yes ]; then
  say "[Q4] security-opt culprit not proven."
  say "[Q4] base_rc=$BASE_RC sec_rc=$SEC_RC llama_base_rc=$LLAMA_BASE_RC llama_sec_rc=$LLAMA_SEC_RC"
  say "[Q4] full_base_rc=$FULL_BASE_RC full_sec_rc=$FULL_SEC_RC"
  halt "no evidence-based patch selected; native llama-embed remains safe floor"
fi

say "=== [Q4] patch AM to remove --security-opt=no-new-privileges and keep default rootless userns ==="
CAND="$TMPD/am.candidate"
PY="$TMPD/patch_am_q.py"
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
    stripped = line.strip()
    if stripped == "NoNewPrivileges=yes":
        changed = True
        continue
    if "--security-opt=no-new-privileges" in line:
        changed = True
        continue
    if "--userns=host" in line:
        changed = True
        continue
    new.append(line)

if not any(l.strip() == "Delegate=yes" for l in new):
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
say "[Q4] AM candidate patched; bash -n OK"

if [ ! -f "$AM_BAK" ]; then
  cp -p "$AM" "$AM_BAK"
  say "[Q4] AM backup -> $AM_BAK"
fi
if ! cp -p "$CAND" "$AM"; then
  halt "could not install patched AM"
fi
if ! bash -n "$AM"; then
  cp -p "$AM_BAK" "$AM" 2>/dev/null || true
  halt "installed patched AM failed bash -n; restored backup"
fi
say "[Q4] installed patched AM -> $AM"

AQ_TOKEN="aq-security-opt-no-new-privileges-rootless-userns-defect"
AM_TOKEN="llama-embed-container-promotion-v1"

if ! grep -qF "$AQ_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AQ flag isolation proved the real blocker was podman run --security-opt=no-new-privileges under rootless default userns on this Ubuntu 26.04 / Podman 5.7.0 stack. AP had already disproved generic systemd/userns failure. AM patched to remove --security-opt=no-new-privileges and avoid --userns=host, preserving default rootless UID remapping. security_short=%s full_short=%s base_rc=%s sec_rc=%s llama_base_rc=%s llama_sec_rc=%s full_base_rc=%s full_sec_rc=%s. |\n' \
    "$(date +%F)" \
    "$AQ_TOKEN" \
    "$SECURITY_OPT_CULPRIT" \
    "$FULL_CULPRIT" \
    "$BASE_RC" \
    "$SEC_RC" \
    "$LLAMA_BASE_RC" \
    "$LLAMA_SEC_RC" \
    "$FULL_BASE_RC" \
    "$FULL_SEC_RC" >> "$IDX"
  say "[Q4] AQ correction row appended."
else
  say "[Q4] AQ correction row already present (guard suppressed)."
fi
grep -qF "$AQ_TOKEN" "$IDX" 2>/dev/null && say "[Q4] suppression proof: sentinel present." || say "[Q4] WARNING: sentinel missing."

# ===================== [Q5] rerun patched AM =====================
say "=== [Q5] rerun patched AM ==="
"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true
bash "$AM"
AMRC=$?
say "[Q5] AM rc=$AMRC"

if ! grep -qF "$AM_TOKEN" "$IDX" 2>/dev/null; then
  say "[Q5] AM promotion sentinel missing; inspect AM output above."
  halt "patched AM did not produce llama-embed-container-promotion-v1 despite proven flag isolation"
fi

say "[Q5] container_service_active=$(active_state "$CONT_SERVICE.service")"
say "[Q5] container_status=$(container_status "$CONTAINER_NAME")"
say "[Q5] no_new_privileges=$(unit_prop "$CONT_SERVICE.service" NoNewPrivileges)"
say "[Q5] delegate=$(unit_prop "$CONT_SERVICE.service" Delegate)"

# ===================== [Q6] reconcile core stack =====================
if [ -f "$AA" ]; then
  say "=== [Q6] run AA green-stack reconcile ==="
  bash "$AA"
  AARC=$?
  say "[Q6] AA rc=$AARC"
else
  say "[Q6] AA script missing: $AA"
fi

# ===================== [Q7] core gate =====================
say "=== [Q7] core stack gate ==="
CORE_OK=yes
for s in postgres redis minio weaviate; do
  ACT="$(active_state "$s.service")"
  CST="$(container_status "$s")"
  say "[Q7] $s active=$ACT container=$CST"
  if [ "$ACT" != active ] || [ "$CST" != running ]; then
    CORE_OK=no
  fi
done

if [ "$CORE_OK" != yes ]; then
  say "[Q7] core stack not fully active+running; paste [Q6]/[Q7]."
  halt "llama-embed container promoted but core stack not green"
fi

say "[RESULT] LLAMA-EMBED CONTAINER PROMOTED AFTER SECURITY-OPT FLAG HEAL — service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1 host_admin=http://127.0.0.1:$PORT; AQ proved podman --security-opt=no-new-privileges was the real blocker and AM now uses default rootless userns remapping; native llama-embed retained disabled for rollback; next brick LiteLLM; still no Ollama/OpenWebUI/chat-model."
exit 0
