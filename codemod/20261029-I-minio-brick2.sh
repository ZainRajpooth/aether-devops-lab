#!/usr/bin/env bash
# 20261029-I — minio brick 2. Lessons ENCODED from line 1: guard-sentinel-in-payload (+in-run proof),
# ancestor+volume-type persist, preflight BOTH minio keys, parity-first image chain w/ loud substitution,
# loopback host-publish (net-hostname for internal), NO bucket-namespace pollution, EnvironmentFile spine.
# File-run => every halt/exit is contained; terminal cannot close. exit 0 on ALL branches.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
SECRETS="$HOME/.config/aether/secrets.env"; IDX="$CD/INDEX.md"
SLUG="20261029-I-minio"; SENTINEL="minio brick2 GREEN"   # MUST appear in the payload echo below (H5 rule)
DATAPATH="/data"                                          # minio export dir (mount dest; buckets are subdirs)
say(){ printf '  %s\n' "$*"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }          # contained: prints + exits THIS file only

# [M0] preflight: BOTH minio keys present & non-empty in the spine (desync trap guard)
U=$([ -f "$SECRETS" ] && grep -c '^MINIO_ROOT_USER=.'  "$SECRETS" 2>/dev/null || echo 0)
P=$([ -f "$SECRETS" ] && grep -c '^MINIO_ROOT_PASSWORD=.' "$SECRETS" 2>/dev/null || echo 0)
say "[M0] secrets.env minio keys: USER_present=$U PASSWORD_present=$P"
[ "$U" -ge 1 ] || halt "MINIO_ROOT_USER absent/empty in secrets.env -> bitnami would default it to 'minioadmin' and DESYNC from the captured password. Add the real access key to secrets.env first. minio NOT started (no state mutated)."
[ "$P" -ge 1 ] || halt "MINIO_ROOT_PASSWORD absent/empty in secrets.env. minio NOT started."

# [M1] resolve image: parity-first chain, verbatim stderr per failure, winner recorded
REFS=( "docker.io/bitnamilegacy/minio:latest" "docker.io/bitnami/minio:latest" "docker.io/minio/minio:latest" )
IMG=""; NOTE=""; ERRLOG=""
for ref in "${REFS[@]}"; do
  if podman pull "$ref" >/tmp/mp.$$ 2>&1; then IMG="$ref"; break
  else last=$(tail -n1 /tmp/mp.$$); ERRLOG+="  [$ref] $last"$'\n'; say "  pull failed $ref -> $last"; fi
done; rm -f /tmp/mp.$$
[ -n "$IMG" ] || { printf '%s' "$ERRLOG" | sed 's/^/    /'; halt "all minio refs failed (registry/network outage?) — see stderr above; no state mutated."; }
case "$IMG" in
  *bitnamilegacy*) NOTE="parity ref (captured tag)";;
  *bitnami/minio*)  NOTE="SUBSTITUTION: captured 'bitnamilegacy' unavailable -> bitnami lineage (same CLI contract)";;
  *minio/minio*)    NOTE="SUBSTITUTION: bitnami lineage unavailable -> official minio (gate is ref-agnostic)";;
esac
say "[M1] image := $IMG  [$NOTE]"

# [M2] author unit (no Exec: let image ENTRYPOINT/CMD run; loopback publish; ceilings; spine via EnvironmentFile)
cat > "$QD/minio.container" <<UNIT
# STATEFUL brick 2 (minio). Secrets via EnvironmentFile=secrets.env (single-source spine; rotation=1-file edit).
# Image: $IMG  ($NOTE). No Exec set -> image default entrypoint/CMD runs (server /data, console :9001).
# Host-publish is LOOPBACK-only (secure perimeter); traefik/n8n reach minio over the 'aether' net by hostname
#   minio:9000, unaffected by the loopback host bind. Override for LAN console: change 127.0.0.1: -> 0.0.0.0: (not advised; route via traefik+zitadel auth instead).
# Object/S3 semantics NOT probed here (a stray file in /data pollutes the bucket namespace) -> proven at Lane-A.
# Known debt: EnvironmentFile injects ALL spine keys (env-spread); proper fix = podman secret + Secret= (queued post-green).
[Container]
Image=$IMG
ContainerName=minio
Network=aether
EnvironmentFile=$SECRETS
Volume=minio_data:$DATAPATH
PublishPort=127.0.0.1:9010:9000
PublishPort=127.0.0.1:9011:9001

[Service]
Restart=always
TimeoutStartSec=120
MemoryMax=1G
CPUQuota=50%
UNIT
say "[M2] wrote $QD/minio.container"

# [M3] ensure data volume (idempotent)
podman volume exists minio_data 2>/dev/null || podman volume create minio_data >/dev/null
podman volume exists minio_data && say "[M3] volume minio_data present" || halt "volume create failed"

