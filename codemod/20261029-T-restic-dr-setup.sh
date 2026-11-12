#!/usr/bin/env bash
# 20261029-T — restic DR setup for the green rootless Podman edge stack.
# Free/open-source only. No sudo. No cloud cost. No secret echo.
# Installs restic as a user binary, creates encrypted repo wiring, writes a quiescing backup script,
# installs a systemd user service + timer, verifies with a config-scope dry-run, and enables the timer
# only when an external DR destination is detected.
# Hard rules: multi-line if/then/fi only; bash -n mandatory before run; no heredoc inside $( ).
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
TOKEN="restic-dr-staged"
IDX="$CD/INDEX.md"

TMPD="$(mktemp -d)"
cleanup(){ rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }
need_cmd(){
  if ! command -v "$1" >/dev/null 2>&1; then
    halt "missing required command: $1"
  fi
}
install_proposed(){
  local src="$1" dest="$2" mode="$3" label="$4"
  if [ "$DRY" = 1 ]; then
    say "[dry] would install $label -> $dest"
    if [ -f "$dest" ]; then
      diff -u "$dest" "$src" | sed 's/^/    /' || true
    else
      diff -u /dev/null "$src" | sed 's/^/    /' || true
    fi
    return 0
  fi
  if [ -f "$dest" ] && [ ! -f "$dest.pre-T.bak" ]; then
    cp -p "$dest" "$dest.pre-T.bak"
  fi
  install -D -m "$mode" "$src" "$dest"
  say "[ok] installed $label -> $dest"
}

need_cmd bash
need_cmd curl
need_cmd tar
need_cmd sha256sum
need_cmd python3
need_cmd podman
need_cmd systemctl

mkdir -p "$BIN" "$ETC" "$SYSTEMD_USER"
chmod 700 "$ETC" || true

# ===================== [T0] restic binary =====================
say "=== [T0] restic user binary ==="
RESTIC=""
resolve_restic(){
  if [ -x "$HOME/.local/bin/restic" ]; then
    RESTIC="$HOME/.local/bin/restic"
    return 0
  fi
  if command -v restic >/dev/null 2>&1; then
    RESTIC="$(command -v restic)"
    return 0
  fi
  RESTIC=""
  return 1
}
install_restic(){
  if resolve_restic; then
    say "[T0] restic present: $RESTIC"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    say "[T0] dry-run: would install restic to $HOME/.local/bin/restic"
    return 0
  fi
  local tmp="$TMPD/restic"
  mkdir -p "$tmp"
  local api="$tmp/api.json"
  if ! curl -fsSL "https://api.github.com/repos/restic/restic/releases/latest" -o "$api"; then
    halt "could not query latest restic release from GitHub"
  fi
  local tag ver arch base url csum_url expected actual found
  tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$api")" || halt "could not parse restic tag"
  ver="${tag#v}"
  arch="amd64"
  base="restic_${ver}_linux_${arch}"
  url="https://github.com/restic/restic/releases/download/${tag}/${base}.tar.gz"
  csum_url="https://github.com/restic/restic/releases/download/${tag}/restic_${ver}_checksums.txt"
  if ! curl -fsSL "$url" -o "$tmp/${base}.tar.gz"; then
    halt "could not download $url"
  fi
  if ! curl -fsSL "$csum_url" -o "$tmp/checksums.txt"; then
    halt "could not download checksums"
  fi
  expected="$(awk -v f="${base}.tar.gz" '$2==f {print $1}' "$tmp/checksums.txt")"
  if [ -z "$expected" ]; then
    halt "checksum not found for ${base}.tar.gz"
  fi
  actual="$(sha256sum "$tmp/${base}.tar.gz" | awk '{print $1}')"
  if [ "$expected" != "$actual" ]; then
    halt "sha256 mismatch for restic download"
  fi
  if ! tar -xzf "$tmp/${base}.tar.gz" -C "$tmp"; then
    halt "could not extract restic archive"
  fi
  found="$(find "$tmp" -type f -name restic | head -n1)"
  if [ -z "$found" ]; then
    halt "restic binary not found after extraction"
  fi
  mkdir -p "$HOME/.local/bin"
  install -D -m 700 "$found" "$HOME/.local/bin/restic"
  RESTIC="$HOME/.local/bin/restic"
  say "[T0] installed restic -> $RESTIC"
}
install_restic

# ===================== [T1] restic password file =====================
say "=== [T1] restic password file ==="
if [ -s "$RESTIC_PASS" ]; then
  say "[T1] present: $RESTIC_PASS (value not printed)"
