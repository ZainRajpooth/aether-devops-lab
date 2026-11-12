# SUPERSEDED-BY-H3/H4: the inline gate below compares mount and PGDATA for exact equality, but postgres 16+ intentionally sets PGDATA to a pgdata subdir of the mount so the mount point can hold lost+found; that equality is a false RED on a healthy cluster. Use codemod/20261029-H3-postgres-gate-recalibrate.sh as the authoritative gate (ancestor + volume-type). Header-only edit; gate logic untouched.
#!/usr/bin/env bash
# 20261029-H2 — diagnose the postgres brick death, then resume it SAFELY (file-run => exit contained).
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
PGINIT="$A/infra/configs/postgres/initdb"; SECRETS="$HOME/.config/aether/secrets.env"
SLUG="20261029-H-postgres"; WIN="-45min"
say(){ printf '  %s\n' "$*"; }
bail(){ printf '[HALT] %s\n' "$*" >&2; exit 2; }            # exits THIS script only (file-run => terminal safe)

# ---------- [D1] artifact fingerprint => where did it die? ----------
HAS_INITDB=$([ -s "$PGINIT/01-provision-n8n.sh" ] && echo y || echo n)
HAS_UNIT=$([ -s "$QD/postgres.container" ] && echo y || echo n)
HAS_RENDERED=$([ -s "$SYS/postgres.container" ] && echo y || echo n)
HAS_VOL=$(podman volume exists postgres_data 2>/dev/null && echo y || echo n)
HAS_CTR=$(podman ps -a --filter name=postgres --format '{{.Names}}' 2>/dev/null | grep -qx postgres && echo y || echo n)
CTR_RUN=$(podman ps --filter name=postgres --format '{{.Status}}' 2>/dev/null || true)
HAS_ROW=$(grep -qF "$SLUG" "$CD/INDEX.md" 2>/dev/null && echo y || echo n)
if   [ "$HAS_CTR" = n ] && [ "$HAS_VOL" = n ] && [ "$HAS_RENDERED" = n ] && [ "$HAS_ROW" = n ]; then DP="S1-pull(pre-stateful)"
elif [ "$HAS_CTR" = n ] && [ "$HAS_VOL" = y ]; then DP="S2/S3(post-vol,pre-ctr)"
elif [ "$HAS_CTR" = y ]; then DP="S4/S5(container-exists run='$CTR_RUN')"
elif [ "$HAS_ROW" = y ]; then DP="S6(gate-wrote-row-then-die)"
else DP="UNKNOWN"; fi
say "[D1] death-point fingerprint: $DP"
say "     initdb=$HAS_INITDB unit=$HAS_UNIT rendered=$HAS_RENDERED vol=$HAS_VOL ctr=$HAS_CTR row=$HAS_ROW"

# ---------- [D2] journal scan => why? (oom / suspend / free-mem) ----------
OOM=$(journalctl -k --since "$WIN" --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | head -n 3 || true)
SUS=$(journalctl   --since "$WIN" --no-pager 2>/dev/null | grep -iE 'suspend|pm-suspend|resuming from|waking up|sleep entered' | head -n 3 || true)
AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
JRN_OK=$([ -n "$OOM$SUS" ] && echo seen || echo "none-seen(journal may be unreadable: $(journalctl --since "$WIN" 2>&1 | head -n1 | cut -c1-40))")
say "[D2] oom-lines: ${OOM:-<none>} | suspend-lines: ${SUS:-<none>} | mem-avail=${AVAIL:-?}MiB | $JRN_OK"
CAUSE="exit-trap(pull-fail)"
[ -n "$OOM" ] && CAUSE="OOM-kill"
[ -z "$OOM" ] && [ -n "$SUS" ] && CAUSE="suspend-mid-fetch(transient)"

# ---------- [D3] image state (atomic store => absent==clean, no partial commit) ----------
I19=$(podman image exists docker.io/library/postgres:19rc1-alpine 2>/dev/null && echo y || echo n)
I17=$(podman image exists docker.io/library/postgres:17-alpine     2>/dev/null && echo y || echo n)
say "[D3] image 19rc1=$I19 17=$I17"

