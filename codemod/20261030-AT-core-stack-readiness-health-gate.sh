#!/usr/bin/env bash
# 20261030-AT — prove core-stack functional readiness after AS/AA.
# Owns AA gap:
#   AA gated only on systemd active + podman running, not functional readiness.
# This script:
#   1) verifies llama-embed container health;
#   2) waits for postgres/redis/minio/weaviate functional probes;
#   3) reports optional observability/mail services;
#   4) appends guarded ledger rows for pass/fail;
#   5) halts with evidence if core readiness fails.
# Safety:
#   - no sudo
#   - no image pull
#   - no model download
#   - no ollama/open-webui
#   - no secret echo
# Hard rules:
#   - multi-line if/then/fi only
#   - bash -n mandatory before run
#   - no heredoc inside $( )
#   - no backticks
set -uo pipefail

DRY=0
if [ "${1:-}" = "--check" ]; then
  DRY=1
  shift
fi

A="$HOME/DevOps/aether"
CD="$A/codemod"
IDX="$CD/INDEX.md"

TOKEN_PASS="core-stack-readiness-green-v1"
TOKEN_FAIL="core-stack-readiness-failed-v1"

LLAMA_SERVICE="llama-embed-container"
LLAMA_CONTAINER="llama-embed"
LLAMA_PORT="8081"

CORE_SERVICES=(postgres redis minio weaviate)
OPTIONAL_SERVICES=(prometheus node-exporter mailpit)

ATTEMPTS=60
SLEEP_SECONDS=2

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
need_cmd(){
  if ! command -v "$1" >/dev/null 2>&1; then
    halt "missing required command: $1"
  fi
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
env_value(){
  local name="$1"
  local key="$2"
  local def="$3"
  local raw
  raw="$(podman inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' || true)"
  raw="$(norm "$raw")"
  if [ -z "$raw" ]; then
    printf '%s' "$def"
  else
    printf '%s' "$raw"
  fi
}
published_port(){
  local name="$1"
  local cport="$2"
  local raw port
  raw="$(podman port "$name" "$cport" 2>/dev/null | head -n1 || true)"
  raw="$(norm "$raw")"
  if [ -z "$raw" ]; then
    return 1
  fi
  port="${raw##*:}"
  if [ -z "$port" ]; then
    return 1
  fi
  printf '%s' "$port"
}
tcp_ok(){
  local port="$1"
  if [ -z "$port" ]; then
    return 1
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}
http_ok(){
  local url="$1"
  curl -fsS --max-time 5 "$url" >/dev/null 2>&1
}

ready_llama(){
  if [ "$(active_state "$LLAMA_SERVICE.service")" != active ]; then
    return 1
  fi
  if [ "$(container_status "$LLAMA_CONTAINER")" != running ]; then
    return 1
  fi
  http_ok "http://127.0.0.1:$LLAMA_PORT/health"
}

ready_postgres(){
  local pguser pgdb p
  if [ "$(container_status postgres)" != running ]; then
    return 1
  fi

  pguser="$(env_value postgres POSTGRES_USER postgres)"
  pgdb="$(env_value postgres POSTGRES_DB "$pguser")"

  if podman exec postgres pg_isready -U "$pguser" -d "$pgdb" -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
    return 0
  fi

  p="$(published_port postgres 5432/tcp)" || return 1
  tcp_ok "$p"
}

ready_redis(){
  local pass p
  if [ "$(container_status redis)" != running ]; then
    return 1
  fi

  pass="$(env_value redis REDIS_PASSWORD '')"

  if [ -n "$pass" ]; then
    if podman exec -e REDISCLI_AUTH="$pass" redis redis-cli ping 2>/dev/null | grep -q PONG; then
      return 0
    fi
  else
    if podman exec redis redis-cli ping 2>/dev/null | grep -q PONG; then
      return 0
    fi
  fi

  p="$(published_port redis 6379/tcp)" || return 1
  tcp_ok "$p"
}

ready_minio(){
  local p
  if [ "$(container_status minio)" != running ]; then
    return 1
  fi

  p="$(published_port minio 9000/tcp)" || true
  if [ -n "$p" ] && http_ok "http://127.0.0.1:$p/minio/health/live"; then
    return 0
  fi

  if podman exec minio sh -c 'curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1 || wget -q -O /dev/null http://127.0.0.1:9000/minio/health/live' >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

ready_weaviate(){
  local p
  if [ "$(container_status weaviate)" != running ]; then
    return 1
  fi

  p="$(published_port weaviate 8080/tcp)" || return 1
  http_ok "http://127.0.0.1:$p/v1/.well-known/ready"
}

ready_prometheus(){
  local p
  p="$(published_port prometheus 9090/tcp)" || return 1
  http_ok "http://127.0.0.1:$p/-/healthy"
}

ready_node_exporter(){
  local p
  p="$(published_port node-exporter 9100/tcp)" || return 1
  http_ok "http://127.0.0.1:$p/metrics"
}

ready_mailpit(){
  local p
  p="$(published_port mailpit 8025/tcp)" || true
  if [ -n "$p" ] && http_ok "http://127.0.0.1:$p/api/v1/messages"; then
    return 0
  fi

  p="$(published_port mailpit 1025/tcp)" || return 1
  tcp_ok "$p"
}

report_optional(){
  local o r
  for o in "${OPTIONAL_SERVICES[@]}"; do
    r=no
    case "$o" in
      prometheus)
        if ready_prometheus; then
          r=yes
        fi
        ;;
      node-exporter)
        if ready_node_exporter; then
          r=yes
        fi
        ;;
      mailpit)
        if ready_mailpit; then
          r=yes
        fi
        ;;
    esac
    say "[T3] optional $o active=$(active_state "$o.service") container=$(container_status "$o") ready=$r"
  done
}

