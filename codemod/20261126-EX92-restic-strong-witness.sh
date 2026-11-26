#!/usr/bin/env bash
# EX92: restore a real source artifact AND a pg_dump artifact from restic; prove both, plus noise audit.
# Usage: bash /tmp/EX92.sh [--check]
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; CM="$A/codemod"
ENVF="$A/secrets/restic.env"; REP="$CM/EX92-restic-strong-witness.json"; TOK="$A/secrets/woodpecker-pat.token"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
say(){ printf '  %s\n' "$*"; }; hr(){ printf '\n===== %s =====\n' "$*"; }; halt(){ say "[HALT] $*"; exit 1; }
[ -f "$ENVF" ] || halt "restic env missing"
set -a; . "$ENVF"; set +a
command -v restic >/dev/null 2>&1 || halt "host restic absent"

hr "X0 inventory + cache-noise audit (read-only)"
timeout 300 restic check >/dev/null 2>&1 && say "G0 restic check: PASS" || halt "G0 repo check failed"
W=$(mktemp -d); mkdir -p "$W/target"
timeout 300 restic ls latest --json 2>/dev/null > "$W/nodes.jsonl" || { rm -rf "$W"; halt "ls failed"; }
git -C "$A" ls-files | sed "s|^|$A/|" > "$W/tracked"
git -C "$P" ls-files | sed "s|^|$P/|" >> "$W/tracked"
python3 - "$W/nodes.jsonl" "$W/tracked" "$W" <<'PY' || { rm -rf "$W"; halt "picker failed"; }
import json,os,re,sys
nodes_f, tracked_f, out = sys.argv[1:4]
tracked = {l.rstrip("\n") for l in open(tracked_f) if l.strip()}
files=[]
for line in open(nodes_f):
    line=line.strip()
    if not line: continue
    try: n=json.loads(line)
    except Exception: continue
    if n.get("type")!="file": continue
    p=n.get("path",""); s=n.get("size",0)
    if p.startswith("/") and s>0: files.append((p,s))
noise=re.compile(r"/(\.pytest_cache|\.ruff_cache|__pycache__|\.dart_tool|build)/")
nz=[(p,s) for p,s in files if noise.search(p)]
print("  snapshot files: %d | cache-noise files: %d (%.1f MiB)" % (len(files),len(nz),sum(s for _,s in nz)/1048576))
cand=[(p,s) for p,s in files if p in tracked and s<=2*1048576 and os.path.isfile(p) and not noise.search(p)]
cand.sort(key=lambda x:(-x[1],x[0]))
w1=cand[0][0] if cand else ""
dumps=[(p,s) for p,s in files if re.search(r"/infra/db/dumps/pixorb-.*\.sql\.gz$",p) and s<=8*1048576]
dumps.sort(key=lambda x:x[0])
w2=dumps[-1][0] if dumps else ""
open(os.path.join(out,"w1"),"w").write(w1)
open(os.path.join(out,"w2"),"w").write(w2)
print("  W1 source witness: %s (%d bytes)" % (w1 or "<none>", cand[0][1] if cand else 0))
print("  W2 dump witness:   %s (%d bytes)" % (w2 or "<none>", dumps[-1][1] if dumps else 0))
PY
W1=$(cat "$W/w1"); W2=$(cat "$W/w2")
say "--- backup invocation (read-only, for the exclusion brick) ---"
grep -nE 'restic .*backup|--exclude' "$A/infra/scripts/aether-backup.sh" 2>/dev/null | head -6 | sed 's/^/  /' || say "  not found"
[ -n "$W1" ] || { rm -rf "$W"; halt "no tracked source witness in snapshot"; }
[ -n "$W2" ] || { rm -rf "$W"; halt "NO pg_dump ARTIFACT IN LATEST SNAPSHOT - data-safety gap"; }
if [ -f "$REP" ]; then AGE=$(( $(date +%s) - $(stat -c %Y "$REP") ))
  if [ "$AGE" -le 86400 ]; then say "strong-witness report present (no-op, ${AGE}s old)"; python3 -c "
import json;d=json.load(open('$REP'));print('  verdict:',d['verdict']);print('  W1:',d['w1']['path']);print('  W2:',d['w2']['path'])"; rm -rf "$W"; exit 0; fi; fi
if [ "$CHECK" = 1 ]; then say "[CHECK] no writes performed"; rm -rf "$W"; exit 0; fi

