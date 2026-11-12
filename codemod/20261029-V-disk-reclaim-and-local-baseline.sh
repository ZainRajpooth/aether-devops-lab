#!/usr/bin/env bash
# 20261029-V — disk reclaim + gated restic baseline for the green rootless Podman stack.
# Safe reclaim only: dangling images, build cache, optional user journal vacuum.
# Baseline policy:
#   external media detected -> full external backup + enable timer
#   local staging           -> full local backup only with --allow-local and free-space gate; timer stays disabled unless --enable-local-timer
# Hard rules: multi-line if/then/fi only; bash -n mandatory before run; no heredoc inside $( ); no secret echo; no sudo.
set -uo pipefail

DRY=0
ALLOW_LOCAL=0
ENABLE_LOCAL_TIMER=0

for arg in "$@"; do
  case "$arg" in
    --check)
      DRY=1
      ;;
    --allow-local)
      ALLOW_LOCAL=1
      ;;
    --enable-local-timer)
      ENABLE_LOCAL_TIMER=1
      ;;
    *)
      printf '[HALT] unknown argument: %s\n' "$arg" >&2
      exit 0
      ;;
  esac
done

A="$HOME/DevOps/aether"
CD="$A/codemod"
BIN="$A/bin"
ETC="$HOME/.config/aether"
IDX="$CD/INDEX.md"
BACKUP_SCRIPT="$BIN/40_restic_dr.sh"
RESTIC_PASS="$ETC/restic-password"
TOKEN="disk-reclaim-local-baseline-v1"
GREEN_SERVICES="postgres minio weaviate redis"

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
is_uint(){
  case "${1:-}" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}
active_service(){
  local s
  s=$(systemctl --user is-active "$1.service" 2>/dev/null || true)
  s=$(norm "$s")
  if [ -z "$s" ]; then
    s=inactive
  fi
  printf '%s' "$s"
}
assert_green(){
  local s st
  for s in $GREEN_SERVICES; do
    st=$(active_service "$s")
    if [ "$st" != active ]; then
      halt "green service not active: $s=$st"
    fi
  done
}
free_kb(){
  df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'
}
used_pct(){
  df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'
}
used_kb(){
  df -Pk "$1" 2>/dev/null | awk 'NR==2{print $3}'
}
kb_to_gib(){
  awk -v k="${1:-0}" 'BEGIN{printf "%.2fGiB", k/1048576}'
}
bytes_to_gib(){
  awk -v b="${1:-0}" 'BEGIN{printf "%.2fGiB", b/1073741824}'
}
print_disk(){
  local label="$1" p="$2" pct uk ak
  pct=$(used_pct "$p")
  uk=$(used_kb "$p")
  ak=$(free_kb "$p")
  say "[$label] $p used=$(kb_to_gib "$uk") avail=$(kb_to_gib "$ak") =${pct}%"
}
podman_df(){
  podman system df 2>/dev/null | sed 's/^/    /' || true
}

need_cmd bash
need_cmd podman
need_cmd systemctl
need_cmd df
need_cmd awk
need_cmd sed
need_cmd du
need_cmd python3

assert_green

# ===================== [V0] disk before =====================
say "=== [V0] disk before safe reclaim ==="
print_disk before /home
print_disk before /
say "[V0] podman df before:"
podman_df

# ===================== [V1] safe reclaim =====================
if [ "$DRY" = 0 ]; then
  say "=== [V1] safe reclaim: dangling images + build cache + optional user journal vacuum ==="
  podman image prune -f 2>&1 | sed 's/^/    /' || true
  podman builder prune -f 2>&1 | sed 's/^/    /' || true
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --user --vacuum-size=200M 2>&1 | sed 's/^/    /' || true
  fi
  assert_green
  say "[V1] disk after safe reclaim:"
  print_disk after /home
  print_disk after /
  say "[V1] podman df after:"
  podman_df
else
  say "[V1] dry-run: no prune, no journal vacuum"
fi

# ===================== [V2] estimate backup scope =====================
say "=== [V2] estimate first backup scope ==="
HAVE_UNSHARE=no
if podman unshare true >/dev/null 2>&1; then
  HAVE_UNSHARE=yes
