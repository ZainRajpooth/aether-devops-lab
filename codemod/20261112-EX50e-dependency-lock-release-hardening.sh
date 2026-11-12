#!/usr/bin/env bash
# 20261112-EX50e — release Podman dependency lock, harden WP units, login, smoke.
set -uo pipefail
H="$HOME"; SEC="$H/DevOps/aether/secrets"; CD="$H/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
TOKEN="ex50e-dependency-lock-release-hardening-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-run}"; WP="http://127.0.0.1:8000"
SU="$H/.config/systemd/user/woodpecker-server.service"
AU="$H/.config/systemd/user/woodpecker-agent.service"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"

hr "X0 evidence: containers + dependency references"
podman ps -a --format '{{.ID}}  {{.Names}}  {{.Status}}' 2>/dev/null | sed 's/^/    /' || true
podman ps -a --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do
  [ -n "$c" ] || continue
  podman inspect "$c" --format '    {{.Name}} net={{.HostConfig.NetworkMode}} volfrom={{.HostConfig.VolumesFrom}} pid={{.HostConfig.PidMode}} ipc={{.HostConfig.IpcMode}}' 2>/dev/null || true
done | grep -E 'net=container:|volfrom=\[[^]]|pid=container:|ipc=container:' || say "    (no explicit namespace/volume references printed)"
grep -nE '^ExecStart' "$SU" "$AU" | sed 's/^/    /' || true
if [ "$MODE" = check ]; then
  say "plan: stop units -> guard protected -> podman rm -f --depend server/agent ->"
  say "      insert ExecStartPre orphan-guard (anchored, idempotent) -> start server -> agent -> login -> smoke"
  say "[RESULT] EX50e CHECK - nothing written."; exit 0
fi

hr "X1 stop crash-loop"
systemctl --user stop woodpecker-agent.service 2>/dev/null || true
systemctl --user stop woodpecker-server.service 2>/dev/null || true
systemctl --user reset-failed woodpecker-agent.service woodpecker-server.service 2>/dev/null || true
say "units stopped"

hr "X2 guard: dependents must not include protected services"
podman ps -a --format '{{.Names}}' > "$TMP/all.txt" 2>/dev/null || true
python3 - "$TMP/all.txt" > "$TMP/dep.txt" <<'PY'
import json,subprocess,sys
names=[l.strip() for l in open(sys.argv[1]) if l.strip()]
targets={}
for n in ("woodpecker-server","woodpecker-agent"):
    try:
        d=json.loads(subprocess.run(["podman","inspect",n],capture_output=True,text=True).stdout)[0]
        targets[d["Id"]]=n; targets[n]=n
    except Exception: pass
prot={"postgres","gitea","minio"}
deps=[]
for n in names:
    try:
        d=json.loads(subprocess.run(["podman","inspect",n],capture_output=True,text=True).stdout)[0]
    except Exception: continue
    hc=d.get("HostConfig",{}) or {}
    refs=[]
    for k in ("NetworkMode","PidMode","IpcMode","UTSMode"):
        v=str(hc.get(k) or "")
        if v.startswith("container:"): refs.append(v.split(":",1)[1])
    vf=hc.get("VolumesFrom") or []
    refs+= [str(x) for x in vf]
    for r in refs:
        if r in targets:
            deps.append(n); break
print("\n".join(sorted(set(deps))))
PY
say "dependents of server/agent: $(tr '\n' ' ' < "$TMP/dep.txt")"
if grep -xE 'postgres|gitea|minio' "$TMP/dep.txt" >/dev/null 2>&1; then
  halt "protected service is a dependent; manual review required"
fi

hr "X3 release lock (containers only; volumes preserved)"
podman rm -f -i --depend woodpecker-server 2>&1 | sed 's/^/    /' || true
podman rm -f -i --depend woodpecker-agent 2>&1 | sed 's/^/    /' || true
say "lock released"

hr "X4 harden units: ExecStartPre orphan-guard (idempotent, anchored)"
for pair in "$SU:woodpecker-server" "$AU:woodpecker-agent"; do
  f="${pair%%:*}"; n="${pair##*:}"
  [ -f "$f" ] || halt "missing unit: $f"
  if grep -qF "podman rm -f -i --depend $n" "$f"; then
    say "guard already present: $n"
  else
    cp -p "$f" "$f.pre-ex50e.$STAMP.bak"; chmod 600 "$f.pre-ex50e.$STAMP.bak"
    python3 - "$f" "$n" <<'PY'
import sys,os,tempfile
p,n=sys.argv[1],sys.argv[2]
lines=open(p,encoding="utf-8").readlines()
guard=f"ExecStartPre=/usr/bin/podman rm -f -i --depend {n}\n"
out=[];done=False
for l in lines:
    if not done and l.startswith("ExecStart="):
        out.append(guard); done=True
    out.append(l)
if not done: out.append(guard)
fd,t=tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd,"".join(out).encode()); os.fchmod(fd,0o644); os.close(fd); os.replace(t,p)
PY
    say "guard inserted: $n (backup .pre-ex50e.$STAMP.bak)"
  fi
done
systemctl --user daemon-reload

hr "X5 server readiness gate"
systemctl --user start woodpecker-server.service 2>/dev/null || true
ok=no; for i in $(seq 1 60); do
  st="$(podman inspect woodpecker-server --format '{{.State.Status}}' 2>/dev/null || echo missing)"
  c="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$WP/api/version" 2>/dev/null || echo 000)"
  [ "$st" = running ] && [ "$c" = 200 ] && { ok=yes; say "server running + api=200 (iter $i)"; break; }
  sleep 2
done
[ "$ok" = yes ] || { journalctl --user -u woodpecker-server.service -n 20 --no-pager | tail -15 | sed 's/^/    /'; ledger "FAIL" "server not ready after lock release"; halt "server not ready"; }

hr "X6 agent readiness gate"
systemctl --user start woodpecker-agent.service 2>/dev/null || true
ok=no; for i in $(seq 1 30); do [ "$(systemctl --user is-active woodpecker-agent.service 2>/dev/null | head -1)" = active ] && { ok=yes; break; }; sleep 2; done
[ "$ok" = yes ] || { journalctl --user -u woodpecker-agent.service -n 20 --no-pager | tail -15 | sed 's/^/    /'; halt "agent not active"; }
say "agent active"

hr "X7 single OAuth re-login (permanent bridge)"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' || halt "permanent bridge not listening"
sudo -v || halt "sudo needed"
sudo cp -p /etc/hosts "/etc/hosts.pre-ex50e.$STAMP.bak"
echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
say "OPEN http://127.0.0.1:8000 -> Login with Gitea -> user=$AUSER"
say "  password: cat $SEC/gitea-admin.pass  (Gitea password; NOT OS, NOT MinIO)"
printf '  Type DONE after login: ' > /dev/tty; IFS= read -r ACK < /dev/tty
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts cleaned"
curl -sS -H "Authorization: Bearer $PAT" "$WP/api/user/repos" | grep -q woodpecker-proof || halt "forge access not restored"
say "forge access verified"

hr "X8 pipeline smoke"
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

hr "X9 RESULT"
say "[RESULT] EX50e COMPLETE - lock released, units hardened, login verified, smoke green. LANE 1 CLOSED."
ledger "PASS" "EX50e: dependency lock released; ExecStartPre guards; server+agent active; pipeline #$N success"
exit 0
