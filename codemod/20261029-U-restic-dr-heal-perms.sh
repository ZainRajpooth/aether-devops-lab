#!/usr/bin/env bash
# 20261029-U — restic DR heal after T config dry-run permission denial.
# Root cause: redis entrypoint chowned derived redis.conf; backup should use canonical secrets.env, not derived conf.
# Adds podman unshare auto-wrapper for rootless volume/subuid readability, --verify mode, safer include scope,
# config-scope dry-run gate, timer policy, guarded ledger row.
# Hard rules: multi-line if/then/fi only; bash -n mandatory before run; no heredoc inside $( ); no secret echo.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
BIN="$A/bin"
ETC="$HOME/.config/aether"
SYSTEMD_USER="$HOME/.config/systemd/user"
BACKUP_SCRIPT="$BIN/40_restic_dr.sh"
BACKUP_ENV="$ETC/backup.env"
RESTIC_PASS="$ETC/restic-password"
SERVICE="$SYSTEMD_USER/aether-backup.service"
TIMER="$SYSTEMD_USER/aether-backup.timer"
IDX="$CD/INDEX.md"
TOKEN="restic-dr-staged-v2"

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
install_proposed(){
  local src="$1"
  local dest="$2"
  local mode="$3"
  local label="$4"
  if [ "$DRY" = 1 ]; then
    say "[dry] would install $label -> $dest"
    if [ -f "$dest" ]; then
      diff -u "$dest" "$src" | sed 's/^/    /' || true
    else
      diff -u /dev/null "$src" | sed 's/^/    /' || true
    fi
    return 0
  fi
  if [ -f "$dest" ] && [ ! -f "$dest.pre-U.bak" ]; then
    cp -p "$dest" "$dest.pre-U.bak"
  fi
  install -D -m "$mode" "$src" "$dest"
  say "[ok] installed $label -> $dest"
}

need_cmd bash
need_cmd podman
need_cmd systemctl
need_cmd awk
need_cmd sed
need_cmd install
need_cmd mktemp

mkdir -p "$BIN" "$ETC" "$SYSTEMD_USER"
chmod 700 "$ETC" || true

# ===================== [U0] environment probe =====================
say "=== [U0] environment probe ==="
RESTIC_BIN=""
if [ -x "$HOME/.local/bin/restic" ]; then
  RESTIC_BIN="$HOME/.local/bin/restic"
elif command -v restic >/dev/null 2>&1; then
  RESTIC_BIN="$(command -v restic)"
fi
if [ -z "$RESTIC_BIN" ]; then
  halt "restic not found; install restic or rerun T after fixing PATH"
fi
say "[U0] restic=$RESTIC_BIN"

WRAPPER="host"
if podman unshare true >/dev/null 2>&1; then
  WRAPPER="podman-unshare"
fi
say "[U0] podman_unshare_probe=$WRAPPER"
if [ ! -s "$RESTIC_PASS" ]; then
  halt "restic password file missing: $RESTIC_PASS; rerun T or create it deliberately"
fi
say "[U0] restic_password_present=yes (value not printed)"

# ===================== [U1] backup.env =====================
say "=== [U1] backup.env ==="
cat > "$TMPD/backup.env" <<'ENVEOF'
# Aether restic DR configuration. No secrets in this file.
# Leave AETHER_BACKUP_REPO empty to auto-detect external media, else set an explicit repo path.
AETHER_BACKUP_REPO=""
AETHER_BACKUP_MIN_FREE_KB="5242880"
AETHER_BACKUP_SERVICES="postgres minio weaviate redis"
AETHER_BACKUP_QUIESCE="yes"
AETHER_BACKUP_ALLOW_LOCAL="no"
AETHER_BACKUP_USE_PODMAN_UNSHARE="auto"
AETHER_BACKUP_INCLUDE_REDIS_CONF="no"
ENVEOF

install_proposed "$TMPD/backup.env" "$BACKUP_ENV" 600 "backup.env"

# ===================== [U2] backup script =====================
say "=== [U2] backup script ==="
cat > "$TMPD/40_restic_dr.sh" <<'BSEOF'
#!/usr/bin/env bash
# Aether rootless Podman restic DR backup, v2.
# Modes:
#   --status    print detected repo/mode/free space/wrapper, no backup
#   --dry-run   initialize repo if needed and run restic backup --dry-run
#   --verify    open repo and run restic snapshots, no backup
#   no args     real backup; refuses local staging unless AETHER_BACKUP_ALLOW_LOCAL=yes
# Secrets:
#   Uses ~/.config/aether/restic-password; never prints it.
#   Excludes restic-password from backup by default. Losing the password makes the repo unrecoverable.
# Scope:
#   Backs up canonical secrets.env, Quadlet units, aether scripts, and Podman volume mountpoints.
#   Derived redis.conf is excluded by default because the Redis entrypoint may chown it to a container uid.
# Rootless ownership:
#   Uses podman unshare automatically when available so restic can read subuid-owned volume files.
set -uo pipefail

