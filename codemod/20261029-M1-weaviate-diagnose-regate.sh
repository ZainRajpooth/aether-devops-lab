#!/usr/bin/env bash
# 20261029-M1 — weaviate brick3 RED heal: READ-ONLY on runtime+systemd (no restart/pull/render/reload/volume-rm).
# Fixes L's two owned defects: (1) missing readiness poll (curled at Up 1s => ready=000 timing race, the J1 class
# not carried forward), (2) parity NOTE mislabelled digest-pull fail as 'registry GC' when the real cause is
# lock.running_id = IMAGE ID (config digest), NOT a pullable manifest digest (RepoDigests) => 'manifest schema
# unsupported'. Polls ready up to 90s recording the code SEQUENCE (000->503->200 = healthy bind proof), detects
# crash-loop via StartedAt change, captures logs. Green => guarded sentinel-in-payload row + in-run suppression
# proof + replay regenerated WITH poll + corrected parity comment + L header marked. exit 0 on EVERY branch.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
IDX="$CD/INDEX.md"; REPLAY="$CD/20261029-L-weaviate.sh"; LSCRIPT="$CD/20261029-L-weaviate-brick3.sh"
SLUG="20261029-L-weaviate"; LEDGER_TOKEN="weaviate brick3 GREEN"          # MUST be in the green payload echo (H5)
IMGID_TOKEN="image-id-not-manifest-digest"                                # general correction sentinel
LMARK="DEFECTS-HEALED-BY-M1"
DDATA="/var/lib/weaviate"                                                 # from L/[W0] (spine-known)
say(){ printf '  %s\n' "$*"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }                          # contained, file-run
hc(){ curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || true; }   # NO ||echo (000000 class)

# [V0] read-only snapshot (status / exit / restarts / startedAt / ports / image)
ST=$(podman inspect weaviate --format '{{.State.Status}}' 2>/dev/null || echo absent)
EX=$(podman inspect weaviate --format '{{.State.ExitCode}}' 2>/dev/null || echo '?')
S0=$(podman inspect weaviate --format '{{.State.StartedAt}}' 2>/dev/null || echo '?')
RC=$(podman inspect weaviate --format '{{.State.RestartCount}}' 2>/dev/null || echo '?')
PORTS=$(podman port weaviate 2>/dev/null | tr '\n' ' ' || echo '?')
IMG=$(podman inspect weaviate --format '{{.Config.Image}}' 2>/dev/null || echo '?')
say "[V0] status=$ST exit=$EX restarts=$RC startedAt=$S0 image=$IMG"
say "     ports: $PORTS"
[ "$ST" = absent ] && halt "container 'weaviate' absent — unit never started; inspect 'systemctl --user status weaviate' then re-run L. No state to poll."

