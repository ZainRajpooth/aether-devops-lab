#!/usr/bin/env bash
# EX76 verifier. Read-only. Bullet-agnostic, stack-scoped.
set -uo pipefail
DISTRO_RE='^(app-|.*apport|.*drkonqi|.*spice-vdagent)'
fu(){ systemctl --user list-units --failed --no-legend --no-pager 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if ($i ~ /\.(service|timer|socket|mount|scope|slice|target|path|automount|swap)$/) {print $i; break}}'; }
[ "$(systemctl --user show podman-stats.service -p Restart --value)" = "no" ] && echo "  merged Restart=no: PASS" || { echo "[HALT] merge"; exit 1; }
V=$(systemd-analyze --user verify podman-stats.service 2>&1 | grep -i 'podman-stats' | grep -icE 'refusing|bad|invalid')
[ "$V" = 0 ] && echo "  analyzer accepts: PASS" || { echo "[HALT] analyzer"; exit 1; }
systemctl --user list-timers podman-stats.timer --no-legend 2>/dev/null | grep -q podman-stats && echo "  timer armed: PASS" || { echo "[HALT] timer"; exit 1; }
curl -s --max-time 4 http://127.0.0.1:9100/metrics | grep -q 'podman_container_cpu_percent' && echo "  podman metrics: PASS" || { echo "[HALT] metrics"; exit 1; }
for u in pixorb-pg-dump.service aether-backup.service aether-backup-prune.service; do
  [ "$(systemctl --user show "$u" -p Restart --value)" = "no" ] || { echo "[HALT] data-safety $u"; exit 1; }
done
echo "  data-safety unregressed: PASS"
SF=0; for u in $(fu); do printf '%s' "$u" | grep -qE "$DISTRO_RE" || SF=$((SF+1)); done
[ "$SF" = 0 ] && echo "  zero STACK failed units: PASS" || { echo "[HALT] $SF stack failures"; exit 1; }
echo "  NOTE: distro transients (apport-kde) reported only, never modified"
echo "  DEBT: GUI manager ~/DevOps/apps/podman/Podman.py writes blanket Restart=always; zz- outranks it"
echo "[RESULT] EX76 VERIFY PASS"
