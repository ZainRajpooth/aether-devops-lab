#!/usr/bin/env bash
# 20261103-DT — make the ENTIRE generated fleet boot-persistent via the ONE verified
# mechanism (default.target.wants symlink), mirroring the 8 real platform units. Acts
# on every P17 unit that is generator-backed AND lacks a wants symlink AND is not
# is-enabled=enabled (=> the 7 platform generated + zitadel + portainer). NEVER touches
# the 8 real units (their symlinks target ~/.config real files, not the generator dir).
# Zero runtime disruption: creates symlinks + daemon-reload only (no start/stop/rm of
# any container/unit). Reads no secret file -> nothing to redact. Modes: check|run|rollback.
set -uo pipefail
HOME_="$HOME"
SUDIR="$HOME_/.config/systemd/user"
UIDn="$(id -u)"
GENBASE="/run/user/${UIDn}/systemd/generator"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="dt-wants-symlink-boot-persistence-v1"
MODE="${1:-run}"
P17="postgres redis minio weaviate prometheus node-exporter mailpit llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik zitadel portainer"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
unit_for(){ case "$1" in llama-embed) printf 'llama-embed-container.service';; *) printf '%s.service' "$1";; esac; }
frag(){ systemctl --user show "$1" -p FragmentPath --value 2>/dev/null | tr -d '\r'; }
is_gen(){ case "$1" in "$GENBASE"/*) return 0;; *) return 1;; esac; }
has_sym(){ local u="$1" d; for d in "$SUDIR"/*.wants; do [ -e "$d/$u" ] && return 0; done; return 1; }
en_yes(){ [ "$(systemctl --user is-enabled "$1" 2>/dev/null | tr -d '\r\n')" = enabled ]; }

hr "T-ROLLBACK (only if MODE=rollback): remove symlinks whose target is under $GENBASE"
if [ "$MODE" = rollback ]; then
  REM=()
  for s in $P17; do u="$(unit_for "$s")"
    for d in "$SUDIR"/*.wants; do
      [ -L "$d/$u" ] || continue
      tgt="$(readlink -f "$d/$u" 2>/dev/null || true)"
      case "$tgt" in "$GENBASE"/*) rm -f "$d/$u"; REM+=("$u"); say "removed $d/$u (-> $tgt)";; esac
    done
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  say "rollback removed ${#REM[@]} generator-targeted symlink(s): ${REM[*]:-none}"
  say "[RESULT] DT ROLLBACK COMPLETE - real-unit symlinks untouched; reboot-persistence reverted to pre-DT state."
  exit 0
fi

hr "T0 plan (measure each P17 unit; decide target set)"
declare -a TARGETS
for s in $P17; do u="$(unit_for "$s")"; fp="$(frag "$u")"
  gen=no; is_gen "$fp" && gen=yes
  sym=no; has_sym "$u" && sym=yes
  en=no;  en_yes  "$u" && en=yes
  verdict="leave-as-is"
  if [ "$gen" = yes ] && [ "$sym" = no ] && [ "$en" = no ]; then
    if [ -n "$fp" ] && [ -e "$fp" ]; then TARGETS+=("$u|$fp"); verdict="WILL-SYMLINK"
    else verdict="SKIP(fragment-unresolvable)"; fi
  fi
  printf '  %-28s gen=%-3s sym=%-3s en=%-3s %s\n' "$u" "$gen" "$sym" "$en" "$verdict"
done
say "target set size = ${#TARGETS[@]} (expect 9 = 7 platform-generated + zitadel + portainer)"

hr "T1 act (MODE=$MODE)"
if [ "${#TARGETS[@]}" -eq 0 ]; then
  say "nothing to do: every generated unit already persistent (idempotent no-op)"
else
  mkdir -p "$SUDIR/default.target.wants"
  ACTED=()
  for t in "${TARGETS[@]}"; do u="${t%%|*}"; fp="${t#*|}"
    if [ "$MODE" = check ]; then say "[check] would: ln -sfn $fp -> $SUDIR/default.target.wants/$u"
    else ln -sfn "$fp" "$SUDIR/default.target.wants/$u" && ACTED+=("$u") && say "symlinked $u -> $fp"; fi
  done
  if [ "$MODE" != check ]; then systemctl --user daemon-reload >/dev/null 2>&1 || true; say "daemon-reloaded; acted this run = ${#ACTED[@]}: ${ACTED[*]:-none}"; fi
fi
[ "$MODE" = check ] && { say "[RESULT] DT CHECK - plan above; nothing written/started."; exit 0; }

hr "T2 verify (recompute persistence for ALL 17; expect 17/17)"
printf '  %-28s %-5s %-5s %s\n' UNIT SYM EN BOOT?
ok=0; tot=0
for s in $P17; do u="$(unit_for "$s")"; tot=$((tot+1))
  sym=no; has_sym "$u" && sym=yes
  en=no;  en_yes  "$u" && en=yes
  b=NO
  [ "$sym" = yes ] && b="YES(wants)"
  [ "$en" = yes ] && [ "$sym" != yes ] && b="YES(enabled)"
  [ "$b" != NO ] && ok=$((ok+1))
  printf '  %-28s %-5s %-5s %s\n' "$u" "$sym" "$en" "$b"
done
say "persistent = $ok/$tot (expect 17/17)"
[ "$ok" = "$tot" ] && say "[RESULT] DT COMPLETE - 17/17 boot-persistent via verified wants symlinks; zero runtime disruption (no unit restarted)." \
                   || say "[RESULT] DT PARTIAL - $ok/$tot persistent; paste the T2 NO rows."

hr "T3 ledger (append-only)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | DT: added default.target.wants symlinks (-> generator FragmentPath, guarded by [ -e ]) for every generated P17 unit lacking symlink+enabled => the 7 platform-generated + zitadel + portainer (target-set=%d); 8 real units untouched (their symlinks target ~/.config real files); no unit started/stopped; daemon-reload only; verify %s/%s. Implements DS FIX-2a broadened-by-evidence; removes reliance on unverified reconciler for the generated class. rollback mode removes only generator-targeted links. |\n' \
    "$(date +%F)" "$TOKEN" "$([ "$ok" = "$tot" ] && echo PASS || echo PARTIAL)" "${#TARGETS[@]}" "$ok" "$tot" >> "$IDX"
  say "ledger row appended"
fi
exit 0
