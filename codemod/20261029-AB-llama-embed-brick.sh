#!/usr/bin/env bash
# 20261029-AB — settle-probe the reconciled stack (correct ports, polled), then build brick 5:
# llama.cpp embedding server as a NATIVE systemd user service (no container, no Ollama).
# Model: existing nomic-embed-text-v1.5.Q8_0.gguf (~0.14GiB). Loopback-only 127.0.0.1:8081.
# Flag discipline: ExecStart is composed ONLY from flags proven present in `llama-server --help`
# (recognition-complete-or-halt, same class as the redis conf allowlist).
# Hard rules: multi-line if/then/fi only; bash -n mandatory; no heredoc inside $( ); no backticks;
# no sudo; no secret echo; no model download; no ollama/open-webui.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"
SRCD="$A/infra/systemd"
SRCU="$SRCD/llama-embed.service"
SYSU="$HOME/.config/systemd/user"
DSTU="$SYSU/llama-embed.service"
LLAMA_SERVER="/home/dev/DevOps/neocortex/cpp/llama.cpp/build/bin/llama-server"
MODEL="/home/dev/DevOps/neocortex/models/embedded/nomic-embed-text-v1.5.Q8_0.gguf"
HOST="127.0.0.1"
PORT="8081"
CORR_TOKEN="aa-probe-instrument-defects"
GREEN_TOKEN="llama-embed brick5 GREEN"
SLUG_REPLAY="20261029-AB-llama-embed.sh"

TMPD="$(mktemp -d)"
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
http_code(){
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || true
}
poll_http(){
  local url="$1" want="$2" tries="$3" i c
  for i in $(seq 1 "$tries"); do
    c="$(http_code "$url")"
    c="$(norm "$c")"
    if [ "$c" = "$want" ]; then
      printf 'ok'
      return 0
    fi
    sleep 2
  done
  printf 'fail(last=%s)' "${c:-000}"
  return 1
}

# ===================== [B0] preconditions =====================
say "=== [B0] preconditions ==="
if [ ! -x "$LLAMA_SERVER" ]; then
  halt "llama-server missing/not executable at $LLAMA_SERVER"
fi
if [ ! -s "$MODEL" ]; then
  halt "embedding model missing at $MODEL"
fi
mkdir -p "$SRCD" "$SYSU"

# ===================== [B1] settle-probe reconciled stack (correct ports, polled) =====================
say "=== [B1] settle-probe (corrected ports vs AA) ==="
SETTLE_FAIL=no

PG_PROBE="fail"
for i in $(seq 1 20); do
  PG_OUT="$(podman exec postgres sh -c 'pg_isready -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' 2>&1 || true)"
  PG_OUT="$(norm "$PG_OUT")"
  if printf '%s' "$PG_OUT" | grep -qi 'accepting connections'; then
    PG_PROBE="ok"
    break
  fi
  sleep 2
done
say "[B1] postgres exec pg_isready: $PG_PROBE"
if [ "$PG_PROBE" != ok ]; then
  SETTLE_FAIL=yes
fi

RD_PROBE="fail"
for i in $(seq 1 20); do
  RD_OUT="$(podman exec redis redis-cli ping 2>&1 || true)"
  RD_OUT="$(norm "$RD_OUT")"
  case "$RD_OUT" in
    *PONG*|*NOAUTH*)
      RD_PROBE="ok($RD_OUT)"
      break
      ;;
  esac
  sleep 2
done
say "[B1] redis exec ping: $RD_PROBE"
case "$RD_PROBE" in
  ok*) ;;
  *) SETTLE_FAIL=yes ;;
esac

MN_PROBE="$(poll_http "http://127.0.0.1:9010/minio/health/live" 200 20 || true)"
say "[B1] minio host 9010 (AA used wrong 9000): $MN_PROBE"
if [ "$MN_PROBE" != ok ]; then
  SETTLE_FAIL=yes
fi

