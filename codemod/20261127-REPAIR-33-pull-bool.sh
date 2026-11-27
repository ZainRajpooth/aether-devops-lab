#!/usr/bin/env bash
# REPAIR-33: pull: never -> pull: false (Woodpecker 3.20 bool schema); push; gate green.
# Usage: bash /tmp/REPAIR-33.sh [--check]
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
P="$HOME/DevOps/pixorb"; A="$HOME/DevOps/aether"; CM="$A/codemod"; T=$(tr -d '\r\n' < "$A/secrets/woodpecker-pat.token")
Y="$P/.woodpecker.yml"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
say(){ printf '  %s\n' "$*"; }; hr(){ printf '\n===== %s =====\n' "$*"; }; halt(){ say "[HALT] $*"; exit 1; }

hr "X0 evidence"
grep -n 'pull:' "$Y" | sed 's/^/  /' || say "  no pull lines"
grep -n 'image: localhost/pixorb-ci' "$Y" | sed 's/^/  /'
[ "$(grep -c 'pull: never' "$Y")" = 2 ] || halt "expected exactly 2 'pull: never' lines"
if [ "$CHECK" = 1 ]; then say "[CHECK] no writes performed"; exit 0; fi

hr "X1 anchored type fix"
S=$(mktemp -d)
sed 's/^    pull: never$/    pull: false/' "$Y" > "$S/wp.yml"
diff -u "$Y" "$S/wp.yml" | head -12
[ "$(grep -c 'pull: false' "$S/wp.yml")" = 2 ] && [ "$(grep -c 'pull: never' "$S/wp.yml")" = 0 ] \
  && say "G0 both pull lines now boolean false: PASS" || { rm -rf "$S"; halt "G0 substitution incomplete"; }
install -m 644 "$S/wp.yml" "$Y"; rm -rf "$S"; say "written: .woodpecker.yml"

hr "X2 push + bounded CI gate"
git -C "$P" add .woodpecker.yml
git -C "$P" diff --cached --quiet && say "nothing to commit (no-op)" || {
  git -C "$P" commit -q -m "ci: pull schema is boolean in woodpecker 3.20 (REPAIR-33)"; say "committed"; }
git -C "$P" push -q origin main && say "G1 push: PASS" || halt "G1 push failed"
SHA=$(git -C "$P" rev-parse HEAD); ST=""; NUM=""
for i in $(seq 1 48); do
  curl -s --max-time 8 -H "Authorization: Bearer $T" "http://127.0.0.1:8000/api/repos/3/pipelines?perPage=10" -o /tmp/r33-pl.json
  read -r NUM ST <<<"$(python3 -c "
import json
d=json.load(open('/tmp/r33-pl.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
p=m[0] if m else {}
print(p.get('number',''), p.get('status',''))" 2>/dev/null)"
  say "  t=$((i*15))s pipeline #${NUM:-?} status=${ST:-none}"
  case "$ST" in success|failure|error|killed|declined) break;; esac
  sleep 15
done
[ "$ST" = success ] && say "G2 pixorb CI green: PASS (#$NUM)" || halt "G2 CI status=${ST:-none}"

hr "X3 record + ledger"
mkdir -p "$CM"; SELF="$CM/20261127-REPAIR-33-pull-bool.sh"
if [ -f "$SELF" ] && cmp -s "$0" "$SELF"; then say "record present (no-op)"; else install -m 755 "$0" "$SELF"; say "written: codemod record"; fi
IDX="$CM/INDEX.md"
grep -qF "repair-33-pull-bool-v1:PASS" "$IDX" || printf '| %s | C | %s | GATE=PASS | %s |\n' "$(date +%F)" "repair-33-pull-bool-v1:PASS" "woodpecker 3.20 pull field is bool; never->false; hermetic CI now compiles and runs green" >> "$IDX"
git -C "$A" add codemod && { git -C "$A" diff --cached --quiet || git -C "$A" commit -q -m "docs(codemod): pull bool schema record (REPAIR-33)"; }
git -C "$A" push -q origin main 2>/dev/null || true
say "[RESULT] REPAIR-33 COMPLETE."
exit 0
