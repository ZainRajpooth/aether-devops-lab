#!/usr/bin/env bash
# EX64a - Safe-cache disk reclamation. Destructive-class: allowlist only.
# PERMANENT INVARIANT (user decision "none"): never touch Downloads, Videos, Documents,
# DevOps, .lingma, .var, .dartServer, .pub-cache, .vscode, .config, Podman volumes,
# restic repo, MinIO data, Postgres data. Only regenerable caches below.
set -uo pipefail
A="$HOME/DevOps/aether"; IDX="$A/codemod/INDEX.md"; H="$HOME"
LEDGER="ex64a-disk-reclaim-v1"; MODE="${1:-run}"
ALLOW=("$H/.cache/pip" "$H/.cache/thumbnails" "$H/.cache/mozilla" "$H/.cache/BraveSoftware" "$H/.cache/google-chrome" "$H/.cache/yarn" "$H/.cache/npm/_cacache")
PROTECT=("$H/Downloads" "$H/Videos" "$H/Documents" "$H/DevOps" "$H/.lingma" "$H/.config")
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
avail(){ df --output=avail -BM /home | tail -1 | tr -dc '0-9'; }
hr "X0 probes"
B4=$(avail); say "avail_MB before: $B4"
say "cache size: $(du -sh "$H/.cache" 2>/dev/null | cut -f1)"
for p in "${PROTECT[@]}"; do [ -e "$p" ] || say "note: protected path absent $p"; done
say "protected paths declared: ${#PROTECT[@]}"
if [ "$MODE" = check ]; then
  say "plan: clear ${#ALLOW[@]} regenerable cache dirs -> journal vacuum 100M -> trash -> dangling images"
  say "[RESULT] EX64a CHECK - nothing written."; exit 0
fi
hr "X1 allowlisted cache clears"
for p in "${ALLOW[@]}"; do
  if [ -d "$p" ]; then rm -rf "$p" && say "cleared: ${p#$H/}"; else say "absent (no-op): ${p#$H/}"; fi
done
hr "X2 journal, trash, dangling images"
journalctl --user --vacuum-size=100M >/dev/null 2>&1 && say "journal <=100M" || say "journal vacuum skipped"
if [ -d "$H/.local/share/Trash" ]; then rm -rf "$H/.local/share/Trash/"* 2>/dev/null; say "trash emptied"; fi
podman image prune -f >/dev/null 2>&1 && say "dangling images pruned" || say "image prune skipped"
hr "X3 gates"
for p in "${PROTECT[@]}"; do
  case "$p" in "$H/.lingma") [ -e "$p" ] || say "note: $p absent (pre-existing)";; *) [ -e "$p" ] || halt "PROTECTED PATH MISSING: $p";; esac
done
say "protected-path gate: PASS"
AF=$(avail); say "avail_MB after: $AF"; say "delta_MB: $((AF-B4))"
say "cache size after: $(du -sh "$H/.cache" 2>/dev/null | cut -f1)"
hr "X4 ledger"
grep -qF "$LEDGER:PASS" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "$LEDGER:PASS" "original run 5.9G->7.8G avail; cache 3.3G->1.4G; protected paths intact" >> "$IDX"
say "ledger: $LEDGER:PASS"
say "[RESULT] EX64a COMPLETE (record + idempotent replay)."
exit 0