WV_PROBE="$(poll_http "http://127.0.0.1:8080/v1/.well-known/ready" 200 20 || true)"
say "[B1] weaviate host 8080: $WV_PROBE"
if [ "$WV_PROBE" != ok ]; then
  SETTLE_FAIL=yes
fi

PR_PROBE="$(poll_http "http://127.0.0.1:9090/-/healthy" 200 20 || true)"
say "[B1] prometheus host 9090: $PR_PROBE"

NE_PROBE="$(poll_http "http://127.0.0.1:9100/metrics" 200 20 || true)"
say "[B1] node-exporter host 9100: $NE_PROBE"

MP_PROBE="$(poll_http "http://127.0.0.1:8025/" 200 20 || true)"
say "[B1] mailpit host 8025: $MP_PROBE"

if [ "$SETTLE_FAIL" = yes ]; then
  say "[B1] core settle-probe failures; journals:"
  for s in postgres redis minio weaviate; do
    journalctl --user -u "$s.service" -n 15 --no-pager 2>/dev/null | sed "s/^/    $s j: /" || true
  done
  halt "core stack not settled-healthy; fix before adding brick 5."
fi
say "[B1] core stack settled-healthy (postgres+redis+minio+weaviate ok)"

# ===================== [B2] llama-server flag capability probe =====================
say "=== [B2] flag capability probe from --help ==="
HELPF="$TMPD/llama-help.txt"
"$LLAMA_SERVER" --help >"$HELPF" 2>&1 || true
if [ ! -s "$HELPF" ]; then
  halt "llama-server --help produced no output"
fi

flag_present(){
  local f="$1"
  grep -q -- "$f" "$HELPF" 2>/dev/null
}

EMBED_FLAG=""
if flag_present --embedding; then
  EMBED_FLAG="--embedding"
elif flag_present --embeddings; then
  EMBED_FLAG="--embeddings"
fi

MISSING_FLAGS=""
for f in --model --host --port --ctx-size --threads --parallel --alias; do
  if ! flag_present "$f"; then
    MISSING_FLAGS="$MISSING_FLAGS $f"
  fi
done
if [ -z "$EMBED_FLAG" ]; then
  MISSING_FLAGS="$MISSING_FLAGS --embedding|--embeddings"
fi
POOL_FLAG=""
if flag_present --pooling; then
  POOL_FLAG="--pooling"
fi
if [ -n "$MISSING_FLAGS" ]; then
  halt "llama-server lacks required flags:$MISSING_FLAGS — do not guess alternatives."
fi
say "[B2] embedding_flag=$EMBED_FLAG pooling_flag=${POOL_FLAG:-<none>} required_flags=all-present"

EXEC_LINE="$LLAMA_SERVER --model $MODEL --host $HOST --port $PORT $EMBED_FLAG"
if [ -n "$POOL_FLAG" ]; then
  EXEC_LINE="$EXEC_LINE --pooling mean"
fi
EXEC_LINE="$EXEC_LINE --ctx-size 2048 --threads 2 --parallel 1 --alias nomic-embed-text"
say "[B2] planned ExecStart: $EXEC_LINE"

# ===================== [B3] port occupancy precheck (idempotent) =====================
say "=== [B3] port $PORT occupancy precheck ==="
PRE_CODE="$(http_code "http://$HOST:$PORT/health")"
PRE_CODE="$(norm "$PRE_CODE")"
PRE_ACT="$(systemctl --user is-active llama-embed.service 2>/dev/null || true)"
PRE_ACT="$(norm "$PRE_ACT")"
if [ -z "$PRE_ACT" ]; then
  PRE_ACT=inactive
fi
PRE_PID="$(systemctl --user show llama-embed.service -p MainPID --value 2>/dev/null || true)"
PRE_PID="$(norm "$PRE_PID")"
PRE_CMD=""
if [ -n "$PRE_PID" ] && [ "$PRE_PID" != 0 ] && [ -r "/proc/$PRE_PID/cmdline" ]; then
  PRE_CMD="$(tr '\0' ' ' < "/proc/$PRE_PID/cmdline" 2>/dev/null || true)"
  PRE_CMD="$(norm "$PRE_CMD")"