else
  if [ "$DRY" = 1 ]; then
    say "[T1] dry-run: would create $RESTIC_PASS (0600)"
  else
    python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(64)))' > "$RESTIC_PASS" || halt "could not create restic password"
    chmod 600 "$RESTIC_PASS"
    say "[T1] created $RESTIC_PASS (0600, value not printed)"
  fi
fi

# ===================== [T2] backup.env =====================
say "=== [T2] backup.env ==="
cat > "$TMPD/backup.env" <<'ENVEOF'
# Aether restic DR configuration. No secrets in this file.
# Leave AETHER_BACKUP_REPO empty to auto-detect external media, else set an explicit repo path.
AETHER_BACKUP_REPO=""
AETHER_BACKUP_MIN_FREE_KB="5242880"
AETHER_BACKUP_SERVICES="postgres minio weaviate redis"
AETHER_BACKUP_QUIESCE="yes"
AETHER_BACKUP_ALLOW_LOCAL="no"
ENVEOF

if [ -f "$BACKUP_ENV" ]; then
  say "[T2] preserving existing $BACKUP_ENV"
else
  install_proposed "$TMPD/backup.env" "$BACKUP_ENV" 600 "backup.env"
fi

# ===================== [T3] backup script =====================
say "=== [T3] backup script ==="
cat > "$TMPD/40_restic_dr.sh" <<'BSEOF'
#!/usr/bin/env bash
# Aether rootless Podman restic DR backup.
# Modes:
#   --status    print detected repo/mode/free space, no backup
#   --dry-run   initialize repo if needed and run restic backup --dry-run
#   no args     real backup; refuses local staging unless AETHER_BACKUP_ALLOW_LOCAL=yes
# Secrets:
#   Uses ~/.config/aether/restic-password; never prints it.
# Consistency:
#   Real backups stop the named user services first and restart them on exit.
set -uo pipefail

ARG="${1:-}"
DRY=0
STATUS=0
if [ "$ARG" = "--dry-run" ]; then
  DRY=1
fi
if [ "$ARG" = "--status" ]; then
  STATUS=1
fi

A="$HOME/DevOps/aether"
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
: "${AETHER_BACKUP_DRY_SCOPE:=all}"

RESTIC=""
if [ -x "$HOME/.local/bin/restic" ]; then
  RESTIC="$HOME/.local/bin/restic"
elif command -v restic >/dev/null 2>&1; then
  RESTIC="$(command -v restic)"
fi

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

if [ "$STATUS" = 1 ]; then
  printf 'AETHER_BACKUP_REPO=%s\n' "$REPO"
  printf 'AETHER_BACKUP_MODE=%s\n' "$MODE"
  printf 'AETHER_BACKUP_FREE_KB=%s\n' "${FREE:-0}"
  exit 0
fi

if [ -z "$RESTIC" ] || [ ! -x "$RESTIC" ]; then
  printf '[FAIL] restic not found; run codemod/20261029-T-restic-dr-setup.sh\n' >&2
  exit 1
fi

if [ ! -s "$RESTIC_PASS" ]; then
  printf '[FAIL] restic password file missing: %s\n' "$RESTIC_PASS" >&2
  exit 1
fi

mkdir -p "$REPO" || exit 1

if [ ! -f "$REPO/config" ]; then
  "$RESTIC" -r "$REPO" --password-file "$RESTIC_PASS" init || exit 1
fi

INCLUDES=()
add_include(){
  if [ -e "$1" ]; then
    INCLUDES+=("$1")
  fi
}

if [ "$DRY" = 1 ] && [ "$AETHER_BACKUP_DRY_SCOPE" = config ]; then
  add_include "$HOME/.config/aether/secrets.env"
  add_include "$HOME/.config/aether/redis/redis.conf"
  add_include "$HOME/DevOps/aether/infra/quadlet"
  add_include "$HOME/DevOps/aether/codemod/INDEX.md"
else
  for vol in postgres_data minio_data weaviate_data redis_data; do
    mp="$(podman volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)"
    if [ -n "$mp" ]; then
      add_include "$mp"
    fi
  done
  add_include "$HOME/.config/aether/secrets.env"
  add_include "$HOME/.config/aether/redis/redis.conf"
  add_include "$HOME/DevOps/aether/infra/quadlet"
  add_include "$HOME/DevOps/aether/legacy/compose/recovery-runtime.yml"
  add_include "$HOME/DevOps/aether/codemod/INDEX.md"
fi

if [ "${#INCLUDES[@]}" -eq 0 ]; then
  printf '[FAIL] no include paths found\n' >&2
  exit 1