# ---------- incident ledger row (append-only, guarded once) ----------
grep -qF "postgres-pull-death" "$CD/INDEX.md" 2>/dev/null \
 || echo "| $(date +%F) | INCIDENT | postgres-pull-death | DP=$DP CAUSE=$CAUSE | paste-exit trap (regression vs ADR-0002 file-run rule): [S1] pull non-zero -> die -> exit killed login shell -> terminal closed; pre-stateful so NO vol/ctr/cluster (clean). Heal=H2 file-run+retry+artifact-resume. |" >> "$CD/INDEX.md"

# ---------- resume decision matrix ----------
IMG=""; NOTE=""
pick_img(){ [ "$I19" = y ] && { IMG="docker.io/library/postgres:19rc1-alpine"; NOTE="parity(19rc1) present"; }; \
            [ -z "$IMG" ] && [ "$I17" = y ] && { IMG="docker.io/library/postgres:17-alpine"; NOTE="stable(17) present"; }; }
pull_retry(){ # $1=ref ; 3 tries backoff ; prints final stderr verbatim on exhaustion ; returns 0/1
  local ref="$1" n errf=/tmp/pgpull.$$.err
  for n in 1 2 3; do
    if podman pull "$ref" >"$errf" 2>&1; then rm -f "$errf"; return 0; fi
    say "  pull try $n failed for $ref: $(tail -n1 "$errf")"; [ "$n" -lt 3 ] && sleep $((n*8))
  done
  say "  [PULL-EXHAUSTED] last stderr for $ref:"; sed 's/^/    /' "$errf" | head -n 6; rm -f "$errf"; return 1; }

if [ "$CAUSE" = "OOM-kill" ] && [ "$I19" = n ] && [ "$I17" = n ]; then
  bail "OOM seen AND no postgres image => NOT retrying the pull (would OOM-loop). Mitigation: free RAM (temporarily 'systemctl --user stop prometheus mailpit node-exporter' for the pull), or retry when cooler; then re-run H2. Volume/cluster untouched => safe."
fi
pick_img
if [ -z "$IMG" ]; then
  say "[R-pull] fetching postgres (network step isolated, retried)"
  pull_retry docker.io/library/postgres:19rc1-alpine && { IMG="docker.io/library/postgres:19rc1-alpine"; NOTE="parity(19rc1) pulled"; } \
  || { pull_retry docker.io/library/postgres:17-alpine && { IMG="docker.io/library/postgres:17-alpine"; NOTE="FALLBACK stable(17) pulled (parity 19rc1 unavailable)"; } \
       || bail "both postgres refs failed after backoff — see [PULL-EXHAUSTED] stderr above (real cause now visible: DNS/429/reset?). No state mutated."; }
fi
say "[R] image := $IMG  [$NOTE]"

# ensure initdb orphan (idempotent rewrite if missing)
mkdir -p "$PGINIT"
[ -s "$PGINIT/01-provision-n8n.sh" ] || cat > "$PGINIT/01-provision-n8n.sh" <<'INI'
#!/bin/bash
set -euo pipefail
DB="$DB_POSTGRESDB_DATABASE"; U="$DB_POSTGRESDB_USER"; P="$DB_POSTGRESDB_PASSWORD"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1 \
  || psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE DATABASE \"$DB\""
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tc "SELECT 1 FROM pg_roles WHERE rolname='$U'" | grep -q 1 \
  || psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE USER \"$U\" WITH PASSWORD '$P'"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB\" TO \"$U\""
INI
chmod +x "$PGINIT/01-provision-n8n.sh"

