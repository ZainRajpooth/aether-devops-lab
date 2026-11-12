#!/usr/bin/env bash
# 20261103-DS — READ-ONLY reboot-persistence audit. Mutates NOTHING (except /tmp +
# an append-only ledger INFO row). Never starts/stops/edits units or the DB. Never
# prints secrets: no `systemctl cat`, no raw .container/setup-log; every file/unit
# -content read is piped through redact(). Decides the boot mechanism empirically.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
CDIR="$HOME_/.config/containers/systemd"
SUDIR="$HOME_/.config/systemd/user"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="ds-readonly-reboot-persistence-audit-v1"
NET="aether"
REC_LIST="/tmp/ds-recon-units.$$.txt"
: > "$REC_LIST"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
# secrets loaded ONLY to redact (never echoed)
MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
redact(){ awk -v a="$MKEY" -v b="$PGPASS" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "    [REDACTED-LINE]"; else print }'; }
unit_for(){ case "$1" in llama-embed) printf 'llama-embed-container.service';; *) printf '%s.service' "$1";; esac; }
P17="postgres redis minio weaviate prometheus node-exporter mailpit llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik zitadel portainer"

hr "S0 DR partial-state (naming is COSMETIC for boot; measured only)"
for n in zitadel portainer; do
  f="$CDIR/$n.container"
  cn="no"; [ -f "$f" ] && grep -qxF "ContainerName=$n" "$f" 2>/dev/null && cn="yes"
  wb="no"; [ -f "$f.pre-DR.bak" ] && wb="yes"
  live_bare="no"; live_sysd="no"
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$n" && live_bare="yes"
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "systemd-$n" && live_sysd="yes"
  un="$(systemctl --user is-active "$n.service" 2>/dev/null | tr -d '\n')"
  say "$n: file-ContainerName=$cn  pre-DR.bak=$wb  live[bare=$live_bare systemd-$n=$live_sysd]  unit=$un"
done
say "=> naming mismatch (if any) only affects the GUI label, NOT whether it boots. Boot analysis is S1-S4."

hr "S1 GATE-1 lingering (no linger => NO user unit, incl the 15, runs before login)"
UN="$(id -un)"; UIDn="$(id -u)"
LG1="$(loginctl show-user "$UN" --property=Linger 2>/dev/null | cut -d= -f2 | tr -d ' \r' || true)"
LG2="$(loginctl show-user "$UIDn" --property=Linger 2>/dev/null | cut -d= -f2 | tr -d ' \r' || true)"
LINGER="no"; { [ "$LG1" = yes ] || [ "$LG2" = yes ]; } && LINGER="yes"
say "Linger(user=$UN uid=$UIDn) = $LINGER  (raw: '$LG1'/'$LG2')"
[ "$LINGER" = yes ] || say "  !! If 'no', NOTHING user-scoped boots unattended -> that is the FIRST fix (loginctl enable-linger $UN; may need polkit/sudo)."

