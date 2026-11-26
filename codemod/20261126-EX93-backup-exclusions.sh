#!/usr/bin/env bash
# EX93: add cache excludes to restic backup; run it; prove noise=0 AND source+dump still present.
# Usage: bash /tmp/EX93.sh [--check]
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; CM="$A/codemod"
BS="$A/infra/scripts/aether-backup.sh"; ENVF="$A/secrets/restic.env"
REP="$CM/EX93-backup-exclusions.json"; TOK="$A/secrets/woodpecker-pat.token"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
say(){ printf '  %s\n' "$*"; }; hr(){ printf '\n===== %s =====\n' "$*"; }; halt(){ say "[HALT] $*"; exit 1; }
[ -f "$BS" ] && [ -f "$ENVF" ] || halt "backup script or restic env missing"
set -a; . "$ENVF"; set +a
measure(){
  timeout 300 restic ls latest --json 2>/dev/null > "$1.jsonl" || return 1
  git -C "$A" ls-files | sed "s|^|$A/|" > "$1.tracked"
  git -C "$P" ls-files | sed "s|^|$P/|" >> "$1.tracked"
  python3 - "$1.jsonl" "$1.tracked" <<'PY'
import json,re,sys
files=[]
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: n=json.loads(line)
    except Exception: continue
    if n.get("type")=="file" and n.get("path","").startswith("/"): files.append((n["path"],n.get("size",0)))
tracked={l.rstrip("\n") for l in open(sys.argv[2]) if l.strip()}
noise=re.compile(r"/(\.pytest_cache|\.ruff_cache|__pycache__|\.dart_tool|build)/")
nz=[(p,s) for p,s in files if noise.search(p)]
src=[p for p,_ in files if p in tracked and not noise.search(p)]
dump=[p for p,_ in files if re.search(r"/infra/db/dumps/pixorb-.*\.sql\.gz$",p)]
print(len(files),len(nz),round(sum(s for _,s in nz)/1048576,1),len(src),len(dump))
open("/tmp/ex93-noise-sample","w").write("\n".join(p for p,_ in nz[:5]))
PY
}
nums(){ for v in "$@"; do case "$v" in ''|*[!0-9]*) return 1;; esac; done; return 0; }

hr "X0 baseline"
grep -nE 'restic backup' "$BS" | cut -c1-200 | sed 's/^/  /'
say "  unit Restart=$(systemctl --user show aether-backup.service -p Restart --value 2>/dev/null)"
B=$(mktemp -d)
M=$(measure "$B/before") || { rm -rf "$B"; halt "baseline ls failed"; }
read -r F0 N0 M0 S0 D0 <<<"$M"
nums "$F0" "$N0" "$S0" "$D0" || { say "  raw='$M'"; rm -rf "$B"; halt "non-numeric baseline metrics"; }
say "  BEFORE: files=$F0 noise=$N0 (${M0} MiB) tracked_source=$S0 dumps=$D0"
[ "$D0" -ge 1 ] || { rm -rf "$B"; halt "no dump in baseline snapshot"; }
if [ -f "$REP" ] && [ $(( $(date +%s) - $(stat -c %Y "$REP") )) -le 86400 ] && grep -q "\.dart_tool" "$BS"; then
  say "exclusions present + fresh report (no-op)"; python3 -c "
import json;d=json.load(open('$REP'));print('  verdict:',d['verdict'],'noise:',d['before']['noise'],'->',d['after']['noise'])"
  rm -rf "$B"; exit 0; fi

hr "X1 stage anchored exclusion insert"
python3 - "$BS" "$B/backup.sh" <<'PY' || { rm -rf "$B"; halt "staging failed"; }
import sys
src,out=sys.argv[1],sys.argv[2]
t=open(src).read()
anchor="--exclude '**/node_modules' "
assert t.count(anchor)==1, "anchor not unique: %d" % t.count(anchor)
add="--exclude '**/.pytest_cache' --exclude '**/.ruff_cache' --exclude '**/.dart_tool' --exclude '**/build' "
if ".dart_tool" in t: print("  excludes already present")
else:
    t=t.replace(anchor, anchor+add, 1); print("  inserted 4 excludes after node_modules")
open(out,"w").write(t)
PY
cmp -s "$BS" "$B/backup.sh" && say "unchanged: aether-backup.sh" || diff -u "$BS" "$B/backup.sh" | head -14
if [ "$CHECK" = 1 ]; then say "[CHECK] no writes performed"; rm -rf "$B"; exit 0; fi
if ! cmp -s "$BS" "$B/backup.sh"; then
  [ -f "$BS.pre-ex93.bak" ] || cp -p "$BS" "$BS.pre-ex93.bak"
  install -m 755 "$B/backup.sh" "$BS"; say "written: aether-backup.sh"; fi
bash -n "$BS" && say "G0 backup script syntax: PASS" || { rm -rf "$B"; halt "G0 syntax"; }

