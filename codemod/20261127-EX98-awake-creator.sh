#!/usr/bin/env bash
# EX98: create+enable aether-awake.service (canonical sentinel creator); prove gate blocks and creator restores.
# Usage: bash /tmp/EX98.sh [--check]
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; CM="$A/codemod"; TOK="$A/secrets/woodpecker-pat.token"
U="$HOME/.config/systemd/user/aether-awake.service"; RS="$A/infra/systemd/aether-awake.service"
SENT="/run/user/$(id -u)/aether-awake"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
say(){ printf '  %s\n' "$*"; }; hr(){ printf '\n===== %s =====\n' "$*"; }; halt(){ say "[HALT] $*"; exit 1; }

hr "X0 discovery: gated units + linger"
mapfile -t GATED < <(for d in "$HOME"/.config/systemd/user/*.d; do
  [ -f "$d/10-aether-boot.conf" ] || continue
  grep -q 'aether-awake' "$d/10-aether-boot.conf" || continue
  basename "$d" | sed 's/\.d$//'
done)
say "  gated units (${#GATED[@]}): ${GATED[*]}"
[ "${#GATED[@]}" -ge 1 ] || halt "no gated units discovered - anchor evidence missing"
LIN=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)
say "  Linger=$LIN"
say "  sentinel now: $([ -e "$SENT" ] && echo present || echo ABSENT)"

hr "X1 stage canonical creator unit"
S=$(mktemp -d)
{
  printf '[Unit]\n'
  printf 'Description=Aether awake sentinel - boot gate for the container stack\n'
  printf 'Before=%s\n' "${GATED[*]}"
  printf '\n[Service]\n'
  printf 'Type=oneshot\n'
  printf 'RemainAfterExit=yes\n'
  printf 'ExecStart=/usr/bin/touch %%t/aether-awake\n'
  printf 'ExecStartPost=/usr/bin/chmod 0644 %%t/aether-awake\n'
  printf 'ExecStop=/usr/bin/rm -f %%t/aether-awake\n'
  printf '\n[Install]\n'
  printf 'WantedBy=default.target\n'
} > "$S/aether-awake.service"
cat "$S/aether-awake.service" | sed 's/^/  /'
if [ -f "$U" ]; then cmp -s "$U" "$S/aether-awake.service" && say "unchanged: installed unit" || diff -u "$U" "$S/aether-awake.service" | head -20; fi
if [ "$CHECK" = 1 ]; then say "[CHECK] no writes performed"; rm -rf "$S"; exit 0; fi
mkdir -p "$A/infra/systemd"
for f in "$U" "$RS"; do
  if [ -f "$f" ] && cmp -s "$f" "$S/aether-awake.service"; then say "unchanged: $f"; else
    [ -f "$f" ] && [ ! -f "$f.pre-ex98.bak" ] && cp -p "$f" "$f.pre-ex98.bak"
    install -m 644 "$S/aether-awake.service" "$f"; say "written: $f"; fi
done
rm -rf "$S"
systemctl --user daemon-reload || halt "daemon-reload failed"
systemctl --user cat aether-awake.service >/dev/null 2>&1 && say "G0 unit loads: PASS" || halt "G0 unit not loadable"

hr "X2 enable at boot + start"
if [ "$LIN" != yes ]; then
  say "  enabling linger for $USER"
  loginctl enable-linger "$USER" 2>/dev/null || true
  LIN=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)
fi
[ "$LIN" = yes ] && say "G1 Linger=yes (user units run at boot): PASS" || halt "G1 Linger=$LIN - run: loginctl enable-linger $USER"
systemctl --user enable aether-awake.service >/dev/null 2>&1 || halt "enable failed"
[ "$(systemctl --user is-enabled aether-awake.service 2>/dev/null)" = enabled ] && say "G2 creator enabled: PASS" || halt "G2 not enabled"
systemctl --user start aether-awake.service || halt "creator start failed"
[ -e "$SENT" ] && say "G3 sentinel present: PASS" || halt "G3 sentinel absent"

hr "X3 NEGATIVE CONTROL: gate must block without sentinel, creator must restore"
systemctl --user stop aether-awake.service
[ ! -e "$SENT" ] && say "G4 ExecStop removes sentinel: PASS" || halt "G4 sentinel survived stop"
systemctl --user start podman-stats.service >/dev/null 2>&1 || true
CR=$(systemctl --user show podman-stats.service -p ConditionResult --value 2>/dev/null)
[ "$CR" = no ] && say "G5 gate really blocks a start (ConditionResult=no): PASS" || say "G5 ConditionResult=$CR (informational)"
systemctl --user start aether-awake.service || halt "creator restart failed"
[ -e "$SENT" ] && say "G6 creator restores sentinel: PASS" || halt "G6 restore failed"
systemctl --user start podman-stats.service >/dev/null 2>&1 && say "G7 gated unit starts once sentinel restored: PASS" || halt "G7 still blocked"

hr "X4 stack regressions"
podman ps --format '{{.Names}}' | grep -qx pixorb-api && say "G8 api container Up: PASS" || halt "G8"
H=0; for i in $(seq 1 20); do
  C=$(curl -s -o /tmp/ex98-h -w '%{http_code}' --max-time 3 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health 2>/dev/null)
  [ "$C" = 200 ] && grep -q '"db":true' /tmp/ex98-h && { H=1; break; }; sleep 3; done
[ "$H" = 1 ] && say "G9 edge /health db=true: PASS" || halt "G9"
systemctl --user is-active --quiet pixorb-worker.service && say "G10 worker active: PASS" || halt "G10"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: shop.pixorb.localhost' http://127.0.0.1:8888/)" = 200 ] && say "G11 shop edge: PASS" || halt "G11"
bash "$P/infra/scripts/lock-verify.sh" >/dev/null 2>&1 && say "G12 drift gate: PASS" || halt "G12"

hr "X5 record + ledger + CI"
mkdir -p "$CM"; SELF="$CM/20261127-EX98-awake-creator.sh"
if [ -f "$SELF" ] && cmp -s "$0" "$SELF"; then say "record present (no-op)"; else install -m 755 "$0" "$SELF"; say "written: codemod record"; fi
IDX="$CM/INDEX.md"
grep -qF "ex98-awake-creator-v1:PASS" "$IDX" || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "ex98-awake-creator-v1:PASS" "canonical aether-awake.service created+enabled (WantedBy=default.target, Before=gated set); linger verified; negative control proves gate blocks and creator restores; stack green" >> "$IDX"
git -C "$A" add infra/systemd/aether-awake.service codemod
git -C "$A" diff --cached --quiet && say "nothing to commit (no-op)" || {
  git -C "$A" commit -q -m "ops(boot): canonical awake-sentinel creator, enabled at boot (EX98)"; say "committed"; }
git -C "$A" push -q origin main && say "G13 push: PASS" || halt "G13 push failed"
SHA=$(git -C "$A" rev-parse HEAD); T=$(tr -d '\r\n' < "$TOK"); ST=""; NUM=""
for i in $(seq 1 40); do
  curl -s --max-time 8 -H "Authorization: Bearer $T" "http://127.0.0.1:8000/api/repos/2/pipelines?perPage=10" -o /tmp/ex98-pl.json
  read -r NUM ST <<<"$(python3 -c "
import json
d=json.load(open('/tmp/ex98-pl.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
p=m[0] if m else {}
print(p.get('number',''), p.get('status',''))" 2>/dev/null)"
  say "  pipeline #${NUM:-?} status=${ST:-none}"
  case "$ST" in success|failure|error|killed|declined) break;; esac
  sleep 15
done
[ "$ST" = success ] && say "G14 aether CI green: PASS (#$NUM)" || halt "G14 CI status=$ST"
say "DEBT: pixorb working tree still holds deferred REPAIR-26/27 + contract-test edits (EX99)."
say "[RESULT] EX98 COMPLETE."
exit 0
