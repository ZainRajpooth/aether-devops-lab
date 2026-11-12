#!/usr/bin/env bash
# 20261029-W — restic env-override heal + provisional local baseline rerun.
# Root cause: backup.env sourced with set -a overrode caller AETHER_BACKUP_ALLOW_LOCAL=yes.
# Heal: install restic backup v3, prove caller env override works, then rerun V --allow-local.
# Hard rules: multi-line if/then/fi only; bash -n mandatory before run; no heredoc inside $( ); no secret echo; no sudo.
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
IDX="$CD/INDEX.md"
BACKUP_SCRIPT="$BIN/40_restic_dr.sh"
BS_NEW="$CD/lib/40_restic_dr.v3.sh"
V_SCRIPT="$CD/20261029-V-disk-reclaim-and-local-baseline.sh"
TOKEN="restic-env-override-heal-v1"
GREEN_SERVICES="postgres minio weaviate redis"

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
parse_status(){
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}'
}
restore_backup_script(){
  if [ -f "$BACKUP_SCRIPT.pre-W.bak" ]; then
    cp -p "$BACKUP_SCRIPT.pre-W.bak" "$BACKUP_SCRIPT" 2>/dev/null || true
    say "[W] restored previous backup script from $(basename "$BACKUP_SCRIPT").pre-W.bak"
  fi
}

need_cmd bash
need_cmd podman
need_cmd systemctl
need_cmd awk
need_cmd sed
need_cmd diff
need_cmd install

[ -f "$BS_NEW" ] || halt "missing proposed backup script: $BS_NEW"
[ -x "$V_SCRIPT" ] || halt "missing V script: $V_SCRIPT"

if ! bash -n "$BS_NEW"; then
  halt "proposed backup script failed bash -n"
fi

assert_green

DEFAULT_OUT="$(bash "$BS_NEW" --status 2>&1)"
DEFAULT_RC=$?
if [ "$DEFAULT_RC" != 0 ]; then
  printf '%s\n' "$DEFAULT_OUT" | sed 's/^/    /' || true
  halt "proposed backup script --status failed rc=$DEFAULT_RC"
fi
DEFAULT_ALLOW="$(printf '%s\n' "$DEFAULT_OUT" | parse_status AETHER_BACKUP_ALLOW_LOCAL)"
DEFAULT_ALLOW="$(norm "$DEFAULT_ALLOW")"
say "[W0] default allow_local=$DEFAULT_ALLOW"
if [ "$DEFAULT_ALLOW" = "yes" ]; then
  halt "default allow_local should be no; override logic suspicious"
fi

TEST_OUT="$(AETHER_BACKUP_ALLOW_LOCAL=yes bash "$BS_NEW" --status 2>&1)"
TEST_RC=$?
if [ "$TEST_RC" != 0 ]; then
  printf '%s\n' "$TEST_OUT" | sed 's/^/    /' || true
  halt "proposed backup script env-override status failed rc=$TEST_RC"
fi
TEST_ALLOW="$(printf '%s\n' "$TEST_OUT" | parse_status AETHER_BACKUP_ALLOW_LOCAL)"
TEST_ALLOW="$(norm "$TEST_ALLOW")"
say "[W0] env-override proof: allow_local=$TEST_ALLOW"
if [ "$TEST_ALLOW" != "yes" ]; then
  halt "env override did not take effect; proposed script not installed"
fi

if [ "$DRY" = 1 ]; then
  say "[W1] dry-run diff current -> proposed:"
  if [ -f "$BACKUP_SCRIPT" ]; then
    diff -u "$BACKUP_SCRIPT" "$BS_NEW" | sed 's/^/    /' || true
  else
    diff -u /dev/null "$BS_NEW" | sed 's/^/    /' || true
  fi
  say "[RESULT] DRY-RUN complete; no script install, no V rerun, no backup, no ledger row."
  exit 0
fi

if [ -f "$BACKUP_SCRIPT" ] && [ ! -f "$BACKUP_SCRIPT.pre-W.bak" ]; then
  cp -p "$BACKUP_SCRIPT" "$BACKUP_SCRIPT.pre-W.bak"
  say "[W1] backup -> $BACKUP_SCRIPT.pre-W.bak"
fi

if ! install -D -m 755 "$BS_NEW" "$BACKUP_SCRIPT"; then
  restore_backup_script
  halt "could not install proposed backup script"
fi
say "[W1] installed restic backup v3 -> $BACKUP_SCRIPT"

INST_OUT="$(AETHER_BACKUP_ALLOW_LOCAL=yes "$BACKUP_SCRIPT" --status 2>&1)"
INST_RC=$?
if [ "$INST_RC" != 0 ]; then
  printf '%s\n' "$INST_OUT" | sed 's/^/    /' || true
  restore_backup_script
  halt "installed backup script --status failed rc=$INST_RC"
fi
INST_ALLOW="$(printf '%s\n' "$INST_OUT" | parse_status AETHER_BACKUP_ALLOW_LOCAL)"
INST_ALLOW="$(norm "$INST_ALLOW")"
if [ "$INST_ALLOW" != "yes" ]; then
  printf '%s\n' "$INST_OUT" | sed 's/^/    /' || true
  restore_backup_script
  halt "installed backup script did not honor env override"
fi
say "[W2] installed override proof: allow_local=$INST_ALLOW"

V_LOG="$TMPD/v.out"
bash "$V_SCRIPT" --allow-local >"$V_LOG" 2>&1
VRC=$?
sed 's/^/    /' "$V_LOG" || true

if [ "$VRC" != 0 ]; then
  halt "V script returned nonzero rc=$VRC"
fi
if grep -q '\[HALT\]' "$V_LOG"; then
  halt "V script reported HALT"
fi
if ! grep -Eq 'backup_ran=yes|local snapshot already exists' "$V_LOG"; then
  halt "V script did not report local baseline success"
fi

assert_green

if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $TOKEN | APPEND-ONLY | Restic backup.env sourcing overrode caller AETHER_BACKUP_ALLOW_LOCAL, causing V local baseline refusal. v3 preserves caller env overrides, adds quiesce stop failure abort and resume polling. Installed $BACKUP_SCRIPT; reran V --allow-local; V reported baseline success; local staging remains provisional not true DR. |" >> "$IDX"
  say "[W3] ledger row appended."
else
  say "[W3] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[W3] suppression proof: sentinel present." || say "[W3] WARNING: sentinel missing."

say "[RESULT] RESTIC ENV-OVERRIDE HEAL COMPLETE — provisional local baseline rerun succeeded; true DR still requires external media + restore test before ollama."
exit 0