# [M4] render (COPY) -> reload -> enable -> start; bounded wait
mkdir -p "$SYS"; install -D -m 644 "$QD/minio.container" "$SYS/minio.container"
systemctl --user daemon-reload
systemctl --user enable minio.service 2>/dev/null || true
systemctl --user start minio.service
for i in $(seq 1 40); do systemctl --user is-active --quiet minio.service && break; sleep 2; done

# [M5] LOUD GATE (aggregate; hard-fail PRINTED not shell-killed)
ACT=$(systemctl --user is-active minio.service 2>/dev/null || echo inactive)
RUN=$(podman ps --filter name=minio --format '{{.Names}} {{.Status}}' 2>/dev/null || echo none)
API=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:9010/minio/health/live 2>/dev/null || echo 000)
CON=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:9011/ 2>/dev/null || echo 000)
# ancestor-or-exact + type=volume persistence proof (universal predicate; target=DATAPATH)
PERSIST=no; PMATCH=""
while read -r typ dest; do
  [ -z "${dest:-}" ] && continue
  case "$DATAPATH" in "$dest"|"$dest"/*) if [ "$typ" = volume ] || [ "$typ" = bind ]; then PERSIST=yes; PMATCH="$typ at $dest"; fi ;; esac
done < <(podman inspect minio --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>/dev/null)
say "[M5] active=$ACT run=$RUN api_live=$API console=$CON persist=$PERSIST match=$PMATCH"
journalctl --user -u minio.service --no-pager --tail 6 2>/dev/null | sed 's/^/    j: /' || true
PASS=no
{ [ "$ACT" = active ] && [ "$API" = 200 ] && { [ "$CON" = 200 ] || [ "$CON" = 302 ]; } && [ "$PERSIST" = yes ]; } && PASS=yes

# [M6] ledger append GUARDED by sentinel that IS in the payload (H5 rule) + in-run suppression proof
if [ "$PASS" = yes ]; then
  if ! grep -qF "$SENTINEL" "$IDX" 2>/dev/null; then
    echo "| $(date +%F) | B | $SLUG | GATE=PASS | $SENTINEL: live container, api+console healthy, data on named volume (ancestor+volume-type), loopback 9010/9011, image=$IMG ($NOTE), keys preflighted both-present; object-semantics deferred to Lane-A; replay=$SLUG.sh |" >> "$IDX"
    say "[M6] green row appended (sentinel-in-payload)."
  else say "[M6] green row already present (guard suppressed re-run)."; fi
  # in-run proof the guard WORKS (measure, don't claim):
  grep -qF "$SENTINEL" "$IDX" 2>/dev/null && say "[M6] suppression proof: '$SENTINEL' present in INDEX => re-run takes suppress branch." || say "[M6] WARNING: sentinel not in INDEX — guard may not suppress; inspect."
else
  say "[M6] gate RED -> NO green row written (no partial ledger). Read [M5]: api!=200 => minio not serving (check j: lines / image CMD); console!=200/302 => console port/path; persist=no => volume not mounted at $DATAPATH."
fi

# [M7] archive replayable record (idempotent: ensure vol + re-render + re-start + re-gate)
cat > "$CD/${SLUG}.sh" <<REPLAY
#!/usr/bin/env bash
# 20261029-I-minio-brick2.sh — replayable from a green engine: ensure vol, render/start, gate. Idempotent.
set -uo pipefail
A="\$HOME/DevOps/aether"; QD="\$A/infra/quadlet"; SYS="\$HOME/.config/containers/systemd"
podman volume exists minio_data 2>/dev/null || podman volume create minio_data >/dev/null
install -D -m 644 "\$QD/minio.container" "\$SYS/minio.container"
systemctl --user daemon-reload; systemctl --user enable minio.service 2>/dev/null||true; systemctl --user start minio.service
for i in \$(seq 1 40); do systemctl --user is-active --quiet minio.service && break; sleep 2; done
API=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:9010/minio/health/live)
CON=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:9011/)
{ [ "\$API" = 200 ] && { [ "\$CON" = 200 ] || [ "\$CON" = 302 ]; }; } && echo "  [GATE PASS] minio" || { echo "  [GATE FAIL] api=\$API console=\$CON"; exit 1; }
REPLAY
chmod +x "$CD/${SLUG}.sh"
say "[M7] archived -> codemod/${SLUG}.sh"

[ "$PASS" = yes ] && say "[RESULT] MINIO GREEN (brick 2) — spine feeds a 2nd stateful unit; next: weaviate (then redis, ollama, litellm, n8n...)." \
  || say "[RESULT] MINIO RED — see [M5]/[M6]; do NOT advance (tier is sequential). Inspect j: lines first; clean re-init only if volume/mount mismatch confirmed."
exit 0
