#!/usr/bin/env bash
# 20261030-BF — reconcile ledger with the LIVE running Grafana and harden it in place.
# Closes three defects proven by BD [D9]:
#   D1 stale-body gate lie: BD printed a 200 body beside a real 000 because checks returned
#      early on code!=200 without truncating $body. BF truncates before every read.
#   D2 DNS cold-start crash-loop: permanent grafana died on
#      "lookup postgres on 10.89.0.1:53: server misbehaving" -> Restart=always -> 97 cycles.
#      BF inserts ExecStartPre that blocks launch until aether DNS resolves postgres+prometheus,
#      reusing the EXACT ExecStart already installed (working runtime preserved; only a guard added).
#   D3 ledger had no green sentinel though the brick is live. BF verifies the running instance,
#      then writes bf-grafana-brick8-green-v3 + a quoted replay.
# In-place safety: does NOT alter container args/volume/network/port; one bounded restart to load
#   the guard; if the live gate fails after hardening, BF halts WITHOUT writing green (never fabricates).
# No sudo; no pull (grafana+alpine must be cached); no model download; no ollama/open-webui; no secret echo.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks.
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

SERVICE="grafana"
CONTAINER="grafana"
PORT="3000"
NET="aether"
IMAGE="docker.io/grafana/grafana:latest"
ALPINE="docker.io/library/alpine:latest"

PG_CONTAINER="postgres"
PROM_SERVICE="prometheus"
PROM_CONTAINER="prometheus"

GF_ENV="$A/secrets/grafana.env"
SCRIPT_DIR="$A/infra/scripts"
DNS_SCRIPT="$SCRIPT_DIR/grafana-dns-wait.sh"
DNS_SCRIPT_TMP="$TMPD/grafana-dns-wait.sh"

UNIT_SRC_DIR="$A/infra/systemd"
UNIT_SRC="$UNIT_SRC_DIR/grafana.service"
UNIT_INST="$HOME/.config/systemd/user/grafana.service"
UNIT_SRC_BAK="$UNIT_SRC.pre-BF.bak"
UNIT_INST_BAK="$UNIT_INST.pre-BF.bak"

DATASOURCE_UID="prometheus-aether"
DASHBOARD_UID="aether-overview"

CORRECTION_TOKEN="bf-grafana-dns-coldstart-and-stale-body-defect"
FAIL_TOKEN="bf-grafana-reconcile-failed-v1"
TOKEN="bf-grafana-brick8-green-v3"
SLUG_REPLAY="20261030-BF-grafana-dns-guard-reconcile-replay.sh"

ADMIN_USER=""
ADMIN_PASS=""
G_HEALTH=no
G_DS=no
G_DASH=no
G_QUERY=no
G_HEALTH_CODE=000
G_DS_CODE=000
G_DASH_CODE=000
G_QUERY_CODE=000
G_QUERY_DETAIL=""
G_ADMIN_RESET=no
NRESTARTS_AFTER=0

cleanup(){
  rm -rf "$TMPD" 2>/dev/null || true
}
trap cleanup EXIT