fi
say "[V2] podman_unshare_available=$HAVE_UNSHARE"

TOTAL_BYTES=0
add_path_size(){
  local label="$1" path="$2" size=""
  if [ ! -e "$path" ]; then
    say "    $label missing: $path"
    return 0
  fi
  if [ "$HAVE_UNSHARE" = yes ]; then
    size=$(podman unshare du -sb "$path" 2>/dev/null | awk 'NR==1{print $1}' || true)
  else
    size=$(du -sb "$path" 2>/dev/null | awk 'NR==1{print $1}' || true)
  fi
  size=$(norm "$size")
  if ! is_uint "$size"; then
    size=0
  fi
  TOTAL_BYTES=$((TOTAL_BYTES + size))
  say "    $label $(bytes_to_gib "$size") path=$path"
}

for vol in postgres_data minio_data weaviate_data redis_data; do
  mp=$(podman volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
  mp=$(norm "$mp")
  if [ -n "$mp" ]; then
    add_path_size "volume:$vol" "$mp"
  else
    say "    volume:$vol missing mountpoint"
  fi
done

add_path_size "config:aether" "$HOME/.config/aether"
add_path_size "config:containers-systemd" "$HOME/.config/containers/systemd"
add_path_size "repo:aether" "$HOME/DevOps/aether"

EST_BYTES=$((TOTAL_BYTES * 125 / 100 + 1073741824))
say "[V2] raw_scope=$(bytes_to_gib "$TOTAL_BYTES") estimated_initial_backup=$(bytes_to_gib "$EST_BYTES")"

# ===================== [V3] restic status =====================
say "=== [V3] restic status ==="
if [ ! -x "$BACKUP_SCRIPT" ]; then
  halt "backup script missing/not executable: $BACKUP_SCRIPT; rerun U first"
fi

STATUS_OUT=$("$BACKUP_SCRIPT" --status 2>&1)
SRC=$?
if [ "$SRC" != 0 ]; then
  printf '%s\n' "$STATUS_OUT" | sed 's/^/    /' || true
  halt "backup script --status failed rc=$SRC"
fi

parse_status(){
  local key="$1"
  printf '%s\n' "$STATUS_OUT" | awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}'
}

REPO=$(parse_status AETHER_BACKUP_REPO)
MODE=$(parse_status AETHER_BACKUP_MODE)
WRAPPER=$(parse_status AETHER_BACKUP_WRAPPER)
REPO=$(norm "$REPO")
MODE=$(norm "$MODE")
WRAPPER=$(norm "$WRAPPER")
say "[V3] repo=$REPO mode=$MODE wrapper=$WRAPPER"

RESTIC_BIN=""
if [ -x "$HOME/.local/bin/restic" ]; then
  RESTIC_BIN="$HOME/.local/bin/restic"
elif command -v restic >/dev/null 2>&1; then
  RESTIC_BIN="$(command -v restic)"
fi
if [ -z "$RESTIC_BIN" ]; then
  halt "restic binary not found"
fi

restic_cmd(){
  if [ "$WRAPPER" = podman-unshare ]; then
    podman unshare "$RESTIC_BIN" "$@"
  else
    "$RESTIC_BIN" "$@"
  fi
}

