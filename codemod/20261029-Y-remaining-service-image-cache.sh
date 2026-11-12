#!/usr/bin/env bash
# 20261029-Y — cache remaining service images, excluding ollama/open-webui.
# Goal: download future brick images now, configure later.
# Safety:
#   - no sudo
#   - no secrets echoed
#   - no Ollama models
#   - no ollama image
#   - no open-webui image
#   - disk guard stops if /home free falls below reserve
#   - candidate chains avoid one bad tag killing the batch
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
SELECTED="$CD/image-cache.remaining.selected.list"
MANIFEST="$CD/image-cache.remaining.resolved.tsv"
TOKEN="remaining-service-images-v1"

# Keep at least 12 GiB free on /home after caching.
RESERVE_KB=12582912
# Require at least 16 GiB free before starting this batch.
PRECHECK_MIN_KB=16777216

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
    *ollama*|*open-webui*|*openwebui*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

for c in bash podman df awk sed head tail install grep sort wc; do
  need_cmd "$c"
done

mkdir -p "$CD"

# ===================== [Y0] planned image refs =====================
declare -A REFS

REFS[litellm]="ghcr.io/berriai/litellm:main-latest,ghcr.io/berriai/litellm:latest,docker.io/berriai/litellm:main-latest,docker.io/berriai/litellm:latest"
REFS[n8n]="docker.io/n8nio/n8n:latest"
REFS[grafana]="docker.io/grafana/grafana:latest"
REFS[portainer]="docker.io/portainer/portainer-ce:latest"
REFS[traefik]="docker.io/library/traefik:latest,docker.io/traefik:latest"
REFS[gitea]="docker.io/gitea/gitea:latest"
REFS[woodpecker-server]="quay.io/woodpecker-ci/woodpecker:latest,docker.io/woodpeckerci/server:latest"
REFS[woodpecker-agent]="quay.io/woodpecker-ci/woodpecker:latest,docker.io/woodpeckerci/agent:latest"
REFS[zitadel]="ghcr.io/zitadel/zitadel:latest,docker.io/zitadel/zitadel:latest"

ORDER=(
  litellm
  n8n
  grafana
  portainer
  traefik
  gitea
  woodpecker-server
  woodpecker-agent
  zitadel
)

MANI_TMP="$TMPD/resolved.tsv"
SEL_TMP="$TMPD/selected.list"
printf 'service\tstatus\tchosen_ref\timageid\tsize_bytes\trepodigests\n' > "$MANI_TMP"
: > "$SEL_TMP"

# ===================== [Y1] disk precheck =====================
say "=== [Y1] disk precheck ==="
print_disk Y1 /home
print_disk Y1 /

FREE_BEFORE="$(to_int "$(free_kb /home)")"
PCT_BEFORE="$(norm "$(used_pct /home)")"
say "[Y1] free_before=$(kb_to_gib "$FREE_BEFORE") used_before=${PCT_BEFORE:-?}% reserve_after=$(kb_to_gib "$RESERVE_KB") precheck_min=$(kb_to_gib "$PRECHECK_MIN_KB")"

if [ "$FREE_BEFORE" -lt "$PRECHECK_MIN_KB" ]; then
  halt "insufficient free space before remaining image cache; free=$(kb_to_gib "$FREE_BEFORE") required_at_least=$(kb_to_gib "$PRECHECK_MIN_KB")"
fi

# ===================== [Y2] dry-run plan =====================
if [ "$DRY" = 1 ]; then
  say "=== [Y2] dry-run planned services ==="
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
    say "[Y2-dry] $svc present=${present:-none} candidates=${REFS[$svc]}"
  done
  say "[RESULT] DRY-RUN complete; no image pull, no list install, no ledger row."
  exit 0
fi

