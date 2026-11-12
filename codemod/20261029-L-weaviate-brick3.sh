# DEFECTS-HEALED-BY-M1: L had two owned defects, healed by M1 (read-only regate). (1) No readiness poll: waited on is-active then curled once => false RED at 'Up 1 second' (the J1/minio class not carried forward). (2) Parity NOTE mislabelled the digest-pull fail as 'registry GC'; real cause = lock.running_id is an IMAGE ID (config digest), not a pullable manifest digest (RepoDigests) => 'manifest schema unsupported'; :latest is the only pullable parity for a :latest-captured service. Use codemod/20261029-M1-weaviate-diagnose-regate.sh + the regenerated 20261029-L-weaviate.sh (with poll) as authoritative. Header-only; L logic untouched.
#!/usr/bin/env bash
# 20261029-L — weaviate brick 3. Lessons ENCODED from line 1: parity=captured-digest-from-lock -> :latest
# (loud), tight MemoryMax + measured MemAvailable echo, ready(unauth)=steel-thread / schema(key)=INFO,
# data-dest from spine + backups-dest best-effort-from-capture, guard-sentinel-in-payload (+in-run proof),
# ancestor+volume-type persist, NO schema write (Lane-A deferred), EnvironmentFile spine, file-run exit 0.
# Supports --check (B7): preflight + parity exists-check + unit preview to /tmp; NO pull/volume/render/start.
set -uo pipefail
DRY=0; [ "${1:-}" = "--check" ] && { DRY=1; shift; }
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; IDX="$CD/INDEX.md"
LOCK="$A/legacy/compose/images.lock.tsv"; SRC="$A/legacy/compose/recovery-runtime.yml"
SLUG="20261029-L-weaviate"; LEDGER_TOKEN="weaviate brick3 GREEN"   # MUST be in the payload echo (H5 rule)
say(){ printf '  %s\n' "$*"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }                    # contained, file-run
hc(){ curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@" 2>/dev/null || true; }   # NO ||echo (000000 class)

# [W0] preflight spine keys + measured RAM headroom (constraint ingestion, visible)
WKEY=$(grep '^WEAVIATE_API_KEY=' "$SECRETS" 2>/dev/null | cut -d= -f2- || true)
ALLOWED=$(grep '^AUTHENTICATION_APIKEY_ALLOWED_KEYS=' "$SECRETS" 2>/dev/null | cut -d= -f2- || true)
DDATA=$(grep '^PERSISTENCE_DATA_PATH=' "$SECRETS" 2>/dev/null | cut -d= -f2- || true)
[ -n "$DDATA" ] || DDATA="/var/lib/weaviate"   # fallback, WARNed below
MEMAVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
say "[W0] WEAVIATE_API_KEY_present=$([ -n "$WKEY" ]&&echo y||echo n) ALLOWED_present=$([ -n "$ALLOWED" ]&&echo y||echo n) DATA_DEST=$DDATA MemAvailable=${MEMAVAIL:-?}MiB"
[ -n "$WKEY" ] || halt "WEAVIATE_API_KEY absent/empty in secrets.env -> weaviate auth would mis-configure. Add it (single-source edit) first. weaviate NOT started (no state mutated)."
[ -n "$ALLOWED" ] || say "[W0] WARN: AUTHENTICATION_APIKEY_ALLOWED_KEYS empty -> weaviate may reject all keys (schema probe will 401); fix in secrets.env if Lane-A needs 200."
[ "$(grep '^PERSISTENCE_DATA_PATH=' "$SECRETS" 2>/dev/null)" ] || say "[W0] WARN: PERSISTENCE_DATA_PATH not in spine; using fallback $DDATA (recorded, not guessed-from-nothing)."

# [W1] parity resolve: captured digest (from lock) -> :latest, loud substitution
DIGEST=$(awk -F'\t' '$1=="weaviate"{print $3; exit}' "$LOCK" 2>/dev/null || true)
CHAIN=()
[ -n "$DIGEST" ] && CHAIN+=("docker.io/semitechnologies/weaviate@$DIGEST")
CHAIN+=("docker.io/semitechnologies/weaviate:latest")
IMG=""; NOTE=""
if [ "$DRY" = 1 ]; then
  for r in "${CHAIN[@]}"; do say "[W1-dry] image exists? $r -> $(podman image exists "$r" 2>/dev/null && echo yes || echo no)"; done
  say "[W1-dry] would pull first-missing in chain order (digest parity first, :latest fallback)."
  IMG="(dry: not pulled)"; NOTE="dry-run"
else
  for r in "${CHAIN[@]}"; do
    if podman pull "$r" >/tmp/wv.$$ 2>&1; then IMG="$r"; break
    else say "  pull failed $r -> $(tail -n1 /tmp/wv.$$)"; fi
  done; rm -f /tmp/wv.$$
  [ -n "$IMG" ] || halt "no weaviate ref pullable (digest+:latest both failed) — see stderr above; no state mutated."
  if [ -n "$DIGEST" ] && [ "$IMG" = "docker.io/semitechnologies/weaviate@$DIGEST" ]; then
    NOTE="parity: captured digest (fidelity to the image that actually ran; full digest recovered from images.lock.tsv)"
  elif [ -n "$DIGEST" ]; then
    NOTE="SUBSTITUTION: captured digest $DIGEST not pullable (registry GC) -> :latest (DRIFT: newer than captured; contract re-proven by gate)"
  else
    NOTE="captured digest unrecoverable from lock -> :latest"
  fi
  say "[W1] image := $IMG  [$NOTE]"
fi

# [W2] volume name:dest pairs — data from spine (DDATA), extras best-effort from capture (B13: no invented dests)
VOLPAIRS=$(python3 - "$SRC" "$DDATA" <<'PY'
import sys,re,os
src,ddata=sys.argv[1],sys.argv[2]
TL=re.compile(r'^"?([A-Za-z_]+)"?:\s*$')
SVC=re.compile(r'^  "?([A-Za-z0-9_.-]+)"?:\s*$')
SUB=re.compile(r'^    "?([A-Za-z_]+)"?:\s*$')
IT =re.compile(r'^\s+- "?([^"]+)"?\s*$')
def tlk(l):
    m=TL.match(l); return m.group(1) if m else None
cur=None; sub=None; in_wv=False; dests=[]
for raw in open(src):
    l=raw.rstrip('\n'); k=tlk(l)
    if k=='services': in_wv=False; cur=None; sub=None; continue
    if k: in_wv=False
    sm=SVC.match(l)
    if sm:
        cur=sm.group(1); sub=None; in_wv=(cur=='weaviate'); continue
    if not in_wv: continue
    sb=SUB.match(l)
    if sb: sub=sb.group(1); continue
    it=IT.match(l)
    if it and sub=='volumes':
        d=it.group(1).split(':',1)[1] if ':' in it.group(1) else ''
        if d.startswith('/'): dests.append(d)
seen=set(); out=[]
# data first (the spine-known dest), then extras
for d in dests:
    if d==ddata and d not in seen: seen.add(d); out.append(('weaviate_data',d))
n=0
for d in dests:
    if d in seen: continue
    seen.add(d); n+=1
    nm='weaviate_backups' if ('backup' in d.lower()) else f'weaviate_vol_{n}'
    out.append((nm,d))
if not any(nm=='weaviate_data' for nm,_ in out):
    out.insert(0,('weaviate_data',ddata))   # guarantee the steel-thread data mount
for nm,d in out: print(f'{nm}:{d}')
PY
)
say "[W2] volume pairs:"; printf '%s\n' "$VOLPAIRS" | sed 's/^/    /'
VOLLINES=$(printf '%s\n' "$VOLPAIRS" | sed 's/^/Volume=/')

# [W3] author unit (dry -> /tmp preview; real -> source unit). No Exec (image CMD runs weaviate serve).
UNIT_BODY="# STATEFUL brick 3 (weaviate). Secrets via EnvironmentFile=secrets.env (single-source spine).
# Image: $IMG  ($NOTE). No Exec -> image default runs 'weaviate serve' on :8080.
# Host-publish LOOPBACK-only; n8n/traefik reach weaviate over 'aether' net by hostname weaviate:8080.
# MemoryMax=2G = EliteBook constraint (udpate.md: weaviate heavy; runs module-less so 2G is a firm safe cap).
# NO schema write / test collection here (would pollute weaviate namespace) -> Lane-A roundtrip deferred.
# Known debt: EnvironmentFile injects ALL spine keys (env-spread); podman secret+Secret= refactor post-green.
[Container]
Image=$IMG
ContainerName=weaviate
Network=aether
EnvironmentFile=$SECRETS
$VOLLINES
PublishPort=127.0.0.1:8080:8080

[Service]
Restart=always
TimeoutStartSec=120
MemoryMax=2G
CPUQuota=50%"
if [ "$DRY" = 1 ]; then
  PV="/tmp/weaviate.unit.$$.preview"; printf '%s\n' "$UNIT_BODY" > "$PV"
  say "[W3-dry] unit preview -> $PV (NOT written to $QD; NOT rendered/started):"; sed 's/^/    /' "$PV"; rm -f "$PV"
  say "[RESULT] DRY-RUN complete; no pull/volume/render/start/ledger. Re-run without --check to build brick 3."
  exit 0
fi
UNIT="$QD/weaviate.container"; [ -f "$UNIT" ] && cp -p "$UNIT" "$UNIT.pre-L.bak"
printf '%s\n' "$UNIT_BODY" > "$UNIT"; say "[W3] wrote $UNIT (safety copy $(basename "$UNIT").pre-L.bak if prior existed)"

# [W4] ensure volumes (one per pair), render, reload, enable, start, bounded wait
while IFS=: read -r nm d; do
  [ -z "$nm" ] && continue
  podman volume exists "$nm" 2>/dev/null || podman volume create "$nm" >/dev/null
done <<< "$VOLPAIRS"
mkdir -p "$SYS"; install -D -m 644 "$UNIT" "$SYS/weaviate.container"
systemctl --user daemon-reload
systemctl --user enable weaviate.service 2>/dev/null || true
systemctl --user start weaviate.service
for i in $(seq 1 60); do systemctl --user is-active --quiet weaviate.service && break; sleep 2; done

# [W5] LOUD GATE: active + ready(unauth,steel) + schema(key,INFO) + persist(ancestor+volume-type)
ACT=$(systemctl --user is-active weaviate.service 2>/dev/null || echo inactive)
RUN=$(podman ps --filter name=weaviate --format '{{.Names}} {{.Status}}' 2>/dev/null || echo none)
READY=$(hc http://127.0.0.1:8080/v1/.well-known/ready); [ -z "$READY" ] && READY=000
SCHEMA=$(hc -H "Authorization: Bearer $WKEY" http://127.0.0.1:8080/v1/schema); [ -z "$SCHEMA" ] && SCHEMA=000
PERSIST=no; PMATCH=""
while read -r typ dest; do
  [ -z "${dest:-}" ] && continue
  case "$DDATA" in "$dest"|"$dest"/*) if [ "$typ" = volume ] || [ "$typ" = bind ]; then PERSIST=yes; PMATCH="$typ at $dest"; fi ;; esac
done < <(podman inspect weaviate --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>/dev/null)
AUTHINFO="key-valid(Lane-A ready)"; [ "$SCHEMA" = 200 ] || { [ "$SCHEMA" = 401 ] && AUTHINFO="up+auth-enforced but WEAVIATE_API_KEY not in allowed list -> one-line secrets.env fix (NOT echoed)"; [ "$SCHEMA" = 000 ] && AUTHINFO="anomalous (ready=$READY but schema 000)"; }
say "[W5] active=$ACT run=$RUN ready=$READY schema=$SCHEMA($AUTHINFO) persist=$PERSIST match=$PMATCH DATA=$DDATA"
journalctl --user -u weaviate.service --no-pager --tail 8 2>/dev/null | sed 's/^/    j: /' || true
PASS=no; { [ "$ACT" = active ] && [ "$READY" = 200 ] && [ "$PERSIST" = yes ]; } && PASS=yes

# [W6] ledger (green only): guarded sentinel-in-payload + in-run suppression proof (H5 rule)
if [ "$PASS" = yes ]; then
  if ! grep -qF "$LEDGER_TOKEN" "$IDX" 2>/dev/null; then
    echo "| $(date +%F) | B | $SLUG | GATE=PASS | $LEDGER_TOKEN: ready(unauth)=200 steel-thread, schema(key)=$SCHEMA ($AUTHINFO), data on named volume (ancestor+volume-type, DATA=$DDATA), loopback 8080, image=$IMG ($NOTE), keys preflighted; RAM ceiling 2G (EliteBook constraint, MemAvailable=${MEMAVAIL:-?}MiB at start); schema-write/Lane-A roundtrip deferred; replay=$SLUG.sh |" >> "$IDX"
    say "[W6] green row appended (sentinel-in-payload)."
  else say "[W6] green row already present (guard suppressed re-run)."; fi
  grep -qF "$LEDGER_TOKEN" "$IDX" 2>/dev/null && say "[W6] suppression proof: '$LEDGER_TOKEN' present => re-run takes suppress branch." || say "[W6] WARNING: sentinel missing — guard may not suppress."
else
  say "[W6] gate RED -> NO green row. Read [W5]: ready!=200 => weaviate not serving (j: lines / image CMD / env); persist=no => data volume not ancestor of $DDATA; active!=active => start failed (j: lines)."
fi

# [W7] replay archive (idempotent: ensure vols + re-render + re-start + re-gate; parity ref frozen in unit)
cat > "$CD/${SLUG}.sh" <<REPLAY
#!/usr/bin/env bash
# 20261029-L-weaviate-brick3.sh — replayable from a green engine: ensure vols, render/start, gate. Idempotent.
set -uo pipefail
A="\$HOME/DevOps/aether"; QD="\$A/infra/quadlet"; SYS="\$HOME/.config/containers/systemd"
hc(){ curl -s -o /dev/null -w '%{http_code}' --max-time 6 "\$@" 2>/dev/null || true; }
while IFS=: read -r nm d; do [ -z "\$nm" ] && continue; podman volume exists "\$nm" 2>/dev/null || podman volume create "\$nm" >/dev/null; done < <(grep '^Volume=' "\$QD/weaviate.container" | sed 's/^Volume=//')
install -D -m 644 "\$QD/weaviate.container" "\$SYS/weaviate.container"
systemctl --user daemon-reload; systemctl --user enable weaviate.service 2>/dev/null||true; systemctl --user start weaviate.service
for i in \$(seq 1 60); do systemctl --user is-active --quiet weaviate.service && break; sleep 2; done
R=\$(hc http://127.0.0.1:8080/v1/.well-known/ready)
[ "\$R" = 200 ] && echo "  [GATE PASS] weaviate ready=200" || { echo "  [GATE FAIL] ready=\$R"; exit 1; }
REPLAY
chmod +x "$CD/${SLUG}.sh"; say "[W7] archived -> codemod/${SLUG}.sh"

[ "$PASS" = yes ] && say "[RESULT] WEAVIATE GREEN (brick 3) — spine feeds a 3rd stateful unit, RAM-capped, auth posture measured; next: redis (then ollama, litellm, n8n...)." \
  || say "[RESULT] WEAVIATE RED — see [W5]/[W6]; do NOT advance (tier sequential). Inspect j: lines first; clean re-init only if volume/mount mismatch confirmed."
exit 0
