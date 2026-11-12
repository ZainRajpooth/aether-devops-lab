#!/usr/bin/env bash
# Aether rootless Podman restic DR backup, v3.
# Caller environment overrides backup.env.
# Precedence: caller env > backup.env > built-in defaults.
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

AETHER_OVERRIDE_VARS="AETHER_BACKUP_REPO AETHER_BACKUP_MIN_FREE_KB AETHER_BACKUP_SERVICES AETHER_BACKUP_QUIESCE AETHER_BACKUP_ALLOW_LOCAL AETHER_BACKUP_USE_PODMAN_UNSHARE AETHER_BACKUP_INCLUDE_REDIS_CONF AETHER_BACKUP_DRY_SCOPE"
declare -A AETHER_PRESET=()

for var in $AETHER_OVERRIDE_VARS; do
  if printenv "$var" >/dev/null 2>&1; then
    AETHER_PRESET["$var"]="$(printenv "$var")"
  fi
done

if [ -f "$BACKUP_ENV" ]; then
  set -a
  . "$BACKUP_ENV"
  set +a
fi

if [ "${#AETHER_PRESET[@]}" -gt 0 ]; then
  for var in "${!AETHER_PRESET[@]}"; do
    printf -v "$var" '%s' "${AETHER_PRESET[$var]}"
    export "$var"
  done
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

norm(){
  local s="${1:-}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
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
  printf 'AETHER_BACKUP_ALLOW_LOCAL=%s\n' "$AETHER_BACKUP_ALLOW_LOCAL"
  printf 'AETHER_BACKUP_DRY_SCOPE=%s\n' "$AETHER_BACKUP_DRY_SCOPE"
  exit 0
fi

if [ -z "$RESTIC" ]; then
  printf '[FAIL] restic not found; run codemod/20261029-T-restic-dr-setup.sh or install restic\n' >&2
  exit 1
fi

if [ ! -x "$RESTIC" ]; then
  printf '[FAIL] restic not executable: %s\n' "$RESTIC" >&2
  exit 1
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
    mp="$(norm "$mp")"
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
  --exclude .git
  --exclude __pycache__
  --exclude '*.pyc'
  --exclude 'work.*'
  --exclude '.cache'
  --exclude 'restic-password'
  --exclude '*.sock'
  --exclude 'postmaster.pid'
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
  if [ "${#STOPPED[@]}" -eq 0 ]; then
    return 0
  fi
  local s st i
  for s in "${STOPPED[@]}"; do
    systemctl --user start "$s.service" >/dev/null 2>&1 || true
    for i in $(seq 1 30); do
      st="$(systemctl --user is-active "$s.service" 2>/dev/null || true)"
      st="$(norm "$st")"
      if [ "$st" = "active" ]; then
        break
      fi
      sleep 1
    done
  done
}

if [ "$DRY" != 1 ] && [ "$AETHER_BACKUP_QUIESCE" = "yes" ]; then
  trap resume_services EXIT
  for s in $AETHER_BACKUP_SERVICES; do
    st="$(systemctl --user is-active "$s.service" 2>/dev/null || true)"
    st="$(norm "$st")"
    if [ "$st" = "active" ]; then
      if ! systemctl --user stop "$s.service" >/dev/null 2>&1; then
        printf '[FAIL] could not stop %s.service for quiesced backup\n' "$s" >&2
        exit 3
      fi
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