hr "X1 restore both witnesses"
timeout 600 restic restore latest --target "$W/target" --include "$W1" --include "$W2" >"$W/rest.log" 2>&1
RC=$?
[ "$RC" = 0 ] && say "G1 restic restore exit 0: PASS" || { tail -8 "$W/rest.log" | sed 's/^/  /'; rm -rf "$W"; halt "G1 restore rc=$RC"; }
R1="$W/target$W1"; R2="$W/target$W2"
[ -s "$R1" ] && [ -s "$R2" ] && say "G2 both witnesses materialised: PASS" || { rm -rf "$W"; halt "G2 missing restored file"; }

hr "X2 integrity: source SHA + dump gzip/trailer"
S1=$(sha256sum "$W1" | cut -d' ' -f1); T1=$(sha256sum "$R1" | cut -d' ' -f1)
[ "$S1" = "$T1" ] && say "G3 source SHA-256 == live: PASS" || { rm -rf "$W"; halt "G3 source checksum mismatch"; }
gzip -t "$R2" && say "G4 dump gzip integrity: PASS" || { rm -rf "$W"; halt "G4 dump corrupt"; }
gunzip -c "$R2" | tail -5 | grep -q 'PostgreSQL database dump complete' && say "G5 dump trailer present: PASS" || { rm -rf "$W"; halt "G5 dump truncated"; }

hr "X3 NEGATIVE CONTROLS (both must be detected)"
printf 'x' >> "$R1"
[ "$S1" != "$(sha256sum "$R1" | cut -d' ' -f1)" ] && say "G6 source corruption detected: PASS" || { rm -rf "$W"; halt "G6 source comparator VACUOUS"; }
truncate -s -1 "$R2"
gzip -t "$R2" 2>/dev/null && { rm -rf "$W"; halt "G7 gzip comparator VACUOUS"; } || say "G7 dump truncation detected: PASS"
rm -rf "$W"; say "G8 scratch removed: PASS"

hr "X4 chain + production untouched"
systemctl --user is-active --quiet aether-backup.timer && say "G9 backup timer active: PASS" || say "G9 backup timer inactive (report)"
curl -s --max-time 5 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health | grep -q '"db":true' && say "G10 api db=true: PASS" || halt "G10"
[ "$(podman inspect pixorb-api --format '{{.State.Health.Status}}')" = healthy ] && say "G11 api healthy: PASS" || halt "G11"

hr "X5 report + ledger + CI"
python3 - "$REP" "$W1" "$S1" "$W2" <<'PY'
import json,sys,datetime
p,w1,s1,w2=sys.argv[1:5]
json.dump({"ts":datetime.datetime.now().isoformat(timespec="seconds"),"verdict":"STRONG_RESTORE_PROVEN",
 "w1":{"path":w1,"sha256":s1,"sha_match":True,"corruption_detected":True},
 "w2":{"path":w2,"gzip_ok":True,"trailer_ok":True,"truncation_detected":True}},open(p,"w"),indent=2)
print("  report written:",p)
PY
SELF="$CM/20261126-EX92-restic-strong-witness.sh"
if [ -f "$SELF" ] && cmp -s "$0" "$SELF"; then say "record present (no-op)"; else install -m 755 "$0" "$SELF"; say "written: codemod record"; fi
IDX="$CM/INDEX.md"
grep -qF "ex92-restic-strong-witness-v1:PASS" "$IDX" || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "ex92-restic-strong-witness-v1:PASS" "restic restored a tracked source artifact (SHA match) AND a pg_dump artifact (gzip+trailer); both negative controls fired; cache-noise quantified for exclusion brick" >> "$IDX"
git -C "$A" add codemod
git -C "$A" diff --cached --quiet && say "nothing to commit (no-op)" || {
  git -C "$A" commit -q -m "ops(data-safety): strong restic restore witnesses - source + dump (EX92)"; say "committed"; }
git -C "$A" push -q origin main && say "G12 push: PASS" || halt "G12 push failed"
SHA=$(git -C "$A" rev-parse HEAD); T=$(tr -d '\r\n' < "$TOK"); ST=""; NUM=""
for i in $(seq 1 40); do
  curl -s --max-time 8 -H "Authorization: Bearer $T" "http://127.0.0.1:8000/api/repos/2/pipelines?perPage=10" -o /tmp/ex92-pl.json
  read -r NUM ST <<<"$(python3 -c "
import json
d=json.load(open('/tmp/ex92-pl.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
p=m[0] if m else {}
print(p.get('number',''), p.get('status',''))" 2>/dev/null)"
  say "  pipeline #${NUM:-?} status=${ST:-none}"
  case "$ST" in success|failure|error|killed|declined) break;; esac
  sleep 15
done
[ "$ST" = success ] && say "G13 aether CI green: PASS (#$NUM)" || halt "G13 CI status=$ST"
say "NEXT: exclusion brick anchors on the printed 'restic backup' line to drop cache noise."
say "[RESULT] EX92 COMPLETE."
exit 0
