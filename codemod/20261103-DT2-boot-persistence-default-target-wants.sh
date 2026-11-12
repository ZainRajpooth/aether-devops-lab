#!/usr/bin/env bash
# 20261103-DT2 — harden DT: (a) kill the cosmetic set -u empty-array crash, (b) enforce
# the BOOT-CRITICAL invariant that DT only loosely checked: every GENERATED P17 unit must
# have default.target.wants/<u> resolving to the live /run generator FragmentPath (the only
# target the quadlet generator recreates each boot). The 8 REAL units are NEVER touched
# (their correct target is the ~/.config real file). Zero runtime disruption: only
# ln -sfn + daemon-reload; no start/stop/rm of any unit or container; reads no secret file.
# Modes: check | run | rollback. Idempotent.
set -uo pipefail
HOME_="$HOME"
SUDIR="$HOME_/.config/systemd/user"
LINKDIR="$SUDIR/default.target.wants"
UIDn="$(id -u)"
GENBASE="/run/user/${UIDn}/systemd/generator"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="dt2-boot-persistence-default-target-wants-v1"
MODE="${1:-run}"
P17="postgres redis minio weaviate prometheus node-exporter mailpit llama-embed litellm n8n gitea grafana woodpecker-server woodpecker-agent traefik zitadel portainer"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
unit_for(){ case "$1" in llama-embed) printf 'llama-embed-container.service';; *) printf '%s.service' "$1";; esac; }
frag(){ systemctl --user show "$1" -p FragmentPath --value 2>/dev/null | tr -d '\r'; }
is_gen(){ case "$1" in "$GENBASE"/*) return 0;; *) return 1;; esac; }
en_yes(){ [ "$(systemctl --user is-enabled "$1" 2>/dev/null | tr -d '\r\n')" = enabled ]; }
link_target(){ readlink -f "$LINKDIR/$1" 2>/dev/null || true; }   # "" if no link / dangling

hr "X-ROLLBACK (only if MODE=rollback): remove default.target.wants links whose target is under $GENBASE"
if [ "$MODE" = rollback ]; then
  REM=""
  for s in $P17; do u="$(unit_for "$s")"; [ -L "$LINKDIR/$u" ] || continue
    tgt="$(link_target "$u")"
    case "$tgt" in "$GENBASE"/*) rm -f "$LINKDIR/$u"; REM="$REM $u"; say "removed $LINKDIR/$u (-> $tgt)";; esac
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  say "rollback removed:${REM:- none}"
  say "[RESULT] DT2 ROLLBACK COMPLETE - real-unit links untouched; reboot-persistence reverted to pre-DT2 state."
  exit 0
fi

hr "X0 plan (per unit: gen? link in default.target.wants? target == live fragment?)"
TARGETS=(); TCOUNT=0
for s in $P17; do u="$(unit_for "$s")"; fp="$(frag "$u")"; gen=no; is_gen "$fp" && gen=yes
  cur="$(link_target "$u")"; sym=no; [ -L "$LINKDIR/$u" ] && sym=yes
  if [ "$gen" = yes ]; then
    if [ -n "$fp" ] && [ -e "$fp" ] && [ "$cur" = "$fp" ]; then v="OK(gen, link->fragment)"
    elif [ -n "$fp" ] && [ -e "$fp" ]; then TARGETS+=("$u|$fp"); TCOUNT=$((TCOUNT+1)); v="WILL-RELINK(cur=${cur:-NONE})"
    else v="SKIP(fragment-unresolvable)"; fi
  else
    v="leave(real, never touched)"
  fi
  printf '  %-28s gen=%-3s sym=%-3s %s\n' "$u" "$gen" "$sym" "$v"
done
say "relink target-set = $TCOUNT (these are the generated units lacking a correct default.target.wants link)"

hr "X1 act (MODE=$MODE)"
if [ "$TCOUNT" -eq 0 ]; then
  say "nothing to relink: every generated unit already has default.target.wants -> live fragment (idempotent no-op)"
else
  mkdir -p "$LINKDIR"
  ACTED=""
  for t in ${TARGETS[@]+"${TARGETS[@]}"}; do uu="${t%%|*}"; ff="${t#*|}"
    if [ "$MODE" = check ]; then say "[check] would: ln -sfn $ff -> $LINKDIR/$uu"
    else ln -sfn "$ff" "$LINKDIR/$uu" && ACTED="$ACTED $uu" && say "relinked $uu -> $ff"; fi
  done
  if [ "$MODE" != check ]; then systemctl --user daemon-reload >/dev/null 2>&1 || true; say "daemon-reloaded; acted this run:${ACTED:- none}"; fi
fi
[ "$MODE" = check ] && { say "[RESULT] DT2 CHECK - plan above; nothing written/started."; exit 0; }

hr "X2 verify (boot truth: link in default.target.wants AND, for generated, target==fragment)"
printf '  %-28s %-4s %-9s %s\n' UNIT LINK GEN-TGT BOOT?
PERSIST=0; TOT=0; GENBAD=""
for s in $P17; do u="$(unit_for "$s")"; TOT=$((TOT+1)); fp="$(frag "$u")"; gen=no; is_gen "$fp" && gen=yes
  sym=no; [ -L "$LINKDIR/$u" ] && sym=yes
  cur="$(link_target "$u")"
  gt="-"; boot=NO
  if [ "$gen" = yes ]; then gt=no; [ "$sym" = yes ] && [ "$cur" = "$fp" ] && gt=yes; [ "$gt" = yes ] && boot=YES
  else [ "$sym" = yes ] && boot=YES; fi
  [ "$boot" = YES ] && PERSIST=$((PERSIST+1)) || { [ "$gen" = yes ] && GENBAD="$GENBAD $u"; }
  printf '  %-28s %-4s %-9s %s\n' "$u" "$sym" "$gt" "$boot"
done
say "persistent(default.target.wants) = $PERSIST/$TOT (expect 17/17)"
[ -n "$GENBAD" ] && say "!! generated units WITHOUT correct default.target.wants link:$GENBAD"
if [ "$PERSIST" = "$TOT" ] && [ -z "$GENBAD" ]; then
  say "[RESULT] DT2 COMPLETE - 17/17 pinned in default.target.wants; all 9 generated links resolve to the live /run generator path (reproduced each boot); 8 real untouched; zero runtime disruption. SAFE TO REBOOT to verify."
else
  say "[RESULT] DT2 PARTIAL - paste the X2 NO/!! rows; do NOT reboot until 17/17 + no GENBAD."
fi

hr "X3 ledger (append-only)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=%s | DT2: fixed DT cosmetic set-u empty-array crash (counter + guarded expansion); enforced BOOT-CRITICAL invariant DT only loosely checked - every generated P17 unit must have default.target.wants/<u> resolving to live /run generator FragmentPath (the only target the generator recreates each boot); relink-set=%d; 8 real units never touched; no unit/container started/stopped; daemon-reload only; verify %s/%s, genbad=[%s]. Provenance of DT-seen links unexplained (DS absent->DT present w/o DT creating them; likely GUI reconciler/manual, possibly wrong wants dir/stale target) - DT2 makes state correct regardless. |\n' \
    "$(date +%F)" "$TOKEN" "$([ "$PERSIST" = "$TOT" ] && [ -z "$GENBAD" ] && echo PASS || echo PARTIAL)" "$TCOUNT" "$PERSIST" "$TOT" "${GENBAD:-none}" >> "$IDX"
  say "ledger row appended"
fi
exit 0
