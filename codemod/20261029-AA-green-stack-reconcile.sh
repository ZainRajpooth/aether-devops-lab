#!/usr/bin/env bash
# 20261029-AA — reconcile rootless Podman green stack after Z showed containers=0.
# Scope:
#   - ensure aether Podman network exists
#   - reload Quadlet-generated user units
#   - start/re-enable known green services
#   - verify active + running
#   - lightweight probes for redis/postgres/http endpoints
#   - report loginctl linger state
# Safety:
#   - no sudo
#   - no image pulls
#   - no model loads
#   - no volume deletion
#   - no old Docker container interaction
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
QD="$A/infra/quadlet"
SYS="$HOME/.config/containers/systemd"
IDX="$CD/INDEX.md"
NET="aether"
TOKEN="green-stack-reconcile-v1"

SERVICES=(
  postgres
  redis
  minio
  weaviate
  prometheus
  node-exporter
  mailpit
)

CORE=(
  postgres
  redis
  minio
  weaviate
)

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
free_kb(){
  df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'
}
used_pct(){
  df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'
}
kb_to_gib(){
  awk -v k="$(to_int "${1:-0}")" 'BEGIN{printf "%.2fGiB", k/1048576}'
}
print_disk(){
  local label="$1"
  local p="$2"
  local uk ak pct
  uk="$(to_int "$(df -Pk "$p" 2>/dev/null | awk 'NR==2{print $3}')")"
  ak="$(to_int "$(free_kb "$p")")"
  pct="$(norm "$(used_pct "$p")")"
  say "[$label] $p used=$(kb_to_gib "$uk") avail=$(kb_to_gib "$ak") =${pct:-?}%"
}
is_core(){
  local svc="$1"
  local c
  for c in "${CORE[@]}"; do
    if [ "$c" = "$svc" ]; then
      return 0
    fi
  done
  return 1
}
unit_exists(){
  systemctl --user cat "$1.service" >/dev/null 2>&1
}
unit_file_state(){
  local s
  s="$(systemctl --user is-enabled "$1.service" 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=unknown
  fi
  printf '%s' "$s"
}
active_state(){
  local s
  s="$(systemctl --user is-active "$1.service" 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=inactive
  fi
  printf '%s' "$s"
}
container_state(){
  local s
  s="$(podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=absent
  fi
  printf '%s' "$s"
}
probe_http(){
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      printf 'ok'
    else
      printf 'fail'
    fi
  else
    printf 'no-curl'
  fi
}

for c in bash podman systemctl df awk sed grep curl loginctl; do
  need_cmd "$c"
done

# ===================== [A0] state before =====================
say "=== [A0] disk/runtime before reconcile ==="
print_disk A0 /home
print_disk A0 /

say "[A0] podman system df:"
podman system df 2>/dev/null | sed 's/^/    /' || true

say "[A0] relevant user units:"
systemctl --user list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(postgres|redis|minio|weaviate|prometheus|node-exporter|mailpit)\.service$' | sed 's/^/    unit-file: /' || true

say "[A0] relevant active units:"
systemctl --user list-units --type=service --all --no-pager 2>/dev/null | grep -E '(postgres|redis|minio|weaviate|prometheus|node-exporter|mailpit)\.service' | sed 's/^/    /' || true

# ===================== [A1] network =====================
say "=== [A1] Podman network ==="
if podman network exists "$NET" 2>/dev/null; then
  say "[A1] network present: $NET"
else
  if [ "$DRY" = 1 ]; then
    say "[A1] dry-run: would create Podman network $NET"
  else
    if podman network create "$NET" >/dev/null 2>&1; then
      say "[A1] created Podman network $NET"
    else
      halt "could not create Podman network $NET; core Quadlets expect this network"
    fi
  fi
fi

# ===================== [A2] reload Quadlet units =====================
say "=== [A2] systemd user daemon reload ==="
if [ "$DRY" = 1 ]; then
  say "[A2] dry-run: would run systemctl --user daemon-reload"
else
  systemctl --user daemon-reload || true
  say "[A2] daemon-reload complete"
fi

# ===================== [A3] start/reconcile services =====================
say "=== [A3] reconcile services ==="
MISSING_CORE_UNITS=no

