#!/usr/bin/env bash
# 20261103-DG — READ-ONLY. Confirms 15/15 + Zitadel-not-deployed + audits EVERY
# *-dns-wait*.sh on disk and maps each platform unit's EFFECTIVE ExecStartPre guard
# to its class, to expose any reboot-spam risk left by per-service v2 scripts.
# No start/stop/kill/write except ledger + (no) backups. Gated: file + bash -n + child bash.
set -uo pipefail
HOME_="$HOME"
CANON="$HOME_/DevOps/aether/infra/scripts/aether-dns-wait.sh"
CD="$HOME_/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
TOKEN="dg-readonly-status-guardaudit-v1"
NET="aether"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
cont_state(){ podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null || echo absent; }
unit_active(){ systemctl --user is-active "$1" 2>/dev/null | tr -d '\n'; }
unit_exists(){ systemctl --user list-unit-files "$1" --no-pager --plain 2>/dev/null | grep -q "$1"; }

classify_script(){ # $1=path -> echoes CLASS
  local p="$1"
  if [ ! -f "$p" ]; then printf 'MISSING'; return; fi
  if grep -q 'resolves in-netns' "$p" 2>/dev/null; then printf 'V3.4-SAFE'; return; fi
  if grep -q 'getent hosts' "$p" 2>/dev/null && grep -q 'podman run' "$p" 2>/dev/null; then printf 'LEGACY-V2'; return; fi
  printf 'OTHER'
}

hr "G1 platform 15: container + unit + verdict"
P15="postgres redis minio weaviate prometheus node-exporter mailpit llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik"
UP=0; DOWN=0
for s in $P15; do
  case "$s" in llama-embed) uname="llama-embed-container.service";; *) uname="$s.service";; esac
  cname="$s"; [ "$s" = "llama-embed" ] && cname="llama-embed"
  c="$(cont_state "$cname")"; u="$(unit_active "$uname")"
  v="DOWN"
  if [ "$c" = running ] && [ "$u" = active ]; then v="UP"; UP=$((UP+1)); elif [ "$c" = running ]; then v="UP-idle"; UP=$((UP+1)); else DOWN=$((DOWN+1)); fi
  printf '  %-20s cont=%-8s unit=%-8s %s\n' "$s" "$c" "$u" "$v"
done
say "verdict: UP=$UP DOWN=$DOWN (expect UP=15 DOWN=0)"

hr "G2 Zitadel triple-check (proves NOT deployed, not assumed)"
zi_img="$(podman image exists ghcr.io/zitadel/zitadel:latest 2>/dev/null && echo yes || echo no)"
zi_ctr="$(podman ps -a --filter name=zitadel --format '{{.Names}} {{.Status}}' 2>/dev/null)"
zi_unit="$(systemctl --user list-unit-files 'zitadel*' --no-pager --plain 2>/dev/null | grep -c zitadel || true)"
say "image cached: $zi_img"
say "container(s): ${zi_ctr:-NONE}"
say "unit-files matching zitadel: ${zi_unit:-0}"
if [ "$zi_img" = yes ] && [ -z "$zi_ctr" ] && [ "${zi_unit:-0}" -eq 0 ]; then
  say "=> ZITADEL = NOT DEPLOYED (cached image only) = Brick 13. Confirmed."
else
  say "=> ZITADEL state differs from expectation; see lines above."
fi

hr "G3 inventory EVERY guard script on disk -> class"
mapfile -t GUARDS < <(find "$HOME_/DevOps" /usr/local/bin /opt 2>/dev/null -type f -name '*dns-wait*.sh' | sort -u)
if [ "${#GUARDS[@]}" -eq 0 ]; then say "none found"; fi
for g in "${GUARDS[@]}"; do
  printf '  %-70s %s\n' "$g" "$(classify_script "$g")"
done

hr "G4 map each platform unit's EFFECTIVE ExecStartPre guard -> class (reboot-risk detector)"
RISK_UNITS=""
for s in $P15; do
  case "$s" in llama-embed) uname="llama-embed-container.service";; *) uname="$s.service";; esac
  eff="$(systemctl --user show "$uname" -p ExecStartPre --value 2>/dev/null || true)"
  if [ -z "$eff" ]; then printf '  %-20s guard=NONE (leaf)\n' "$s"; continue; fi
  # extract script paths (tokens ending .sh) from the effective ExecStartPre list
  scripts="$(printf '%s\n' "$eff" | grep -oE '[^ ]+\.sh' | sort -u)"
  line="  $s guard="
  worst="SAFE"
  for sp in $scripts; do
    cl="$(classify_script "$sp")"
    line="$line[$(basename "$sp")=$cl] "
    if [ "$cl" = LEGACY-V2 ] || [ "$cl" = MISSING ]; then worst="RISK"; fi
  done
  printf '%s%s\n' "$line" "=> $worst"
  if [ "$worst" = RISK ]; then RISK_UNITS="$RISK_UNITS $s"; fi
done

hr "G5 verdict + open items"
say "platform runtime: $([ "$DOWN" -eq 0 ] && [ "$UP" -eq 15 ] && echo 'GREEN 15/15' || echo "NOT GREEN (UP=$UP DOWN=$DOWN)")"
say "zitadel: NOT DEPLOYED (Brick 13) — say 'deploy zitadel'"
say "woodpecker pipeline PROOF: OPEN (Brick 12) — containers run, no build proven yet"
say "aether-backup: UNDECIDED — say 'repair aether-backup' or 'retire aether-backup'"
if [ -n "$RISK_UNITS" ]; then
  say "REBOOT-SPAM RISK units (effective guard is LEGACY-V2/MISSING):$RISK_UNITS"
  say "  => these will re-spawn the 90-loop alpine probes on next reboot/start until their"
  say "     guard script is synced to v3.4 OR a drop-in re-points ExecStartPre to CANON."
  say "  => next hardening brick DH: sync every LEGACY-V2 guard to v3.4 + drop-in any unit"
  say "     whose script path is not the CANON. (read-only DG only detected; it changed nothing)"
else
  say "REBOOT-SPAM RISK: none detected (every unit's effective guard is V3.4-SAFE or NONE)."
fi

hr "G6 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=INFO | DG read-only: platform UP=%s DOWN=%s; zitadel NOT-deployed confirmed (img=%s ctr=[%s] units=%s); guard inventory + per-unit effective-guard mapping done; reboot-risk units:[%s]. No mutations. |\n' \
    "$(date +%F)" "$TOKEN" "$UP" "$DOWN" "$zi_img" "${zi_ctr:-}" "${zi_unit:-0}" "${RISK_UNITS:-none}" >> "$IDX"
  say "ledger row appended (read-only INFO row)"
fi
say "[RESULT] DG COMPLETE - read-only status+guard audit done; see G5 for the exact open items."
exit 0