say(){ printf '  %s\n' "$*"; }
norm(){
  local s="${1:-}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}
halt(){
  printf '[HALT] %s\n' "$*" >&2
  exit 0
}
need_cmd(){
  if ! command -v "$1" >/dev/null 2>&1; then
    halt "missing required command: $1"
  fi
}
to_int(){
  local v
  v="$(norm "${1:-0}")"
  case "$v" in
    ''|*[!0-9]*)
      printf '0'
      ;;
    *)
      printf '%s' "$v"
      ;;
  esac
}
valid_ident(){
  local s="${1:-}"
  if printf '%s' "$s" | grep -Eq '^[A-Za-z_][A-Za-z0-9_$]{0,62}$'; then
    return 0
  fi
  return 1
}
valid_uid(){
  local s="${1:-}"
  if [ -z "$s" ]; then
    return 1
  fi
  case "$s" in
    *..*)
      return 1
      ;;
  esac
  if printf '%s' "$s" | grep -Eq '^[A-Za-z0-9_.-]{1,190}$'; then
    return 0
  fi
  return 1
}
active_state(){
  local s
  s="$(systemctl --user is-active "$1" 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=inactive
  fi
  printf '%s' "$s"
}
enabled_state(){
  local s
  s="$(systemctl --user is-enabled "$1" 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=unknown
  fi
  printf '%s' "$s"
}
container_status(){
  local name="$1"
  local s
  s="$(podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=absent
  fi
  printf '%s' "$s"
}
nrestarts(){
  local v
  v="$(systemctl --user show "$1" -p NRestarts --value 2>/dev/null || true)"
  printf '%s' "$(to_int "$v")"
}
env_has(){
  grep -q "^$1=." "$GF_ENV" 2>/dev/null
}
read_env_value(){
  awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$GF_ENV" 2>/dev/null || true
}
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true
}
setup_netrc(){
  if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
    return 1
  fi
  printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$ADMIN_PASS" > "$TMPD/netrc"
  chmod 600 "$TMPD/netrc" 2>/dev/null || true
}
# Fresh-body discipline: ALWAYS truncate the body file before reading it, and only trust it on 200.
api_code_fresh(){
  local path="$1"
  local out="$2"
  local code
  : > "$out"
  if [ ! -f "$TMPD/netrc" ]; then
    if ! setup_netrc; then
      printf '000'
      return 1
    fi
  fi
  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 10 --netrc-file "$TMPD/netrc" "http://127.0.0.1:$PORT$path" 2>/dev/null || true)"
  code="$(norm "$code")"
  if [ -z "$code" ]; then
    code=000
  fi
  printf '%s' "$code"
}
health_check(){
  local out="$TMPD/health.out"
  local code body
  : > "$out"
  code="$(norm "$(http_code "http://127.0.0.1:$PORT/api/health")")"
  G_HEALTH_CODE="$code"
  if [ "$code" != 200 ]; then
    return 1
  fi
  curl -s --max-time 5 "http://127.0.0.1:$PORT/api/health" >"$out" 2>/dev/null || true
  body="$(tr -d '[:space:]' < "$out" 2>/dev/null || true)"
  printf '%s' "$body" | grep -q '"database":"ok"'
}
ds_check(){
  local out="$TMPD/ds.out"
  local code
  code="$(api_code_fresh "/api/datasources/uid/$DATASOURCE_UID" "$out")"
  G_DS_CODE="$code"
  if [ "$code" != 200 ]; then
    return 1
  fi
  grep -q "\"uid\":\"$DATASOURCE_UID\"" "$out" 2>/dev/null
}
dash_check(){
  local out="$TMPD/dash.out"
  local code
  code="$(api_code_fresh "/api/dashboards/uid/$DASHBOARD_UID" "$out")"
  G_DASH_CODE="$code"
  if [ "$code" != 200 ]; then
    return 1
  fi
  grep -q "\"uid\":\"$DASHBOARD_UID\"" "$out" 2>/dev/null
}
query_check(){
  local out="$TMPD/query.out"
  local list="$TMPD/dslist.out"
  local code ds_id
  code="$(api_code_fresh "/api/datasources/proxy/uid/$DATASOURCE_UID/api/v1/query?query=1" "$out")"
  G_QUERY_CODE="$code"
  if [ "$code" = 200 ] && grep -q '"status":"success"' "$out" 2>/dev/null; then
    G_QUERY_DETAIL="uid-proxy"
    return 0
  fi
  code="$(api_code_fresh "/api/datasources" "$list")"
  if [ "$code" != 200 ]; then
    G_QUERY_DETAIL="datasource-list-failed:$code"
    return 1
  fi
  ds_id="$(python3 "$TMPD/ds_id.py" < "$list" 2>/dev/null || true)"
  ds_id="$(norm "$ds_id")"
  case "$ds_id" in
    ''|*[!0-9]*)
      G_QUERY_DETAIL="datasource-id-missing"
      return 1
      ;;
  esac
  code="$(api_code_fresh "/api/datasources/proxy/$ds_id/api/v1/query?query=1" "$out")"
  G_QUERY_CODE="$code"
  if [ "$code" = 200 ] && grep -q '"status":"success"' "$out" 2>/dev/null; then
    G_QUERY_DETAIL="id-proxy:$ds_id"
    return 0
  fi
  G_QUERY_DETAIL="query-failed:$code"
  return 1
}
run_subchecks(){
  G_HEALTH=no
  G_DS=no
  G_DASH=no
  G_QUERY=no
  G_QUERY_DETAIL=""
  if health_check; then G_HEALTH=yes; fi
  if ds_check; then G_DS=yes; fi
  if dash_check; then G_DASH=yes; fi
  if query_check; then G_QUERY=yes; fi
  if [ "$G_HEALTH" = yes ] && [ "$G_DS" = yes ] && [ "$G_DASH" = yes ] && [ "$G_QUERY" = yes ]; then
    return 0
  fi
  return 1
}
# If health is ok (DB migrated) but authed endpoints 401, the live DB admin diverged from env.
# Recover DB-side without HTTP auth, then retry. Never guesses; never echoes the password.
recover_admin_if_needed(){
  if [ "$G_HEALTH" != yes ]; then
    return 1
  fi
  if [ "$G_DS" = yes ] && [ "$G_DASH" = yes ] && [ "$G_QUERY" = yes ]; then
    return 0
  fi
  if [ "$G_DS_CODE" = 401 ] || [ "$G_DASH_CODE" = 401 ] || [ "$G_QUERY_CODE" = 401 ]; then
    say "[F5] authed endpoints 401 -> resetting admin password DB-side (no echo)"
    if podman exec "$CONTAINER" grafana cli admin reset-admin-password "$ADMIN_PASS" >/dev/null 2>&1; then
      G_ADMIN_RESET=yes
      rm -f "$TMPD/netrc" 2>/dev/null || true
      if ! setup_netrc; then
        return 1
      fi
      return 0
    fi
    say "[F5] reset-admin-password failed (container not ready or DB locked)"
    return 1
  fi
  return 1
}
wait_ready(){
  local tries="${1:-120}"
  local i
  for i in $(seq 1 "$tries"); do
    if run_subchecks; then
      return 0
    fi
    if recover_admin_if_needed; then
      if run_subchecks; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}