for svc in "${SERVICES[@]}"; do
  say "--- $svc ---"

  if ! unit_exists "$svc"; then
    if [ -f "$QD/$svc.container" ] || [ -f "$SYS/$svc.container" ]; then
      if [ "$DRY" = 0 ]; then
        systemctl --user daemon-reload || true
      fi
    fi
  fi

  if ! unit_exists "$svc"; then
    say "[A3] unit missing: $svc.service"
    if is_core "$svc"; then
      MISSING_CORE_UNITS=yes
    fi
    continue
  fi

  EN="$(unit_file_state "$svc")"
  say "[A3] enabled=$EN"

  if [ "$DRY" = 0 ]; then
    systemctl --user reset-failed "$svc.service" >/dev/null 2>&1 || true

    if [ "$EN" != enabled ]; then
      systemctl --user enable "$svc.service" >/dev/null 2>&1 || true
      EN="$(unit_file_state "$svc")"
      say "[A3] enabled now=$EN"
    fi

    systemctl --user start "$svc.service" >/dev/null 2>&1 || true
  fi

  ACT="inactive"
  CST="absent"

  for i in $(seq 1 30); do
    ACT="$(active_state "$svc")"
    if [ "$ACT" = active ]; then
      CST="$(container_state "$svc")"
      if [ "$CST" = running ]; then
        break
      fi
    fi
    sleep 1
  done

  PROBE="skipped"

  if [ "$ACT" = active ] && [ "$CST" = running ]; then
    case "$svc" in
      redis)
        RO="$(podman exec redis redis-cli ping 2>&1 || true)"
        RO="$(norm "$RO")"
        case "$RO" in
          *PONG*|*NOAUTH*)
            PROBE="ok($RO)"
            ;;
          *)
            PROBE="fail($RO)"
            ;;
        esac
        ;;
      postgres)
        PO="$(podman exec postgres sh -c 'pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1 || true)"
        PO="$(norm "$PO")"
        if printf '%s\n' "$PO" | grep -qi 'accepting connections'; then
          PROBE="ok"
        else
          PROBE="fail($PO)"
        fi
        ;;
      minio)
        PROBE="$(probe_http http://127.0.0.1:9000/minio/health/live)"
        ;;
      weaviate)
        PROBE="$(probe_http http://127.0.0.1:8080/v1/.well-known/ready)"
        ;;
      prometheus)
        PROBE="$(probe_http http://127.0.0.1:9090/-/healthy)"
        ;;
      node-exporter)
        PROBE="$(probe_http http://127.0.0.1:9100/metrics)"
        ;;
      mailpit)
        PROBE="$(probe_http http://127.0.0.1:8025/)"
        ;;
      *)
        PROBE="none"
        ;;
    esac
  fi

  say "[A3] active=$ACT container=$CST probe=$PROBE"
done

if [ "$MISSING_CORE_UNITS" = yes ]; then
  halt "core Podman/Quadlet units are missing. Do not proceed until units are restored from codemod/quadlet sources."
fi

# ===================== [A4] core runtime gate =====================
say "=== [A4] core runtime gate ==="
CORE_RUNTIME_FAIL=no

for svc in "${CORE[@]}"; do
  ACT="$(active_state "$svc")"
  CST="$(container_state "$svc")"
  say "[A4] $svc active=$ACT container=$CST"
  if [ "$ACT" != active ] || [ "$CST" != running ]; then
    CORE_RUNTIME_FAIL=yes
  fi
done

if [ "$DRY" = 0 ] && [ "$CORE_RUNTIME_FAIL" = yes ]; then
  say "[A4] failure logs:"
  for svc in "${CORE[@]}"; do
    journalctl --user -u "$svc.service" -n 20 --no-pager 2>/dev/null | sed "s/^/    $svc j: /" || true
  done
  halt "core services did not reach active+running. Paste [A4] logs; do not proceed to llama.cpp yet."
fi

# ===================== [A5] linger check =====================
say "=== [A5] rootless linger check ==="
LINGER="$(loginctl show-user "$USER" --property=Linger 2>/dev/null || true)"
LINGER="$(norm "$LINGER")"
if [ -z "$LINGER" ]; then
  LINGER=unknown
fi
say "[A5] loginctl_linger=$LINGER"

if [ "$LINGER" != yes ]; then
  say "[A5] hint: to keep rootless services alive across logout/reboot, run:"
  say "      loginctl enable-linger $USER"
  say "      systemctl --user daemon-reload"
fi

# ===================== [A6] final state =====================
say "=== [A6] final runtime state ==="
print_disk A6 /home
print_disk A6 /

say "[A6] podman system df:"
podman system df 2>/dev/null | sed 's/^/    /' || true

say "[A6] podman ps:"
podman ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | sed 's/^/    /' || true

SUMMARY=""
for svc in "${SERVICES[@]}"; do
  ACT="$(active_state "$svc")"
  CST="$(container_state "$svc")"
  SUMMARY="${SUMMARY} ${svc}=${ACT}/${CST}"
done

# ===================== [A7] guarded ledger row =====================
say "=== [A7] ledger row ==="
if [ "$DRY" = 1 ]; then
  say "[A7] dry-run: would append ledger row if absent"
else
  if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
    echo "| $(date +%F) | B | 20261029-AA-green-stack-reconcile | GATE=PASS | $TOKEN: reconciled rootless Podman green stack after Z showed containers=0; network=$NET; services:$SUMMARY; core_gate=PASS; linger=$LINGER; no images pulled; no models loaded; no volumes deleted. |" >> "$IDX"
    say "[A7] ledger row appended."
  else
    say "[A7] ledger row already present (guard suppressed)."
  fi
  grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[A7] suppression proof: sentinel present." || say "[A7] WARNING: sentinel missing."
fi

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no network create, no daemon reload, no enable/start, no ledger row."
else
  say "[RESULT] GREEN STACK RECONCILED — core Podman services are active+running; next brick can be llama.cpp native service, still no Ollama/OpenWebUI/models beyond existing GGUF inventory."
fi
exit 0
