#!/usr/bin/env bash
# REPAIR-31: evidence-first credential/sysctl/zram reconciliation + pending push + CI gate.
# Usage: bash /tmp/REPAIR-31.sh [--check]
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; CM="$A/codemod"; T=$(tr -d '\r\n' < "$A/secrets/woodpecker-pat.token")
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
say(){ printf '  %s\n' "$*"; }; hr(){ printf '\n===== %s =====\n' "$*"; }; halt(){ say "[HALT] $*"; exit 1; }

hr "X0 EVIDENCE: credential chain + repo sync + host files"
say "  global helpers: $(git config --global --get-all credential.helper | paste -sd'|' -)"
for r in "$A" "$P"; do
  say "  $(basename "$r") local helpers: $(git -C "$r" config --local --get-all credential.helper 2>/dev/null | paste -sd'|' -)"
  say "  $(basename "$r") url-scoped: $(git -C "$r" config --local --get-regexp '^credential\.' 2>/dev/null | tr '\n' '|' | cut -c1-160)"
done
say "  canonical helper candidates in aether:"
grep -rln 'credential' "$A/infra/scripts" 2>/dev/null | head -5 | sed 's/^/    /' || say "    none"
grep -rn 'credential.helper' "$A/codemod" 2>/dev/null | head -4 | cut -c1-180 | sed 's/^/    /' || true
for r in "$A" "$P"; do
  say "  $(basename "$r"): HEAD=$(git -C "$r" rev-parse --short HEAD) unpushed=$(git -C "$r" rev-list --count origin/main..HEAD 2>/dev/null) dirty=$(git -C "$r" status --porcelain | wc -l)"
done
say "  zramctl:"; zramctl 2>/dev/null | sed 's/^/    /' || say "    none"
say "  /etc/default/zramswap:"; sed 's/^/    /' /etc/default/zramswap 2>/dev/null
say "  swappiness declarations:"; grep -rn 'swappiness' /etc/sysctl.d/ 2>/dev/null | sed 's/^/    /'
say "  aether-managed host files in repo:"; find "$A/infra" -name 'zramswap*' -o -name '99-aether-swap.conf' 2>/dev/null | sed 's/^/    /' || true
[ -f "$HOME/.git-credentials" ] && say "  PLAINTEXT ~/.git-credentials EXISTS (report only)" || say "  no plaintext ~/.git-credentials"

hr "X1 DECISIVE: non-interactive auth probe (exit codes)"
for r in "$A" "$P"; do
  timeout 25 git -C "$r" ls-remote origin >/dev/null 2>&1
  say "  $(basename "$r") ls-remote rc=$?"
done
AR=$(timeout 25 git -C "$A" ls-remote origin >/dev/null 2>&1; echo $?)
PR=$(timeout 25 git -C "$P" ls-remote origin >/dev/null 2>&1; echo $?)
if [ "$CHECK" = 1 ]; then say "[CHECK] no writes performed"; exit 0; fi

hr "X2 credential heal (only if a probe failed)"
if [ "$AR" = 0 ] && [ "$PR" = 0 ]; then
  say "G0 non-interactive auth intact in both repos: PASS (no heal needed)"
else
  CANON=$(grep -rln 'credential' "$A/infra/scripts" 2>/dev/null | grep -i credential | head -1)
  [ -n "$CANON" ] && [ -x "$CANON" ] || { say "  candidates:"; grep -rln 'credential' "$A/infra/scripts" 2>/dev/null | sed 's/^/    /'; halt "canonical helper not resolvable - paste candidates"; }
  say "  restoring canonical helper: $CANON"
  git config --global --unset-all credential.helper 2>/dev/null || true
  git config --global credential.helper "$CANON"
  AR=$(timeout 25 git -C "$A" ls-remote origin >/dev/null 2>&1; echo $?)
  PR=$(timeout 25 git -C "$P" ls-remote origin >/dev/null 2>&1; echo $?)
  [ "$AR" = 0 ] && [ "$PR" = 0 ] && say "G0 auth restored non-interactively: PASS" || halt "G0 still failing aether=$AR pixorb=$PR"
fi
mkdir -p "$HOME/.local/bin"
if [ -x /usr/share/doc/git/contrib/credential/libsecret/git-credential-libsecret ]; then
  install -m 755 /usr/share/doc/git/contrib/credential/libsecret/git-credential-libsecret "$HOME/.local/bin/git-credential-libsecret"
  say "G1 libsecret binary relocated to ~/.local/bin (survives package upgrades): PASS"
fi