# author unit (same disciplined content as the design; EnvironmentFile single-source; no literals; no no-new-privileges on pg)
cat > "$QD/postgres.container" <<U
# STATEFUL brick 1 (resumed by H2 after [S1] paste-exit death). EnvironmentFile=secrets.env (rotation=1-file edit).
# DOCKER_PG_LLVM_DEPS omitted (build-time/inert; inlining re-imports escaping trap). no-new-privileges omitted (breaks root->postgres drop).
[Container]
Image=$IMG
ContainerName=postgres
Network=aether
EnvironmentFile=$SECRETS
Volume=postgres_data:/var/lib/postgresql/data
Volume=$PGINIT:/docker-entrypoint-initdb.d:ro
PublishPort=127.0.0.1:5432:5432

[Service]
Restart=always
TimeoutStartSec=120
MemoryMax=1G
CPUQuota=50%
U

podman volume exists postgres_data 2>/dev/null || podman volume create postgres_data >/dev/null
mkdir -p "$SYS"; install -D -m 644 "$QD/postgres.container" "$SYS/postgres.container"
systemctl --user daemon-reload
systemctl --user enable postgres.service 2>/dev/null || true
systemctl --user start postgres.service
for i in $(seq 1 40); do systemctl --user is-active --quiet postgres.service && break; sleep 2; done

# ---------- six-conjunct gate (identical semantics to the design) ----------
ACT=$(systemctl --user is-active postgres.service 2>/dev/null || echo inactive)
RUN=$(podman ps --filter name=postgres --format '{{.Names}} {{.Status}}' 2>/dev/null || echo none)
READY=$(podman exec postgres sh -c 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" && echo ok || echo no' 2>/dev/null || echo no)
SEL1=$(podman exec postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -h 127.0.0.1 -d "$POSTGRES_DB" -tAc "SELECT 1"' 2>/dev/null || echo ERR)
PGDATA_ENV=$(podman exec postgres sh -c 'printf %s "$PGDATA"' 2>/dev/null || echo '?')
PGVER=$(podman exec postgres sh -c 'test -f "$PGDATA/PG_VERSION" && echo yes || echo no' 2>/dev/null || echo no)
MNT_OK=no; podman inspect postgres --format '{{range .Mounts}}{{.Destination}}{{println}}{{end}}' 2>/dev/null | grep -qx "$PGDATA_ENV" && MNT_OK=yes
N8N=$(podman exec postgres sh -c 'PGPASSWORD="$DB_POSTGRESDB_PASSWORD" psql -U "$DB_POSTGRESDB_USER" -h 127.0.0.1 -d "$DB_POSTGRESDB_DATABASE" -tAc "SELECT current_database()"' 2>/dev/null || echo ERR)
say "[GATE] active=$ACT ready=$READY sel1=$SEL1 PGDATA=$PGDATA_ENV PGVER=$PGVER mount==PGDATA=$MNT_OK n8n=$N8N run=$RUN"
journalctl --user -u postgres.service --no-pager --tail 6 2>/dev/null | sed 's/^/    j: /' || true
PASS=no
{ [ "$ACT" = active ] && [ "$READY" = ok ] && [ "$SEL1" = 1 ] && [ "$PGVER" = yes ] && [ "$MNT_OK" = yes ] && [ "$N8N" != ERR ] && [ -n "$N8N" ]; } && PASS=yes
if [ "$PASS" = yes ]; then
  grep -qF "postgres-resume-pass" "$CD/INDEX.md" 2>/dev/null \
   || echo "| $(date +%F) | B | $SLUG | GATE=PASS (resumed by H2; heals $DP/$CAUSE) | postgres brick1: EnvironmentFile=secrets.env, ceilings 1G/50%, [ABS] vol+initdb, loopback 5432, image=$IMG ($NOTE), n8n db+role provisioned+auth; replay=H2 |" >> "$CD/INDEX.md"
  say "[RESULT] POSTGRES GREEN — spine proven live; stateful tier continues (next: minio)."
else
  say "[RESULT] POSTGRES RED — see [GATE] row. If PGVER=no/MNT_OK=no => vol/initdb path mismatch (clean re-init: stop+volume rm+re-run H2). If n8n=ERR => initdb did not fire (volume not fresh?)."
  say "         (no shell-kill possible here: this is file-run; your terminal survives any branch.)"
fi
