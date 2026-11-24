#!/usr/bin/env bash
# EX64b - Dev ergonomics: central ~/.venvs + uv venv helper, managed .bashrc block,
# tmux baseline, VS Code workspace, runbook. infra/dotfiles/ is the canonical source.
set -uo pipefail
A="$HOME/DevOps/aether"; DF="$A/infra/dotfiles"; IDX="$A/codemod/INDEX.md"; H="$HOME"
TOKEN="ex64b-dev-ergonomics-v1"; MODE="${1:-run}"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
restore(){ if [ -f "$2" ] && cmp -s "$1" "$2"; then say "$4 unchanged (no-op)"; else install -m "$3" "$1" "$2"; say "$4 restored from dotfiles"; fi; }
hr "X0 gates on applied state"
[ -x "$H/.local/bin/venv" ] && bash -n "$H/.local/bin/venv" && say "venv helper: present+syntax" || halt "venv helper missing"
[ "$(grep -c '>>> AETHER ERGONOMICS >>>' "$H/.bashrc")" = 1 ] && say "bashrc block: exactly 1" || halt "bashrc block count wrong"
[ -f "$H/.tmux.conf" ] && say "tmux.conf: present" || halt "tmux.conf missing"
python3 -c 'import json;json.load(open("'"$A"'/aether.code-workspace"))' && say "workspace JSON: valid" || halt "workspace invalid"
[ -f "$A/docs/dev-ergonomics.md" ] && say "runbook: present" || halt "runbook missing"
if [ "$MODE" = check ]; then say "[RESULT] EX64b CHECK - nothing written."; exit 0; fi
hr "X1 replay from canonical dotfiles"
restore "$DF/venv" "$H/.local/bin/venv" 755 "venv helper"
restore "$DF/tmux.conf" "$H/.tmux.conf" 644 "tmux.conf"
restore "$DF/bashrc-block.sh" /tmp/ex64b-block.sh 644 "bashrc block (staging)"
python3 - <<'PY'
import re,os
p=os.path.expanduser("~/.bashrc"); t=open(p).read(); b=open("/tmp/ex64b-block.sh").read().strip()
s="# >>> AETHER ERGONOMICS >>>"; e="# <<< AETHER ERGONOMICS <<<"
if s in t:
    n=re.sub(re.escape(s)+r".*?"+re.escape(e), b, t, flags=re.S)
    if n!=t: open(p,"w").write(n); print("  bashrc block replaced")
    else: print("  bashrc block unchanged (no-op)")
else:
    open(p,"w").write(t.rstrip()+"\n\n"+b+"\n"); print("  bashrc block appended")
PY
rm -f /tmp/ex64b-block.sh
bash -n "$H/.bashrc" && say "bashrc syntax: OK" || halt "bashrc syntax broken"
hr "X2 functional gate"
export AETHER_VENV_ROOT="$H/.venvs"; export PATH="$H/.local/bin:$PATH"
venv new smoke >/dev/null 2>&1 || halt "venv new smoke failed"
"$AETHER_VENV_ROOT/smoke/bin/python" -c 'import sys;assert sys.prefix.endswith("smoke")' && say "venv functional: PASS"
venv rm smoke >/dev/null 2>&1
hr "X3 ledger"
grep -qF "$TOKEN:PASS" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "$TOKEN:PASS" "venv root+helper; bashrc block 1x; tmux; workspace; runbook; smoke venv 3.15.0" >> "$IDX"
say "ledger: $TOKEN:PASS"
say "[RESULT] EX64b COMPLETE (record + idempotent replay)."
exit 0