dump_detail(){
  run_subchecks || true
  say "[GATE] health=$G_HEALTH code=$G_HEALTH_CODE"
  say "[GATE] datasource=$G_DS code=$G_DS_CODE uid=$DATASOURCE_UID"
  say "[GATE] dashboard=$G_DASH code=$G_DASH_CODE uid=$DASHBOARD_UID"
  say "[GATE] prom_query=$G_QUERY code=$G_QUERY_CODE detail=$G_QUERY_DETAIL"
  say "[GATE] admin_reset_applied=$G_ADMIN_RESET"
  if [ -s "$TMPD/health.out" ]; then
    say "[GATE] health-body=$(head -c 240 "$TMPD/health.out" | tr '\n' ' ')"
  fi
}
journal_tail(){
  journalctl --user -u "$SERVICE.service" -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  podman logs --tail 40 "$CONTAINER" 2>&1 | sed 's/^/    c: /' || true
}
write_replay_bf(){
  cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# Replay/verify for BF: hardened Grafana unit installed+active, live observable gate green.
set -uo pipefail
A="$HOME/DevOps/aether"
ENV="$A/secrets/grafana.env"
UNIT_SRC="$A/infra/systemd/grafana.service"
UNIT_INST="$HOME/.config/systemd/user/grafana.service"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable grafana.service >/dev/null 2>&1 || true
systemctl --user restart grafana.service
HZ=no
for i in $(seq 1 120); do
  B="$(curl -s --max-time 5 http://127.0.0.1:3000/api/health 2>/dev/null || true)"
  if printf '%s' "$B" | tr -d '[:space:]' | grep -q '"database":"ok"'; then
    HZ=yes
    break
  fi
  sleep 2
done
U="$(awk -F= '/^GF_SECURITY_ADMIN_USER=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
P="$(awk -F= '/^GF_SECURITY_ADMIN_PASSWORD=/{print substr($0,index($0,"=")+1); exit}' "$ENV")"
N="/tmp/bf-replay.$$.netrc"
printf 'machine 127.0.0.1 login %s password %s\n' "$U" "$P" > "$N"
chmod 600 "$N" 2>/dev/null || true
DS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "$N" http://127.0.0.1:3000/api/datasources/uid/prometheus-aether)"
DASH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "$N" http://127.0.0.1:3000/api/dashboards/uid/aether-overview)"
Q="$(curl -s --max-time 15 --netrc-file "$N" 'http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus-aether/api/v1/query?query=1')"
rm -f "$N"
if [ "$HZ" = yes ] && [ "$DS" = 200 ] && [ "$DASH" = 200 ] && printf '%s' "$Q" | grep -q '"status":"success"'; then
  echo "  [GATE PASS] grafana health=ok datasource=ok dashboard=ok prom_query=success"
else
  echo "  [GATE FAIL] grafana health=$HZ datasource=$DS dashboard=$DASH"
  exit 1
fi
REPLAY
  chmod +x "$CD/$SLUG_REPLAY"
  say "[REPLAY] archived -> codemod/$SLUG_REPLAY"
}

