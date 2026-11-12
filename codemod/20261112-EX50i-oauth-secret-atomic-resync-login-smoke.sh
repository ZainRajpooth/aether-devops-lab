#!/usr/bin/env bash
# 20261112-EX50i — atomic OAuth app recreate (confidential_client=true), secret resync, login, smoke.
set -uo pipefail
H="$HOME"; SEC="$H/DevOps/aether/secrets"; CD="$H/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex50i-oauth-secret-atomic-resync-login-smoke-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"; WP="http://127.0.0.1:8000"; GT="http://127.0.0.1:3001"
WE="$SEC/woodpecker.env"; MARK="$SEC/woodpecker-oauth.sync"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
gt(){ podman exec postgres psql -U devops -d gitea -tAc "$1" 2>/dev/null || true; }
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"
sha(){ python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$1"; }
envval(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]+=/,"");print;exit}' "$WE" 2>/dev/null || true; }
upsert(){ python3 - "$WE" "$@" <<'PY'
import os,sys,tempfile
p=sys.argv[1]; upd=dict(x.split("=",1) for x in sys.argv[2:] if "=" in x)
lines=open(p,encoding="utf-8",errors="replace").readlines() if os.path.exists(p) else []
out=[];seen=set()
for l in lines:
    s=l.strip()
    if s and not s.startswith("#") and "=" in s:
        k=s.split("=",1)[0].strip()
        if k in upd:
            if k not in seen: out.append(f"{k}={upd[k]}\n"); seen.add(k)
            continue
    out.append(l)
for k,v in upd.items():
    if k not in seen: out.append(f"{k}={v}\n")
fd,t=tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd,"".join(out).encode()); os.fchmod(fd,0o600); os.close(fd); os.replace(t,p)
PY
}
appinfo(){ curl -sS -m 10 -u "$AUSER:$APASS" "$GT/api/v1/user/applications/oauth2" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
a=[x for x in d if x.get("name")=="woodpecker"]
print((str(a[0]["id"])+" "+a[0]["client_id"]+" "+str(a[0].get("confidential_client")).lower()) if a else "")'; }

hr "X0 evidence + idempotence marker"
INFO="$(appinfo)"; say "app(id client_id confidential) = ${INFO:-<none>}"
AID="${INFO%% *}"; REST="${INFO#* }"; ACID="${REST%% *}"; AFLAG="${REST##* }"
ECID="$(envval WOODPECKER_GITEA_CLIENT)"; ESEC="$(envval WOODPECKER_GITEA_SECRET)"
say "env client_id match app: $([ "$ECID" = "$ACID" ] && echo yes || echo no)"
say "env secret sha: $(sha "$ESEC")"
MSYNC=""; [ -f "$MARK" ] && MSYNC="$(tr -d '\n\r' < "$MARK")"
CUR="$(sha "${ECID}:${ESEC}")"
NOOP=no
if [ -n "$MSYNC" ] && [ "$MSYNC" = "$CUR" ] && [ "$ECID" = "$ACID" ] && [ "$AFLAG" = true ]; then NOOP=yes; fi
say "sync marker match: $([ "$MSYNC" = "$CUR" ] && echo yes || echo no) ; would-be NO-OP: $NOOP"
if [ "$MODE" = check ]; then
  [ "$NOOP" = yes ] && say "plan: NO-OP (already synced)" || say "plan: DELETE app $AID -> CREATE confidential_client=true -> capture pair -> env sync -> restart server"
  say "then: hosts window -> login -> PAT gate -> smoke -> ledger"
  say "[RESULT] EX50i CHECK - nothing written."; exit 0
fi

hr "X1 atomic recreate + secret resync"
if [ "$NOOP" = yes ]; then
  say "already synced; no mutation (idempotent)"
else
  cp -p "$WE" "$WE.pre-ex50i.$STAMP.bak"; chmod 600 "$WE.pre-ex50i.$STAMP.bak"
  if [ -n "$AID" ]; then
    D="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X DELETE -u "$AUSER:$APASS" "$GT/api/v1/user/applications/oauth2/$AID" || echo 000)"
    say "delete old app $AID -> $D"
  fi
  C="$(curl -sS -m 20 -o "$TMP/create.json" -w '%{http_code}' -X POST -u "$AUSER:$APASS" -H 'Content-Type: application/json' \
    -d '{"name":"woodpecker","redirect_uris":["http://127.0.0.1:8000/authorize"],"confidential_client":true}' \
    "$GT/api/v1/user/applications/oauth2" || echo 000)"
  say "create app -> $C"
  [ "$C" = 200 ] || [ "$C" = 201 ] || halt "create failed"
  NCID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("client_id",""))' "$TMP/create.json")"
  NSEC="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("client_secret",""))' "$TMP/create.json")"
  NID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$TMP/create.json")"
  [ -n "$NCID" ] && [ -n "$NSEC" ] || halt "create response lacked client_id/secret"
  FLAGNOW="$(appinfo)"; say "post-create: ${FLAGNOW:-<none>}"
  if [ "${FLAGNOW##* }" != true ]; then
    say "create defaulted public -> DB flag flip (no secret churn)"
    gt "UPDATE oauth2_application SET confidential_client=true WHERE id=$NID;" >/dev/null
    FLAGNOW="$(appinfo)"; say "post-flip: ${FLAGNOW:-<none>}"
    [ "${FLAGNOW##* }" = true ] || halt "confidential_client not true"
  fi
  upsert "WOODPECKER_GITEA_CLIENT=$NCID" "WOODPECKER_GITEA_SECRET=$NSEC"
  printf '%s' "$(sha "${NCID}:${NSEC}")" > "$MARK"; chmod 600 "$MARK"
  say "env synced; secret sha now: $(sha "$NSEC")"
  systemctl --user restart woodpecker-server.service 2>/dev/null || true
  ok=no; for i in $(seq 1 45); do [ "$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)" = 200 ] && { ok=yes; break; }; sleep 2; done
  [ "$ok" = yes ] || halt "server not ready after resync"
  say "server api=200"
