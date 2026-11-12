#!/usr/bin/env bash
# 20261029-Z — heal Woodpecker image refs from Y, then read-only llama.cpp asset inventory.
# Root cause of Y PARTIAL: wrong candidate refs:
#   docker.io/woodpeckerci/server:latest
#   docker.io/woodpeckerci/agent:latest
# Correct refs from prior Docker screenshots:
#   docker.io/woodpeckerci/woodpecker-server:v3
#   docker.io/woodpeckerci/woodpecker-agent:v3
# Policy:
#   - no sudo
#   - no secrets echoed
#   - no ollama/open-webui/k3d/k3s/nginx/registry pulls
#   - no model loaded
#   - no services started
#   - disk guard keeps /home above reserve
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
EXTRA="$CD/image-cache.extra.list"
SELECTED_OLD="$CD/image-cache.remaining.selected.list"
MANIFEST_OLD="$CD/image-cache.remaining.resolved.tsv"
MANIFEST_HEAL="$CD/image-cache.woodpecker-heal.resolved.tsv"
SELECTED_HEAL="$CD/image-cache.woodpecker-heal.selected.list"
TOKEN="woodpecker-image-ref-heal-v1"

# Keep at least 20 GiB free on /home after this small heal.
RESERVE_KB=20971520
# Require at least 22 GiB free before starting.
PRECHECK_MIN_KB=23068672

