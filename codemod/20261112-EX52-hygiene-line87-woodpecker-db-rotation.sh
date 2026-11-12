#!/usr/bin/env bash
# 20261112-EX52 — hygiene: remove stray EX51 line-87 token; rotate exposed woodpecker DB password; new restore point.
set -uo pipefail
H="$HOME"; A="$H/DevOps/aether"; SEC="$A/secrets"; CD="$A/codemod"; IDX="$CD/INDEX.md"; DOCS="$A/docs"
TOKEN="ex52-hygiene-line87-woodpecker-db-rotation-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"
EX51="$CD/20261112-EX51-lane2-restic-minio-backup-restore-timer.sh"
WE="$SEC/woodpecker.env"; MARK="$SEC/pg-rotation.sync"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
sha(){ python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$1"; }
envval(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]+=/,"");print;exit}' "$WE" 2>/dev/null || true; }
psql_su(){ podman exec postgres psql -U devops -d postgres -tAc "$1" 2>/dev/null || true; }

hr "X0 probe"
[ -f "$EX51" ] || halt "canonical EX51 codemod missing: $EX51"
STRAY="$(grep -c '^R CAN_PATH=' "$EX51" || true)"; say "stray line-87 tokens present: $STRAY"
say "roles: $(psql_su "SELECT string_agg(rolname,',') FROM pg_roles WHERE rolname IN ('devops','woodpecker','gitea');")"
EP="$(envval WOODPECKER_DATABASE_PASSWORD)"; say "env db pass sha: $(sha "$EP")"
MS=""; [ -f "$MARK" ] && MS="$(tr -d '\n\r' < "$MARK")"
NOOP=no; [ -n "$MS" ] && [ "$MS" = "$(sha "$EP")" ] && [ "$STRAY" = 0 ] && NOOP=yes
say "rotation marker match: $([ "$MS" = "$(sha "$EP")" ] && echo yes || echo no) ; would-be NO-OP: $NOOP"
set -a; . "$SEC/restic.env"; set +a
SN="$(restic snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
say "restore point snapshots: $SN"
[ "$SN" -ge 1 ] || halt "no restore point; run EX51 first"
if [ "$MODE" = check ]; then
  say "plan: remove stray line (anchored) -> ALTER ROLE woodpecker -> env password+datasource sync ->"
  say "      restart server -> TCP auth gate -> scheduled backup (new restore point) -> docs+ledger"
  say "[RESULT] EX52 CHECK - nothing written."; exit 0
fi

hr "X1 remove stray EX51 token (anchored, idempotent)"
if [ "$STRAY" != 0 ]; then
  cp -p "$EX51" "$EX51.pre-ex52.$STAMP.bak"; chmod 600 "$EX51.pre-ex52.$STAMP.bak"
  python3 - "$EX51" <<'PY'
import sys,os,tempfile
p=sys.argv[1]; lines=open(p,encoding="utf-8").readlines()
out=[l for l in lines if not l.startswith('R CAN_PATH=')]
fd,t=tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd,"".join(out).encode()); os.fchmod(fd,0o700); os.close(fd); os.replace(t,p)
PY
  say "stray line removed (backup .pre-ex52.$STAMP.bak)"
else
  say "already clean (no-op)"
fi
bash -n "$EX51" || halt "EX51 syntax broken after fix"
say "EX51 bash -n: OK"

hr "X2 rotate woodpecker DB password"
if [ "$NOOP" = yes ]; then
  say "marker matches current env password; rotation skipped (idempotent)"
else
  cp -p "$WE" "$WE.pre-ex52.$STAMP.bak"; chmod 600 "$WE.pre-ex52.$STAMP.bak"
  NP="$(python3 -c 'import secrets;print(secrets.token_hex(24))')"
  psql_su "ALTER ROLE woodpecker PASSWORD '$NP';" >/dev/null || halt "ALTER ROLE failed"
  python3 - "$WE" "$NP" <<'PY'
