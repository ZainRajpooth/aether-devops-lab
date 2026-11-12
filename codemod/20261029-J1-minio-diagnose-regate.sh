#!/usr/bin/env bash
# 20261029-J1 — minio RED heal: READ-ONLY on runtime (no restart/pull/volume-rm in ANY branch).
# Fixes two instrument faults from I/[M5]: (1) timing race (curled before ports bound),
# (2) $(curl||echo 000) double-append => "000000". Adds readiness poll + crash detection.
# Steel-thread gate = S3 API 200; console demoted to INFO (B13: no guessed quadlet Exec=).
# Writes ONLY: guarded INDEX row + regenerated replay (.pre-J1.bak). exit 0 on every branch.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
IDX="$CD/INDEX.md"; REPLAY="$CD/20261029-I-minio.sh"
SLUG="20261029-I-minio"; SENTINEL="minio brick2 GREEN"
say(){ printf '  %s\n' "$*"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }                 # contained, file-run
httpcode(){ curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true; }   # NO ||echo (the 000000 bug)

# [J1] snapshot inspect (read-only)
ST=$(podman inspect minio --format '{{.State.Status}}' 2>/dev/null || echo absent)
EX=$(podman inspect minio --format '{{.State.ExitCode}}' 2>/dev/null || echo '?')
S0=$(podman inspect minio --format '{{.State.StartedAt}}' 2>/dev/null || echo '?')
RC=$(podman inspect minio --format '{{.State.RestartCount}}' 2>/dev/null || echo '?')
ARGS=$(podman inspect minio --format '{{.Path}} {{.Args}} | EP={{.Config.Entrypoint}} CMD={{.Config.Cmd}}' 2>/dev/null || echo '?')
PORTS=$(podman port minio 2>/dev/null | tr '\n' ' ' || echo '?')
say "[J1] status=$ST exit=$EX restarts=$RC startedAt=$S0"
say "     args: $ARGS"
say "     ports: $PORTS"
[ "$ST" = absent ] && halt "container 'minio' absent — unit never started; re-run I after checking 'systemctl --user status minio'"

# [J2] readiness poll (<=60s) + crash detection via StartedAt change
API=""; CON=""; ITER=0; CRASH=no; GREEN_ITER=0
for i in $(seq 1 30); do
  ITER=$i
  S1=$(podman inspect minio --format '{{.State.StartedAt}}' 2>/dev/null || echo '?')
  if [ "$S1" != "$S0" ] && [ "$S1" != '?' ]; then CRASH=yes; say "  [J2] restart detected at iter $i ($S0 -> $S1) => crash-loop"; break; fi
  API=$(httpcode http://127.0.0.1:9010/minio/health/live); [ -z "$API" ] && API=000
  CON=$(httpcode http://127.0.0.1:9011/);                    [ -z "$CON" ] && CON=000
  if [ "$API" = 200 ]; then GREEN_ITER=$i; break; fi
  sleep 2
done
say "[J2] poll done: iter=$ITER api=$API console=$CON green_iter=$GREEN_ITER crash=$CRASH"

# [J3] evidence (read-only, always)
say "[J3] --- podman logs minio (tail 30) ---"
podman logs --tail 30 minio 2>&1 | sed 's/^/    /' || true
ENVN=$(podman exec minio sh -c 'printenv' 2>/dev/null | grep -c '^MINIO_ROOT_' || echo 0)
say "[J3] MINIO_ROOT_* env keys injected (count, no values): $ENVN"

# [J4] decision
if [ "$CRASH" = yes ] || [ "$EX" != 0 -a "$EX" != '?' ]; then
  halt "crash-loop / non-zero exit (exit=$EX restarts=$RC). Evidence in [J3] logs above. NOT auto-patching (B13/§7). Likely causes to read in logs: perms on /data, unsupported 'bitnamilegacy' tag, or env contract. Options: (a) I will re-run with the official 'minio/minio:latest' substitution if you say so; (b) paste the [J3] log lines and I root-cause precisely. Runtime untouched."
fi
if [ "$API" != 200 ]; then
  halt "S3 API never bound within 60s (api=$API, status=$ST, no restart). Read [J3] logs: if minio printed an error it is there; if silent, the image CMD may differ from the captured 'server /data --console-address :9001'. Paste [J3] and I disambiguate. Runtime untouched."
fi

# ---- API 200 => steel-thread GREEN (console is INFO) ----
CONINFO="ok"; { [ "$CON" = 200 ] || [ "$CON" = 302 ]; } || CONINFO="not-bound(info: operator UI only; add quadlet Exec= when authoring edge if you want the web console — non-blocking for Lane-A S3 path)"
say "[J4] S3 API 200 at iter $GREEN_ITER => minio functionally GREEN (console=$CON -> $CONINFO)"

# guarded ledger row (sentinel IS in payload) + in-run suppression proof (H5 rule)
if ! grep -qF "$SENTINEL" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | $SLUG | GATE=PASS(J1 regate) | $SENTINEL: S3 API 200 (steel-thread), console=$CON ($CONINFO), data on named volume (ancestor+volume-type, proven in I/[M5]), loopback 9010/9011, image=$(podman inspect minio --format '{{.Config.Image}}' 2>/dev/null||echo '?'), keys preflighted both-present; timing-race+000000 instrument faults healed by readiness-poll + '||true' httpcode; replay regenerated w/ poll. |" >> "$IDX"
  say "[J4] green row appended (sentinel-in-payload)."
else say "[J4] green row already present (guard suppressed)."; fi
grep -qF "$SENTINEL" "$IDX" 2>/dev/null && say "[J4] suppression proof: '$SENTINEL' present => re-run takes suppress branch." || say "[J4] WARNING: sentinel missing — guard may not suppress."

# regenerate replay WITH readiness poll + corrected instrument (B1 safety copy first)
if [ -f "$REPLAY" ]; then cp -p "$REPLAY" "$REPLAY.pre-J1.bak" && say "[J5] backup -> $(basename "$REPLAY").pre-J1.bak"; fi
cat > "$REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# 20261029-I-minio-brick2.sh — replayable, poll-corrected (J1). Gate = S3 API 200; console INFO.
set -uo pipefail
A="$HOME/DevOps/aether"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
hc(){ curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true; }
podman volume exists minio_data 2>/dev/null || podman volume create minio_data >/dev/null
install -D -m 644 "$QD/minio.container" "$SYS/minio.container"
systemctl --user daemon-reload; systemctl --user enable minio.service 2>/dev/null||true; systemctl --user start minio.service
API=""; CON=""
for i in $(seq 1 30); do API=$(hc http://127.0.0.1:9010/minio/health/live); [ "$API" = 200 ] && break; sleep 2; done
CON=$(hc http://127.0.0.1:9011/)
[ "$API" = 200 ] && echo "  [GATE PASS] minio api=200 console=$CON" || { echo "  [GATE FAIL] api=$API console=$CON"; exit 1; }
REPLAY
chmod +x "$REPLAY"; say "[J5] replay regenerated w/ poll + '||true' instrument"
say "[RESULT] MINIO GREEN (brick 2, regated by J1) — S3 API live, volume proven, console noted; next: weaviate (then redis, ollama, litellm, n8n...)."
exit 0