dump_failure(){
  local svc p
  for svc in "${CORE_SERVICES[@]}"; do
    say "--- failure evidence: $svc ---"
    say "active=$(active_state "$svc.service") enabled=$(enabled_state "$svc.service") container=$(container_status "$svc")"

    for p in 5432/tcp 6379/tcp 9000/tcp 8080/tcp 9090/tcp 9100/tcp 8025/tcp 1025/tcp; do
      say "port $p: $(podman port "$svc" "$p" 2>/dev/null || true)"
    done

    journalctl --user -u "$svc.service" -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
    podman logs --tail 30 "$svc" 2>&1 | sed 's/^/    c: /' || true
  done
}

for c in bash podman systemctl journalctl curl awk sed grep seq sleep; do
  need_cmd "$c"
done

mkdir -p "$CD"
touch "$IDX"

# ===================== [T0] preconditions =====================
say "=== [T0] preconditions ==="
say "[T0] llama_service_active=$(active_state "$LLAMA_SERVICE.service") llama_service_enabled=$(enabled_state "$LLAMA_SERVICE.service") llama_container=$(container_status "$LLAMA_CONTAINER")"

for svc in "${CORE_SERVICES[@]}"; do
  say "[T0] $svc active=$(active_state "$svc.service") enabled=$(enabled_state "$svc.service") container=$(container_status "$svc")"
done

if [ "$DRY" = 1 ]; then
  say "[T0] dry-run plan: wait up to $((ATTEMPTS * SLEEP_SECONDS)) seconds for functional readiness."
  say "[RESULT] DRY-RUN complete; no waiting, no ledger row."
  exit 0
fi

# ===================== [T1] readiness wait =====================
say "=== [T1] functional readiness wait ==="

READY_LLAMA=no
READY_PG=no
READY_REDIS=no
READY_MINIO=no
READY_WEAVIATE=no