for c in bash podman systemctl journalctl curl awk sed grep python3 cmp install chmod seq sleep mktemp tr head; do
  need_cmd "$c"
done

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$UNIT_SRC_DIR" "$SCRIPT_DIR" "$HOME/.config/systemd/user"
touch "$IDX"

# ===================== [F0] preconditions (pure reads; no writes) =====================
say "=== [F0] preconditions ==="
if ! podman image exists "$IMAGE" 2>/dev/null; then
  halt "grafana image missing: $IMAGE"
fi
if ! podman image exists "$ALPINE" 2>/dev/null; then
  halt "alpine image missing: $ALPINE (DNS guard needs it cached; do not pull ad hoc)"
fi
if ! podman network exists "$NET" 2>/dev/null; then
  halt "network $NET missing"
fi
if [ "$(container_status "$PG_CONTAINER")" != running ]; then
  halt "postgres container not running"
fi
if [ "$(active_state "$PROM_SERVICE.service")" != active ] ||
   [ "$(container_status "$PROM_CONTAINER")" != running ]; then
  halt "prometheus not active+running"
fi
if [ ! -f "$UNIT_INST" ]; then
  halt "installed grafana unit missing: $UNIT_INST (re-run BD first; BF preserves its ExecStart)"
fi
if ! grep -q '^ExecStart=' "$UNIT_INST" 2>/dev/null; then
  halt "installed grafana unit has no ExecStart line; refusing to harden an empty unit"
fi
if [ ! -f "$GF_ENV" ]; then
  halt "grafana env missing: $GF_ENV"
fi
ADMIN_USER="$(read_env_value GF_SECURITY_ADMIN_USER)"
ADMIN_PASS="$(read_env_value GF_SECURITY_ADMIN_PASSWORD)"
if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
  halt "grafana env missing GF_SECURITY_ADMIN_USER/PASSWORD"
fi
if ! valid_uid "$DATASOURCE_UID"; then
  halt "unsafe datasource uid"
fi
if ! valid_uid "$DASHBOARD_UID"; then
  halt "unsafe dashboard uid"
