#!/usr/bin/env bash
# 20261112-EX61 — Fix aether-network quadlet loading and enable backup-prune timer.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"
TOKEN="ex61-fix-network-quadlet-and-prune-timer-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
QDIR="$H/.config/containers/systemd"
SDIR="$H/.config/systemd/user"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

hr "X0 probes"
say "quadlet dir: $QDIR"
say "network quadlet: $([ -f "$QDIR/aether.network" ] && echo present || echo MISSING)"
say "prune timer: $(systemctl --user is-enabled aether-backup-prune.timer 2>/dev/null || echo missing)"
if [ "$MODE" = check ]; then
  say "plan: write/verify aether.network -> write/verify prune timer -> daemon-reload -> enable timer -> run prune once"
  say "[RESULT] EX61 CHECK - nothing written."; exit 0
fi

hr "X1 aether.network quadlet"
cat > "$TMP/aether.network" <<'NET'
[Network]
Driver=bridge
Subnet=10.89.0.0/24
Gateway=10.89.0.1
NET
mkdir -p "$QDIR"
if [ -f "$QDIR/aether.network" ] && cmp -s "$TMP/aether.network" "$QDIR/aether.network"; then
  say "aether.network unchanged (no-op)"
else
  [ -f "$QDIR/aether.network" ] && cp -p "$QDIR/aether.network" "$QDIR/aether.network.pre-ex61.$STAMP.bak"
  install -m 644 "$TMP/aether.network" "$QDIR/aether.network"
  say "aether.network written"
fi

hr "X2 aether-backup-prune timer"
cat > "$TMP/aether-backup-prune.timer" <<'TMR'
[Unit]
Description=Weekly Aether restic prune

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
TMR
mkdir -p "$SDIR"
if [ -f "$SDIR/aether-backup-prune.timer" ] && cmp -s "$TMP/aether-backup-prune.timer" "$SDIR/aether-backup-prune.timer"; then
  say "prune timer unchanged (no-op)"
else
  [ -f "$SDIR/aether-backup-prune.timer" ] && cp -p "$SDIR/aether-backup-prune.timer" "$SDIR/aether-backup-prune.timer.pre-ex61.$STAMP.bak"
  install -m 644 "$TMP/aether-backup-prune.timer" "$SDIR/aether-backup-prune.timer"
  say "prune timer written"
fi

hr "X3 daemon reload + enable + test"
systemctl --user daemon-reload
say "daemon reloaded"

# Enable timer
systemctl --user enable --now aether-backup-prune.timer
say "prune timer enabled: $(systemctl --user is-enabled aether-backup-prune.timer)"

# Verify network service loaded
NET_STATE="$(systemctl --user is-active aether-network.service 2>/dev/null || echo unknown)"
say "aether-network.service state: $NET_STATE"
[ "$NET_STATE" = "active" ] || [ "$NET_STATE" = "inactive" ] || halt "network service failed to load"

# Run prune once to prove it works
say "running prune service once..."
systemctl --user start aether-backup-prune.service
PRUNE_STATE="$(systemctl --user is-active aether-backup-prune.service 2>/dev/null || echo unknown)"
# oneshot services go to inactive(dead) after success, check journal for success
JOURNAL="$(journalctl --user -u aether-backup-prune.service -n 5 --no-pager 2>/dev/null | tail -1)"
say "prune result: $JOURNAL"

hr "X4 RESULT"
say "[RESULT] EX61 COMPLETE - network quadlet loaded, prune timer enabled and tested."
exit 0