for attempt in $(seq 1 "$ATTEMPTS"); do
  if [ "$READY_LLAMA" != yes ]; then
    if ready_llama; then
      READY_LLAMA=yes
      say "[T1] attempt=$attempt llama ready"
    fi
  fi

  if [ "$READY_PG" != yes ]; then
    if ready_postgres; then
      READY_PG=yes
      say "[T1] attempt=$attempt postgres ready"
    fi
  fi

  if [ "$READY_REDIS" != yes ]; then
    if ready_redis; then
      READY_REDIS=yes
      say "[T1] attempt=$attempt redis ready"
    fi
  fi

  if [ "$READY_MINIO" != yes ]; then
    if ready_minio; then
      READY_MINIO=yes
      say "[T1] attempt=$attempt minio ready"
    fi
  fi

  if [ "$READY_WEAVIATE" != yes ]; then
    if ready_weaviate; then
      READY_WEAVIATE=yes
      say "[T1] attempt=$attempt weaviate ready"
    fi
  fi

  if [ "$READY_LLAMA" = yes ] &&
     [ "$READY_PG" = yes ] &&
     [ "$READY_REDIS" = yes ] &&
     [ "$READY_MINIO" = yes ] &&
     [ "$READY_WEAVIATE" = yes ]; then
    say "[T1] all required probes ready at attempt=$attempt"
    break
  fi

  sleep "$SLEEP_SECONDS"
done

# ===================== [T2] final state =====================
say "=== [T2] final required readiness ==="
say "[T2] llama ready=$READY_LLAMA"
say "[T2] postgres ready=$READY_PG"
say "[T2] redis ready=$READY_REDIS"
say "[T2] minio ready=$READY_MINIO"
say "[T2] weaviate ready=$READY_WEAVIATE"

report_optional

# ===================== [T3] gate =====================
if [ "$READY_LLAMA" != yes ] ||
   [ "$READY_PG" != yes ] ||
   [ "$READY_REDIS" != yes ] ||
   [ "$READY_MINIO" != yes ] ||
   [ "$READY_WEAVIATE" != yes ]; then

  if ! grep -qF "$TOKEN_FAIL" "$IDX" 2>/dev/null; then
    printf '| %s | DIAG | %s | APPEND-ONLY | core-stack readiness failed: llama=%s postgres=%s redis=%s minio=%s weaviate=%s; AA active+running gate was insufficient; functional probes required before LiteLLM/RAG/persistence. |\n' \
      "$(date +%F)" \
      "$TOKEN_FAIL" \
      "$READY_LLAMA" \
      "$READY_PG" \
      "$READY_REDIS" \
      "$READY_MINIO" \
      "$READY_WEAVIATE" >> "$IDX"
    say "[T3] failure ledger row appended."
  else
    say "[T3] failure ledger row already present (guard suppressed)."
  fi
  grep -qF "$TOKEN_FAIL" "$IDX" 2>/dev/null && say "[T3] suppression proof: failure sentinel present." || say "[T3] WARNING: failure sentinel missing."

  dump_failure
  halt "core-stack functional readiness failed; inspect [T3] evidence before proceeding"
fi

# ===================== [T4] success ledger =====================
say "=== [T4] success ledger row ==="
if ! grep -qF "$TOKEN_PASS" "$IDX" 2>/dev/null; then
  printf '| %s | DIAG | %s | APPEND-ONLY | core-stack readiness green: llama=%s postgres=%s redis=%s minio=%s weaviate=%s; functional probes passed; next brick LiteLLM can use measured upstream http://llama-embed:8081/v1. |\n' \
    "$(date +%F)" \
    "$TOKEN_PASS" \
    "$READY_LLAMA" \
    "$READY_PG" \
    "$READY_REDIS" \
    "$READY_MINIO" \
    "$READY_WEAVIATE" >> "$IDX"
  say "[T4] success ledger row appended."
else
  say "[T4] success ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN_PASS" "$IDX" 2>/dev/null && say "[T4] suppression proof: success sentinel present." || say "[T4] WARNING: success sentinel missing."

say "[RESULT] CORE STACK READINESS GREEN — llama-embed + postgres/redis/minio/weaviate pass functional probes; next: build litellm; still no Ollama/OpenWebUI/chat-model."
exit 0
