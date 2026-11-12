#!/usr/bin/env bash
# 20261112-EX50b — Lane 1 closeout (fixed heredoc): prune, rotate, re-adopt MinIO, collaborator, docs.
set -uo pipefail
umask 077
H="$HOME"; SEC="$H/DevOps/aether/secrets"; CD="$H/DevOps/aether/codemod"
DOCS="$H/DevOps/aether/docs"; IDX="$CD/INDEX.md"
TOKEN="ex50b-lane1-closeout-rotate-document-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
WP="http://127.0.0.1:8000"; GT="http://127.0.0.1:3001"
WE="$SEC/woodpecker.env"; AE="$SEC/aether.env"
TMP="$(mktemp -d)"; chmod 700 "$TMP"
cleanup(){ rm -rf "$TMP"; if [ -n "${FWD_PID:-}" ]; then kill "$FWD_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD" "$DOCS"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
gen(){ python3 -c 'import secrets;print(secrets.token_hex(24))'; }
upsert(){ python3 - "$@" <<'PY'
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
fd,t=tempfile.mkstemp(dir=os.path.dirname(p) or "."); os.write(fd,"".join(out).encode()); os.fchmod(fd,0o600); os.close(fd); os.replace(t,p)
PY
}
bak(){ cp -p "$1" "$1.pre-ex50b.$STAMP.bak"; chmod 600 "$1.pre-ex50b.$STAMP.bak"; }
http(){ curl -sS -m "${2:-8}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000; }

BOT="$(tr -d '\n\r' < "$SEC/gitea-wp-bot.user")"
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"; APASS="$(tr -d '\n\r' < "$SEC/gitea-admin.pass")"
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"

hr "X1 prune unused Woodpecker secrets"
for s in GITEA_BOT_PASS GITEA_BOT_PASS_ENC; do
  c="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $PAT" "$WP/api/repos/1/secrets/$s" || echo 000)"
  say "delete $s -> $c"
done
curl -sS -H "Authorization: Bearer $PAT" "$WP/api/repos/1/secrets" | python3 -c 'import json,sys;print("  remaining:",[s["name"] for s in json.load(sys.stdin)])'

hr "X2 MinIO: rotate root+devX+conX, re-adopt systemd"
bak "$AE"; for f in minio-root.pass minio-users/minio-normal.pass minio-users/minio-console-admin.pass; do bak "$SEC/$f"; done
R_PASS="$(gen)"; D_PASS="$(gen)"; C_PASS="$(gen)"
upsert "$AE" "MINIO_ROOT_PASSWORD=$R_PASS"
if ! systemctl --user is-active --quiet minio.service; then
  say "minio not under systemd -> re-adopting"
  podman stop minio >/dev/null 2>&1 || true; podman rm -f minio >/dev/null 2>&1 || true
  systemctl --user daemon-reload; systemctl --user start minio.service
fi
systemctl --user restart minio.service
ok=no; for i in $(seq 1 45); do [ "$(http http://127.0.0.1:9010/minio/health/live 3)" = 200 ] && { ok=yes; break; }; sleep 2; done
[ "$ok" = yes ] || halt "minio api not healthy after rotation"
podman exec -i minio sh -c '
  set -eu; IFS= read -r rp; IFS= read -r dp; IFS= read -r cp
  mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$rp" >/dev/null
  for u in devX conX; do mc admin user rm local "$u" >/dev/null 2>&1 || true; done
  mc admin user add local devX "$dp" >/dev/null; mc admin policy attach local readwrite --user devX >/dev/null
  mc admin user add local conX "$cp" >/dev/null; mc admin policy attach local consoleAdmin --user conX >/dev/null
  mc admin user ls local
' < <(printf '%s\n%s\n%s\n' "$R_PASS" "$D_PASS" "$C_PASS") | sed 's/^/    /'
printf '%s' "$R_PASS" > "$SEC/minio-root.pass"
printf '%s' "$D_PASS" > "$SEC/minio-users/minio-normal.pass"
printf '%s' "$C_PASS" > "$SEC/minio-users/minio-console-admin.pass"
chmod 600 "$SEC/minio-root.pass" "$SEC/minio-users/minio-normal.pass" "$SEC/minio-users/minio-console-admin.pass"
say "rotated+saved; console=$(http http://127.0.0.1:9011/browser) api=$(http http://127.0.0.1:9010/minio/health/live)"
say "UPDATE KeePassXC entries for adminX/devX/conX from the .pass files"

hr "X3 collaborator fix (adminX sees repo in /repos)"
c="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -u "$AUSER:$APASS" -H 'Content-Type: application/json' \
  -d '{"permission":"admin"}' "$GT/api/v1/repos/$BOT/woodpecker-proof/collaborators/$AUSER" || echo 000)"
say "add collaborator $AUSER -> $c"

hr "X4 rotate WP gRPC/agent secret + Gitea OAuth client"
bak "$WE"
GS="$(gen)"
APPS="$(curl -sS -u "$AUSER:$APASS" "$GT/api/v1/user/applications/oauth2")"
OID="$(printf '%s' "$APPS" | python3 -c 'import json,sys;print(next((a["id"] for a in json.load(sys.stdin) if a["name"]=="woodpecker"),""))')"
if [ -n "$OID" ]; then curl -sS -o /dev/null -X DELETE -u "$AUSER:$APASS" "$GT/api/v1/user/applications/oauth2/$OID"; fi
NEW="$(curl -sS -u "$AUSER:$APASS" -H 'Content-Type: application/json' \
  -d '{"name":"woodpecker","redirect_uris":["http://127.0.0.1:8000/authorize"]}' \
  "$GT/api/v1/user/applications/oauth2")"
