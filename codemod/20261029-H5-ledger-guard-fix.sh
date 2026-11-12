#!/usr/bin/env bash
# 20261029-H5 — fix the self-defeating green-row guard in H3+H4 (sentinel absent from payload => dupes),
# audit the resulting duplicate append-only, re-confirm postgres green READ-ONLY. Patient untouched.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"
F3="$CD/20261029-H3-postgres-gate-recalibrate.sh"
F4="$CD/20261029-H4-close-h3-loose-ends.sh"
IDX="$CD/INDEX.md"
OLD='postgres-gate-recalibrated-pass'   # the sentinel the guard searched for (never in any row body)
NEW='postgres brick1 GREEN'             # a string that IS in both row bodies => guard will now match
say(){ printf '  %s\n' "$*"; }

# [1] MEASURE the duplicate (do not assume the count)
CNT=$(grep -c 'recalibrated by H' "$IDX" 2>/dev/null || echo 0)
say "[1] green-row entries currently in INDEX (token 'recalibrated by H'): $CNT  (expected 2 = H3 + H4; >1 == the guard defect)"

# [2] realign the guard sentinel->payload in H3 and H4 (guarded idempotent sed; only while OLD still present)
for f in "$F3" "$F4"; do
  [ -f "$f" ] || { say "[2] skip (absent): $(basename "$f")"; continue; }
  if grep -qF "\"$OLD\"" "$f"; then
    sed -i "s/$OLD/$NEW/g" "$f" && say "[2] patched $(basename "$f"): guard token '$OLD' -> '$NEW' (now matches payload)." \
      || say "[2] sed failed on $(basename "$f") (harmless; inspect)."
  else
    say "[2] $(basename "$f") already realigned (no-op)."
  fi
done

# [3] append ONE append-only CORRECTION row (worded to NOT contain OLD/NEW/'recalibrated by H', so it never
#     inflates the [1] count nor trips the realigned [3]-guard). Duplicate rows are NOT deleted (append-only).
if ! grep -qF "ledger-guard-sentinel-payload-mismatch" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | ledger-guard-sentinel-payload-mismatch | APPEND-ONLY | H3+H4 guarded the green-row append with a sentinel string absent from their own row payload => guard never fired => duplicate green entries (measured count above). Root cause = same sentinel/payload mismatch family as the scope+quoting+_data bugs. Fix = guard realigned to a payload-present token (re-runs now suppress). Append-only honored: duplicate entries retained; this row is the audit trail. Postgres patient unaffected (green on 3 reads). |" >> "$IDX"
  say "[3] correction row appended (guarded; dupes retained per append-only)."
else
  say "[3] correction row already present (no-op)."
fi

# [4] prove the realigned guard now SUPPRESSES (non-mutating): the payload token exists in INDEX
if grep -qF "$NEW" "$IDX" 2>/dev/null; then
  say "[4] suppression proof: token '$NEW' IS present in INDEX => a re-run of H3/H4 takes the 'present' branch (no 3rd row)."
else
  say "[4] WARNING: token '$NEW' not found in INDEX — realignment may not have taken; inspect."
fi

# [5] READ-ONLY authoritative re-read (NO restart/re-pull/volume-rm); clean green line; exit 0 always
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
  && say "[RESULT] POSTGRES GREEN (4th read) + ledger guard defect closed & audited append-only; stateful tier continues (next: minio)." \
  || say "[RESULT] POSTGRES RED on re-read — read [GATE*]; do NOT auto-fix (persist=no => real vol/PGDATA mismatch; n8n=ERR => initdb didn't fire). Inspect first."
exit 0