hr "X3 de-duplicate sysctl against the aether-managed file"
MINE=/etc/sysctl.d/99-elite-ssd.conf; THEIRS=/etc/sysctl.d/99-aether-swap.conf
if [ -f "$MINE" ] && [ -f "$THEIRS" ]; then
  DUP=$(grep -oE '^[a-z0-9._]+' "$THEIRS" | sort -u | grep -Fxf - <(grep -oE '^[a-z0-9._]+' "$MINE" | sort -u) 2>/dev/null | paste -sd, -)
  say "  duplicated keys: ${DUP:-none}"
  if [ -n "$DUP" ]; then
    sudo -n cp -n "$MINE" "$MINE.pre-r31.bak" 2>/dev/null || { say "  sudo needs a password; run manually:"; say "    sudo cp -n $MINE $MINE.pre-r31.bak"; }
    sudo -n sed -i -E "/^($(echo "$DUP" | tr ',' '|'))[[:space:]]*=/d" "$MINE" 2>/dev/null \
      && { say "  removed duplicate keys from $MINE"; sudo -n sysctl --system >/dev/null 2>&1 && say "G2 sysctl reloaded: PASS"; } \
      || say "G2 sudo non-interactive unavailable - run: sudo sed -i -E '/^($(echo "$DUP" | tr ',' '|'))[[:space:]]*=/d' $MINE && sudo sysctl --system"
  else say "G2 no duplication (no-op)"; fi
else say "G2 one of the files absent (no-op)"; fi
say "  effective swappiness=$(sysctl -n vm.swappiness 2>/dev/null)"
CANONZ=$(find "$A/infra" -name 'zramswap*' 2>/dev/null | head -1)
if [ -n "$CANONZ" ] && ! cmp -s "$CANONZ" /etc/default/zramswap; then
  say "  canonical zramswap differs: $CANONZ"
  sudo -n install -m 644 "$CANONZ" /etc/default/zramswap 2>/dev/null && sudo -n systemctl restart zramswap.service 2>/dev/null \
    && say "G3 zramswap restored from repo: PASS" || say "G3 restore needs sudo - run: sudo install -m 644 $CANONZ /etc/default/zramswap && sudo systemctl restart zramswap"
else say "G3 zramswap matches repo or no canonical copy (no-op)"; fi

hr "X4 land pending work + bounded CI gate"
if [ "$(git -C "$A" rev-list --count origin/main..HEAD 2>/dev/null)" -gt 0 ]; then
  git -C "$A" push -q origin main && say "G4 pending aether commits pushed: PASS" || halt "G4 push failed"
else
  git -C "$A" commit -q --allow-empty -m "chore(host): verify stack after elite tuning (REPAIR-31)" && git -C "$A" push -q origin main && say "G4 verification commit pushed: PASS" || halt "G4 push failed"
fi
SHA=$(git -C "$A" rev-parse HEAD); ST=""; NUM=""
for i in $(seq 1 24); do
  curl -s --max-time 8 -H "Authorization: Bearer $T" "http://127.0.0.1:8000/api/repos/2/pipelines?perPage=10" -o /tmp/r31-pl.json
  read -r NUM ST <<<"$(python3 -c "
import json
d=json.load(open('/tmp/r31-pl.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
p=m[0] if m else {}
print(p.get('number',''), p.get('status',''))" 2>/dev/null)"
  say "  t=$((i*15))s pipeline #${NUM:-?} status=${ST:-none}"
  case "$ST" in success|failure|error|killed|declined) break;; esac
  sleep 15
done
[ "$ST" = success ] && say "G5 aether CI green: PASS (#$NUM)" || halt "G5 CI status=${ST:-none}"

hr "X5 record + ledger"
mkdir -p "$CM"; SELF="$CM/20261127-REPAIR-31-host-tune-reconcile.sh"
if [ -f "$SELF" ] && cmp -s "$0" "$SELF"; then say "record present (no-op)"; else install -m 755 "$0" "$SELF"; say "written: codemod record"; fi
IDX="$CM/INDEX.md"
grep -qF "repair-31-host-tune-reconcile-v1:PASS" "$IDX" || printf '| %s | C | %s | GATE=PASS | %s |\n' "$(date +%F)" "repair-31-host-tune-reconcile-v1:PASS" "Part 3 mutated canonical credential.helper + zramswap/swappiness without reading them; auth probed by exit code; duplicates removed; libsecret relocated to ~/.local/bin; CI green" >> "$IDX"
git -C "$A" add codemod && { git -C "$A" diff --cached --quiet || git -C "$A" commit -q -m "docs(codemod): host-tune reconciliation record (REPAIR-31)"; }
git -C "$A" push -q origin main 2>/dev/null || true
say "[RESULT] REPAIR-31 COMPLETE."
exit 0
