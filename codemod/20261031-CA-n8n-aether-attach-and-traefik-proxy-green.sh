#!/usr/bin/env bash
# 20261031-CA — complete brick 11 by fixing the LAST real blocker: n8n not in aether DNS.
# Evidence (BZ Z3 CGroup + BY Y1): dns-wait passes gitea/grafana/woodpecker-server and
# wedges on `getent hosts n8n`; the aardvark daemon is ALIVE (postgres/others resolve), so
# this is a TOPOLOGY bug in n8n's unit, not a DNS-data-plane fault. BZ's dns-wait heal is
# correct and is NOT touched here.
#
# C0 read-only: print NetworkMode + Networks JSON for n8n vs gitea/grafana/woodpecker-server,
#    print n8n + gitea ExecStart lines, print bounded getent for the four. Decide branch.
# C1 fix n8n:
#      - if n8n Networks lacks "aether": minimally patch n8n.service ExecStart (continuation-
#        safe logical-line merge, backup .pre-CA.bak, anchored --network replace/insert) in
#        BOTH source + installed unit, daemon-reload, systemctl restart n8n.
#      - else (has aether but unregistered): podman restart n8n to re-fire netavark registration.
#    Then PROVE getent n8n non-loopback (bounded, retried). Fail-fast with dump if not.
# C2 prove all four (gitea/grafana/woodpecker-server/n8n) resolve non-loopback.
# C3 reset-failed + start traefik; wait active+running (bounded ~150s; dns-wait now passes fast).
# C4 FIRST true proxied :8888 gate: 5 functional endpoints REQUIRED (traefik-api, gitea,
#    woodpecker, grafana, n8n); dashboard INFO-only (never blocks the brick).
# C5 ledger: CA green token + (since proxied-200 is a stronger proof than BQ's structural
#    API check) write bq-traefik-brick11-green-v1 if absent; refresh BY-replay.
# Safety: no sudo; no pull; no /etc/hosts edit; no network recreate; never restarts
#    postgres/litellm; does NOT rewrite dns-wait; --check pure/read-only.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( );
#             no backticks; every `local` on its own line.
set -uo pipefail

TMPD="$(mktemp -d)"
DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
ALPINE="docker.io/library/alpine:latest"
NET="aether"
FOUR="gitea grafana woodpecker-server n8n"
UNIT_SRC_DIR="$A/infra/systemd"
UNIT_INST_DIR="$HOME/.config/systemd/user"
N8N_SRC="$UNIT_SRC_DIR/n8n.service"
N8N_INST="$UNIT_INST_DIR/n8n.service"

TOKEN="ca-n8n-aether-attach-and-traefik-proxy-green-v1"
BQ_TOKEN="bq-traefik-brick11-green-v1"
BAK_SUFFIX="pre-CA.bak"

N8N_BRANCH="undecided"
PROBE_RC=0
PROBE_ADDR=""