fi
say "[F0] grafana+alpine cached; network=$NET; postgres running; prometheus active"
say "[F0] unit present with ExecStart; admin_user=$ADMIN_USER (password not shown)"
say "[F0] current unit_active=$(active_state "$SERVICE.service") container=$(container_status "$CONTAINER") nrestarts=$(nrestarts "$SERVICE.service")"

cat > "$TMPD/ds_id.py" <<'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    for x in d:
        if x.get("uid") == "prometheus-aether":
            print(x.get("id", ""))
            break
except Exception:
    pass
PYEOF
chmod 600 "$TMPD/ds_id.py" 2>/dev/null || true

if [ "$DRY" = 1 ]; then
  say "[F0] dry-run plan (pure; no script write, no unit write, no restart, no SQL, no ledger):"
  say "    1) write $DNS_SCRIPT (bounded aether DNS-resolution gate for postgres+prometheus)"
  say "    2) insert ExecStartPre into the EXISTING unit (ExecStart preserved byte-for-byte)"
  say "    3) daemon-reload + enable + restart grafana.service (one bounded blip on :$PORT)"
  say "    4) live observable gate on :$PORT with fresh-body discipline (+ 401->DB-side admin reset)"
  say "    5) reset-failed + 12s stability watch; assert NRestarts stays 0 (no crash-loop)"
  say "    6) guarded correction + green ledger rows; quoted replay"
  say "[RESULT] DRY-RUN complete; nothing written, service untouched."
  exit 0
fi

# ===================== [F1] DNS-readiness guard script =====================
say "=== [F1] write DNS-readiness guard script ==="
cat > "$DNS_SCRIPT_TMP" <<'SEOF'
#!/usr/bin/env bash
# grafana-dns-wait.sh — block until aether DNS resolves the given hosts.
# Fixes BD [D9] transient "lookup postgres on 10.89.0.1:53: server misbehaving" cold-start loop:
# Grafana exits on first DB-connect DNS failure (no retry); systemd then crash-loops it.
# This pre-start gate waits (bounded) so Grafana only launches once DNS is warm.
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
TRIES="${AETHER_DNS_TRIES:-90}"
DELAY="${AETHER_DNS_DELAY:-1}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "usage: grafana-dns-wait.sh HOST [HOST...]" >&2
  exit 2
fi
for h in "${hosts[@]}"; do
  ok=0
  i=1
  while [ "$i" -le "$TRIES" ]; do
    if podman run --rm --network "$NET" "$ALPINE" getent hosts "$h" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  if [ "$ok" -ne 1 ]; then
    echo "dns-wait: host '$h' did not resolve on network '$NET' after $TRIES tries" >&2
    exit 1
  fi
  echo "dns-wait: resolved $h on $NET"
done
exit 0
SEOF

if ! bash -n "$DNS_SCRIPT_TMP"; then
  halt "DNS guard script failed bash -n; not installed"
fi
install -D -m 755 "$DNS_SCRIPT_TMP" "$DNS_SCRIPT" || halt "could not install $DNS_SCRIPT"
say "[F1] installed DNS guard -> $DNS_SCRIPT"

# ===================== [F2] insert ExecStartPre, preserve ExecStart =====================
say "=== [F2] harden unit (insert ExecStartPre; ExecStart untouched) ==="
PYINS="$TMPD/insert_pre.py"
cat > "$PYINS" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
pre_line = sys.argv[3]
cmt = "# BF hardening: block start until aether DNS resolves backing hosts (fixes BD [D9] SERVFAIL cold-start loop)."
t = src.read_text(encoding="utf-8")
if pre_line in t:
    dst.write_text(t, encoding="utf-8")
    sys.exit(0)
lines = t.splitlines(keepends=True)
out = []
inserted = False
for ln in lines:
    out.append(ln)
    if not inserted and ln.rstrip("\n") == "Type=simple":
        out.append(cmt + "\n")
        out.append(pre_line + "\n")
        inserted = True