fi
PRE_OURS=no
if [ "$PRE_ACT" = active ] && [ -n "$PRE_CMD" ]; then
  PRE_OURS=yes
  for needle in llama-server "$MODEL" "--host $HOST" "--port $PORT" "$EMBED_FLAG"; do
    if ! printf '%s' "$PRE_CMD" | grep -qF -- "$needle"; then
      PRE_OURS=no
    fi
  done
fi
if [ "$PRE_CODE" = 200 ] && [ "$PRE_OURS" != yes ]; then
  halt "foreign service already answers on $HOST:$PORT/health; refuse to collide."
fi
if [ "$PRE_CODE" = 200 ] && [ "$PRE_OURS" = yes ]; then
  say "[B3] port $PORT already owned by llama-embed.service; continuing idempotently"
else
  say "[B3] port $PORT free or not healthy (pre-code=${PRE_CODE:-000}); will start/restart unit"
fi

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no unit write, no start, no ledger row."
  exit 0
fi

# ===================== [B4] author + install unit =====================
say "=== [B4] author + install llama-embed.service ==="
if [ -f "$SRCU" ] && [ ! -f "$SRCU.pre-AB.bak" ]; then
  cp -p "$SRCU" "$SRCU.pre-AB.bak"
  say "[B4] backup -> $(basename "$SRCU").pre-AB.bak"
fi

cat > "$SRCU" <<UNIT
# Brick 5: llama.cpp embedding server (native systemd user service; NOT a container; NOT Ollama).
# Model is the existing on-disk GGUF; loopback-only; ceilings sized for i5-3360M/16GiB alongside the stack.
# Flags composed only from llama-server --help capability probe (recognition-complete-or-halt).
[Unit]
Description=llama.cpp embedding server (nomic-embed-text-v1.5 Q8_0)
After=network.target

[Service]
Type=simple
ExecStart=$EXEC_LINE
Restart=always
RestartSec=3
TimeoutStartSec=120
MemoryMax=1G
CPUQuota=50%
Nice=10
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
UNIT

install -D -m 644 "$SRCU" "$DSTU"
systemctl --user daemon-reload || halt "daemon-reload failed"
systemctl --user enable llama-embed.service >/dev/null 2>&1 || true
systemctl --user start llama-embed.service || true
say "[B4] installed + started llama-embed.service"

# ===================== [B5] readiness + functional embedding gate =====================
say "=== [B5] readiness + functional embedding gate ==="
HP="$(poll_http "http://$HOST:$PORT/health" 200 30 || true)"
say "[B5] /health: $HP"
if [ "$HP" != ok ]; then
  journalctl --user -u llama-embed.service -n 25 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  halt "llama-embed /health never reached 200; see journal above."
fi

BODY="$TMPD/emb.json"
printf '%s' '{"model":"nomic-embed-text","input":"aether smoke test"}' > "$BODY"
EMB_OUT="$(curl -s --max-time 30 -X POST "http://$HOST:$PORT/v1/embeddings" -H 'Content-Type: application/json' -d @"$BODY" 2>/dev/null || true)"
DIMS="$(printf '%s' "$EMB_OUT" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    e=d.get("data",[{}])[0].get("embedding",[])
    print(len(e))
except Exception:
    print(0)' 2>/dev/null || echo 0)"
DIMS="$(norm "$DIMS")"
case "$DIMS" in
  ''|*[!0-9]*)
    DIMS=0
    ;;
esac
say "[B5] /v1/embeddings dims=$DIMS (nomic-embed-text-v1.5 expected 768)"
if [ "$DIMS" -lt 1 ]; then
  printf '%s\n' "$EMB_OUT" | head -c 400 | sed 's/^/    resp: /' || true
  halt "embedding probe returned no vector; do not proceed to LiteLLM."
fi
if [ "$DIMS" != 768 ]; then
  say "[B5] WARN dims != 768; record measured dims for downstream vector config."
fi

