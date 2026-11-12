#!/usr/bin/env bash
# 20261029-AN — heal post-reboot rootless Podman namespace/pause state, then retry AM only if safe.
# Root cause from AM:
#   podman run failed with newuidmap Operation not permitted and suggested podman system migrate.
# This script:
#   1) collects non-secret rootless Podman / userns / AppArmor evidence;
#   2) runs podman system migrate;
#   3) proves basic rootless container execution with cached alpine;
#   4) verifies native llama-embed rollback health;
#   5) reports core Podman stack state;
#   6) retries AM only if basic container smoke passes;
#   7) appends a guarded ledger row.
# Safety:
#   - no sudo
#   - no image pull unless alpine is already cached; if missing, it halts rather than surprise-pulling
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
FM="$CD/20261029-AM-llama-embed-container-promote.sh"

NATIVE_SERVICE="llama-embed"
CONT_SERVICE="llama-embed-container"
CONTAINER_NAME="llama-embed"
PORT="8081"
ALPINE="docker.io/library/alpine:latest"

TOKEN="rootless-podman-post-reboot-heal-v1"
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

for c in bash podman systemctl loginctl grep sysctl cat awk sed head tail install curl; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

if [ ! -f "$FM" ]; then
  halt "missing AM script: $FM"
fi

# ===================== [N0] identity/session =====================
say "=== [N0] identity/session ==="
say "[N0] user=$USER uid=$(id -u) home=$HOME"
say "[N0] xdg_runtime_dir=${XDG_RUNTIME_DIR:-unset}"
LINGER="$(loginctl show-user "$USER" --property=Linger 2>/dev/null || true)"
LINGER="$(norm "$LINGER")"
if [ -z "$LINGER" ]; then
  LINGER=unknown
fi
say "[N0] loginctl_linger=$LINGER"

# ===================== [N1] subuid/subgid evidence =====================
say "=== [N1] subuid/subgid evidence ==="
SUBUID_STATUS=unknown
SUBGID_STATUS=unknown
SUBUID_LINE=""
SUBGID_LINE=""

if [ -r /etc/subuid ]; then
  SUBUID_LINE="$(grep -m1 "^$USER:" /etc/subuid 2>/dev/null || true)"
  SUBUID_LINE="$(norm "$SUBUID_LINE")"
  if [ -n "$SUBUID_LINE" ]; then
    SUBUID_STATUS=present
  else
    SUBUID_STATUS=missing
  fi
else
  SUBUID_STATUS=unreadable
fi

if [ -r /etc/subgid ]; then
  SUBGID_LINE="$(grep -m1 "^$USER:" /etc/subgid 2>/dev/null || true)"
  SUBGID_LINE="$(norm "$SUBGID_LINE")"
  if [ -n "$SUBGID_LINE" ]; then
    SUBGID_STATUS=present
  else
    SUBGID_STATUS=missing
  fi
else
  SUBGID_STATUS=unreadable
fi

say "[N1] subuid_status=$SUBUID_STATUS line=${SUBUID_LINE:-none}"
say "[N1] subgid_status=$SUBGID_STATUS line=${SUBGID_LINE:-none}"

if [ "$SUBUID_STATUS" = missing ] || [ "$SUBGID_STATUS" = missing ]; then
  say "[N1] missing subordinate UID/GID range is a known rootless Podman blocker."
  say "[N1] privileged remediation required, for example:"
  say "      sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER"
  say "      podman system migrate"
  halt "subuid/subgid missing for $USER; cannot safely retry rootless container promotion"
fi

# ===================== [N2] kernel userns sysctls =====================
say "=== [N2] kernel/userns sysctls ==="
UNPRIV="$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || true)"
UNPRIV="$(norm "$UNPRIV")"
MAXNS="$(sysctl -n user.max_user_namespaces 2>/dev/null || true)"
MAXNS="$(norm "$MAXNS")"
APPRESTRICT="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || true)"
APPRESTRICT="$(norm "$APPRESTRICT")"

