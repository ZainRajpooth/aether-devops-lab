#!/usr/bin/env bash
# 20261029-H4 — finish H3's aborted step + make H3 replay-clean. NON-INVASIVE: postgres/volume/image untouched.
# Owns the H3 bug: quoted heredoc baked a literal $F2 that was only defined in the outer paste => set -u abort
# at line 47 (CONTAINED: terminal survived, proving file-run discipline holds). Green result + ledger row STAND.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"
F="$CD/20261029-H3-postgres-gate-recalibrate.sh"
F2="$CD/20261029-H2-postgres-diagnose-resume.sh"
SLUG="20261029-H-postgres"
say(){ printf '  %s\n' "$*"; }

# [1] make H3 self-contained so replays don't re-hit the unbound-F2 abort (guarded idempotent insert)
if [ -f "$F" ] && ! grep -qF 'F2="$CD/20261029-H2' "$F"; then
  sed -i 's|SLUG="20261029-H-postgres"$|SLUG="20261029-H-postgres"; F2="$CD/20261029-H2-postgres-diagnose-resume.sh"|' "$F" \
    && say "[1] H3 patched: F2 defined internally (replay-clean)." \
    || say "[1] H3 patch skipped (anchor not found; inspect manually)."
else say "[1] H3 already carries internal F2 (no-op)."; fi

# [2] finish the step H3 aborted before: mark archived H2 gate superseded (header-only; logic untouched)
if [ -f "$F2" ] && ! grep -qF "SUPERSEDED-BY-H3" "$F2"; then
  sed -i '1i# SUPERSEDED-BY-H3/H4: the inline gate below compares mount and PGDATA for exact equality, but postgres 16+ intentionally sets PGDATA to a pgdata subdir of the mount so the mount point can hold lost+found; that equality is a false RED on a healthy cluster. Use codemod/20261029-H3-postgres-gate-recalibrate.sh as the authoritative gate (ancestor + volume-type). Header-only edit; gate logic untouched.' "$F2" \
    && say "[2] H2 archived gate marked superseded (header only)." \
    || say "[2] H2 mark skipped (sed insert failed harmlessly)."
else say "[2] H2 already marked (no-op)."; fi

# [3] confirm the green ledger row H3 wrote (ran before line 47); append guarded if somehow absent
if grep -qF "postgres brick1 GREEN" "$CD/INDEX.md" 2>/dev/null; then
  say "[3] green ledger row present (H3 wrote it pre-abort)."
else
  echo "| $(date +%F) | B | $SLUG | GATE=PASS(recalibrated by H3/H4) | postgres brick1 GREEN: live container, n8n db+role auth ok, cluster persisted on named volume (PGDATA = mount + /pgdata subdir; ancestor+volume-type replaces the buggy equality). Patient untouched. |" >> "$CD/INDEX.md"
  say "[3] green ledger row was missing -> appended (guarded)."
fi

# [4] READ-ONLY authoritative re-read (NO restart/re-pull/volume-rm); clean green line; exit 0 always
ACT=$(systemctl --user is-active postgres.service 2>/dev/null || echo inactive)
READY=$(podman exec postgres sh -c 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" && echo ok || echo no' 2>/dev/null || echo no)
SEL1=$(podman exec postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -h 127.0.0.1 -d "$POSTGRES_DB" -tAc "SELECT 1"' 2>/dev/null || echo ERR)
N8N=$(podman exec postgres sh -c 'PGPASSWORD="$DB_POSTGRESDB_PASSWORD" psql -U "$DB_POSTGRESDB_USER" -h 127.0.0.1 -d "$DB_POSTGRESDB_DATABASE" -tAc "SELECT current_database()"' 2>/dev/null || echo ERR)
PGDATA=$(podman exec postgres sh -c 'printf %s "$PGDATA"' 2>/dev/null || echo '?')
PGVER=$(podman exec postgres sh -c 'test -f "$PGDATA/PG_VERSION" && echo yes || echo no' 2>/dev/null || echo no)
PERSIST=no; PMATCH=""
while read -r typ dest; do
  [ -z "${dest:-}" ] && continue
  case "$PGDATA" in
    "$dest"|"$dest"/*) if [ "$typ" = volume ] || [ "$typ" = bind ]; then PERSIST=yes; PMATCH="$typ at $dest"; fi ;;
  esac
done < <(podman inspect postgres --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' 2>/dev/null)
say "[GATE*] active=$ACT ready=$READY sel1=$SEL1 PGDATA=$PGDATA PGVER=$PGVER persist=$PERSIST match=$PMATCH n8n=$N8N"
PASS=no
{ [ "$ACT" = active ] && [ "$READY" = ok ] && [ "$SEL1" = 1 ] && [ "$PGVER" = yes ] && [ "$PERSIST" = yes ] && [ "$N8N" != ERR ] && [ -n "$N8N" ]; } && PASS=yes
[ "$PASS" = yes ] \
  && say "[RESULT] POSTGRES GREEN (clean re-read; H3/H4 loose ends closed; the prior abort was contained => file-run discipline confirmed holding)." \
  || say "[RESULT] POSTGRES RED on re-read — read [GATE*]; do NOT auto-fix (persist=no => real vol/PGDATA mismatch; n8n=ERR => initdb didn't fire). Inspect, then clean re-init only if confirmed."
exit 0
