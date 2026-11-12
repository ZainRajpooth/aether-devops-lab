#!/usr/bin/env bash
set -uo pipefail
H="$HOME"; SEC="$H/DevOps/aether/secrets"; CD="$H/DevOps/aether/codemod"; IDX="$CD/INDEX.md"
DOCS="$H/DevOps/aether/docs"; TOKEN="ex50c-heal-agent-login-smoke-v1"; STAMP="$(date +%Y%m%d-%H%M%S)"
WP="http://127.0.0.1:8000"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }
mkdir -p "$CD"; touch "$IDX"
ledger(){ local g="$1" d="$2" t="${TOKEN}:$1"
  grep -qF "$t" "$IDX" 2>/dev/null || printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$t" "$g" "$d" >> "$IDX"; say "ledger: $t"; }
PAT="$(tr -d '\n\r' < "$SEC/woodpecker-pat.token")"
AUSER="$(tr -d '\n\r' < "$SEC/gitea-admin.user")"

hr "X0 state snapshot"
for u in minio woodpecker-server woodpecker-agent; do
  say "$u: $(systemctl --user is-active "$u.service" 2>/dev/null || echo unknown)"
done
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' && say "permanent bridge: LISTENING on 127.0.0.2:3000" || say "permanent bridge: NOT listening"
grep -nE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts | sed 's/^/  hosts: /' || say "hosts: clean"

hr "X1 heal woodpecker-agent"
journalctl --user -u woodpecker-agent.service -n 12 --no-pager 2>/dev/null | tail -8 | sed 's/^/    /' || true
systemctl --user reset-failed woodpecker-agent.service 2>/dev/null || true
systemctl --user restart woodpecker-agent.service 2>/dev/null || true
ok=no; for i in $(seq 1 20); do [ "$(systemctl --user is-active woodpecker-agent.service)" = active ] && { ok=yes; break; }; sleep 2; done
if [ "$ok" != yes ]; then
  journalctl --user -u woodpecker-agent.service -n 40 --no-pager 2>/dev/null | tail -30 | sed 's/^/    /'
  halt "agent still failed; paste journal above"
fi
say "agent active"
podman logs --tail 4 woodpecker-agent 2>&1 | tail -3 | sed 's/^/    /' || true

hr "X2 normalize /etc/hosts (remove pollution now)"
sudo -v || halt "sudo needed"
sudo cp -p /etc/hosts "/etc/hosts.pre-ex50c.$STAMP.bak"
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts clean: $(grep -cE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || true) gitea lines"

hr "X3 prove new MinIO creds (S3 auth with devX)"
DP="$(tr -d '\n\r' < "$SEC/minio-users/minio-normal.pass")"
podman exec -i minio sh -c '
  IFS= read -r dp
  mc alias set devtest http://127.0.0.1:9000 devX "$dp" >/dev/null 2>&1 && mc ls devtest >/dev/null 2>&1 && echo "  devX S3 auth OK" || echo "  devX S3 auth FAIL"
' < <(printf '%s\n' "$DP")
say "Console login = conX + minio-users/minio-console-admin.pass (new). OS password is NOT used anywhere here."

hr "X4 browser re-login via PERMANENT bridge (temporary hosts entry)"
ss -ltn 2>/dev/null | grep -q '127.0.0.2:3000' || halt "permanent bridge not listening; cannot login"
echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
say "hosts entry added TEMPORARILY for login only"
say "OPEN: http://127.0.0.1:8000  -> sign out if needed -> Login with Gitea"
say "  Gitea username: $AUSER"
say "  Gitea password: run in another terminal:  cat $SEC/gitea-admin.pass"
printf '  Type DONE after Woodpecker shows you logged in: ' > /dev/tty; IFS= read -r ACK < /dev/tty
sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
say "hosts entry removed again (pollution gone)"
R="$(curl -sS -H "Authorization: Bearer $PAT" "$WP/api/user/repos" || true)"
printf '%s' "$R" | grep -q woodpecker-proof || halt "forge access not restored; retry login"
say "forge access verified via PAT"

hr "X5 pipeline smoke (proves rotated gRPC secret + agent)"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PAT" "$WP/api/repos/1/pipelines/8" || echo 000)"
say "restart pipeline #8 -> $CODE"
OK=no; NUM=""; ST=""
for i in $(seq 1 40); do
  R="$(podman exec postgres psql -U devops -d woodpecker -tAc "SELECT number||' '||status FROM pipelines WHERE repo_id=1 ORDER BY id DESC LIMIT 1" 2>/dev/null || true)"
  if [ -n "$R" ]; then read -r NUM ST <<<"$R"
    say "pipeline #$NUM status=$ST"
    [ "$ST" = success ] && { OK=yes; break; }
    case "$ST" in failure|error|killed) break;; esac
  fi
  sleep 3
done
[ "$OK" = yes ] || halt "smoke pipeline not success"

hr "X6 docs + result"
cat >> "$DOCS/brick12-runbook.md" <<'MD'

## Login bridge (permanent)
A permanent forwarder listens 127.0.0.2:3000 -> 127.0.0.1:3001 (GX04).
For interactive Woodpecker OAuth login ONLY:
  echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts   # add
  ...browser login...
  sudo sed -i '/[[:space:]]gitea$/d' /etc/hosts     # remove immediately after
Never leave the hosts line in place: it leaks into all Podman containers and
breaks step-container DNS (clone failures).
## Identity map
OS=dev/OS-pass | Gitea=adminX/gitea-admin.pass | Woodpecker=via Gitea OAuth |
MinIO console=conX/minio-console-admin.pass | MinIO S3=devX/minio-normal.pass |
MinIO root=adminX/minio-root.pass
MD
say "[RESULT] EX50c COMPLETE - agent healed, hosts clean, login done, smoke green."
ledger "PASS" "EX50c: agent active; hosts normalized; re-login verified; pipeline #$NUM success"
exit 0