say "[N2] kernel.unprivileged_userns_clone=${UNPRIV:-unknown}"
say "[N2] user.max_user_namespaces=${MAXNS:-unknown}"
say "[N2] kernel.apparmor_restrict_unprivileged_userns=${APPRESTRICT:-unknown}"

if [ "$UNPRIV" = 0 ]; then
  say "[N2] unprivileged user namespaces are disabled by kernel sysctl."
  say "[N2] privileged remediation required:"
  say "      sudo sysctl -w kernel.unprivileged_userns_clone=1"
  halt "kernel.unprivileged_userns_clone=0 blocks rootless Podman"
fi

if [ "$MAXNS" = 0 ]; then
  say "[N2] user namespaces are disabled by max_user_namespaces=0."
  say "[N2] privileged remediation required:"
  say "      sudo sysctl -w user.max_user_namespaces=15000"
  halt "user.max_user_namespaces=0 blocks rootless Podman"
fi

# ===================== [N3] AppArmor evidence =====================
say "=== [N3] AppArmor evidence ==="
APPARMOR_ENABLED="$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || true)"
APPARMOR_ENABLED="$(norm "$APPARMOR_ENABLED")"
if [ -z "$APPARMOR_ENABLED" ]; then
  APPARMOR_ENABLED=unknown
fi
say "[N3] apparmor_enabled=$APPARMOR_ENABLED"
say "[N3] apparmor_restrict_unprivileged_userns=${APPRESTRICT:-unknown}"

if [ "$APPARMOR_ENABLED" = Y ] && [ "$APPRESTRICT" = 1 ]; then
  say "[N3] WARNING: AppArmor unprivileged-userns restriction appears active."
  say "[N3] The basic container smoke test below will decide whether this is fatal."
fi

# ===================== [N4] Podman version/info =====================
say "=== [N4] Podman version/info ==="
PVER="$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)"
PVER="$(norm "$PVER")"
say "[N4] podman_version=${PVER:-unknown}"

PROOT="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
PCGROUP="$(podman info --format '{{.Host.CgroupManager}}' 2>/dev/null || true)"
PNET="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
say "[N4] rootless=${PROOT:-unknown} cgroup_manager=${PCGROUP:-unknown} network_backend=${PNET:-unknown}"

if [ "$DRY" = 1 ]; then
  NH_DRY="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
  say "[N4-dry] native llama-embed health now=${NH_DRY:-000}"
  say "[RESULT] DRY-RUN complete; no podman system migrate, no container smoke, no native restart, no AM retry, no ledger row."
  exit 0
fi

# ===================== [N5] reset stale rootless Podman pause state =====================
say "=== [N5] podman system migrate ==="
MIGRATE_RC=0
if podman system migrate >"$TMPD/migrate.out" 2>"$TMPD/migrate.err"; then
  say "[N5] podman system migrate OK"
  head -n 8 "$TMPD/migrate.out" 2>/dev/null | sed 's/^/    /' || true
else
  MIGRATE_RC=$?
  say "[N5] podman system migrate rc=$MIGRATE_RC"
  tail -n 12 "$TMPD/migrate.err" 2>/dev/null | sed 's/^/    /' || true
fi

# ===================== [N6] basic rootless container smoke =====================
say "=== [N6] basic rootless container smoke ==="
SMOKE_RC=125
SMOKE_MSG="alpine image missing"

if podman image exists "$ALPINE" 2>/dev/null; then
  if podman run --rm --network none "$ALPINE" /bin/echo ok >"$TMPD/smoke.out" 2>"$TMPD/smoke.err"; then
    SMOKE_RC=0
    SMOKE_MSG="$(norm "$(cat "$TMPD/smoke.out" 2>/dev/null || true)")"
    say "[N6] smoke OK output=$SMOKE_MSG"
  else
    SMOKE_RC=$?
    SMOKE_MSG="smoke failed"
    say "[N6] smoke rc=$SMOKE_RC"
    tail -n 15 "$TMPD/smoke.err" 2>/dev/null | sed 's/^/    /' || true
  fi
else
  say "[N6] alpine image missing: $ALPINE"
fi