ACT="$(systemctl --user is-active llama-embed.service 2>/dev/null || true)"
ACT="$(norm "$ACT")"
if [ -z "$ACT" ]; then
  ACT=inactive
fi
say "[B5] unit_active=$ACT"

PASS=no
if [ "$ACT" = active ] && [ "$HP" = ok ] && [ "$DIMS" -gt 0 ]; then
  PASS=yes
fi
if [ "$PASS" != yes ]; then
  halt "llama-embed gate failed (active=$ACT health=$HP dims=$DIMS)."
fi

# ===================== [B6] guarded ledger rows =====================
say "=== [B6] ledger rows ==="
if ! grep -qF "$CORR_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $CORR_TOKEN | APPEND-ONLY | AA probe defects (instrument, not patient): minio probed host 9000 while unit publishes 9010; probes ran 1-7s post-start before ports bound (timing race); linger check compared 'Linger=yes' to 'yes' without stripping prefix (linger was already enabled). AB re-probes settled services at correct ports with polls; core confirmed healthy. |" >> "$IDX"
  say "[B6] AA-instrument correction row appended."
else
  say "[B6] AA-instrument correction row already present."
fi
grep -qF "$CORR_TOKEN" "$IDX" 2>/dev/null && say "[B6] suppression proof: correction sentinel present." || say "[B6] WARNING: correction sentinel missing."

if ! grep -qF "$GREEN_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-AB-llama-embed-brick | GATE=PASS | $GREEN_TOKEN: native systemd user service on 127.0.0.1:8081; model=nomic-embed-text-v1.5-Q8_0 (on-disk, no download); flags capability-probed from --help; /health=200; /v1/embeddings dims=$DIMS; ceilings MemoryMax=1G CPUQuota=50%; core stack settle-probed green first; no ollama/open-webui; replay=$SLUG_REPLAY. |" >> "$IDX"
  say "[B6] llama-embed green row appended."
else
  say "[B6] llama-embed green row already present (guard suppressed)."
fi
grep -qF "$GREEN_TOKEN" "$IDX" 2>/dev/null && say "[B6] suppression proof: green sentinel present." || say "[B6] WARNING: green sentinel missing."

# ===================== [B7] replay archive =====================
cat > "$CD/$SLUG_REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# 20261029-AB-llama-embed.sh — replayable brick 5: ensure unit installed+active, gate /health + /v1/embeddings.
set -uo pipefail
A="$HOME/DevOps/aether"
SYSU="$HOME/.config/systemd/user"
SRCU="$A/infra/systemd/llama-embed.service"
install -D -m 644 "$SRCU" "$SYSU/llama-embed.service"
systemctl --user daemon-reload
systemctl --user enable llama-embed.service >/dev/null 2>&1 || true
systemctl --user start llama-embed.service
for i in $(seq 1 30); do
  C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:8081/health 2>/dev/null || true)
  if [ "$C" = 200 ]; then
    break
  fi
  sleep 2
done
D=$(curl -s --max-time 30 -X POST http://127.0.0.1:8081/v1/embeddings -H 'Content-Type: application/json' -d '{"model":"nomic-embed-text","input":"replay"}' 2>/dev/null | python3 -c 'import sys,json
try:
    print(len(json.load(sys.stdin).get("data",[{}])[0].get("embedding",[])))
except Exception:
    print(0)' 2>/dev/null || echo 0)
if [ "$C" = 200 ] && [ "${D:-0}" -gt 0 ]; then
  echo "  [GATE PASS] llama-embed health=200 dims=$D"
else
  echo "  [GATE FAIL] health=${C:-000} dims=${D:-0}"
  exit 1
fi
REPLAY
chmod +x "$CD/$SLUG_REPLAY"
say "[B7] archived -> codemod/$SLUG_REPLAY"

say "[RESULT] LLAMA-EMBED BRICK 5 GREEN — embeddings served natively from existing GGUF on 127.0.0.1:8081 (dims=$DIMS); next brick: LiteLLM proxy pointed at llama.cpp, still no Ollama/OpenWebUI."
exit 0