# ===================== [Y3] pull/cache loop =====================
say "=== [Y3] cache remaining service images ==="
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

  # First see whether any candidate is already cached.
  for ref in "${refs[@]}"; do
    if contains_forbidden "$ref"; then
      say "[Y3] skip forbidden candidate: $ref"
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
    say "[Y3] already present: $chosen"
  else
    # Pull first working candidate.
    for ref in "${refs[@]}"; do
      if contains_forbidden "$ref"; then
        say "[Y3] skip forbidden candidate: $ref"
        continue
      fi

      say "[Y3] pulling candidate: $ref"
      if podman pull --quiet "$ref" >"$TMPD/pull.out" 2>"$TMPD/pull.err"; then
        chosen="$ref"
        status="pulled"
        PULLED=$((PULLED + 1))
        say "[Y3] pulled: $ref"
        break
      else
        CANDIDATE_FAILURES=$((CANDIDATE_FAILURES + 1))
        say "[Y3] candidate failed: $ref"
        tail -n 3 "$TMPD/pull.err" 2>/dev/null | sed 's/^/    /' || true
      fi

      FREE_NOW="$(to_int "$(free_kb /home)")"
      if [ "$FREE_NOW" -lt "$RESERVE_KB" ]; then
        STOPPED=yes
        say "[Y3] disk guard tripped; free=$(kb_to_gib "$FREE_NOW") reserve=$(kb_to_gib "$RESERVE_KB")"
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
    say "[Y3] no candidate succeeded for $svc"
  fi

  if [ "$STOPPED" = yes ]; then
    say "[Y3] stopping remaining services due to disk guard"
    break
  fi
done

# ===================== [Y4] write manifests and extra list =====================
say "=== [Y4] write manifests ==="
if [ -s "$SEL_TMP" ]; then
  sort -u "$SEL_TMP" > "$TMPD/selected.unique"
else
  : > "$TMPD/selected.unique"
fi

install -D -m 644 "$MANI_TMP" "$MANIFEST"
install -D -m 644 "$TMPD/selected.unique" "$SELECTED"
say "[Y4] wrote manifest -> $MANIFEST"
say "[Y4] wrote selected list -> $SELECTED"

if [ -f "$EXTRA" ] && [ ! -f "$EXTRA.pre-Y.bak" ]; then
  cp -p "$EXTRA" "$EXTRA.pre-Y.bak"
  say "[Y4] backup -> $EXTRA.pre-Y.bak"
fi

touch "$EXTRA"
while read -r ref; do
  if [ -n "$ref" ]; then
    if ! grep -qxF "$ref" "$EXTRA" 2>/dev/null; then
      printf '%s\n' "$ref" >> "$EXTRA"
    fi
  fi
done < "$TMPD/selected.unique"
say "[Y4] updated extra list -> $EXTRA"

# ===================== [Y5] final inventory =====================
say "=== [Y5] final inventory ==="
IMG_COUNT_AFTER="$(to_int "$(podman images -aq 2>/dev/null | wc -l)")"
FREE_AFTER="$(to_int "$(free_kb /home)")"
PCT_AFTER="$(norm "$(used_pct /home)")"
print_disk Y5 /home
print_disk Y5 /
say "[Y5] images_after=$IMG_COUNT_AFTER pulled=$PULLED present=$PRESENT failed_services=$FAILED_SERVICES candidate_failures=$CANDIDATE_FAILURES stopped=$STOPPED"
say "[Y5] podman system df:"
podman system df 2>/dev/null | sed 's/^/    /' || true

STATUS="PASS"
if [ "$FAILED_SERVICES" -gt 0 ] || [ "$STOPPED" = "yes" ]; then
  STATUS="PARTIAL"
fi

# ===================== [Y6] guarded ledger row =====================
say "=== [Y6] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-Y-remaining-service-image-cache | GATE=$STATUS | $TOKEN: services=${#ORDER[@]} pulled=$PULLED present=$PRESENT failed_services=$FAILED_SERVICES candidate_failures=$CANDIDATE_FAILURES stopped=$STOPPED images_after=$IMG_COUNT_AFTER /home_avail_after=$(kb_to_gib "$FREE_AFTER") /home_used_after=${PCT_AFTER:-?}%; excluded ollama/open-webui; no models pulled; selected=$SELECTED manifest=$MANIFEST. |" >> "$IDX"
  say "[Y6] ledger row appended."
else
  say "[Y6] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[Y6] suppression proof: sentinel present." || say "[Y6] WARNING: sentinel missing."

if [ "$STATUS" = "PASS" ]; then
  say "[RESULT] REMAINING SERVICE IMAGES CACHED — next: read-only llama.cpp probe, then LiteLLM brick pointed at llama.cpp; still no Ollama/OpenWebUI/models."
else
  say "[RESULT] REMAINING SERVICE IMAGE CACHE PARTIAL — see failed_services/stopped above; do not force setup until missing images are resolved or deliberately skipped."
fi
exit 0