cleanup(){ rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }
need_cmd(){ if ! command -v "$1" >/dev/null 2>&1; then halt "missing required command: $1"; fi; }
bak_once(){
  local f="$1"
  if [ -f "$f" ] && [ ! -f "$f.$BAK_SUFFIX" ]; then
    cp -p "$f" "$f.$BAK_SUFFIX" || true
    say "[BAK] $f.$BAK_SUFFIX"
  fi
}
active_state(){ printf '%s' "$(norm "$(systemctl --user is-active "$1" 2>/dev/null || true)")"; }
container_status(){ printf '%s' "$(norm "$(podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null || true)")"; }
netmode_of(){ printf '%s' "$(norm "$(podman inspect "$1" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)")"; }
nets_json_of(){ printf '%s' "$(norm "$(podman inspect "$1" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null || true)")"; }
is_loopback(){
  local a="${1:-}"
  case "$a" in
    127.*|::1|localhost) return 0 ;;
    '') return 0 ;;
    *) return 1 ;;
  esac
}
http_code(){
  local url="$1"
  local host="${2:-}"
  local code
  if [ -n "$host" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $host" "$url" 2>/dev/null || true)"
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)"
  fi
  code="$(norm "$code")"
  if [ -z "$code" ]; then code=000; fi
  printf '%s' "$code"
}
wait_http(){
  local url="$1"
  local host="${2:-}"
  local tries="${3:-30}"
  local i
  local code
  for i in $(seq 1 "$tries"); do
    code="$(http_code "$url" "$host")"
    if [ "$code" = 200 ]; then return 0; fi
    sleep 2
  done
  return 1
}
probe_getent(){
  local name="$1"
  local o="$TMPD/ge-$name.out"
  local e="$TMPD/ge-$name.err"
  local rc=0
  : > "$o"; : > "$e"
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" >"$o" 2>"$e" || rc=$?
  else
    podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" >"$o" 2>"$e" || rc=$?
  fi
  PROBE_RC="$rc"
  PROBE_ADDR="$(awk 'NR==1{print $1}' "$o" 2>/dev/null || true)"
  PROBE_ADDR="$(norm "$PROBE_ADDR")"
}
dump_n8n(){
  say "=== [DUMP] n8n attachment + ExecStart + recent journal ==="
  say "  n8n NetworkMode=$(netmode_of n8n)  Networks=$(nets_json_of n8n)"
  say "  gitea NetworkMode=$(netmode_of gitea)  Networks=$(nets_json_of gitea)"
  grep -nE '^Exec(Start|StartPre|Stop)=' "$N8N_INST" 2>/dev/null | sed 's/^/    inst: /' || true
  journalctl --user -u n8n.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 30 n8n 2>&1 | sed 's/^/    c: /' || true
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head id date timeout; do
  need_cmd "$c"
done

# ===================== [C0] read-only evidence + branch decision =====================
say "=== [C0] evidence: who is on aether, who is not ==="
for n in $FOUR; do
  probe_getent "$n"
  say "[C0] getent $n -> '${PROBE_ADDR:-none}' rc=$PROBE_RC"
done
say "[C0] --- network attachment ---"
for n in $FOUR; do
  say "[C0] $n NetworkMode=$(netmode_of "$n") Networks=$(nets_json_of "$n")"
done

N8N_NETS="$(nets_json_of n8n)"
if printf '%s' "$N8N_NETS" | grep -q '"aether"'; then
  N8N_HAS_AETHER=yes
else
  N8N_HAS_AETHER=no
fi
say "[C0] n8n_has_aether=$N8N_HAS_AETHER"

if [ "$N8N_HAS_AETHER" = yes ]; then
  N8N_BRANCH="restart-to-reregister"
else
  N8N_BRANCH="patch-unit-network"
fi
say "[C0] decided branch: $N8N_BRANCH"

if [ ! -f "$N8N_INST" ]; then
  halt "installed n8n unit not found: $N8N_INST"
fi

if [ "$DRY" = 1 ]; then
  say "[C0] dry-run plan (pure/read-only; no patch, no restart, no writes, no ledger):"
  say "    C1 branch=$N8N_BRANCH"
  if [ "$N8N_BRANCH" = patch-unit-network ]; then
    say "    C1 patch ExecStart of $N8N_SRC + $N8N_INST to '--network $NET' (continuation-safe, backup), daemon-reload, restart n8n"
  else
    say "    C1 podman restart n8n (re-fire netavark registration; no unit edit)"
  fi
  say "    C1 prove getent n8n non-loopback ; C2 prove all four resolve"
  say "    C3 start traefik (dns-wait now passes all four) ; C4 first true proxied :8888 gate (5 required + dashboard info)"
  say "    C5 ledger (CA token + BQ green token if absent) + replay refresh"
  say "[RESULT] DRY-RUN complete; nothing written, no service touched."
  exit 0
fi

mkdir -p "$CD" "$UNIT_INST_DIR"
touch "$IDX"

# ===================== [C1] fix n8n on aether + prove =====================
say "=== [C1] apply n8n fix (branch=$N8N_BRANCH) ==="
if [ "$N8N_BRANCH" = patch-unit-network ]; then
  cat > "$TMPD/patch_n8n_net.py" <<'PYEOF'
import sys, re, pathlib
# Merge systemd line-continuations into logical lines, patch ONLY ExecStart lines that
# contain `podman run` to carry `--network <net>`, emit each patched logical line as ONE
# physical line (valid systemd). Non-target logical lines are re-emitted unchanged.
path = sys.argv[1]
net  = sys.argv[2]
raw  = pathlib.Path(path).read_text(encoding="utf-8")
phys = raw.splitlines(keepends=True)
out  = []
buf  = ""
def patch_logical(s):
    if not s.lstrip().startswith("ExecStart="):
        return s
    if "podman run" not in s:
        return s
    if re.search(r"--network[= ]" + re.escape(net) + r"\b", s):
        return s
    if re.search(r"--network[= ]\S+", s):
        return re.sub(r"--network[= ]\S+", "--network " + net, s, count=1)
    return s.replace("podman run", "podman run --network " + net, 1)
for line in phys:
    stripped = line.rstrip("\n")
    if stripped.endswith("\\"):
        buf += stripped[:-1]
        continue
    full = buf + line
    buf = ""
    out.append(patch_logical(full))
if buf:
    out.append(patch_logical(buf))
new = "".join(out)
if new != raw:
    pathlib.Path(path).write_text(new, encoding="utf-8")
    sys.exit(10)   # changed
sys.exit(0)        # no-op
PYEOF
  for u in "$N8N_SRC" "$N8N_INST"; do
    if [ -f "$u" ]; then
      bak_once "$u"
      python3 "$TMPD/patch_n8n_net.py" "$u" "$NET"
      prc=$?
      if [ "$prc" = 10 ]; then
        say "[C1] patched ExecStart network -> $NET in $u"
      elif [ "$prc" = 0 ]; then
        say "[C1] already desired -> $u"
      else
        dump_n8n
        halt "C1 patcher errored on $u (rc=$prc)"
      fi
      if ! bash -n <(sed -n '1,1p' "$u") 2>/dev/null; then :; fi   # unit files are not shell; skip bash -n
    fi
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed n8n.service >/dev/null 2>&1 || true
  if ! systemctl --user restart n8n.service; then
    say "[C1] systemctl restart n8n returned non-zero (verify via getent)"
  fi
else
  say "[C1] n8n already on aether; re-firing netavark registration via podman restart n8n"
  podman restart n8n >/dev/null 2>&1 || true
fi

say "[C1] proving getent n8n (bounded, retried) ..."
N8N_OK=no
for i in $(seq 1 20); do
  probe_getent n8n
  if [ -n "$PROBE_ADDR" ] && ! is_loopback "$PROBE_ADDR"; then
    N8N_OK=yes
    say "[C1] OK getent n8n -> $PROBE_ADDR (rc=$PROBE_RC)"
    break
  fi
  sleep 2
done
if [ "$N8N_OK" != yes ]; then
  say "[C1] n8n still unresolved (addr='${PROBE_ADDR:-none}' rc=$PROBE_RC)"
  dump_n8n
  halt "C1 failed: n8n did not register in aether DNS after fix (branch=$N8N_BRANCH)"
fi

# ===================== [C2] prove all four resolve =====================
say "=== [C2] prove all four backends resolve non-loopback ==="
C2_FAIL=""
for n in $FOUR; do
  probe_getent "$n"
  if [ -z "$PROBE_ADDR" ] || is_loopback "$PROBE_ADDR"; then
    C2_FAIL="$C2_FAIL $n('${PROBE_ADDR:-none}')"
  else
    say "[C2] OK $n -> $PROBE_ADDR"
  fi
done
if [ -n "$C2_FAIL" ]; then
  dump_n8n
  halt "C2 failed: unresolved after n8n fix:$C2_FAIL"
fi
say "[C2] all four resolve on $NET"

# ===================== [C3] start traefik + wait active+running =====================
say "=== [C3] start traefik (dns-wait now passes all four) ==="
systemctl --user reset-failed traefik.service >/dev/null 2>&1 || true
systemctl --user enable traefik.service >/dev/null 2>&1 || true
if ! systemctl --user restart traefik.service; then
  say "[C3] restart traefik returned non-zero (verify via state)"
fi
TR_OK=no
for i in $(seq 1 75); do
  if [ "$(active_state traefik.service)" = active ] && [ "$(container_status traefik)" = running ]; then
    TR_OK=yes
    break
  fi
  sleep 2
done
if [ "$TR_OK" != yes ]; then
  say "[C3] traefik not active+running (state=$(active_state traefik.service) cont=$(container_status traefik))"
  systemctl --user status --no-pager traefik.service 2>/dev/null | sed 's/^/    unit: /' || true
  journalctl --user -u traefik.service -n 40 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 60 traefik 2>&1 | sed 's/^/    c: /' || true
  halt "C3 failed: traefik did not become active+running"
fi
say "[C3] OK traefik active+running"
sleep 6

# ===================== [C4] first true proxied :8888 gate =====================
say "=== [C4] proxied gate through :8888 (5 required + dashboard info) ==="
P_FAIL=""
wait_http "http://127.0.0.1:8888/api/version" "traefik.aether.local" 40 || P_FAIL="$P_FAIL traefik-api($(http_code http://127.0.0.1:8888/api/version traefik.aether.local))"
wait_http "http://127.0.0.1:8888/api/healthz" "gitea.aether.local" 40 || P_FAIL="$P_FAIL gitea($(http_code http://127.0.0.1:8888/api/healthz gitea.aether.local))"
wait_http "http://127.0.0.1:8888/api/health" "woodpecker.aether.local" 40 || P_FAIL="$P_FAIL woodpecker($(http_code http://127.0.0.1:8888/api/health woodpecker.aether.local))"
wait_http "http://127.0.0.1:8888/api/health" "grafana.aether.local" 40 || P_FAIL="$P_FAIL grafana($(http_code http://127.0.0.1:8888/api/health grafana.aether.local))"
wait_http "http://127.0.0.1:8888/healthz" "n8n.aether.local" 40 || P_FAIL="$P_FAIL n8n($(http_code http://127.0.0.1:8888/healthz n8n.aether.local))"
DASH="$(http_code http://127.0.0.1:8888/dashboard/ traefik.aether.local)"
say "[C4] dashboard(info-only, never blocks): $DASH"
if [ -n "$P_FAIL" ]; then
  for u in gitea grafana woodpecker-server n8n traefik; do
    systemctl --user status --no-pager "$u.service" 2>/dev/null | sed "s/^/    unit-$u: /" || true
  done
  podman logs --tail 60 traefik 2>&1 | sed 's/^/    traefik-log: /' || true
  halt "C4 proxied gate failed:$P_FAIL"
fi
say "[C4] proxied gate PASS (traefik-api + gitea + woodpecker + grafana + n8n all 200 via :8888)"

# ===================== [C5] ledger + replay =====================
say "=== [C5] ledger + replay ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261031-CA-n8n-aether-attach-and-traefik-proxy-green | GATE=PASS | %s: COMPLETES BRICK 11. Final blocker was TOPOLOGY, not DNS data plane: n8n was the only backend not registered in aether (BZ Z3 CGroup wedged on getent n8n while gitea/grafana/woodpecker-server resolved; BY Y1 corroborated n8n=none). Branch=%s. Proved getent n8n non-loopback, then all four resolve, started traefik (dns-wait passes all four), and ran the FIRST true proxied :8888 gate: traefik-api+gitea+woodpecker+grafana+n8n all 200 (dashboard info=%s). BZ dns-wait heal left intact (correct). No sudo; no pull; no /etc/hosts edit; no network recreate; postgres/litellm untouched. |\n' \
    "$(date +%F)" "$TOKEN" "$N8N_BRANCH" "$DASH" >> "$IDX"
  say "[C5] CA green row appended."
else
  say "[C5] CA row already present (guard suppressed)."
fi
if ! grep -qF "$BQ_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | brick-11 authoritative proof = CA proxied-200 gate (stronger than BQ structural API check): traefik routes gitea/woodpecker/grafana/n8n via :8888, all 200. |\n' \
    "$(date +%F)" "$BQ_TOKEN" >> "$IDX"
  say "[C5] BQ green token written (proxied-200 is the authoritative brick-11 proof)."
else
  say "[C5] BQ green token already present."
fi

cat > "$CD/20261030-BY-replay.sh" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for brick 11 (CA): all four resolve + traefik proxied :8888 all 200 + agent flat.
set -uo pipefail
NET=aether; ALPINE=docker.io/library/alpine:latest
GE(){ timeout 15 podman run --rm --network "$NET" "$ALPINE" getent hosts "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
hc(){ local u="$1"; local h="${2:-}"; if [ -n "$h" ]; then curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "$u" 2>/dev/null || echo 000; else curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000; fi; }
FAIL=""
for n in postgres gitea grafana woodpecker-server n8n; do
  a="$(GE "$n")"
  case "$a" in ''|127.*|::1|localhost) FAIL="$FAIL $n('$a')" ;; esac
done
P1="$(hc http://127.0.0.1:8888/api/version traefik.aether.local)"
P2="$(hc http://127.0.0.1:8888/api/healthz gitea.aether.local)"
P3="$(hc http://127.0.0.1:8888/api/health woodpecker.aether.local)"
P4="$(hc http://127.0.0.1:8888/api/health grafana.aether.local)"
P5="$(hc http://127.0.0.1:8888/healthz n8n.aether.local)"
[ "$P1" = 200 ] || FAIL="$FAIL traefik-api($P1)"
[ "$P2" = 200 ] || FAIL="$FAIL gitea($P2)"
[ "$P3" = 200 ] || FAIL="$FAIL woodpecker($P3)"
[ "$P4" = 200 ] || FAIL="$FAIL grafana($P4)"
[ "$P5" = 200 ] || FAIL="$FAIL n8n($P5)"
A1="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || echo ?)"; sleep 6
A2="$(systemctl --user show woodpecker-agent.service -p NRestarts --value 2>/dev/null || echo ?)"
[ "$A1" = "$A2" ] || FAIL="$FAIL agent-NR($A1->$A2)"
if [ -z "$FAIL" ]; then
  echo "  [GATE PASS] brick11 dns=all-resolve proxied=all200 agent-NR-flat=$A1"
else
  echo "  [GATE FAIL]$FAIL"; exit 1
fi
REPLAY
chmod +x "$CD/20261030-BY-replay.sh"
say "[C5] replay refreshed -> codemod/20261030-BY-replay.sh"

grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[C5] suppression proof: CA sentinel present." || say "[C5] WARNING: CA sentinel missing."
say "[C5] GUI: BY applied the ghost-row patch; restart the GUI once to load it:"
say "      pkill -f 'Podman\.py' || true; nohup /home/dev/DevOps/.venv/bin/python /home/dev/DevOps/apps/podman/Podman.py >/tmp/aether-podman-gui.log 2>&1 &"
say "[RESULT] CA GREEN — brick 11 COMPLETE: n8n on aether (branch=$N8N_BRANCH), all four resolve, traefik active+running, proxied :8888 all 200 (dashboard info=$DASH); next: build woodpecker pipeline proof; still no Ollama/OpenWebUI/chat-model."
exit 0