SNAP_COUNT=0
if [ -s "$RESTIC_PASS" ] && [ -n "$REPO" ]; then
  SNAP_JSON=$(restic_cmd -r "$REPO" --password-file "$RESTIC_PASS" snapshots --json 2>/dev/null || true)
  SNAP_COUNT=$(printf '%s' "$SNAP_JSON" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(len(json.loads(d)) if d else 0)" 2>/dev/null || echo 0)
  SNAP_COUNT=$(norm "$SNAP_COUNT")
  if ! is_uint "$SNAP_COUNT"; then
    SNAP_COUNT=0
  fi
fi
say "[V3] existing_snapshots=$SNAP_COUNT"

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no prune, no backup, no timer change, no ledger row."
  exit 0
fi

# ===================== [V4] backup policy =====================
say "=== [V4] backup policy ==="
TIMER_ENABLED=no
BACKUP_RAN=no

if [ "$MODE" = "EXTERNAL-DR" ]; then
  if [ "$SNAP_COUNT" -gt 0 ]; then
    say "[V4] external snapshot already exists; skipping baseline"
  else
    say "[V4] running full external backup"
    "$BACKUP_SCRIPT"
    BRC=$?
    if [ "$BRC" != 0 ]; then
      halt "external backup failed rc=$BRC"
    fi
    BACKUP_RAN=yes
  fi

  "$BACKUP_SCRIPT" --verify
  VRC=$?
  if [ "$VRC" != 0 ]; then
    halt "external repo verify failed rc=$VRC"
  fi

  systemctl --user enable aether-backup.timer >/dev/null 2>&1 || halt "could not enable external backup timer"
  systemctl --user restart aether-backup.timer >/dev/null 2>&1 || true
  TIMER_ENABLED=yes
  say "[V4] external DR timer enabled"

elif [ "$MODE" = "LOCAL-STAGING" ]; then
  if [ "$ALLOW_LOCAL" = 0 ]; then
    say "[V4] local staging only; no full backup run. Plug external media or rerun with --allow-local."
  else
    FREE_KB=$(free_kb /home)
    FREE_BYTES=$((FREE_KB * 1024))
    RESERVE_BYTES=5368709120
    NEEDED_BYTES=$((EST_BYTES + RESERVE_BYTES))
    say "[V4] local gate free=$(bytes_to_gib "$FREE_BYTES") needed=$(bytes_to_gib "$NEEDED_BYTES") reserve=5.00GiB"

    if [ "$FREE_BYTES" -lt "$NEEDED_BYTES" ]; then
      halt "insufficient free space for provisional local baseline"
    fi

    if [ "$SNAP_COUNT" -gt 0 ]; then
      say "[V4] local snapshot already exists; skipping baseline"
    else
      say "[V4] running provisional local baseline backup"
      AETHER_BACKUP_ALLOW_LOCAL=yes "$BACKUP_SCRIPT"
      BRC=$?
      if [ "$BRC" != 0 ]; then
        halt "local baseline backup failed rc=$BRC"
      fi
      BACKUP_RAN=yes
    fi

    "$BACKUP_SCRIPT" --verify
    VRC=$?
    if [ "$VRC" != 0 ]; then
      halt "local repo verify failed rc=$VRC"
    fi

    if [ "$ENABLE_LOCAL_TIMER" = 1 ]; then
      systemctl --user enable aether-backup.timer >/dev/null 2>&1 || halt "could not enable local backup timer"
      systemctl --user restart aether-backup.timer >/dev/null 2>&1 || true
      TIMER_ENABLED=yes
      say "[V4] local timer explicitly enabled; this is not true DR and can consume disk"
    else
      systemctl --user disable aether-backup.timer >/dev/null 2>&1 || true
      TIMER_ENABLED=no
      say "[V4] local timer left disabled; manual baseline only"
    fi
  fi
else
  halt "unknown restic mode: $MODE"
fi

assert_green
say "[V4] disk after policy:"
print_disk final /home
print_disk final /

# ===================== [V5] guarded ledger row =====================
say "=== [V5] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-V-disk-reclaim-local-baseline | GATE=PASS | $TOKEN: safe reclaim done; mode=$MODE repo=$REPO wrapper=$WRAPPER; raw_scope=$(bytes_to_gib "$TOTAL_BYTES") estimated_initial_backup=$(bytes_to_gib "$EST_BYTES"); backup_ran=$BACKUP_RAN existing_snapshots_before=$SNAP_COUNT timer_enabled=$TIMER_ENABLED allow_local=$ALLOW_LOCAL enable_local_timer=$ENABLE_LOCAL_TIMER; local staging is provisional not true DR; ollama remains gated until external DR backup + restore test or explicit accepted local risk with headroom. |" >> "$IDX"
  say "[V5] ledger row appended."
else
  say "[V5] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[V5] suppression proof: sentinel present." || say "[V5] WARNING: sentinel missing."

say "[RESULT] DISK RECLAIM + RESTIC BASELINE POLICY APPLIED — mode=$MODE backup_ran=$BACKUP_RAN timer_enabled=$TIMER_ENABLED; next true-DR step is external media backup + restore test before ollama."
exit 0
