#!/usr/bin/env bash
# REPAIR-30: heal stale podman socket (listener proof), start agent, bounded CI re-trigger.
# Usage: bash /tmp/REPAIR-30.sh [--check]
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
A="$HOME/DevOps/aether"; CM="$A/codemod"; T=$(tr -d '\r\n' < "$A/secrets/woodpecker-pat.token")
SOCK="/run/user/$(id -u)/podman/podman.sock"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
say(){ printf '  %s\n' "$*"; }; hr(){ printf '\n===== %s =====\n' "$*"; }; halt(){ say "[HALT] $*"; exit 1; }
api(){ curl -s --max-time 5 --unix-socket "$SOCK" http://d/v4.0.0/libpod/_ping >/dev/null 2>&1; echo $?; }
listeners(){ ss -lx 2>/dev/null | grep -c 'podman.sock'; }
agent_up(){ podman ps --format '{{.Names}}' | grep -qx woodpecker-agent; }

hr "X0 EVIDENCE (authoritative unit + listener proof)"
say "--- real agent unit definition (secrets masked) ---"
systemctl --user cat woodpecker-agent.service 2>/dev/null \
  | sed -E 's/(SECRET|TOKEN|PASSWORD)=[^ "]*/\1=***/g' \
  | grep -E '^(#|ExecStart|Environment|\[)' | cut -c1-240 | sed 's/^/  /' || halt "cannot read agent unit"
say "--- podman.socket journal ---"
journalctl --user -u podman.socket -n 12 --no-pager 2>/dev/null | tail -12 | sed 's/^/  /' || say "  none"
say "  listeners on podman.sock: $(listeners)"
say "  libpod API rc=$(api) (0= answering)"
say "  podman.service: $(systemctl --user is-active podman.service 2>/dev/null)"
if [ "$CHECK" = 1 ]; then say "[CHECK] no writes performed"; exit 0; fi

hr "X1 heal the socket until the API actually answers"
systemctl --user reset-failed podman.socket podman.service 2>/dev/null || true
if [ "$(api)" != 0 ]; then
  systemctl --user stop podman.socket 2>/dev/null || true
  L=$(listeners)
  if [ "${L:-0}" = 0 ] && [ -S "$SOCK" ]; then rm -f "$SOCK"; say "  stale socket inode removed (no listener)"; fi
  systemctl --user start podman.socket || { journalctl --user -u podman.socket -n 20 --no-pager | tail -20 | sed 's/^/  /'; halt "socket start failed"; }
fi
OK=0; for i in $(seq 1 15); do [ "$(api)" = 0 ] && { OK=1; break; }; sleep 1; done
[ "$OK" = 1 ] && say "G0 libpod API answers on socket: PASS" || { journalctl --user -u podman.socket -n 20 --no-pager | tail -20 | sed 's/^/  /'; halt "G0 socket not answering"; }
systemctl --user is-enabled --quiet podman.socket && say "G1 socket enabled at boot: PASS" || systemctl --user enable podman.socket >/dev/null 2>&1 || true

hr "X2 start agent + stability proof"
systemctl --user reset-failed woodpecker-agent.service 2>/dev/null || true
systemctl --user restart woodpecker-agent.service || halt "agent restart rc!=0"
sleep 6; agent_up || { podman logs woodpecker-agent --tail 15 2>&1 | sed 's/^/  /'; journalctl --user -u woodpecker-agent.service -n 15 --no-pager | tail -15 | sed 's/^/  /'; halt "agent absent at t=6s"; }
sleep 20
agent_up && say "G2 agent STAYS up (t=26s): PASS" || { journalctl --user -u woodpecker-agent.service -n 20 --no-pager | tail -20 | sed 's/^/  /'; halt "G2 crash-loop"; }
podman logs woodpecker-agent --tail 40 2>&1 | grep -q 'cannot load backend engine' && halt "backend engine still failing" || say "G3 no backend-engine error: PASS"

hr "X3 bounded CI re-trigger (aborts if agent dies)"
git -C "$A" commit -q --allow-empty -m "ci: re-trigger after podman socket listener restore (REPAIR-30)" && say "committed"
git -C "$A" push -q origin main && say "G4 push: PASS" || halt "G4 push failed"
SHA=$(git -C "$A" rev-parse HEAD); ST=""; NUM=""
for i in $(seq 1 24); do
  agent_up || { say "  agent died during CI wait"; break; }
  curl -s --max-time 8 -H "Authorization: Bearer $T" "http://127.0.0.1:8000/api/repos/2/pipelines?perPage=10" -o /tmp/r30-pl.json
  read -r NUM ST <<<"$(python3 -c "
import json
d=json.load(open('/tmp/r30-pl.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
p=m[0] if m else {}
print(p.get('number',''), p.get('status',''))" 2>/dev/null)"
  say "  t=$((i*15))s pipeline #${NUM:-?} status=${ST:-none}"
  case "$ST" in success|failure|error|killed|declined) break;; esac
  sleep 15
done
[ "$ST" = success ] && say "G5 aether CI green: PASS (#$NUM)" || halt "G5 CI status=${ST:-none}"

hr "X4 record + ledger"
mkdir -p "$CM"; SELF="$CM/20261127-REPAIR-30-socket-listener.sh"
if [ -f "$SELF" ] && cmp -s "$0" "$SELF"; then say "record present (no-op)"; else install -m 755 "$0" "$SELF"; say "written: codemod record"; fi
IDX="$CM/INDEX.md"
grep -qF "repair-30-socket-listener-v1:PASS" "$IDX" || printf '| %s | C | %s | GATE=PASS | %s |\n' "$(date +%F)" "repair-30-socket-listener-v1:PASS" "podman.socket failed with stale inode and no listener; cleared only after ss proved no listener; libpod API answering; agent stable 26s; aether CI green" >> "$IDX"
git -C "$A" add codemod && { git -C "$A" diff --cached --quiet || git -C "$A" commit -q -m "docs(codemod): socket listener restore record (REPAIR-30)"; }
git -C "$A" push -q origin main 2>/dev/null || true
say "[RESULT] REPAIR-30 COMPLETE."
exit 0