if not inserted:
    sys.stderr.write("anchor 'Type=simple' not found in unit\n")
    sys.exit(2)
dst.write_text("".join(out), encoding="utf-8")
PYEOF

PRE_LINE="ExecStartPre=/bin/bash $DNS_SCRIPT postgres prometheus"
DESIRED="$TMPD/grafana.service.desired"
if ! python3 "$PYINS" "$UNIT_INST" "$DESIRED" "$PRE_LINE"; then
  halt "could not build hardened unit (anchor missing)"
fi
if ! bash -n "$DESIRED" 2>/dev/null; then
  : # unit files are not shell; bash -n N/A here; systemd-analyze verifies below
fi
if ! systemd-analyze verify "$DESIRED" >/dev/null 2>&1; then
  say "[F2] systemd-analyze verify reported issues (non-fatal on user units); continuing, gate will catch real breakage"
fi

if [ -f "$UNIT_SRC" ] && [ ! -f "$UNIT_SRC_BAK" ]; then
  cp -p "$UNIT_SRC" "$UNIT_SRC_BAK"
  say "[F2] unit source backup -> $UNIT_SRC_BAK"
fi
if [ -f "$UNIT_INST" ] && [ ! -f "$UNIT_INST_BAK" ]; then
  cp -p "$UNIT_INST" "$UNIT_INST_BAK"
  say "[F2] unit installed backup -> $UNIT_INST_BAK"
fi

if ! cmp -s "$DESIRED" "$UNIT_SRC"; then
  install -D -m 644 "$DESIRED" "$UNIT_SRC" || halt "could not write hardened unit source"
  say "[F2] hardened unit source -> $UNIT_SRC"
else
  say "[F2] unit source already hardened"
fi
if ! cmp -s "$UNIT_SRC" "$UNIT_INST"; then
  install -D -m 644 "$UNIT_SRC" "$UNIT_INST" || halt "could not install hardened unit"
  say "[F2] hardened unit installed -> $UNIT_INST"
else
  say "[F2] installed unit already hardened"
fi

# ===================== [F3] reload + enable + restart (bounded blip) =====================
say "=== [F3] reload + enable + restart grafana.service ==="
if ! systemctl --user daemon-reload; then
  halt "daemon-reload failed"
fi
systemctl --user enable "$SERVICE.service" >/dev/null 2>&1 || true
if ! systemctl --user restart "$SERVICE.service"; then
  journal_tail
  halt "restart of hardened grafana.service failed"
fi
say "[F3] restarted $SERVICE.service with DNS guard"

# ===================== [F4] wait active+running =====================
say "=== [F4] wait active+running ==="
OK=no
for i in $(seq 1 90); do
  if [ "$(active_state "$SERVICE.service")" = active ] &&
     [ "$(container_status "$CONTAINER")" = running ]; then
    OK=yes
    break
  fi
  sleep 2
done
if [ "$OK" != yes ]; then
  journal_tail
  halt "hardened grafana did not reach active+running"
fi
say "[F4] active+running"

# ===================== [F5] live observable gate (fresh bodies) =====================
say "=== [F5] live observable gate on :$PORT ==="
if ! wait_ready 120; then
  dump_detail
  journal_tail
  if ! grep -qF "$FAIL_TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | BF live gate failed after hardening: health=%s(%s) ds=%s(%s) dash=%s(%s) query=%s(%s) admin_reset=%s; grafana left running but UNVERIFIED; inspect [F5] GATE + journal. |\n' \
      "$(date +%F)" "$FAIL_TOKEN" "$G_HEALTH" "$G_HEALTH_CODE" "$G_DS" "$G_DS_CODE" "$G_DASH" "$G_DASH_CODE" "$G_QUERY" "$G_QUERY_CODE" "$G_ADMIN_RESET" >> "$IDX"
    say "[F5] failure ledger row appended."
  fi
  halt "BF live gate failed; no green written (ledger kept honest)"