# [V1] readiness poll (<=90s) recording the code SEQUENCE + crash detection via StartedAt change
READY=""; READY_SEQ=""; ITER=0; CRASH=no; GREEN_ITER=0
for i in $(seq 1 30); do
  ITER=$i
  S1=$(podman inspect weaviate --format '{{.State.StartedAt}}' 2>/dev/null || echo '?')
  if [ "$S1" != "$S0" ] && [ "$S1" != '?' ]; then CRASH=yes; say "  [V1] restart detected at iter $i ($S0 -> $S1) => crash-loop"; break; fi
  ST1=$(podman inspect weaviate --format '{{.State.Status}}' 2>/dev/null || echo '?')
  READY=$(hc http://127.0.0.1:8080/v1/.well-known/ready); [ -z "$READY" ] && READY=000
  READY_SEQ+="$READY "
  if [ "$READY" = 200 ]; then GREEN_ITER=$i; break; fi
  [ "$ST1" = exited ] && { CRASH=yes; say "  [V1] status flipped to exited at iter $i (exit=$EX)"; break; }
  sleep 3
done
say "[V1] poll done: iter=$ITER green_iter=$GREEN_ITER crash=$CRASH ready_seq=[$READY_SEQ] final=$READY"

# [V2] evidence (read-only, always)
say "[V2] --- podman logs weaviate (tail 40) ---"
podman logs --tail 40 weaviate 2>&1 | sed 's/^/    /' || true
ENVN=$(podman exec weaviate sh -c 'printenv' 2>/dev/null | grep -cE '^(WEAVIATE_|AUTHENTICATION_|PERSISTENCE_|QUERY_)' || echo 0)
say "[V2] weaviate-relevant env keys injected (count, no values): $ENVN"

# [V3] corrected parity statement (computed, not asserted) — image-id vs manifest-digest
PARITY_NOTE="L/[W1] attempted docker.io/semitechnologies/weaviate@\$SHA (the lock's running_id). That value is the container IMAGE ID (config-blob digest from docker inspect {{.Image}}), NOT a pullable manifest digest (those live in RepoDigests, which the reconstruct generator never captured). Pulling @<image-id> yields 'manifest schema unsupported' because podman fetches the config blob and rejects it as a manifest. Therefore true digest-parity for the captured build is UNRECOVERABLE from surviving artifacts; the running_ref was the moving tag ':latest', so ':latest' is the only pullable parity and is newer than the captured build by definition. L's NOTE mislabelled this as 'registry GC'."
say "[V3] parity correction: $PARITY_NOTE"

# [V4] decision
if [ "$CRASH" = yes ] || { [ "$EX" != 0 ] && [ "$EX" != '?' ]; }; then
  halt "crash-loop / non-zero exit (exit=$EX restarts=$RC ready_seq=[$READY_SEQ]). Evidence in [V2] logs. NOT auto-patching (B13/7). Likely cause: weaviate ':latest' (newer than captured) config-incompat with the captured env, OR a module/auth key renamed across versions. Factual options (pick on your word, none guessed now): (a) pin a recent KNOWN-GOOD version tag instead of :latest; (b) adapt secrets.env to :latest's expected keys (read [V2]); (c) defer weaviate and author a lighter store (Qdrant per udpate.md) — a pivot, held to word. Runtime untouched."
fi
if [ "$READY" != 200 ]; then
  halt "ready never reached 200 within 90s (ready_seq=[$READY_SEQ], status=$ST, no restart). If seq is flat 000 => HTTP server never bound (config/CMD/env fatal — read [V2]); if stuck 503 => weaviate up but not ready (module/index init — read [V2]). Paste [V2] and I disambiguate from evidence. Runtime untouched."
fi

# ---- ready=200 => steel-thread GREEN (console/schema are INFO) ----
SCHEMA=$(hc -H "Authorization: Bearer $(grep '^WEAVIATE_API_KEY=' "$HOME/.config/aether/secrets.env" 2>/dev/null | cut -d= -f2-)" http://127.0.0.1:8080/v1/schema); [ -z "$SCHEMA" ] && SCHEMA=000
AUTHINFO="key-valid(Lane-A ready)"; [ "$SCHEMA" = 200 ] || { [ "$SCHEMA" = 401 ] && AUTHINFO="up+auth-enforced but WEAVIATE_API_KEY not in allowed list -> one-line secrets.env fix (NOT echoed)"; [ "$SCHEMA" = 000 ] && AUTHINFO="anomalous (ready=200 but schema 000)"; }
PERSIST=no; PMATCH=""
while read -r typ dest; do
  [ -z "${dest:-}" ] && continue
  case "$DDATA" in "$dest"|"$dest"/*) if [ "$typ" = volume ] || [ "$typ" = bind ]; then PERSIST=yes; PMATCH="$typ at $dest"; fi ;; esac
done < <(podman inspect weaviate --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>/dev/null)
ACT=$(systemctl --user is-active weaviate.service 2>/dev/null || echo inactive)
say "[V4] active=$ACT ready=200(at iter $GREEN_ITER) ready_seq=[$READY_SEQ] schema=$SCHEMA($AUTHINFO) persist=$PERSIST match=$PMATCH DATA=$DDATA"
PASS=no; { [ "$ACT" = active ] && [ "$READY" = 200 ] && [ "$PERSIST" = yes ]; } && PASS=yes
[ "$PASS" = yes ] || halt "ready=200 but gate conjuncts failed (active=$ACT persist=$PERSIST) — inspect [V4]; not writing green row."

# [V5] general correction ledger row (image-id != manifest-digest), guarded sentinel-in-payload
if ! grep -qF "$IMGID_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $IMGID_TOKEN | APPEND-ONLY | Reconstruct generator captured docker inspect {{.Image}} = IMAGE ID (config digest) into images.lock.tsv running_id; that is NOT a pullable manifest digest (RepoDigests, never captured). So @<running_id> pulls fail 'manifest schema unsupported', and digest-parity for any :latest-captured service is unrecoverable -> use running_ref tag or accept :latest drift; NEVER attempt @<image-id> pulls. Found at weaviate brick3 (L/[W1]); L's NOTE mislabelled the cause as registry GC. |" >> "$IDX"
  say "[V5] image-id correction row appended."
else say "[V5] image-id correction row already present."; fi
grep -qF "$IMGID_TOKEN" "$IDX" 2>/dev/null && say "[V5] suppression proof: '$IMGID_TOKEN' present." || say "[V5] WARNING: sentinel missing."

# [V6] weaviate green row, guarded sentinel-in-payload + in-run suppression proof (H5 rule)
if ! grep -qF "$LEDGER_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | $SLUG | GATE=PASS(M1 regate) | $LEDGER_TOKEN: ready=200 at iter $GREEN_ITER (ready_seq=[$READY_SEQ] = healthy bind progression, heals L's missing-poll false-RED), schema=$SCHEMA ($AUTHINFO), data on named volume (ancestor+volume-type, DATA=$DDATA), loopback 8080, image=$IMG, keys preflighted; RAM ceiling 2G (EliteBook constraint); parity note corrected: lock.running_id is an IMAGE ID not a manifest digest so :latest is the only pullable parity (newer than captured by design of a moving tag); schema-write/Lane-A roundtrip deferred; replay regenerated WITH poll. |" >> "$IDX"
  say "[V6] green row appended (sentinel-in-payload)."
else say "[V6] green row already present (guard suppressed re-run)."; fi
grep -qF "$LEDGER_TOKEN" "$IDX" 2>/dev/null && say "[V6] suppression proof: '$LEDGER_TOKEN' present => re-run takes suppress branch." || say "[V6] WARNING: sentinel missing — guard may not suppress."

# [V7] regenerate replay WITH readiness poll + corrected parity comment (B1 safety copy first)
if [ -f "$REPLAY" ]; then cp -p "$REPLAY" "$REPLAY.pre-M1.bak" && say "[V7] backup -> $(basename "$REPLAY").pre-M1.bak"; fi
cat > "$REPLAY" <<'REPLAY'
#!/usr/bin/env bash
# 20261029-L-weaviate-brick3.sh — replayable, POLL-CORRECTED (M1). Gate = ready(unauth) 200; schema(INFO).
# Parity note (M1): lock.running_id is an IMAGE ID (config digest), NOT a pullable manifest digest; for a
#   :latest-captured service the only pullable parity is :latest (newer than captured by design). Do NOT
#   attempt @<image-id> pulls (=> 'manifest schema unsupported'). Volume pairs read from the source unit.
set -uo pipefail
A="$HOME/DevOps/aether"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
hc(){ curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || true; }
while IFS=: read -r nm d; do [ -z "$nm" ] && continue; podman volume exists "$nm" 2>/dev/null || podman volume create "$nm" >/dev/null; done < <(grep '^Volume=' "$QD/weaviate.container" | sed 's/^Volume=//')
install -D -m 644 "$QD/weaviate.container" "$SYS/weaviate.container"
systemctl --user daemon-reload; systemctl --user enable weaviate.service 2>/dev/null||true; systemctl --user start weaviate.service
R=""; SEQ=""
for i in $(seq 1 30); do R=$(hc http://127.0.0.1:8080/v1/.well-known/ready); [ -z "$R" ] && R=000; SEQ+="$R "; [ "$R" = 200 ] && break; sleep 3; done
[ "$R" = 200 ] && echo "  [GATE PASS] weaviate ready=200 seq=[$SEQ]" || { echo "  [GATE FAIL] ready=$R seq=[$SEQ]"; exit 1; }
REPLAY
chmod +x "$REPLAY"; say "[V7] replay regenerated w/ 90s poll + corrected parity comment"

# [V8] mark defective L script header-only (do not rewrite its logic; K4 pattern via python to avoid sed '/' traps)
if [ -f "$LSCRIPT" ] && ! grep -qF "$LMARK" "$LSCRIPT"; then
  HDRF="/tmp/aether-l-header.$$.txt"
  printf '%s\n' "# $LMARK: L had two owned defects, healed by M1 (read-only regate). (1) No readiness poll: waited on is-active then curled once => false RED at 'Up 1 second' (the J1/minio class not carried forward). (2) Parity NOTE mislabelled the digest-pull fail as 'registry GC'; real cause = lock.running_id is an IMAGE ID (config digest), not a pullable manifest digest (RepoDigests) => 'manifest schema unsupported'; :latest is the only pullable parity for a :latest-captured service. Use codemod/20261029-M1-weaviate-diagnose-regate.sh + the regenerated 20261029-L-weaviate.sh (with poll) as authoritative. Header-only; L logic untouched." > "$HDRF"
  python3 - "$LSCRIPT" "$HDRF" <<'PY'
import sys, os, tempfile
p, hdrf = sys.argv[1], sys.argv[2]
hdr = open(hdrf, encoding='utf-8').read()
with open(p, encoding='utf-8') as f: lines = f.read().splitlines(keepends=True)
lines.insert(0, hdr)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p) or '.', prefix='.l-weaviate.', text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f: f.write(''.join(lines))
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
  rm -f "$HDRF"; say "[V8] L marked defective-healed (header only)."
else say "[V8] L already marked or absent."; fi

say "[RESULT] WEAVIATE GREEN (brick 3, regated by M1) — ready=200 (seq=[$READY_SEQ]), L's two defects owned+healed read-only, parity corrected, replay poll-fixed; next: redis (then ollama, litellm, n8n...)."
exit 0