LLAMA_SERVER="/home/dev/DevOps/neocortex/cpp/llama.cpp/build/bin/llama-server"
MODEL_ROOT="/home/dev/DevOps/neocortex/models"

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
free_kb(){
  df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'
}
used_pct(){
  df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'
}
kb_to_gib(){
  awk -v k="$(to_int "${1:-0}")" 'BEGIN{printf "%.2fGiB", k/1048576}'
}
bytes_to_gib(){
  awk -v b="$(to_int "${1:-0}")" 'BEGIN{printf "%.2fGiB", b/1073741824}'
}
print_disk(){
  local label="$1"
  local p="$2"
  local uk ak pct
  uk="$(to_int "$(df -Pk "$p" 2>/dev/null | awk 'NR==2{print $3}')")"
  ak="$(to_int "$(free_kb "$p")")"
  pct="$(norm "$(used_pct "$p")")"
  say "[$label] $p used=$(kb_to_gib "$uk") avail=$(kb_to_gib "$ak") =${pct:-?}%"
}
contains_forbidden(){
  local ref="$1"
  case "$ref" in
    *ollama*|*open-webui*|*openwebui*|*k3d*|*k3s*|*nginx*|*registry*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

for c in bash podman df awk sed head tail install grep sort wc find nproc; do
  need_cmd "$c"
done

mkdir -p "$CD"

# ===================== [Z0] policy =====================
say "=== [Z0] image policy ==="
say "[Z0] healing only Woodpecker refs from Y PARTIAL."
say "[Z0] not cached by design: nginx, registry, k3d, k3s, ollama, open-webui."
say "[Z0] reason: Podman/Quadlet replaces k3d/k3s; Traefik/Caddy later replaces old nginx proxy; llama.cpp is preferred model backend; local registry is not needed now."

# ===================== [Z1] planned corrected refs =====================
declare -A REFS

REFS[woodpecker-server]="docker.io/woodpeckerci/woodpecker-server:v3,docker.io/woodpeckerci/woodpecker-server:latest"
REFS[woodpecker-agent]="docker.io/woodpeckerci/woodpecker-agent:v3,docker.io/woodpeckerci/woodpecker-agent:latest"

ORDER=(
  woodpecker-server
  woodpecker-agent
)

MANI_TMP="$TMPD/resolved.tsv"
SEL_TMP="$TMPD/selected.list"
printf 'service\tstatus\tchosen_ref\timageid\tsize_bytes\trepodigests\n' > "$MANI_TMP"
: > "$SEL_TMP"

# ===================== [Z2] disk precheck =====================
say "=== [Z2] disk precheck ==="
print_disk Z2 /home
print_disk Z2 /

FREE_BEFORE="$(to_int "$(free_kb /home)")"
PCT_BEFORE="$(norm "$(used_pct /home)")"
say "[Z2] free_before=$(kb_to_gib "$FREE_BEFORE") used_before=${PCT_BEFORE:-?}% reserve_after=$(kb_to_gib "$RESERVE_KB") precheck_min=$(kb_to_gib "$PRECHECK_MIN_KB")"

if [ "$FREE_BEFORE" -lt "$PRECHECK_MIN_KB" ]; then
  halt "insufficient free space before Woodpecker heal; free=$(kb_to_gib "$FREE_BEFORE") required_at_least=$(kb_to_gib "$PRECHECK_MIN_KB")"
fi

# ===================== [Z3] dry-run plan =====================
if [ "$DRY" = 1 ]; then
  say "=== [Z3] dry-run planned Woodpecker refs ==="
  for svc in "${ORDER[@]}"; do
    IFS=',' read -r -a refs <<< "${REFS[$svc]}"
    present=""
    for ref in "${refs[@]}"; do
      if contains_forbidden "$ref"; then
        continue
      fi
      if podman image exists "$ref" 2>/dev/null; then
        present="$ref"
        break
      fi
    done
    say "[Z3-dry] $svc present=${present:-none} candidates=${REFS[$svc]}"
  done
  say "[Z3-dry] old manifest remains: $MANIFEST_OLD"
  say "[Z3-dry] heal manifest would be: $MANIFEST_HEAL"
  say "[RESULT] DRY-RUN complete; no image pull, no list install, no ledger row, no llama model load."
  exit 0
fi

# ===================== [Z4] pull/cache corrected Woodpecker images =====================
say "=== [Z4] heal Woodpecker images ==="
PULLED=0
PRESENT=0
FAILED_SERVICES=0
CANDIDATE_FAILURES=0
STOPPED=no

for svc in "${ORDER[@]}"; do
  IFS=',' read -r -a refs <<< "${REFS[$svc]}"
  chosen=""
  status="missing"
  imageid=""
  size=0
  digests=""

  say "--- $svc ---"

  for ref in "${refs[@]}"; do
    if contains_forbidden "$ref"; then
      say "[Z4] skip forbidden candidate: $ref"
      continue
    fi
    if podman image exists "$ref" 2>/dev/null; then
      chosen="$ref"
      status="present"
      break
    fi
  done

  if [ "$status" = present ]; then
    PRESENT=$((PRESENT + 1))
    say "[Z4] already present: $chosen"
  else
    for ref in "${refs[@]}"; do
      if contains_forbidden "$ref"; then
        say "[Z4] skip forbidden candidate: $ref"
        continue
      fi

      say "[Z4] pulling candidate: $ref"
      if podman pull --quiet "$ref" >"$TMPD/pull.out" 2>"$TMPD/pull.err"; then
        chosen="$ref"
        status="pulled"
        PULLED=$((PULLED + 1))
        say "[Z4] pulled: $ref"
        break
      else
        CANDIDATE_FAILURES=$((CANDIDATE_FAILURES + 1))
        say "[Z4] candidate failed: $ref"
        tail -n 3 "$TMPD/pull.err" 2>/dev/null | sed 's/^/    /' || true
      fi

      FREE_NOW="$(to_int "$(free_kb /home)")"
      if [ "$FREE_NOW" -lt "$RESERVE_KB" ]; then
        STOPPED=yes
        say "[Z4] disk guard tripped; free=$(kb_to_gib "$FREE_NOW") reserve=$(kb_to_gib "$RESERVE_KB")"
        break
      fi
    done
  fi

  if [ -n "$chosen" ]; then
    imageid="$(norm "$(podman image inspect "$chosen" --format '{{.Id}}' 2>/dev/null || true)")"
    size="$(to_int "$(podman image inspect "$chosen" --format '{{.Size}}' 2>/dev/null || echo 0)")"
    digests="$(norm "$(podman image inspect "$chosen" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null || true)")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$svc" "$status" "$chosen" "$imageid" "$size" "$digests" >> "$MANI_TMP"
    printf '%s\n' "$chosen" >> "$SEL_TMP"
  else
    FAILED_SERVICES=$((FAILED_SERVICES + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$svc" "failed_or_missing" "" "" "0" "" >> "$MANI_TMP"
    say "[Z4] no candidate succeeded for $svc"
  fi

  if [ "$STOPPED" = yes ]; then
    say "[Z4] stopping remaining services due to disk guard"
    break
  fi
done

# ===================== [Z5] write heal manifests and update extra list =====================
say "=== [Z5] write heal manifests ==="
if [ -s "$SEL_TMP" ]; then
  sort -u "$SEL_TMP" > "$TMPD/selected.unique"
else
  : > "$TMPD/selected.unique"
fi

install -D -m 644 "$MANI_TMP" "$MANIFEST_HEAL"
install -D -m 644 "$TMPD/selected.unique" "$SELECTED_HEAL"
say "[Z5] wrote heal manifest -> $MANIFEST_HEAL"
say "[Z5] wrote heal selected list -> $SELECTED_HEAL"

if [ -f "$EXTRA" ] && [ ! -f "$EXTRA.pre-Z.bak" ]; then
  cp -p "$EXTRA" "$EXTRA.pre-Z.bak"
  say "[Z5] backup -> $EXTRA.pre-Z.bak"
fi

touch "$EXTRA"
while read -r ref; do
  if [ -n "$ref" ]; then
    if ! grep -qxF "$ref" "$EXTRA" 2>/dev/null; then
      printf '%s\n' "$ref" >> "$EXTRA"
    fi
  fi
done < "$TMPD/selected.unique"
say "[Z5] updated extra list -> $EXTRA"

# ===================== [Z6] final image inventory =====================
say "=== [Z6] final image inventory ==="
IMG_COUNT_AFTER="$(to_int "$(podman images -aq 2>/dev/null | wc -l)")"
FREE_AFTER="$(to_int "$(free_kb /home)")"
PCT_AFTER="$(norm "$(used_pct /home)")"
print_disk Z6 /home
print_disk Z6 /
say "[Z6] images_after=$IMG_COUNT_AFTER pulled=$PULLED present=$PRESENT failed_services=$FAILED_SERVICES candidate_failures=$CANDIDATE_FAILURES stopped=$STOPPED"
say "[Z6] podman system df:"
podman system df 2>/dev/null | sed 's/^/    /' || true

STATUS="PASS"
if [ "$FAILED_SERVICES" -gt 0 ] || [ "$STOPPED" = "yes" ]; then
  STATUS="PARTIAL"
fi

# ===================== [Z7] guarded ledger row =====================
say "=== [Z7] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | 20261029-Z-woodpecker-image-heal | GATE=$STATUS | $TOKEN: Y used wrong Woodpecker refs; corrected to woodpeckerci/woodpecker-server:v3 and woodpeckerci/woodpecker-agent:v3 with latest fallback. pulled=$PULLED present=$PRESENT failed_services=$FAILED_SERVICES images_after=$IMG_COUNT_AFTER /home_avail_after=$(kb_to_gib "$FREE_AFTER") /home_used_after=${PCT_AFTER:-?}%; no nginx/registry/k3d/k3s/ollama/open-webui pulled; no model loaded; heal_manifest=$MANIFEST_HEAL. |" >> "$IDX"
  say "[Z7] ledger row appended."
else
  say "[Z7] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[Z7] suppression proof: sentinel present." || say "[Z7] WARNING: sentinel missing."

# ===================== [Z8] read-only llama.cpp asset inventory =====================
say "=== [Z8] llama.cpp asset inventory (read-only; no model load) ==="
if [ -x "$LLAMA_SERVER" ]; then
  say "[Z8] llama_server=present path=$LLAMA_SERVER"
  "$LLAMA_SERVER" --version 2>&1 | head -n 5 | sed 's/^/    /' || true
else
  say "[Z8] llama_server=missing path=$LLAMA_SERVER"
fi

say "[Z8] GGUF models under $MODEL_ROOT (top 20 by size):"
find "$MODEL_ROOT" -maxdepth 4 -type f -name '*.gguf' -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n 20 | awk -F'\t' '{printf "    %.2fGiB\t%s\n", $1/1073741824, $2}' || true

say "[Z8] RAM:"
awk '/MemTotal|MemAvailable/ {printf "    %s: %.1fMiB\n", $1, $2/1024}' /proc/meminfo || true

say "[Z8] CPU:"
nproc 2>/dev/null | sed 's/^/    nproc=/' || true
grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/^/    /' || true

if [ "$STATUS" = "PASS" ]; then
  say "[RESULT] WOODPECKER IMAGE HEAL PASS + LLAMA INVENTORY DONE — image cache is now complete for planned non-Ollama services; next brick should be llama.cpp native service, not Ollama."
else
  say "[RESULT] WOODPECKER IMAGE HEAL PARTIAL — see failed_services/stopped above; do not force setup until Woodpecker images are resolved or deliberately skipped."
fi
exit 0