ARG="${1:-}"
DRY=0
STATUS=0
VERIFY=0

if [ "$ARG" = "--dry-run" ]; then
  DRY=1
fi
if [ "$ARG" = "--status" ]; then
  STATUS=1
fi
if [ "$ARG" = "--verify" ]; then
  VERIFY=1
fi

BACKUP_ENV="$HOME/.config/aether/backup.env"
RESTIC_PASS="$HOME/.config/aether/restic-password"

if [ -f "$BACKUP_ENV" ]; then
  set -a
  . "$BACKUP_ENV"
  set +a
fi

: "${AETHER_BACKUP_REPO:=}"
: "${AETHER_BACKUP_MIN_FREE_KB:=5242880}"
: "${AETHER_BACKUP_SERVICES:=postgres minio weaviate redis}"
: "${AETHER_BACKUP_QUIESCE:=yes}"
: "${AETHER_BACKUP_ALLOW_LOCAL:=no}"
: "${AETHER_BACKUP_USE_PODMAN_UNSHARE:=auto}"
: "${AETHER_BACKUP_INCLUDE_REDIS_CONF:=no}"
: "${AETHER_BACKUP_DRY_SCOPE:=all}"

export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$HOME/.cache/restic}"
mkdir -p "$(dirname "$RESTIC_CACHE_DIR")" 2>/dev/null || true

RESTIC=""
if [ -x "$HOME/.local/bin/restic" ]; then
  RESTIC="$HOME/.local/bin/restic"
elif command -v restic >/dev/null 2>&1; then
  RESTIC="$(command -v restic)"
fi

if [ -z "$RESTIC" ]; then
  printf '[FAIL] restic not found; run codemod/20261029-T-restic-dr-setup.sh or install restic\n' >&2
  exit 1
fi

RESTIC_WRAPPER=()
if [ "$AETHER_BACKUP_USE_PODMAN_UNSHARE" = "yes" ]; then
  if ! command -v podman >/dev/null 2>&1; then
    printf '[FAIL] AETHER_BACKUP_USE_PODMAN_UNSHARE=yes but podman not found\n' >&2
    exit 1
  fi
  RESTIC_WRAPPER=(podman unshare)
elif [ "$AETHER_BACKUP_USE_PODMAN_UNSHARE" = "auto" ]; then
  if command -v podman >/dev/null 2>&1; then
    if podman unshare true >/dev/null 2>&1; then
      RESTIC_WRAPPER=(podman unshare)
    fi
  fi
fi

restic_run(){
  if [ "${#RESTIC_WRAPPER[@]}" -gt 0 ]; then
    "${RESTIC_WRAPPER[@]}" "$RESTIC" "$@"
  else
    "$RESTIC" "$@"
  fi
}

get_free_kb(){
  local p="$1"
  if [ -d "$p" ]; then
    df -P "$p" 2>/dev/null | awk 'NR==2{print $4}'
  else
    df -P "$(dirname "$p")" 2>/dev/null | awk 'NR==2{print $4}'
  fi
}

