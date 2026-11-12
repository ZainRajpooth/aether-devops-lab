#!/usr/bin/env bash
# 20261029-X — Podman image cache inventory + disk-gated pull.
# Goal: download/cache required images now, configure bricks later.
# Safety:
#   - no sudo
#   - no secrets echoed
#   - no models pulled
#   - no services started beyond existing ones
#   - stops if /home free space drops below reserve
#   - records desired + resolved image manifest for later parity/pinning
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
QD="$A/infra/quadlet"
SYS="$HOME/.config/containers/systemd"
SRC="$A/legacy/compose/recovery-runtime.yml"
IDX="$CD/INDEX.md"
LIST="$CD/image-cache.desired.list"
RESOLVED="$CD/image-cache.resolved.tsv"
EXTRA="$CD/image-cache.extra.list"
TOKEN="podman-image-cache-v1"

# Reserve 10 GiB free on /home after caching.
RESERVE_KB=10485760
PRECHECK_EXTRA_KB=2097152

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
normalize_ref(){
  local ref="$1"
  ref="$(norm "$ref")"
  ref="$(printf '%s' "$ref" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ -z "$ref" ]; then
    printf ''
    return 0
  fi

  ref="${ref%\"}"
  ref="${ref#\"}"

  case "$ref" in
    '<none>'|none|None|'<no value>')
      printf ''
      return 0
      ;;
  esac

  # Keep digest refs as-is. Standing rule: never synthesize @image-id pulls.
  if [[ "$ref" == *@* ]]; then
    printf '%s' "$ref"
    return 0
  fi

  # Add :latest if no tag is present.
  local last="${ref##*/}"
  if [[ "$last" != *:* ]]; then
    ref="$ref:latest"
  fi

  # Expand Docker Hub short names deterministically.
  if [[ "$ref" == */* ]]; then
    local first="${ref%%/*}"
    if [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then
      printf '%s' "$ref"
    else
      printf 'docker.io/%s' "$ref"
    fi
  else
    printf 'docker.io/library/%s' "$ref"
  fi
}

declare -A SEEN=()
DESIRED=()

consider_ref(){
  local raw="$1"
  local ref
  ref="$(normalize_ref "$raw")"
  if [ -z "$ref" ]; then
    return 0
  fi
  if [ -n "${SEEN[$ref]:-}" ]; then
    return 0
  fi
  SEEN["$ref"]=1
  DESIRED+=("$ref")
}

total_image_bytes(){
  local total=0
  local id size
  while read -r id; do
    if [ -z "$id" ]; then
      continue
    fi
    size="$(to_int "$(podman image inspect "$id" --format '{{.Size}}' 2>/dev/null || echo 0)")"
    total=$((total + size))
  done < <(podman images -aq 2>/dev/null || true)
  printf '%s' "$total"
}

need_cmd bash
need_cmd podman
need_cmd df
need_cmd awk
need_cmd sed
need_cmd find
need_cmd xargs
need_cmd sort
need_cmd wc
need_cmd tail
need_cmd head
need_cmd install
need_cmd grep

mkdir -p "$CD" "$QD"

# ===================== [X0] current inventory =====================
say "=== [X0] current Podman image inventory ==="
IMG_COUNT_BEFORE="$(to_int "$(podman images -aq 2>/dev/null | wc -l)")"
CONTAINER_COUNT="$(to_int "$(podman ps -a -q 2>/dev/null | wc -l)")"
RUNNING_COUNT="$(to_int "$(podman ps -q 2>/dev/null | wc -l)")"
TOTAL_BYTES_BEFORE="$(to_int "$(total_image_bytes)")"
FREE_BEFORE="$(to_int "$(free_kb /home)")"
PCT_BEFORE="$(norm "$(used_pct /home)")"

say "[X0] images_total=$IMG_COUNT_BEFORE containers_total=$CONTAINER_COUNT containers_running=$RUNNING_COUNT"
say "[X0] image_bytes_total=$(bytes_to_gib "$TOTAL_BYTES_BEFORE") /home_avail=$(kb_to_gib "$FREE_BEFORE") /home_used=${PCT_BEFORE:-?}%"
say "[X0] podman system df:"
podman system df 2>/dev/null | sed 's/^/    /' || true

# ===================== [X1] build desired image list =====================
say "=== [X1] build desired image list ==="

# From existing containers, including stopped ones.
while read -r ref; do
  consider_ref "$ref"
done < <(podman ps -a --format '{{.Image}}' 2>/dev/null || true)

# From authored Quadlet sources.
if [ -d "$QD" ]; then
  while read -r ref; do
    consider_ref "$ref"
  done < <(find "$QD" -maxdepth 1 -type f -name '*.container' -print0 2>/dev/null | xargs -0 -r awk -F= '/^Image=/{print $2}' 2>/dev/null || true)
fi

# From rendered user Quadlet sources.
if [ -d "$SYS" ]; then
  while read -r ref; do
    consider_ref "$ref"
  done < <(find "$SYS" -maxdepth 1 -type f -name '*.container' -print0 2>/dev/null | xargs -0 -r awk -F= '/^Image=/{print $2}' 2>/dev/null || true)
fi

# From captured compose blueprint.
if [ -f "$SRC" ]; then
  while read -r ref; do
    consider_ref "$ref"
  done < <(awk '
/^[[:space:]]*image:/ {
  sub(/^[[:space:]]*image:[[:space:]]*/, "")
  sub(/[[:space:]#].*$/, "")
  print
}
' "$SRC" 2>/dev/null | tr -d '"' || true)
fi

# Optional manually curated extra images. One ref per line, # comments allowed.
if [ -f "$EXTRA" ]; then
  while read -r ref; do
    consider_ref "$ref"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$EXTRA" 2>/dev/null | tr -d '"' || true)
  say "[X1] included extra list: $EXTRA"
else
  say "[X1] no extra list present: $EXTRA"
fi

if [ "${#DESIRED[@]}" -gt 0 ]; then
  printf '%s\n' "${DESIRED[@]}" | sort -u > "$TMPD/desired.list"
else
  : > "$TMPD/desired.list"
fi

DESired_COUNT="$(to_int "$(wc -l < "$TMPD/desired.list")")"
say "[X1] desired_images=$DESired_COUNT"

# ===================== [X2] missing images =====================
say "=== [X2] resolve missing images ==="
MISSING=()
if [ -s "$TMPD/desired.list" ]; then
  while read -r ref; do
    if ! podman image exists "$ref" 2>/dev/null; then
      MISSING+=("$ref")
    fi
  done < "$TMPD/desired.list"
fi

MISSING_COUNT="${#MISSING[@]}"
say "[X2] missing_images=$MISSING_COUNT"

print_disk X2 /home
print_disk X2 /

if [ "$DRY" = 1 ]; then
  say "[X2-dry] desired list:"
  sed 's/^/    /' "$TMPD/desired.list" || true
  say "[X2-dry] missing list:"
  if [ "$MISSING_COUNT" -gt 0 ]; then
    printf '%s\n' "${MISSING[@]}" | sed 's/^/    /' || true
  else
    say "    none"
  fi
  say "[RESULT] DRY-RUN complete; no image pull, no list install, no ledger row."
  exit 0
fi

install -D -m 644 "$TMPD/desired.list" "$LIST"
say "[X2] wrote desired list -> $LIST"

# ===================== [X3] disk precheck =====================
say "=== [X3] disk precheck ==="
MIN_START_KB=$((RESERVE_KB + PRECHECK_EXTRA_KB))
say "[X3] reserve_after_kb=$RESERVE_KB precheck_min_kb=$MIN_START_KB current_free_kb=$FREE_BEFORE"
if [ "$FREE_BEFORE" -lt "$MIN_START_KB" ]; then
  halt "insufficient free space before image caching; free=$(kb_to_gib "$FREE_BEFORE") required_at_least=$(kb_to_gib "$MIN_START_KB")"
fi

# ===================== [X4] pull missing images =====================
say "=== [X4] pull missing images ==="
PULLED=0
ERRORS=0
STOPPED=no
PULLED_BYTES=0

if [ "$MISSING_COUNT" -gt 0 ]; then
  for ref in "${MISSING[@]}"; do
    say "[X4] pulling $ref"
    if podman pull --quiet "$ref" >"$TMPD/pull.id" 2>"$TMPD/pull.err"; then
      ID="$(norm "$(head -n1 "$TMPD/pull.id" 2>/dev/null || true)")"
      SIZE="$(to_int "$(podman image inspect "$ID" --format '{{.Size}}' 2>/dev/null || echo 0)")"
      PULLED=$((PULLED + 1))
      PULLED_BYTES=$((PULLED_BYTES + SIZE))
      say "[X4] pulled ref=$ref id=${ID:0:19} size=$(bytes_to_gib "$SIZE")"
    else
      ERRORS=$((ERRORS + 1))
      say "[X4] pull failed ref=$ref"
      tail -n 5 "$TMPD/pull.err" 2>/dev/null | sed 's/^/    /' || true
    fi

    FREE_NOW="$(to_int "$(free_kb /home)")"
    if [ "$FREE_NOW" -lt "$RESERVE_KB" ]; then
      STOPPED=yes
      say "[X4] disk guard tripped after this image; free=$(kb_to_gib "$FREE_NOW") reserve=$(kb_to_gib "$RESERVE_KB")"
      break
    fi
  done
else
  say "[X4] no missing images; nothing to pull"
fi

# ===================== [X5] resolved manifest =====================
say "=== [X5] write resolved image manifest ==="
RESOLVED_TMP="$TMPD/resolved.tsv"
printf 'ref\timageid\tsize_bytes\trepodigests\n' > "$RESOLVED_TMP"

if [ -s "$TMPD/desired.list" ]; then
  while read -r ref; do
    if podman image exists "$ref" 2>/dev/null; then
      ID="$(norm "$(podman image inspect "$ref" --format '{{.Id}}' 2>/dev/null || true)")"
      SIZE="$(to_int "$(podman image inspect "$ref" --format '{{.Size}}' 2>/dev/null || echo 0)")"
      DIGS="$(norm "$(podman image inspect "$ref" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null || true)")"
    else
      ID="missing"
      SIZE="0"
      DIGS=""
    fi
    printf '%s\t%s\t%s\t%s\n' "$ref" "$ID" "$SIZE" "$DIGS" >> "$RESOLVED_TMP"
  done < "$TMPD/desired.list"
fi

install -D -m 644 "$RESOLVED_TMP" "$RESOLVED"
say "[X5] wrote resolved manifest -> $RESOLVED"

# ===================== [X6] final inventory =====================
say "=== [X6] final inventory ==="
IMG_COUNT_AFTER="$(to_int "$(podman images -aq 2>/dev/null | wc -l)")"
TOTAL_BYTES_AFTER="$(to_int "$(total_image_bytes)")"
FREE_AFTER="$(to_int "$(free_kb /home)")"
PCT_AFTER="$(norm "$(used_pct /home)")"

say "[X6] images_before=$IMG_COUNT_BEFORE images_after=$IMG_COUNT_AFTER"
say "[X6] pulled=$PULLED errors=$ERRORS stopped=$STOPPED pulled_bytes=$(bytes_to_gib "$PULLED_BYTES")"
say "[X6] image_bytes_total=$(bytes_to_gib "$TOTAL_BYTES_AFTER") /home_avail=$(kb_to_gib "$FREE_AFTER") /home_used=${PCT_AFTER:-?}%"
say "[X6] podman system df:"
podman system df 2>/dev/null | sed 's/^/    /' || true

STATUS="PASS"
if [ "$ERRORS" -gt 0 ] || [ "$STOPPED" = "yes" ]; then
  STATUS="PARTIAL"
fi

# ===================== [X7] guarded ledger row =====================
say "=== [X7] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | 20261029-X-podman-image-cache | GATE=$STATUS | $TOKEN: desired=$DESired_COUNT missing=$MISSING_COUNT pulled=$PULLED errors=$ERRORS stopped=$STOPPED images_before=$IMG_COUNT_BEFORE images_after=$IMG_COUNT_AFTER image_bytes_total=$(bytes_to_gib "$TOTAL_BYTES_AFTER") /home_avail_after=$(kb_to_gib "$FREE_AFTER") /home_used_after=${PCT_AFTER:-?}%; cached images only, no models pulled, no new services configured; resolved manifest=$RESOLVED desired list=$LIST. |" >> "$IDX"
  say "[X7] ledger row appended."
else
  say "[X7] ledger row already present (guard suppressed)."
fi
grep -qF "$TOKEN" "$IDX" 2>/dev/null && say "[X7] suppression proof: sentinel present." || say "[X7] WARNING: sentinel missing."

if [ "$STATUS" = "PASS" ]; then
  say "[RESULT] PODMAN IMAGE CACHE GREEN — required cached images are present or newly pulled; disk remains above reserve; next can proceed brick-by-brick setup, still no ollama models until DR gate clears."
else
  say "[RESULT] PODMAN IMAGE CACHE PARTIAL — see errors/stopped above; do not force setup until missing images are resolved or deliberately skipped."
fi
exit 0