# ===================== [N7] native llama-embed rollback health =====================
say "=== [N7] native llama-embed rollback health ==="
NH="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
if [ "$NH" != 200 ]; then
  say "[N7] native health=$NH; restarting native llama-embed.service"
  systemctl --user restart "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
  NATIVE_HP="$(poll_http "http://127.0.0.1:$PORT/health" 200 30 || true)"
  if [ "$NATIVE_HP" != ok ]; then
    journalctl --user -u "$NATIVE_SERVICE.service" -n 35 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    halt "native llama-embed rollback is unhealthy; fix brick 5 native service before retrying container promotion"
  fi
  NH=200
fi
say "[N7] native llama-embed healthy on 127.0.0.1:$PORT health=$NH"

# ===================== [N8] core Podman stack state =====================
say "=== [N8] core Podman stack state ==="
CORE_MISSING=no
for s in postgres redis minio weaviate; do
  ACT="$(active_state "$s.service")"
  CST="$(container_status "$s")"
  say "[N8] $s active=$ACT container=$CST"
  if [ "$ACT" != active ] || [ "$CST" != running ]; then
    CORE_MISSING=yes
  fi
done

if [ "$CORE_MISSING" = yes ]; then
  say "[N8] core stack is not fully running. After rootless Podman is healed, run AA green-stack reconcile before LiteLLM."
else
  say "[N8] core stack active+running"
fi

# ===================== [N9] guarded ledger row =====================
say "=== [N9] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | DIAG | %s | APPEND-ONLY | post-reboot rootless Podman heal: migrate_rc=%s smoke_rc=%s smoke_msg=%s unprivileged_userns_clone=%s max_user_namespaces=%s apparmor_enabled=%s apparmor_restrict=%s subuid=%s subgid=%s native_health=%s core_missing=%s; no sudo executed; no model download; no ollama/open-webui. |\n' \
    "$(date +%F)" \
    "$TOKEN" \
    "$MIGRATE_RC" \
    "$SMOKE_RC" \
    "$SMOKE_MSG" \
    "${UNPRIV:-unknown}" \
    "${MAXNS:-unknown}" \
    "$APPARMOR_ENABLED" \
    "${APPRESTRICT:-unknown}" \
    "$SUBUID_STATUS" \
    "$SUBGID_STATUS" \
    "$NH" \
    "$CORE_MISSING" >> "$IDX"
  say "[N9] ledger row appended."
else
  say "[N9] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[N9] suppression proof: sentinel present." || say "[N9] WARNING: sentinel missing."

# ===================== [N10] decision =====================
say "=== [N10] decision ==="

if [ "$SMOKE_RC" != 0 ]; then
  say "[N10] basic rootless container smoke failed; not retrying AM."
  say "[N10] likely causes: stale Podman pause state not cleared, AppArmor unprivileged-userns restriction, kernel userns sysctl, or missing subuid/subgid."

  if [ "$APPARMOR_ENABLED" = Y ] && [ "$APPRESTRICT" = 1 ]; then
    say "[N10] AppArmor restriction is active. Preferred enterprise fix: load/keep a targeted Podman/newuidmap AppArmor profile."
    say "[N10] Solo-lab temporary fix, if accepted:"
    say "      sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
    say "      podman system migrate"
    say "[N10] Persistence should be deliberate, e.g. /etc/sysctl.d/99-rootless-containers.conf, not silent."
  fi

  say "[N10] After any privileged host fix, rerun:"
  say "      bash $FN"
  halt "rootless Podman basic container smoke failed; AM retry withheld"
fi

say "[N10] basic rootless container smoke passed; retrying AM"
bash "$FM"
AMRC=$?
say "[N10] AM rc=$AMRC"

if grep -qF "$AM_TOKEN" "$IDX" 2>/dev/null; then
  say "[N10] AM promotion sentinel present."
else
  halt "AM retry did not produce llama-embed-container-promotion-v1; inspect AM output above"
fi

say "[RESULT] ROOTLESS PODMAN HEALED + LLAMA-EMBED CONTAINER PROMOTION GREEN — service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1; next brick LiteLLM; still no Ollama/OpenWebUI/models."
exit 0