import sys,os,tempfile,urllib.parse
p,np_=sys.argv[1],sys.argv[2]
lines=open(p,encoding="utf-8",errors="replace").readlines()
out=[];seen=set()
for l in lines:
    s=l.strip()
    if s and not s.startswith("#") and "=" in s:
        k,v=s.split("=",1)
        if k=="WOODPECKER_DATABASE_PASSWORD":
            if k not in seen: out.append(f"{k}={np_}\n"); seen.add(k)
            continue
        if k=="WOODPECKER_DATABASE_DATASOURCE":
            u=urllib.parse.urlsplit(v)
            host=u.hostname; port=u.port or 5432
            net=f"{urllib.parse.quote(u.username or 'woodpecker',safe='')}:{urllib.parse.quote(np_,safe='')}@{host}:{port}"
            nv=urllib.parse.urlunsplit((u.scheme,net,u.path,u.query,u.fragment))
            if k not in seen: out.append(f"{k}={nv}\n"); seen.add(k)
            continue
    out.append(l)
for k,val in (("WOODPECKER_DATABASE_PASSWORD",np_),):
    if k not in seen: out.append(f"{k}={val}\n")
fd,t=tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd,"".join(out).encode()); os.fchmod(fd,0o600); os.close(fd); os.replace(t,p)
PY
  printf '%s' "$(sha "$NP")" > "$MARK"; chmod 600 "$MARK"
  say "rotated; env password sha now: $(sha "$NP")"
  A="$(podman exec -e PGPASSWORD="$NP" postgres psql -h 127.0.0.1 -U woodpecker -d woodpecker -tAc 'SELECT 1' 2>/dev/null || true)"
  [ "$A" = 1 ] || halt "TCP auth with new password failed"
  say "TCP auth gate: SELECT 1 = 1"
  systemctl --user restart woodpecker-server.service 2>/dev/null || true
  ok=no; for i in $(seq 1 45); do [ "$(curl -sS -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/api/version 2>/dev/null || echo 000)" = 200 ] && { ok=yes; break; }; sleep 2; done
  [ "$ok" = yes ] || halt "woodpecker not ready after rotation"
  say "server api=200 with rotated DB creds"
fi

hr "X3 new restore point (scheduled path)"
systemctl --user start aether-backup.service || halt "backup service failed"
sleep 2
L="$(ls -1t "$A/backups/logs"/backup-*.log 2>/dev/null | head -1)"
grep -q "\[backup\] OK" "$L" || halt "backup did not report OK"
tail -1 "$L" | sed 's/^/    /'
set -a; . "$SEC/restic.env"; set +a
SN2="$(restic snapshots --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
say "snapshots now: $SN2"

hr "X4 docs + debt + ledger"
python3 - "$DOCS/debt-register.md" <<'PY'
import sys,os
p=sys.argv[1]; add="| 8 | woodpecker DB password (exposed in env dump) | closed | rotated EX52; marker secrets/pg-rotation.sync |\n| 9 | gitea/devops DB passwords loopback-only, not in exposed dump | accepted | rotate in future maintenance window |\n"
t=open(p).read() if os.path.exists(p) else "# Debt register\n"
if "| 8 |" not in t: open(p,"w").write(t+add)
PY
cat >> "$DOCS/backup-runbook.md" <<'MD'

## Credential rotation (EX52)
- woodpecker DB role rotated; env WOODPECKER_DATABASE_PASSWORD + DATASOURCE synced; marker secrets/pg-rotation.sync
- Rollback: restore woodpecker.env.pre-ex52.<stamp>.bak, restart server, ALTER ROLE woodpecker PASSWORD '<old value from bak>'
- gitea/devops DB passwords: accepted loopback-only risk (not in exposed dump)
MD
say "debt register + runbook updated"
hr "X5 RESULT"
say "[RESULT] EX52 COMPLETE - stray token removed, woodpecker DB rotated, new restore point saved."
ledger "PASS" "EX52: line-87 cleanup + woodpecker DB rotation + TCP auth gate + backup snapshots=$SN2"
exit 0
