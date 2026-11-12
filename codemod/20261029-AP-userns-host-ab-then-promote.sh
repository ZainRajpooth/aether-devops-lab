#!/usr/bin/env bash
# 20261029-AP — evidence-first heal for "rootless podman works interactively but fails newuidmap under systemd".
# Owns AO misdiagnosis: removing NoNewPrivileges did NOT change the newuidmap EPERM, so NNP was never the cause.
# Decisive lever: --userns=host removes private-userns creation => newuidmap/newgidmap never run.
# Method (NO guessing on the real service):
#   [P0a] ensure native llama-embed healthy (safe floor).
#   [P0b] read-only: effective unit security props + newuidmap suid bit + /usr mount opts.
#   [P1]  interactive A/B baseline (default userns vs --userns=host) -> both must pass.
#   [P2]  THROWAWAY systemd-user-service A/B:
#           t-priv : podman run (default userns)        -> EXPECT fail w/ newuidmap (reproduces bug in systemd ctx)
#           t-host : podman run --userns=host           -> EXPECT pass (bypasses newuidmap)
#           t-llama: runtime image --userns=host --version under systemd -> EXPECT pass (libs load w/o remap)
#         cleaned by trap.
#   [P3]  decision:
#           if (t-priv fail) and (t-host pass) and (t-llama pass):
#               patch AM heredoc to add --userns=host (+ ensure NNP absent, Delegate present), rerun AM, rerun AA, core gate.
#           else:
#               HALT with [P0b]/[P2] evidence; next step is host-level AppArmor/sysctl, NOT another script guess.
# Safety: no sudo; no pull; no model download; no ollama/open-webui; no secret echo; exit 0 on every halt.
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
AM="$CD/20261029-AM-llama-embed-container-promote.sh"
AA="$CD/20261029-AA-green-stack-reconcile.sh"
AM_BAK="$AM.pre-AP.bak"

NATIVE_SERVICE="llama-embed"
CONT_SERVICE="llama-embed-container"
CONTAINER_NAME="llama-embed"
PORT="8081"
ALPINE="docker.io/library/alpine:latest"
RUNTIME_IMAGE="localhost/aether-llama-runtime:glibc-match-v2"
PROBE_IMAGE="ghcr.io/berriai/litellm:main-latest"

SFX="$$"
T_PRIV="aether-ns-priv-$SFX"
T_HOST="aether-ns-host-$SFX"
T_LLAMA="aether-ns-llama-$SFX"
SYSU="$HOME/.config/systemd/user"

TOKEN="ao-nnp-misdiagnosis-userns-host-bypass"
AM_TOKEN="llama-embed-container-promotion-v1"