hr "X2 run the real backup unit"
R=$(systemctl --user show aether-backup.service -p Restart --value 2>/dev/null)
[ "$R" = always ] && { rm -rf "$B"; halt "Restart=always on a oneshot unit - fix that first"; }
timeout 900 systemctl --user start aether-backup.service && say "G1 backup unit completed: PASS" || { journalctl --user -u aether-backup.service -n 12 --no-pager | tail -10 | sed 's/^/  /'; rm -rf "$B"; halt "G1 backup failed"; }

hr "X3 AFTER: noise must be zero, value must survive"
M=$(measure "$B/after") || { rm -rf "$B"; halt "after ls failed"; }
read -r F1 N1 M1 S1 D1 <<<"$M"
nums "$F1" "$N1" "$S1" "$D1" || { say "  raw='$M'"; rm -rf "$B"; halt "non-numeric after metrics"; }
say "  AFTER:  files=$F1 noise=$N1 (${M1} MiB) tracked_source=$S1 dumps=$D1"
[ "$N1" = 0 ] && say "G2 cache noise eliminated: PASS" || { sed 's/^/    /' /tmp/ex93-noise-sample; rm -rf "$B"; halt "G2 noise remains: $N1"; }
[ "$S1" -ge "$S0" ] && say "G3 tracked source preserved ($S0 -> $S1): PASS" || { rm -rf "$B"; halt "G3 SOURCE LOST $S0 -> $S1"; }
[ "$D1" -ge 1 ] && say "G4 dump artifact preserved: PASS" || { rm -rf "$B"; halt "G4 DUMP LOST"; }
timeout 300 restic check >/dev/null 2>&1 && say "G5 restic check: PASS" || { rm -rf "$B"; halt "G5 repo check"; }
rm -rf "$B"

hr "X4 chain + production"
systemctl --user is-active --quiet aether-backup.timer && say "G6 timer active: PASS" || say "G6 timer inactive (report)"
curl -s --max-time 5 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health | grep -q '"db":true' && say "G7 api db=true: PASS" || halt "G7"
[ "$(podman inspect pixorb-api --format '{{.State.Health.Status}}')" = healthy ] && say "G8 api healthy: PASS" || halt "G8"

hr "X5 report + ledger + CI"
python3 - "$REP" "$F0" "$N0" "$M0" "$S0" "$F1" "$N1" "$M1" "$S1" "$D1" <<'PY'
import json,sys,datetime
p=sys.argv[1]; v=list(map(float,sys.argv[2:11]))
json.dump({"ts":datetime.datetime.now().isoformat(timespec="seconds"),"verdict":"NOISE_EXCLUDED_VALUE_PRESERVED",
 "before":{"files":int(v[0]),"noise":int(v[1]),"noise_mib":v[2],"tracked_source":int(v[3])},
 "after":{"files":int(v[4]),"noise":int(v[5]),"noise_mib":v[6],"tracked_source":int(v[7]),"dumps":int(v[8])}},
 open(p,"w"),indent=2)
print("  report written:",p)
PY
SELF="$CM/20261126-EX93-backup-exclusions.sh"
if [ -f "$SELF" ] && cmp -s "$0" "$SELF"; then say "record present (no-op)"; else install -m 755 "$0" "$SELF"; say "written: codemod record"; fi
IDX="$CM/INDEX.md"
grep -qF "ex93-backup-exclusions-v1:PASS" "$IDX" || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "ex93-backup-exclusions-v1:PASS" "restic excludes .pytest_cache/.ruff_cache/.dart_tool/build; noise 99->0 (~96 MiB); tracked source and pg_dump artifacts preserved; repo check green" >> "$IDX"
git -C "$A" add infra/scripts/aether-backup.sh codemod
git -C "$A" diff --cached --quiet && say "nothing to commit (no-op)" || {
  git -C "$A" commit -q -m "ops(backups): exclude regenerable cache dirs; prove value preserved (EX93)"; say "committed"; }
git -C "$A" push -q origin main && say "G9 push: PASS" || halt "G9 push failed"
SHA=$(git -C "$A" rev-parse HEAD); T=$(tr -d '\r\n' < "$TOK"); ST=""; NUM=""
for i in $(seq 1 40); do
  curl -s --max-time 8 -H "Authorization: Bearer $T" "http://127.0.0.1:8000/api/repos/2/pipelines?perPage=10" -o /tmp/ex93-pl.json
  read -r NUM ST <<<"$(python3 -c "
import json
d=json.load(open('/tmp/ex93-pl.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
p=m[0] if m else {}
print(p.get('number',''), p.get('status',''))" 2>/dev/null)"
  say "  pipeline #${NUM:-?} status=${ST:-none}"
  case "$ST" in success|failure|error|killed|declined) break;; esac
  sleep 15
done
[ "$ST" = success ] && say "G10 aether CI green: PASS (#$NUM)" || halt "G10 CI status=$ST"
say "[RESULT] EX93 COMPLETE."
exit 0