choose_repo(){
  local explicit="$AETHER_BACKUP_REPO"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  local min="$AETHER_BACKUP_MIN_FREE_KB"
  local base d free
  for base in "/run/media/$USER" "/media/$USER"; do
    if [ -d "$base" ]; then
      for d in "$base"/*; do
        if [ -d "$d" ] && [ -w "$d" ]; then
          free="$(get_free_kb "$d")"
          if [ -n "$free" ] && [ "$free" -ge "$min" ]; then
            printf '%s\n' "$d/aether-restic"
            return 0
          fi
        fi
      done
    fi
  done

  printf '%s\n' "$HOME/backups/aether-restic"
}

REPO="$(choose_repo)"
MODE="LOCAL-STAGING"
case "$REPO" in
  /run/media/*|/media/*)
    MODE="EXTERNAL-DR"
    ;;
esac
FREE="$(get_free_kb "$(dirname "$REPO")")"

WRAPPER_LABEL="host"
if [ "${#RESTIC_WRAPPER[@]}" -gt 0 ]; then
  WRAPPER_LABEL="podman-unshare"
fi

if [ "$STATUS" = 1 ]; then
  printf 'AETHER_BACKUP_REPO=%s\n' "$REPO"
  printf 'AETHER_BACKUP_MODE=%s\n' "$MODE"
  printf 'AETHER_BACKUP_FREE_KB=%s\n' "${FREE:-0}"
  printf 'AETHER_BACKUP_WRAPPER=%s\n' "$WRAPPER_LABEL"
  printf 'AETHER_BACKUP_INCLUDE_REDIS_CONF=%s\n' "$AETHER_BACKUP_INCLUDE_REDIS_CONF"
  exit 0
fi

if [ ! -s "$RESTIC_PASS" ]; then
  printf '[FAIL] restic password file missing: %s\n' "$RESTIC_PASS" >&2
  exit 1
fi

mkdir -p "$REPO" || exit 1

if [ ! -f "$REPO/config" ]; then
  restic_run -r "$REPO" --password-file "$RESTIC_PASS" init || exit 1
fi

if [ "$VERIFY" = 1 ]; then
  restic_run -r "$REPO" --password-file "$RESTIC_PASS" snapshots >/dev/null || exit 1
  printf '[VERIFY OK] repo=%s wrapper=%s\n' "$REPO" "$WRAPPER_LABEL"
  exit 0
fi

INCLUDES=()
add_include(){
  local p="$1"
  if [ -e "$p" ]; then
    INCLUDES+=("$p")
  fi
}

add_config_includes(){
  add_include "$HOME/.config/aether/secrets.env"
  add_include "$HOME/.config/aether/backup.env"
  add_include "$HOME/.config/containers/systemd"
  add_include "$HOME/.config/containers/containers.conf"
  add_include "$HOME/DevOps/aether"
  if [ "$AETHER_BACKUP_INCLUDE_REDIS_CONF" = "yes" ]; then
    add_include "$HOME/.config/aether/redis/redis.conf"
  fi
}

if [ "$DRY" = 1 ] && [ "$AETHER_BACKUP_DRY_SCOPE" = "config" ]; then
  add_config_includes
else
  for vol in postgres_data minio_data weaviate_data redis_data; do
    mp="$(podman volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)"
    if [ -n "$mp" ]; then
      add_include "$mp"
    fi
  done
  add_config_includes
fi

if [ "${#INCLUDES[@]}" -eq 0 ]; then
  printf '[FAIL] no include paths found\n' >&2
  exit 1
fi

if [ "$WRAPPER_LABEL" = "host" ]; then
  UNREADABLE=()
  for p in "${INCLUDES[@]}"; do
    if [ -f "$p" ]; then
      if [ ! -r "$p" ]; then
        UNREADABLE+=("$p")
      fi
    elif [ -d "$p" ]; then
      if [ ! -r "$p" ] || [ ! -x "$p" ]; then
        UNREADABLE+=("$p")
      fi
    fi
  done
  if [ "${#UNREADABLE[@]}" -gt 0 ]; then
    printf '[FAIL] host restic cannot read top-level paths: %s\n' "${UNREADABLE[*]}" >&2
    printf 'Hint: allow podman unshare, or keep AETHER_BACKUP_INCLUDE_REDIS_CONF=no, or fix path ownership deliberately.\n' >&2
    exit 4
  fi
fi

EXCLUDES=(
  --exclude __pycache__
  --exclude '*.pyc'
  --exclude 'work.*'
  --exclude '.cache'
  --exclude 'restic-password'
)

CMD=(
  --host aether-edge
  --tag aether
  --tag edge
  --tag rootless-podman
  --exclude-caches
  --exclude-if-present .nobackup
)
CMD+=("${EXCLUDES[@]}")

if [ "$DRY" = 1 ]; then
  CMD+=(--dry-run)
fi

CMD+=("${INCLUDES[@]}")

if [ "$DRY" != 1 ] && [ "$MODE" = "LOCAL-STAGING" ] && [ "$AETHER_BACKUP_ALLOW_LOCAL" != "yes" ]; then
  printf '[REFUSE] local staging full backup disabled; plug in external media or set AETHER_BACKUP_ALLOW_LOCAL=yes\n' >&2
  exit 2
fi

STOPPED=()
resume_services(){
  if [ "${#STOPPED[@]}" -gt 0 ]; then
    local s
    for s in "${STOPPED[@]}"; do
      systemctl --user start "$s.service" >/dev/null 2>&1 || true
    done
  fi
}

if [ "$DRY" != 1 ] && [ "$AETHER_BACKUP_QUIESCE" = "yes" ]; then
  trap resume_services EXIT
  for s in $AETHER_BACKUP_SERVICES; do
    st="$(systemctl --user is-active "$s.service" 2>/dev/null || true)"
    if [ "$st" = "active" ]; then
      systemctl --user stop "$s.service" >/dev/null 2>&1 || true
      STOPPED+=("$s")
    fi
  done
fi

restic_run -r "$REPO" --password-file "$RESTIC_PASS" backup "${CMD[@]}"
RC=$?

RESULT_LABEL="FAIL"
if [ "$RC" = 0 ]; then
  RESULT_LABEL="OK"
fi

if [ "$DRY" = 1 ]; then
  printf '[DRY-RUN %s] repo=%s mode=%s scope=%s wrapper=%s rc=%s\n' \
    "$RESULT_LABEL" "$REPO" "$MODE" "$AETHER_BACKUP_DRY_SCOPE" "$WRAPPER_LABEL" "$RC"
fi

exit "$RC"
BSEOF

install_proposed "$TMPD/40_restic_dr.sh" "$BACKUP_SCRIPT" 755 "backup script"

# ===================== [U3] systemd user service + timer =====================
say "=== [U3] systemd user service + timer ==="
cat > "$TMPD/aether-backup.service" <<'SVCEOF'
[Unit]
Description=Aether restic DR backup
After=network-online.target podman.socket

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash %h/DevOps/aether/bin/40_restic_dr.sh
Environment=HOME=%h
Environment=XDG_RUNTIME_DIR=%t
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:%h/.local/bin
Nice=19
IOSchedulingClass=idle
MemoryMax=512M
CPUQuota=25%
TimeoutStartSec=3600
SVCEOF

cat > "$TMPD/aether-backup.timer" <<'TMREOF'
[Unit]
Description=Aether restic DR timer

[Timer]
OnCalendar=*-*-* 03:17:00
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
TMREOF

install_proposed "$TMPD/aether-backup.service" "$SERVICE" 644 "backup service"
install_proposed "$TMPD/aether-backup.timer" "$TIMER" 644 "backup timer"

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no unit write activation, no repo init, no dry-run execution, no timer enable."
  exit 0
fi

# ===================== [U4] verify =====================
say "=== [U4] verify restic DR wiring ==="
systemctl --user daemon-reload || halt "systemctl --user daemon-reload failed"

STATUS_OUT="$("$BACKUP_SCRIPT" --status 2>&1)"
SRC=$?
if [ "$SRC" != 0 ]; then
  printf '%s\n' "$STATUS_OUT" | sed 's/^/    /' || true
  halt "backup script --status failed rc=$SRC"
fi

parse_status(){
  local key="$1"
  printf '%s\n' "$STATUS_OUT" | awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}'
}

REPO="$(parse_status AETHER_BACKUP_REPO)"
MODE="$(parse_status AETHER_BACKUP_MODE)"
FREE="$(parse_status AETHER_BACKUP_FREE_KB)"
RUN_WRAPPER="$(parse_status AETHER_BACKUP_WRAPPER)"
INCLUDE_CONF="$(parse_status AETHER_BACKUP_INCLUDE_REDIS_CONF)"
say "[U4] repo=$REPO mode=$MODE free_kb=${FREE:-?} wrapper=$RUN_WRAPPER include_redis_conf=$INCLUDE_CONF"

if ! AETHER_BACKUP_DRY_SCOPE=config "$BACKUP_SCRIPT" --dry-run; then
  halt "restic config-scope dry-run failed"
fi

if ! "$BACKUP_SCRIPT" --verify; then
  halt "restic repo verify failed"
fi

# ===================== [U5] timer policy =====================
say "=== [U5] timer policy ==="
TIMER_ENABLED="no"
if [ "$MODE" = "EXTERNAL-DR" ]; then
  systemctl --user enable aether-backup.timer >/dev/null 2>&1 || halt "could not enable backup timer"
  systemctl --user restart aether-backup.timer >/dev/null 2>&1 || true
  TIMER_ENABLED="yes"
  say "[U5] external DR detected; timer enabled"
else
  systemctl --user disable aether-backup.timer >/dev/null 2>&1 || true
  say "[U5] local staging only; timer left disabled. Plug external media or set AETHER_BACKUP_ALLOW_LOCAL=yes for local full backups."
fi

# ===================== [U6] guarded ledger row =====================
say "=== [U6] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-U-restic-dr-heal | GATE=PASS | $TOKEN: restic DR v2 wired; repo=$REPO mode=$MODE wrapper=$RUN_WRAPPER; derived redis.conf excluded by default; canonical secrets.env included; config-scope dry-run OK; repo verify OK; service+timer installed; timer_enabled=$TIMER_ENABLED; full backup not run; ollama remains gated until real external DR backup is available. |" >> "$IDX"
  say "[U6] restic DR v2 row appended."
else
  say "[U6] restic DR v2 row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[U6] suppression proof: restic v2 sentinel present." || say "[U6] WARNING: restic v2 sentinel missing."

say "[RESULT] RESTIC DR v2 STAGED — config dry-run and repo verify passed; mode=$MODE; timer_enabled=$TIMER_ENABLED; next real step is full external backup + restore test before ollama."
exit 0