fi

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
    if [ "$st" = active ]; then
      systemctl --user stop "$s.service" >/dev/null 2>&1 || true
      STOPPED+=("$s")
    fi
  done
fi

CMD=("$RESTIC" -r "$REPO" --password-file "$RESTIC_PASS" backup
     --host aether-edge
     --tag aether
     --tag edge
     --tag rootless-podman
     --exclude-caches
     --exclude-if-present .nobackup)

if [ "$DRY" = 1 ]; then
  CMD+=(--dry-run)
fi

CMD+=("${INCLUDES[@]}")

"${CMD[@]}"
RC=$?

if [ "$DRY" = 1 ]; then
  printf '[DRY-RUN OK] repo=%s mode=%s scope=%s rc=%s\n' "$REPO" "$MODE" "$AETHER_BACKUP_DRY_SCOPE" "$RC"
fi

exit "$RC"
BSEOF

install_proposed "$TMPD/40_restic_dr.sh" "$BACKUP_SCRIPT" 755 "backup script"

# ===================== [T4] systemd user service + timer =====================
say "=== [T4] systemd user service + timer ==="
cat > "$TMPD/aether-backup.service" <<'SVCEOF'
[Unit]
Description=Aether restic DR backup
After=network-online.target podman.socket

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash %h/DevOps/aether/bin/40_restic_dr.sh
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:%h/.local/bin
Nice=19
IOSchedulingClass=idle
MemoryMax=512M
CPUQuota=25%
NoNewPrivileges=yes
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
  say "[RESULT] DRY-RUN complete; no restic install, no password create, no unit write, no repo init, no timer enable."
  exit 0
fi

# ===================== [T5] verify: status + config-scope dry-run + repo readability =====================
say "=== [T5] verify restic DR wiring ==="
systemctl --user daemon-reload || halt "systemctl --user daemon-reload failed"

if ! resolve_restic; then
  halt "restic not resolvable after install"
fi

if ! STATUS_OUT="$("$BACKUP_SCRIPT" --status 2>&1)"; then
  printf '%s\n' "$STATUS_OUT" | sed 's/^/    /' || true
  halt "backup script --status failed"
fi

REPO="$(printf '%s\n' "$STATUS_OUT" | awk -F= '/^AETHER_BACKUP_REPO=/{print $2}' | cut -d= -f1-)"
MODE="$(printf '%s\n' "$STATUS_OUT" | awk -F= '/^AETHER_BACKUP_MODE=/{print $2}')"
FREE="$(printf '%s\n' "$STATUS_OUT" | awk -F= '/^AETHER_BACKUP_FREE_KB=/{print $2}')"
say "[T5] repo=$REPO mode=$MODE free_kb=${FREE:-?}"

if ! AETHER_BACKUP_DRY_SCOPE=config "$BACKUP_SCRIPT" --dry-run; then
  halt "restic config-scope dry-run failed"
fi

if ! "$RESTIC" -r "$REPO" --password-file "$RESTIC_PASS" snapshots >/dev/null 2>&1; then
  halt "restic repo readability check failed"
fi
say "[T5] restic repo readable; snapshots command OK"

# ===================== [T6] timer policy =====================
say "=== [T6] timer policy ==="
TIMER_ENABLED="no"
if [ "$MODE" = "EXTERNAL-DR" ]; then
  systemctl --user enable aether-backup.timer >/dev/null 2>&1 || halt "could not enable backup timer"
  systemctl --user restart aether-backup.timer >/dev/null 2>&1 || true
  TIMER_ENABLED="yes"
  say "[T6] external DR detected; timer enabled"
else
  systemctl --user disable aether-backup.timer >/dev/null 2>&1 || true
  say "[T6] local staging only; timer left disabled. Plug external media or set AETHER_BACKUP_ALLOW_LOCAL=yes for local full backups."
fi

# ===================== [T7] guarded ledger row =====================
say "=== [T7] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-T-restic-dr | GATE=PASS | $TOKEN: restic user binary wired; encrypted repo staged at $REPO; mode=$MODE; config-scope dry-run OK; service+timer installed; timer_enabled=$TIMER_ENABLED; full backup not run; ollama remains gated until real DR backup is available. |" >> "$IDX"
  say "[T7] restic DR row appended."
else
  say "[T7] restic DR row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[T7] suppression proof: restic sentinel present." || say "[T7] WARNING: restic sentinel missing."

say "[RESULT] RESTIC DR STAGED — repo+dry-run verified; timer_enabled=$TIMER_ENABLED; mode=$MODE; next real step is a full external backup before ollama."
exit 0
