#!/usr/bin/env bash
# EX91: prove the restic repository is restorable; bounded single-file restore + negative control.
# Usage: bash /tmp/EX91.sh [--check]
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
A="$HOME/DevOps/aether"; P="$HOME/DevOps/pixorb"; CM="$A/codemod"; TOK="$A/secrets/woodpecker-pat.token"
ENVF="$A/secrets/restic.env"; REP="$CM/EX91-restic-restore-drill.json"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
say(){ printf '  %s\n' "$*"; }; hr(){ printf '\n===== %s =====\n' "$*"; }; halt(){ say "[HALT] $*"; exit 1; }

hr "X0 discovery: how backups actually run"
systemctl --user cat aether-backup.service 2>/dev/null | grep -E '^(ExecStart|EnvironmentFile)' | cut -c1-220 | sed -E 's/(PASSWORD|PASS|TOKEN)=([^ ]+)/\1=***/g' | sed 's/^/  /'
[ -f "$ENVF" ] || halt "restic env missing: $ENVF"
say "  restic.env keys: $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$ENVF" | paste -sd, -)"
set -a; . "$ENVF"; set +a
REPO="${RESTIC_REPOSITORY:-}"; PF="${RESTIC_PASSWORD_FILE:-}"
say "  repository: ${REPO:-<unset>}"
say "  password file: ${PF:-<unset>}"
[ -n "$REPO" ] || halt "RESTIC_REPOSITORY unset"
if command -v restic >/dev/null 2>&1; then RUN="host"; say "  runner: host restic $(restic version 2>/dev/null | head -1)"
elif podman image exists docker.io/restic/restic:latest 2>/dev/null; then RUN="podman"; say "  runner: cached restic image"
else halt "no restic runner available (host binary or cached image)"; fi
r(){ if [ "$RUN" = host ]; then timeout "${T:-300}" restic "$@"; else
  timeout "${T:-300}" podman run --rm -v "$REPO":/repo -v "$PF":/pw:ro -v "${W:-/tmp}":/work \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/pw docker.io/restic/restic:latest "$@"; fi; }
if [ -f "$REP" ]; then AGE=$(( $(date +%s) - $(stat -c %Y "$REP") ))
  if [ "$AGE" -le 86400 ]; then say "drill report present (no-op, ${AGE}s old)"; python3 -c "
import json;d=json.load(open('$REP'));print('  verdict:',d['verdict'],'file:',d['file'],'sha_match:',d['sha_match'])"; exit 0; fi; fi

hr "X1 repository integrity + snapshot inventory"
T=300 r check >/tmp/ex91-check.log 2>&1 && say "G0 restic check: PASS" || { tail -6 /tmp/ex91-check.log | sed 's/^/  /'; halt "G0 repo check failed"; }
T=120 r snapshots --json > /tmp/ex91-snaps.json 2>/dev/null || halt "snapshots listing failed"
python3 -c "
import json;d=json.load(open('/tmp/ex91-snaps.json'))
print('  snapshots:',len(d))
s=d[-1];print('  latest:',s['short_id'],s['time'][:19],'paths:',','.join(s.get('paths',[])[:3]))"
[ "$(python3 -c "import json;print(len(json.load(open('/tmp/ex91-snaps.json'))))")" -ge 1 ] && say "G1 snapshot exists: PASS" || halt "G1 no snapshots"
if [ "$CHECK" = 1 ]; then say "[CHECK] no writes performed"; exit 0; fi

hr "X2 pick the smallest live-backed file (bounded restore)"
W=$(mktemp -d); mkdir -p "$W/target"
T=180 r ls latest --json 2>/dev/null | tail -n +2 > "$W/nodes.jsonl" || { rm -rf "$W"; halt "ls failed"; }
python3 - "$W/nodes.jsonl" "$W/pick" <<'PY' || { rm -rf "$W"; halt "no restorable candidate"; }
import json,sys,os
best=None
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: n=json.loads(line)
    except Exception: continue
    if n.get("type")!="file": continue
    p=n.get("path",""); sz=n.get("size",0)
    if not p.startswith("/") or sz<=0 or sz>262144: continue
    if not os.path.isfile(p): continue
    if "/.git/" in p or "/secrets/" in p or p.endswith((".pass",".token",".pem",".key")): continue
    if best is None or sz<best[1]: best=(p,sz)