CID="$(printf '%s' "$NEW" | python3 -c 'import json,sys;print(json.load(sys.stdin)["client_id"])')"
CSEC="$(printf '%s' "$NEW" | python3 -c 'import json,sys;print(json.load(sys.stdin)["client_secret"])')"
[ -n "$CID" ] && [ -n "$CSEC" ] || halt "oauth app create failed"
upsert "$WE" "WOODPECKER_GRPC_SECRET=$GS" "WOODPECKER_AGENT_SECRET=$GS" "WOODPECKER_GITEA_CLIENT=$CID" "WOODPECKER_GITEA_SECRET=$CSEC"
say "new oauth client + grpc secret written to woodpecker.env"
systemctl --user restart woodpecker-server.service; sleep 6
systemctl --user restart woodpecker-agent.service; sleep 4

hr "X5 temporary login bridge + browser re-login"
sudo -v || halt "sudo needed for temporary /etc/hosts entry"
sudo cp -p /etc/hosts "/etc/hosts.pre-ex50b.$STAMP.bak"
grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
python3 - >"$TMP/fwd.log" 2>&1 <<'PY' &
import socket,threading
def pipe(a,b):
    try:
        while True:
            d=a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    finally:
        for s in (a,b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
srv.bind(("127.0.0.2",3000)); srv.listen(16)
while True:
    c,_=srv.accept()
    u=socket.socket(); u.connect(("127.0.0.1",3001))
    threading.Thread(target=pipe,args=(c,u),daemon=True).start()
    threading.Thread(target=pipe,args=(u,c),daemon=True).start()
PY
FWD_PID=$!
sleep 1
kill -0 "$FWD_PID" 2>/dev/null || { cat "$TMP/fwd.log" | sed 's/^/    /'; halt "login bridge failed (port 3000 busy?)"; }
say "bridge up (127.0.0.2:3000 -> 127.0.0.1:3001); hosts entry added"
say "NOW: open http://127.0.0.1:8000 -> sign out -> log in via Gitea (adminX)."
printf '  Type DONE after login completes: ' > /dev/tty; IFS= read -r ACK < /dev/tty
kill "$FWD_PID" 2>/dev/null || true; FWD_PID=""
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "bridge removed; hosts entry removed"
R="$(curl -sS -H "Authorization: Bearer $PAT" "$WP/api/user/repos" || true)"
printf '%s' "$R" | grep -q woodpecker-proof || halt "forge access not restored after re-login"
say "forge access verified via PAT (repo list contains woodpecker-proof)"

hr "X6 documentation"
cat > "$DOCS/brick12-runbook.md" <<'MD'
# Brick 12 Runbook — Gitea -> Woodpecker steel thread
## Topology
- Gitea host UI: http://127.0.0.1:3001 (internal gitea:3000 on net `aether`)
- Woodpecker UI/API: http://127.0.0.1:8000 ; gRPC woodpecker-server:9000
- Repo hook (repo-scoped, NOT user-scoped): Gitea repo settings -> Webhooks
  url http://woodpecker-server:8000/api/hook?access_token=<JWT>
## Clone pattern (split-horizon DNS workaround)
Gitea ROOT_URL=127.0.0.1:3001 pollutes webhook clone_url; step containers cannot use it.
Pipeline overrides remote via secret (no interpolation):
    clone:
      - name: git
        image: woodpeckerci/plugin-git
        environment:
          PLUGIN_REMOTE: { from_secret: GITEA_CLONE_URL }
Secret GITEA_CLONE_URL = http://<bot>:<urlencoded-pass>@gitea:3000/<owner>/<repo>.git
## Re-login procedure (OAuth rotation / fresh session)
1. sudo sh -c 'echo "127.0.0.2 gitea" >> /etc/hosts'
2. start TCP bridge 127.0.0.2:3000 -> 127.0.0.1:3001 (python socket proxy)
3. browser login at http://127.0.0.1:8000
4. remove hosts line + bridge (EX50b X5 automates)
## Failure signatures
- "network not found: host" -> WOODPECKER_BACKEND_DOCKER_NETWORK must be a real podman network (aether)
- clone 127.0.0.1:3001 refused -> clone_url pollution; use PLUGIN_REMOTE pattern
- "netrc not injected" -> clone image not in allow list; use woodpeckerci/plugin-git
- empty password in remote -> ${SECRET} interpolation requires declared secrets; prefer from_secret
MD
cat > "$DOCS/adr-0007-ci-clone-override.md" <<'MD'
# ADR-0007: Pipeline-level clone override instead of forge ROOT_URL change
Status: accepted (2026-11-12)
Context: Gitea ROOT_URL must stay browser-facing (127.0.0.1:3001); webhook clone_url
therefore unreachable from step containers; host /etc/hosts entries leak into all
Podman containers and break name resolution.
Decision: keep forge config untouched; override clone remote per-pipeline via
PLUGIN_REMOTE + from_secret(GITEA_CLONE_URL). Remove host hosts-entry pollution.
Consequences: each CI repo needs the secret+clone block (template in runbook);
interactive OAuth login needs temporary bridge (runbook); no global DNS hacks.
MD
cat > "$DOCS/debt-register.md" <<'MD'
# Debt register (2026-11-12)
| # | Item | Risk | Plan |
|---|---|---|---|
| 1 | postgres passwords exposed in env dump (loopback-only) | low | rotate in Lane 2 backup window |
| 2 | agent.conf persist errors (read-only /etc/woodpecker) | cosmetic | add writable volume |
| 3 | bad_habit linter warnings | future v4 | when: event filters in template |
| 4 | WP services are plain systemd units, MinIO quadlet | consistency | standardize later |
| 5 | step containers share aether net (no per-step isolation) | medium | evaluate rootless net per pipeline |
MD
say "wrote brick12-runbook.md, adr-0007-ci-clone-override.md, debt-register.md"

hr "X7 RESULT"
say "[RESULT] EX50b COMPLETE - LANE 1 CLOSED."
say "  rotated: MinIO root/devX/conX, WP gRPC/agent, Gitea OAuth client"
say "  pruned: GITEA_BOT_PASS, GITEA_BOT_PASS_ENC"
say "  minio under systemd; adminX collaborator; docs written"
ledger "PASS" "EX50b: lane1 closeout complete; rotations+prune+collaborator+docs; forge access verified"
exit 0