fi
dump_detail
say "[F5] live gate PASS (fresh-body discipline; no stale-body lie)"

# ===================== [F6] stability watch + restart-counter sanity =====================
say "=== [F6] stability watch (prove the 97-loop is gone) ==="
systemctl --user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
sleep 12
NRESTARTS_AFTER="$(nrestarts "$SERVICE.service")"
if [ "$(active_state "$SERVICE.service")" != active ] ||
   [ "$(container_status "$CONTAINER")" != running ] || ! health_check; then
  dump_detail
  journal_tail
  halt "grafana unstable after hardening (still crash-looping)"
fi
if [ "$NRESTARTS_AFTER" -gt 0 ]; then
  journal_tail
  halt "auto-restart counter climbed to $NRESTARTS_AFTER during 12s watch (DNS guard not effective)"
fi
say "[F6] stable: active+running+health ok, NRestarts=$NRESTARTS_AFTER after 12s"

# ===================== [F7] correction ledger =====================
say "=== [F7] correction ledger row ==="
if ! grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | BD [D9] exposed two defects: (1) stale-body gate printed a 200 body beside a real 000 (checks returned early without truncating $body); (2) the promoted unit had no DNS-readiness guard, so a transient aether dnsmasq SERVFAIL for postgres caused a 97-cycle Restart=always crash-loop. BF reconciles the LIVE running Grafana: truncates bodies before read, inserts ExecStartPre=grafana-dns-wait.sh postgres prometheus while preserving the working ExecStart byte-for-byte, re-verifies the live gate, resets+monitors NRestarts, and writes the green sentinel. |\n' \
    "$(date +%F)" "$CORRECTION_TOKEN" >> "$IDX"
  say "[F7] correction row appended."
else
  say "[F7] correction row already present (guard suppressed)."
fi
grep -qF "$CORRECTION_TOKEN" "$IDX" 2>/dev/null && say "[F7] suppression proof: present." || say "[F7] WARNING: missing."

# ===================== [F8] green ledger =====================
say "=== [F8] green ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261030-BF-grafana-dns-guard-reconcile | GATE=PASS | %s: reconciled LIVE Grafana to ledger and hardened in place; service=%s container=%s network=%s host=http://127.0.0.1:%s internal=http://%s:%s db=grafana datasource=%s dashboard=%s health=%s ds=%s query=%s query_detail=%s admin_reset=%s nrestarts_after_watch=%s; ExecStart preserved, ExecStartPre=grafana-dns-wait.sh postgres prometheus added; fresh-body gate; no sqlite; no ollama/open-webui; no secret echo; loopback-only. |\n' \
    "$(date +%F)" "$TOKEN" "$SERVICE" "$CONTAINER" "$NET" "$PORT" "$CONTAINER" "$PORT" \
    "$DATASOURCE_UID" "$DASHBOARD_UID" "$G_HEALTH" "$G_DS" "$G_QUERY" "$G_QUERY_DETAIL" "$G_ADMIN_RESET" "$NRESTARTS_AFTER" >> "$IDX"
  say "[F8] green row appended."
else
  say "[F8] green row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[F8] suppression proof: present." || say "[F8] WARNING: missing."

write_replay_bf

say "[RESULT] GRAFANA BRICK 8 GREEN (HARDENED + RECONCILED) — service=$SERVICE container=$CONTAINER host=http://127.0.0.1:$PORT internal=http://$CONTAINER:$PORT datasource=$DATASOURCE_UID dashboard=$DASHBOARD_UID dns_guard=$DNS_SCRIPT nrestarts_after=$NRESTARTS_AFTER admin_reset=$G_ADMIN_RESET; next: build rag pilot; still no Ollama/OpenWebUI/chat-model."
exit 0