assert best, "no candidate"
open(sys.argv[2],"w").write(best[0])
print("  picked:",best[0],best[1],"bytes")
PY
FILE=$(cat "$W/pick")

hr "X3 restore just that file"
T=300 r restore latest --target "$W/target" --include "$FILE" >/tmp/ex91-rest.log 2>&1
RC=$?
[ "$RC" = 0 ] && say "G2 restic restore exit 0: PASS" || { tail -8 /tmp/ex91-rest.log | sed 's/^/  /'; rm -rf "$W"; halt "G2 restore rc=$RC"; }
RES="$W/target$FILE"
[ -s "$RES" ] || { rm -rf "$W"; halt "restored file missing: $RES"; }
S1=$(sha256sum "$FILE" | cut -d' ' -f1); S2=$(sha256sum "$RES" | cut -d' ' -f1)
[ "$S1" = "$S2" ] && say "G3 restored SHA-256 == live source: PASS" || { say "  live=$S1 restored=$S2"; rm -rf "$W"; halt "G3 checksum mismatch"; }

hr "X4 NEGATIVE CONTROL: comparator must detect corruption"
printf 'x' >> "$RES"
S3=$(sha256sum "$RES" | cut -d' ' -f1)
[ "$S1" != "$S3" ] && say "G4 comparator detected injected corruption: PASS" || { rm -rf "$W"; halt "G4 comparator VACUOUS"; }
rm -rf "$W"; say "G5 scratch removed: PASS"

hr "X5 backup chain + production untouched"
systemctl --user is-active --quiet aether-backup.timer 2>/dev/null && say "G6 backup timer active: PASS" || say "G6 backup timer not active (report only)"
curl -s --max-time 5 -H 'Host: api.pixorb.localhost' http://127.0.0.1:8888/health | grep -q '"db":true' && say "G7 api db=true: PASS" || halt "G7"
[ "$(podman inspect pixorb-api --format '{{.State.Health.Status}}')" = healthy ] && say "G8 api healthy: PASS" || halt "G8"

hr "X6 report + ledger + CI"
python3 - "$REP" "$FILE" "$S1" <<'PY'
import json,sys,datetime
p,f,s=sys.argv[1:4]
json.dump({"ts":datetime.datetime.now().isoformat(timespec="seconds"),"verdict":"RESTORE_PROVEN",
 "file":f,"sha256":s,"sha_match":True,"corruption_detected":True},open(p,"w"),indent=2)
print("  report written:",p)
PY
SELF="$CM/20261126-EX91-restic-restore-drill.sh"
if [ -f "$SELF" ] && cmp -s "$0" "$SELF"; then say "record present (no-op)"; else install -m 755 "$0" "$SELF"; say "written: codemod record"; fi
IDX="$CM/INDEX.md"
grep -qF "ex91-restic-restore-drill-v1:PASS" "$IDX" || printf '| %s | B | %s | GATE=PASS | %s |\n' "$(date +%F)" "ex91-restic-restore-drill-v1:PASS" "restic check + bounded single-file restore; SHA-256 equals live source; injected corruption detected; repo and prod untouched" >> "$IDX"
git -C "$A" add codemod
git -C "$A" diff --cached --quiet && say "nothing to commit (no-op)" || {
  git -C "$A" commit -q -m "ops(data-safety): proven restic restore drill with corruption control (EX91)"; say "committed"; }
git -C "$A" push -q origin main && say "G9 push: PASS" || halt "G9 push failed"
SHA=$(git -C "$A" rev-parse HEAD); T2=$(tr -d '\r\n' < "$TOK"); ST=""; NUM=""
for i in $(seq 1 40); do
  curl -s --max-time 8 -H "Authorization: Bearer $T2" "http://127.0.0.1:8000/api/repos/2/pipelines?perPage=10" -o /tmp/ex91-pl.json
  read -r NUM ST <<<"$(python3 -c "
import json
d=json.load(open('/tmp/ex91-pl.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
p=m[0] if m else {}
print(p.get('number',''), p.get('status',''))" 2>/dev/null)"
  say "  pipeline #${NUM:-?} status=${ST:-none}"
  case "$ST" in success|failure|error|killed|declined) break;; esac
  sleep 15
done
[ "$ST" = success ] && say "G10 aether CI green: PASS (#$NUM)" || halt "G10 CI status=$ST"
say "[RESULT] EX91 COMPLETE."
exit 0