fi

hr "X2 login window (Woodpecker 8000, Gitea creds)"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' || halt "permanent bridge not listening"
sudo -v || halt "sudo needed"
sudo cp -p /etc/hosts "/etc/hosts.pre-ex50i.$STAMP.bak"
grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
say "hosts window OPEN"
say "Browser -> $WP -> 'Login with Gitea' -> user=$AUSER ; password: cat $SEC/gitea-admin.pass"
say "  consent -> must land on Woodpecker dashboard with NO error banner"
printf '  Type DONE after dashboard visible: ' > /dev/tty; IFS= read -r ACK < /dev/tty
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts window CLOSED"

hr "X3 forge gate"
R="$(curl -sS -m 10 -H "Authorization: Bearer $PAT" "$WP/api/user/repos" 2>/dev/null || true)"
printf '%s' "$R" | grep -q woodpecker-proof || { printf '%s\n' "$R" | head -c 300 | sed 's/^/    /'; halt "forge access not restored"; }
say "forge access verified"

hr "X4 smoke"
NUM="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT MAX(number) FROM pipelines WHERE repo_id=1" 2>/dev/null | tr -d ' \n')"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/1/pipelines/$NUM" || echo 000)"
say "restart pipeline #$NUM -> $CODE"
OK=no; ST=""
for i in $(seq 1 40); do
  R="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT number||' '||status FROM pipelines WHERE repo_id=1 ORDER BY id DESC LIMIT 1" 2>/dev/null || true)"
  if [ -n "$R" ]; then read -r N ST <<<"$R"; say "pipeline #$N status=$ST"
    [ "$ST" = success ] && { OK=yes; break; }
    case "$ST" in failure|error|killed) break;; esac
  fi
  sleep 3
done
[ "$OK" = yes ] || halt "smoke not success"

hr "X5 RESULT"
say "[RESULT] EX50i COMPLETE - OAuth secret resynced, login verified, smoke green. LANE 1 CLOSED."
ledger "PASS" "EX50i: atomic confidential app recreate + secret resync; login verified; pipeline #$N success; Lane 1 closed"
exit 0
