#!/usr/bin/env bash
# REPAIR-35: host-side Portainer API probe; complete legacy move; gate + commit.
# Usage: bash /tmp/REPAIR-35.sh [--check]
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; CM="$A/codemod"; T=$(tr -d '\r\n' < "$A/secrets/woodpecker-pat.token")
BIND="/home/dev/DevOps/aether/infra/portainer/data"; LEG="$HOME/.local/share/aether-legacy"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
say(){ printf '  %s\n' "$*"; }; hr(){ printf '\n===== %s =====\n' "$*"; }; halt(){ say "[HALT] $*"; exit 1; }

hr "X0 evidence"
podman ps --format '{{.Names}} | {{.Status}}' | grep portainer | sed 's/^/  /'
podman inspect portainer --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}' 2>/dev/null | sed 's/^/  /'
podman port portainer 2>/dev/null | sed 's/^/  port: /'
[ -d "$BIND" ] && say "  legacy dir present: $(find "$BIND" -type f | wc -l) files" || say "  legacy dir absent"
if [ "$CHECK" = 1 ]; then say "[CHECK] no writes performed"; exit 0; fi

hr "X1 probe Portainer API from HOST (published ports)"
H=0; for i in $(seq 1 20); do
  R=$(curl -sk --max-time 5 https://127.0.0.1:9443/api/status 2>/dev/null)
  echo "$R" | grep -q 'Version' && { H=1; say "  9443 HTTPS responded"; break; }
  R=$(curl -s --max-time 5 http://127.0.0.1:9000/api/status 2>/dev/null)
  echo "$R" | grep -q 'Version' && { H=1; say "  9000 HTTP responded"; break; }
  sleep 2
done
[ "$H" = 1 ] && say "G0 Portainer API alive from host: PASS" || halt "G0 API not responding on either port"

hr "X2 move legacy keys OUT of the repo"
if [ -d "$BIND" ]; then
  N=$(find "$BIND" -type f | wc -l)
  mkdir -p "$LEG"
  DEST="$LEG/portainer-data-$(date +%Y%m%d-%H%M%S)"
  mv "$BIND" "$DEST" || halt "move failed"
  [ "$(find "$DEST" -type f | wc -l)" = "$N" ] && say "G1 legacy preserved ($N files): PASS" || halt "G1 count changed"
  [ ! -d "$BIND" ] && say "G2 keys out of working tree: PASS" || halt "G2 dir remains"
else say "G1/G2 legacy already outside repo (no-op)"; fi

hr "X3 regressions"
curl -s --max-time 5 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health | grep -q '"db":true' && say "G3 api db=true: PASS" || halt "G3"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: shop.pixorb.localhost' http://127.0.0.1:8888/)" = 200 ] && say "G4 shop edge: PASS" || halt "G4"
bash "$P/infra/scripts/lock-verify.sh" >/dev/null 2>&1 && say "G5 drift gate: PASS" || halt "G5"

hr "X4 record + ledger + CI"
mkdir -p "$CM"; SELF="$CM/20261127-REPAIR-35-portainer-host-probe.sh"
if [ -f "$SELF" ] && cmp -s "$0" "$SELF"; then say "record present (no-op)"; else install -m 755 "$0" "$SELF"; say "written: codemod record"; fi
IDX="$CM/INDEX.md"
grep -qF "repair-35-portainer-host-probe-v1:PASS" "$IDX" || printf '| %s | C | %s | GATE=PASS | %s |\n' "$(date +%F)" "repair-35-portainer-host-probe-v1:PASS" "Portainer probed from host via published ports (container has no shell utils); legacy keys moved; stack green" >> "$IDX"
git -C "$A" add codemod
git -C "$A" diff --cached --quiet && say "nothing to commit (no-op)" || {
  git -C "$A" commit -q -m "sec(state): complete portainer migration; host-side API probe (REPAIR-35)"; say "committed"; }
git -C "$A" push -q origin main && say "G6 push: PASS" || halt "G6 push failed"
SHA=$(git -C "$A" rev-parse HEAD); ST=""; NUM=""
for i in $(seq 1 32); do
  curl -s --max-time 8 -H "Authorization: Bearer $T" "http://127.0.0.1:8000/api/repos/2/pipelines?perPage=10" -o /tmp/r35-pl.json
  read -r NUM ST <<<"$(python3 -c "
import json
d=json.load(open('/tmp/r35-pl.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
p=m[0] if m else {}
print(p.get('number',''), p.get('status',''))" 2>/dev/null)"
  say "  t=$((i*15))s pipeline #${NUM:-?} status=${ST:-none}"
  case "$ST" in success|failure|error|killed|declined) break;; esac
  sleep 15
done
[ "$ST" = success ] && say "G7 aether CI green: PASS (#$NUM)" || halt "G7 CI status=${ST:-none}"
say "[RESULT] REPAIR-35 COMPLETE."
exit 0