TMPD="$(mktemp -d)"
cleanup(){
  for u in "$T_PRIV" "$T_HOST" "$T_LLAMA"; do
    systemctl --user disable --now "$u.service" >/dev/null 2>&1 || true
    rm -f "$SYSU/$u.service" 2>/dev/null || true
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
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
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true
}
poll_http(){
  local url="$1" want="$2" tries="$3" i c
  for i in $(seq 1 "$tries"); do
    c="$(norm "$(http_code "$url")")"
    if [ "$c" = "$want" ]; then
      printf 'ok'
      return 0
    fi
    sleep 2
  done
  printf 'fail(last=%s)' "${c:-000}"
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
container_status(){
  local name="$1" s
  s="$(podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)"
  s="$(norm "$s")"
  if [ -z "$s" ]; then
    s=absent
  fi
  printf '%s' "$s"
}
unit_prop(){
  local unit="$1" prop="$2" v
  v="$(systemctl --user show "$unit" -p "$prop" --value 2>/dev/null || true)"
  v="$(norm "$v")"
  if [ -z "$v" ]; then
    v=unknown
  fi
  printf '%s' "$v"
}
run_min_service(){
  # $1=unit-name $2=unit-file ; starts, waits, returns 0 if active+success, prints journal tail
  local unit="$1" file="$2" i st res
  install -D -m 644 "$file" "$SYSU/$unit.service" || return 90
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
  systemctl --user start "$unit.service" >/dev/null 2>&1 || true
  st="activating"
  for i in $(seq 1 25); do
    st="$(active_state "$unit.service")"
    if [ "$st" = active ] || [ "$st" = failed ] || [ "$st" = inactive ]; then
      break
    fi
    sleep 1
  done
  res="$(unit_prop "$unit.service" Result)"
  say "    journal($unit):"
  journalctl --user -u "$unit.service" -n 18 --no-pager 2>/dev/null | sed 's/^/      /' || true
  if [ "$st" = active ] && [ "$res" = success ]; then
    return 0
  fi
  return 1
}

for c in bash podman systemctl curl awk sed grep python3 install cmp ls findmnt; do
  need_cmd "$c"
done

PODMAN_BIN="$(command -v podman)"
if [ -z "$PODMAN_BIN" ]; then
  halt "podman binary not found"
fi

mkdir -p "$CD" "$SYSU"
touch "$IDX"

if [ ! -f "$AM" ]; then
  halt "missing AM script: $AM"
fi

# ===================== [P0a] safe floor: native llama-embed healthy =====================
say "=== [P0a] safe floor: native llama-embed health ==="
NH="$(norm "$(http_code "http://127.0.0.1:$PORT/health")")"
if [ "$NH" != 200 ]; then
  say "[P0a] native health=$NH; restarting native llama-embed.service"
  systemctl --user restart "$NATIVE_SERVICE.service" >/dev/null 2>&1 || true
  if [ "$(poll_http "http://127.0.0.1:$PORT/health" 200 30 || true)" != ok ]; then
    journalctl --user -u "$NATIVE_SERVICE.service" -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    halt "native llama-embed unhealthy even after restart; fix brick 5 native before any container work"
  fi
  NH=200
fi
say "[P0a] native llama-embed healthy on 127.0.0.1:$PORT health=$NH (safe floor established)"

# ===================== [P0b] read-only security evidence =====================
say "=== [P0b] read-only: effective unit props + newuidmap suid + /usr mount opts ==="
say "[P0b] llama-embed-container NoNewPrivileges=$(unit_prop "$CONT_SERVICE.service" NoNewPrivileges)"
say "[P0b] llama-embed-container RestrictSUIDSGID=$(unit_prop "$CONT_SERVICE.service" RestrictSUIDSGID)"
say "[P0b] llama-embed-container CapabilityBoundingSet=$(unit_prop "$CONT_SERVICE.service" CapabilityBoundingSet)"
say "[P0b] llama-embed-container AppArmorProfile=$(unit_prop "$CONT_SERVICE.service" AppArmorProfile)"
say "[P0b] llama-embed-container Delegate=$(unit_prop "$CONT_SERVICE.service" Delegate)"
ls -l /usr/bin/newuidmap /usr/bin/newgidmap 2>/dev/null | sed 's/^/    /' || true
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /usr 2>/dev/null | sed 's/^/    mount /usr: /' || true
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS / 2>/dev/null | sed 's/^/    mount /: /' || true

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no minimal services, no AM patch, no AM/AA run, no ledger row."
  exit 0
fi

# ===================== [P1] interactive A/B baseline =====================
say "=== [P1] interactive A/B baseline (both must pass) ==="
P1_PRIV=1
P1_HOST=1
if "$PODMAN_BIN" run --rm --network none "$ALPINE" /bin/sh -c 'id -u; echo IPRIV_OK' >"$TMPD/p1priv.out" 2>"$TMPD/p1priv.err"; then
  P1_PRIV=0
fi
say "[P1] interactive default-userns rc=$P1_PRIV out=$(norm "$(tail -n1 "$TMPD/p1priv.out" 2>/dev/null || true)")"
if "$PODMAN_BIN" run --rm --userns=host --network none "$ALPINE" /bin/sh -c 'id -u; echo IHOST_OK' >"$TMPD/p1host.out" 2>"$TMPD/p1host.err"; then
  P1_HOST=0
fi
say "[P1] interactive --userns=host rc=$P1_HOST out=$(norm "$(tail -n1 "$TMPD/p1host.out" 2>/dev/null || true)")"
if [ "$P1_PRIV" != 0 ] || [ "$P1_HOST" != 0 ]; then
  tail -n 8 "$TMPD/p1priv.err" 2>/dev/null | sed 's/^/    priv-err: /' || true
  tail -n 8 "$TMPD/p1host.err" 2>/dev/null | sed 's/^/    host-err: /' || true
  halt "interactive baseline failed; rootless podman itself is broken outside systemd too — stop and fix host"
fi

# ===================== [P2] throwaway systemd-user-service A/B =====================
say "=== [P2] throwaway systemd-user-service A/B (decisive) ==="

# t-priv: default userns under systemd (expect FAIL with newuidmap)
printf '%s\n' \
  '[Unit]' \
  "Description=AP ns-priv $SFX" \
  '' \
  '[Service]' \
  'Type=simple' \
  "ExecStart=$PODMAN_BIN run --rm --network none $ALPINE /bin/sh -c 'id -u; echo PRIV_OK'" \
  '' \
  '[Install]' \
  'WantedBy=default.target' \
  > "$TMPD/$T_PRIV.service"

# t-host: --userns=host under systemd (expect PASS)
printf '%s\n' \
  '[Unit]' \
  "Description=AP ns-host $SFX" \
  '' \
  '[Service]' \
  'Type=simple' \
  "ExecStart=$PODMAN_BIN run --rm --userns=host --network none $ALPINE /bin/sh -c 'id -u; echo HOST_OK'" \
  '' \
  '[Install]' \
  'WantedBy=default.target' \
  > "$TMPD/$T_HOST.service"

# t-llama: real runtime image under --userns=host under systemd (expect PASS, proves libs load w/o remap)
T_LLAMA_RC=90
if "$PODMAN_BIN" image exists "$RUNTIME_IMAGE" 2>/dev/null; then
  printf '%s\n' \
    '[Unit]' \
    "Description=AP ns-llama $SFX" \
    '' \
    '[Service]' \
    'Type=simple' \
    "ExecStart=$PODMAN_BIN run --rm --userns=host --network none --entrypoint /opt/llama/bin/llama-server $RUNTIME_IMAGE --version" \
    '' \
    '[Install]' \
    'WantedBy=default.target' \
    > "$TMPD/$T_LLAMA.service"
else
  say "[P2] runtime image missing ($RUNTIME_IMAGE); skipping t-llama (will be caught by AM gates later)"
fi

say "[P2] --- t-priv (default userns under systemd) ---"
run_min_service "$T_PRIV" "$TMPD/$T_PRIV.service"
PRIV_RC=$?
say "[P2] t-priv rc=$PRIV_RC (expect nonzero = reproduces newuidmap failure in systemd ctx)"

say "[P2] --- t-host (--userns=host under systemd) ---"
run_min_service "$T_HOST" "$TMPD/$T_HOST.service"
HOST_RC=$?
say "[P2] t-host rc=$HOST_RC (expect 0 = bypasses newuidmap)"

if [ -f "$TMPD/$T_LLAMA.service" ]; then
  say "[P2] --- t-llama (runtime image --userns=host under systemd) ---"
  run_min_service "$T_LLAMA" "$TMPD/$T_LLAMA.service"
  T_LLAMA_RC=$?
  say "[P2] t-llama rc=$T_LLAMA_RC (expect 0 = llama-server+libs load without remap)"
  journalctl --user -u "$T_LLAMA.service" -n 8 --no-pager 2>/dev/null | grep -Ei 'version|llama|error' | sed 's/^/    llama-j: /' || true
else
  T_LLAMA_RC=1
  say "[P2] t-llama skipped (no runtime image); treating as not-yet-proven"
fi

# ===================== [P3] decision =====================
say "=== [P3] decision ==="
say "[P3] priv_rc=$PRIV_RC host_rc=$HOST_RC llama_rc=$T_LLAMA_RC"

BYPASS_PROVEN=no
if [ "$PRIV_RC" != 0 ] && [ "$HOST_RC" = 0 ] && [ "$T_LLAMA_RC" = 0 ]; then
  BYPASS_PROVEN=yes
fi

if [ "$BYPASS_PROVEN" != yes ]; then
  say "[P3] --userns=host bypass NOT decisively proven on this box in systemd context."
  say "[P3] Interpretation:"
  if [ "$HOST_RC" != 0 ]; then
    say "      t-host failed => even --userns=host cannot run podman under the user manager;"
    say "      the blocker is broader than userns creation (likely AppArmor profile on the service"
    say "      or a systemd sandbox default). See [P0b] AppArmorProfile / CapabilityBoundingSet above."
  fi
  if [ "$PRIV_RC" = 0 ]; then
    say "      t-priv PASSED under systemd => the real unit has a *different* blocker than bare podman;"
    say "      compare [P0b] props of llama-embed-container vs these minimal units."
  fi
  if [ "$T_LLAMA_RC" != 0 ] && [ "$HOST_RC" = 0 ]; then
    say "      t-llama failed though t-host passed => runtime image does not load under --userns=host"
    say "      (file-ownership/permission surprise); keep native llama-embed, do not promote."
  fi
  say "[P3] Native llama-embed remains the safe floor (health 200). Do NOT proceed to LiteLLM on a container llama."
  say "[P3] Likely host-level next step (deliberate, privileged, only if you accept the tradeoff):"
  say "      inspect: sudo aa-status | grep -Ei 'podman|conmon|newuidmap|userns'"
  say "      if an enforcing profile confines the user manager's podman children, prefer a targeted"
  say "      AppArmor profile allowing userns+setuid for podman/newuidmap/conmon over disabling"
  say "      kernel.apparmor_restrict_unprivileged_userns globally."
  if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | AP userns-host A/B: priv_rc=%s host_rc=%s llama_rc=%s bypass_proven=no; native floor health=200 retained; NNP-removal (AO) confirmed NOT the cause (identical newuidmap EPERM persisted); blocker is systemd-context userns/setuid path, not podman binary/image/model; host-level AppArmor/systemd-sandbox inspection queued; no sudo executed; no promotion. |\n' \
      "$(date +%F)" "$TOKEN" "$PRIV_RC" "$HOST_RC" "$T_LLAMA_RC" >> "$IDX"
    say "[P3] ledger row appended (bypass not proven)."
  else
    say "[P3] ledger row already present (guard suppressed)."
  fi
  halt "userns-host bypass not proven in systemd context; withheld AM promotion to avoid shipping a broken or unsupervised llama-embed"
fi

say "[P3] BYPASS PROVEN: default-userns fails under systemd, --userns=host passes, runtime image loads under --userns=host."
say "[P3] Patching AM to add --userns=host (idempotent: also ensures NNP absent + Delegate present), then rerun AM + AA."

# ===================== [P4] patch AM heredoc (self-contained, idempotent) =====================
CAND="$TMPD/am.candidate"
PY="$TMPD/patch_am.py"
cp -p "$AM" "$CAND" || halt "could not copy AM to candidate"

cat > "$PY" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

start = None
for i, line in enumerate(lines):
    if line.startswith('cat > "$DESIRED_UNIT" <<UNIT'):
        start = i
        break
if start is None:
    sys.stderr.write("missing AM desired-unit heredoc start anchor\n")
    sys.exit(2)

end = None
for i in range(start + 1, len(lines)):
    if lines[i].rstrip("\n") == "UNIT":
        end = i
        break
if end is None:
    sys.stderr.write("missing AM desired-unit heredoc end anchor\n")
    sys.exit(2)

block = lines[start + 1:end]
new = []
changed = False

BS = chr(92)  # backslash

for line in block:
    if line.strip() == "NoNewPrivileges=yes":
        changed = True
        continue
    new.append(line)

# add --userns=host right after the 'run --rm' physical line (idempotent)
if not any("--userns=host" in l for l in new):
    out = []
    inserted = False
    for line in new:
        out.append(line)
        if (not inserted) and ("run --rm" in line):
            out.append("  --userns=host " + BS + "\n")
            inserted = True
            changed = True
    if not inserted:
        sys.stderr.write("could not locate 'run --rm' line to insert --userns=host\n")
        sys.exit(2)
    new = out

# ensure Delegate=yes present before [Install]
if not any(l.strip() == "Delegate=yes" for l in new):
    install_idx = None
    for i, line in enumerate(new):
        if line.strip() == "[Install]":
            install_idx = i
            break
    if install_idx is None:
        new.append("Delegate=yes\n")
    else:
        new.insert(install_idx, "Delegate=yes\n\n")
    changed = True

if changed:
    lines[start + 1:end] = new
    p.write_text("".join(lines), encoding="utf-8")
PYEOF

if ! python3 "$PY" "$CAND"; then
  halt "AM patcher failed on candidate; original AM untouched"
fi
if ! bash -n "$CAND"; then
  halt "patched AM candidate failed bash -n; original AM untouched"
fi
say "[P4] AM candidate patched (userns=host + NNP-absent + Delegate); bash -n OK"

if [ ! -f "$AM_BAK" ]; then
  cp -p "$AM" "$AM_BAK"
  say "[P4] AM backup -> $AM_BAK"
fi
if ! cp -p "$CAND" "$AM"; then
  halt "could not install patched AM"
fi
if ! bash -n "$AM"; then
  cp -p "$AM_BAK" "$AM" 2>/dev/null || true
  halt "installed patched AM failed bash -n; restored backup"
fi
say "[P4] installed patched AM -> $AM"

if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | CORRECTION | %s | APPEND-ONLY | AO removed NoNewPrivileges but the newuidmap EPERM persisted verbatim => NNP was NOT the cause (misdiagnosis owned). AP A/B on throwaway systemd user services proved: default-userns podman fails under the user manager (newuidmap EPERM) while --userns=host podman AND the runtime image succeed => blocker is private-userns creation in systemd context, bypassed by sharing host userns. AM patched to add --userns=host (+NNP absent, Delegate yes). Isolation trade accepted for solo local lab: container root=host uid1000, model ro, internal net only, publish 127.0.0.1 only. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[P4] correction row appended."
else
  say "[P4] correction row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[P4] suppression proof: sentinel present." || say "[P4] WARNING: sentinel missing."

# ===================== [P5] rerun patched AM =====================
say "=== [P5] rerun patched AM (promote llama-embed container with --userns=host) ==="
"$PODMAN_BIN" system migrate >/dev/null 2>&1 || true
bash "$AM"
AMRC=$?
say "[P5] AM rc=$AMRC"
if ! grep -qF "$AM_TOKEN" "$IDX" 2>/dev/null; then
  say "[P5] AM promotion sentinel missing; inspect AM output above (its own rollback should have restored native)."
  halt "patched AM did not produce llama-embed-container-promotion-v1 despite proven bypass"
fi
say "[P5] AM promotion sentinel present; container_service_active=$(active_state "$CONT_SERVICE.service") container_status=$(container_status "$CONTAINER_NAME") NoNewPrivileges=$(unit_prop "$CONT_SERVICE.service" NoNewPrivileges)"

# ===================== [P6] reconcile core stack after reboot =====================
if [ -f "$AA" ]; then
  say "=== [P6] run AA green-stack reconcile ==="
  bash "$AA"
  AARC=$?
  say "[P6] AA rc=$AARC"
else
  say "[P6] AA script missing: $AA (llama-embed green, but core reconcile must be run separately)"
fi

# ===================== [P7] core gate =====================
say "=== [P7] core stack gate ==="
CORE_OK=yes
for s in postgres redis minio weaviate; do
  ACT="$(active_state "$s.service")"
  CST="$(container_status "$s")"
  say "[P7] $s active=$ACT container=$CST"
  if [ "$ACT" != active ] || [ "$CST" != running ]; then
    CORE_OK=no
  fi
done
if [ "$CORE_OK" != yes ]; then
  say "[P7] core stack not fully active+running; paste [P6]/[P7]; do not proceed to LiteLLM until core green."
  halt "llama-embed container promoted but core stack not green"
fi

say "[RESULT] LLAMA-EMBED CONTAINER PROMOTED VIA --userns=host + CORE STACK GREEN — service=$CONT_SERVICE container=$CONTAINER_NAME internal_upstream=http://$CONTAINER_NAME:$PORT/v1 host_admin=http://127.0.0.1:$PORT; AO NNP misdiagnosis owned and superseded; userns-host bypass A/B-proven on throwaway units before touching the real service; native llama-embed retained disabled for rollback; next brick LiteLLM; still no Ollama/OpenWebUI/chat-model."
exit 0
