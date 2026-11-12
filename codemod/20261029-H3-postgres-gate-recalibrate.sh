#!/usr/bin/env bash
# 20261029-H3 — RECALIBRATE the postgres gate (instrument fix; patient untouched).
# Old predicate asserted mount == PGDATA (exact). postgres 16+ sets PGDATA = mount + /pgdata subdir
# by design (mount pt may hold lost+found). Correct proof = mount is an ANCESTOR of PGDATA AND type=volume.
# Does NOT restart / re-pull / rm-volume: postgres is already Up and serving (per H2 [GATE]).
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; SLUG="20261029-H-postgres"; F2="$CD/20261029-H2-postgres-diagnose-resume.sh"
say(){ printf '  %s\n' "$*"; }

# defensive: ensure running (it is; no-op if so)
systemctl --user is-active --quiet postgres.service 2>/dev/null \
  || { systemctl --user start postgres.service 2>/dev/null || true; for i in $(seq 1 30); do systemctl --user is-active --quiet postgres.service && break; sleep 2; done; }

ACT=$(systemctl --user is-active postgres.service 2>/dev/null || echo inactive)
READY=$(podman exec postgres sh -c 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" && echo ok || echo no' 2>/dev/null || echo no)
SEL1=$(podman exec postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -h 127.0.0.1 -d "$POSTGRES_DB" -tAc "SELECT 1"' 2>/dev/null || echo ERR)
N8N=$(podman exec postgres sh -c 'PGPASSWORD="$DB_POSTGRESDB_PASSWORD" psql -U "$DB_POSTGRESDB_USER" -h 127.0.0.1 -d "$DB_POSTGRESDB_DATABASE" -tAc "SELECT current_database()"' 2>/dev/null || echo ERR)
PGDATA=$(podman exec postgres sh -c 'printf %s "$PGDATA"' 2>/dev/null || echo '?')
PGVER=$(podman exec postgres sh -c 'test -f "$PGDATA/PG_VERSION" && echo yes || echo no' 2>/dev/null || echo no)

# CORRECT persistence predicate: a mount whose Destination is an ancestor of PGDATA, of type volume/bind
PERSIST=no; PMATCH=""
while read -r typ dest; do
  [ -z "${dest:-}" ] && continue
  case "$PGDATA" in
    "$dest"|"$dest"/*)
      if [ "$typ" = volume ] || [ "$typ" = bind ]; then PERSIST=yes; PMATCH="$typ at $dest"; fi ;;
  esac
done < <(podman inspect postgres --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>/dev/null)

say "[GATE*] active=$ACT ready=$READY sel1=$SEL1 PGDATA=$PGDATA PGVER=$PGVER persist(ancestor+type)=$PERSIST match=$PMATCH n8n=$N8N"
say "        recalibration: old gate asserted mount equals PGDATA; postgres 16+ sets PGDATA to a pgdata subdir of the mount (so the mount point can hold lost+found). Equality was the bug; ancestor + volume-type is the correct persistence proof."

PASS=no
{ [ "$ACT" = active ] && [ "$READY" = ok ] && [ "$SEL1" = 1 ] && [ "$PGVER" = yes ] && [ "$PERSIST" = yes ] && [ "$N8N" != ERR ] && [ -n "$N8N" ]; } && PASS=yes

if [ "$PASS" = yes ]; then
  grep -qF "postgres brick1 GREEN" "$CD/INDEX.md" 2>/dev/null \
   || echo "| $(date +%F) | B | $SLUG | GATE=PASS(recalibrated by H3) | postgres brick1 GREEN: live container, n8n db+role auth ok, cluster persisted on named volume (PGDATA = mount + /pgdata subdir; ancestor+volume-type replaces the buggy equality). Patient untouched — no restart/re-pull/volume-rm; only the measuring stick was recalibrated. |" >> "$CD/INDEX.md"
  say "[RESULT] POSTGRES GREEN (recalibrated gate) — spine proven live; stateful tier continues (next: minio)."
else
  say "[RESULT] POSTGRES STILL RED — read [GATE*]. persist=no => data volume is NOT an ancestor of PGDATA (real mismatch: clean re-init = stop + volume rm + re-run H2). n8n=ERR => initdb did not fire (volume not fresh?). Else recheck active/ready/sel1."
  say "         (file-run: your terminal survives this branch too.)"
fi

# mark the superseded H2 inline gate (header-only; logic untouched to avoid a new quoting-bug class in an archived record)
if [ -f "$F2" ] && ! grep -qF "SUPERSEDED-BY-H3" "$F2"; then
  sed -i '1i# SUPERSEDED-BY-H3: the inline gate below compares mount and PGDATA for exact equality, but postgres 16+ intentionally sets PGDATA to a pgdata subdir of the mount so the mount point can hold lost+found; that equality is a false RED on a healthy cluster. Use codemod/20261029-H3-postgres-gate-recalibrate.sh as the authoritative gate (ancestor + volume-type). Header-only edit; gate logic left untouched to avoid introducing a new quoting-bug class into an archived record.' "$F2" \
    && say "[NOTE] H2 archived gate marked superseded-by-H3 (header only)." \
    || say "[NOTE] H2 mark skipped (sed insert failed harmlessly; H3 remains authoritative)."
fi