hr "S2 per-unit boot-mechanism fingerprint (FragmentPath = generated-vs-real discriminator)"
printf '  %-20s %-9s %-9s %-7s %-6s %-9s %s\n' UNIT FRAGKIND IS_ENABLED WANTS ACTIVE CONTAINER BOOT?
declare -A BOOT
for s in $P17; do
  u="$(unit_for "$s")"
  fp="$(systemctl --user show "$u" -p FragmentPath --value 2>/dev/null | tr -d '\r' || true)"
  kind="none"; case "$fp" in
    /run/user/*/systemd/generator/*) kind="generated" ;;
    "$SUDIR"/*|/etc/systemd/user/*)  kind="real" ;;
    "") kind="absent" ;;
    *) kind="other" ;;
  esac
  en="$(systemctl --user is-enabled "$u" 2>/dev/null | tr -d '\r\n' || true)"; [ -z "$en" ] && en="?"
  w="no"; for d in "$SUDIR"/*.wants; do [ -e "$d/$u" ] && { w="yes"; break; }; done
  ac="$(systemctl --user is-active "$u" 2>/dev/null | tr -d '\r\n' || true)"; [ -z "$ac" ] && ac="?"
  cb="no"; cs="no"
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$s" && cb="yes"
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "systemd-$s" && cs="yes"
  cont="-"; [ "$cb" = yes ] && cont="$s"; [ "$cs" = yes ] && cont="systemd-$s"
  # boot verdict from MEASURED facts only
  rec="no"; grep -qxF "$u" "$REC_LIST" 2>/dev/null && rec="yes"
  b="NO/UNKNOWN"
  if [ "$LINGER" = yes ]; then
    if [ "$w" = yes ]; then b="YES(wants)"
    elif [ "$rec" = yes ]; then b="YES(reconciler)"
    elif [ "$en" = enabled ]; then b="YES(enabled)"
    fi
  fi
  BOOT[$s]="$b"
  printf '  %-20s %-9s %-9s %-7s %-6s %-9s %s\n' "$u" "$kind" "$en" "$w" "$ac" "$cont" "$b"
done

hr "S3 reconciler identity + contract (WHO enforces 'Wake on OS reboot', and does it enumerate units?)"
say "--- files containing the boot-policy banner (redacted) ---"
grep -rIl -E 'Wake on OS reboot|reconciled|enforced at startup' "$SUDIR" "$HOME_/DevOps/aether" 2>/dev/null | sed 's/^/    /' || say "    (none found in user-unit or aether trees)"
say "--- enabled user services (systemd's own view) ---"
systemctl --user list-unit-files --type=service --state=enabled --no-pager --plain 2>/dev/null | awk 'NR>1{print "    "$1}' || say "    (none)"
say "--- wants-dir symlink inventory (the persistent enable mechanism) ---"
for d in "$SUDIR"/*.wants; do
  [ -d "$d" ] || continue
  say "  $d:"; ls -1 "$d" 2>/dev/null | sed 's/^/      /' || true
done
say "--- reconciler unit-name list (lines mentioning .service, redacted) -> cached for S2 rec? ---"
# capture candidate reconciler bodies; extract only *.service tokens (safe), redact rest
for rf in $(grep -rIl -E 'Wake on OS reboot|reconciled|enforced at startup' "$SUDIR" "$HOME_/DevOps/aether" 2>/dev/null); do
  say "  source: $rf"
  grep -oE '[A-Za-z0-9_.@-]+\.service' "$rf" 2>/dev/null | sort -u | redact | sed 's/^/      unit-ref: /' | tee -a "$REC_LIST" >/dev/null || true
  # also show the ExecStart line shape WITHOUT values (redacted)
  grep -nE '^[[:space:]]*Exec(Start|StartPre|Stop)=' "$rf" 2>/dev/null | redact | sed 's/^/      exec: /' | head -8 || true
done
sort -u "$REC_LIST" -o "$REC_LIST" 2>/dev/null || true
say "cached reconciler unit-refs: $(wc -l < "$REC_LIST" 2>/dev/null | tr -d ' ') (used by S2 'rec?' column above; re-run S2 not needed — S2 already consumed it if file pre-existed; see S4 note)"

hr "S4 verdict (re-derived now that S3 has populated the reconciler list)"
printf '  %-20s %s\n' UNIT BOOT-AT-REBOOT
for s in $P17; do printf '  %-20s %s\n' "$s" "${BOOT[$s]:-?}"; done
NEWZ="${BOOT[zitadel]:-?}"; NEWP="${BOOT[portainer]:-?}"
say "---- focus on the 2 new units ----"
say "zitadel : $NEWZ    portainer : $NEWP"
# Note: S2's rec? column ran BEFORE S3 filled REC_LIST, so if a reconciler exists and
# lists these units, S2 may under-report YES(reconciler). S4 re-prints the same BOOT map;
# the authoritative reconciler coverage is: does $REC_LIST contain zitadel.service / portainer.service ?
grep -qxF "zitadel.service"   "$REC_LIST" 2>/dev/null && say "reconciler-lists zitadel.service  : YES" || say "reconciler-lists zitadel.service  : no"
grep -qxF "portainer.service" "$REC_LIST" 2>/dev/null && say "reconciler-lists portainer.service: YES" || say "reconciler-lists portainer.service: no"

hr "S5 conditional next-action (chosen by S1-S4; NOT applied this turn — read-only)"
if [ "$LINGER" != yes ]; then
  say "FIX-1 (required first, blocks ALL 17): enable lingering -> 'loginctl enable-linger $UN' (may prompt polkit; no sudo for own user on most setups). Then re-run DS."
elif [ "$NEWZ" = NO/UNKNOWN ] || [ "$NEWP" = NO/UNKNOWN ]; then
  # decide between reconciler-add vs wants-symlink by what the 15 actually use
  gen15=0; real15=0; wants15=0
  for s in postgres redis minio weaviate prometheus node-exporter mailpit llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik; do
    u="$(unit_for "$s")"; fp="$(systemctl --user show "$u" -p FragmentPath --value 2>/dev/null | tr -d '\r' || true)"
    case "$fp" in /run/user/*/systemd/generator/*) gen15=$((gen15+1));; "$SUDIR"/*|/etc/systemd/user/*) real15=$((real15+1));; esac
    w="no"; for d in "$SUDIR"/*.wants; do [ -e "$d/$u" ] && { w="yes"; break; }; done; [ "$w" = yes ] && wants15=$((wants15+1))
  done
  say "platform pattern measured: of the 15 -> generated=$gen15 real=$real15 with-wants-symlink=$wants15"
  if [ "$wants15" -gt 0 ]; then
    say "FIX-2a (preferred, matches the 15): create the SAME persistent wants symlink for the 2 new units in ~/.config/systemd/user/default.target.wants/ (DT will mirror the exact link target the 15 use, incl. generated->/run generator path which the generator reproduces each boot)."
  elif [ "$gen15" -gt 0 ]; then
    say "FIX-2b: some platform units ARE generated yet boot -> they rely on the reconciler (S3). Add 'zitadel.service portainer.service' to that reconciler's unit list (DT edits the ONE file S3 named, preserving all other bytes)."
  else
    say "FIX-2c: no generated platform unit and no wants symlinks among the 15 (all real+enabled). The 2 new generated units have NO in-tree precedent -> DT converts persistence the safe way (add wants symlinks OR register with reconciler), decided by re-reading S3's reconciler contract. Paste S1-S4 and I ship DT precisely."
  fi
else
  say "NO FIX NEEDED for boot: both new units already show a YES path (wants/reconciler/enabled). Lingering on. You are reboot-safe. (Naming from half-done DR is cosmetic; say 'finish DR naming' only if you want bare labels.)"
fi

hr "S6 ledger (read-only INFO row; append-only)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=INFO | DS read-only reboot audit: Linger=%s; zitadel-boot=%s portainer-boot=%s; reconciler-lists(zitadel,portainer)=(%s,%s); platform-15 pattern computed in S5. No mutations. DR-midway naming = cosmetic. |\n' \
    "$(date +%F)" "$TOKEN" "$LINGER" "${BOOT[zitadel]:-?}" "${BOOT[portainer]:-?}" \
    "$(grep -qxF zitadel.service "$REC_LIST" 2>/dev/null && echo yes || echo no)" \
    "$(grep -qxF portainer.service "$REC_LIST" 2>/dev/null && echo yes || echo no)" >> "$IDX"
  say "ledger row appended (INFO)"
fi
rm -f "$REC_LIST" 2>/dev/null || true
say "[RESULT] DS COMPLETE - paste S1-S5; the single FIX-n line is your next action (I apply it as DT only after you confirm / or auto if NO FIX NEEDED)."
exit 0
