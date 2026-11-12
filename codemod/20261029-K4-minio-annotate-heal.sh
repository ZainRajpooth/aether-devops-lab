#!/usr/bin/env bash
# 20261029-K4 — heal J2 [K4] annotation failure. READ-ONLY on runtime/systemd.
# Fixes: (1) sed '/' delimiter collision with anchor containing '/', (2) NOTE missing leading '#'.
# Writes only: infra/quadlet/minio.container (comment), codemod/INDEX.md (guarded row), J2 header mark.
# Supports --check dry-run (B7). exit 0 on every branch.
set -uo pipefail
DRY=0
if [ "${1:-}" = "--check" ]; then DRY=1; shift; fi

A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"
UNIT="$QD/minio.container"
IDX="$CD/INDEX.md"
J2="$CD/20261029-J2-minio-console-placement.sh"
BAK="$UNIT.pre-J2.bak"
MARKER="CONSOLE-PLACEMENT(J2-probe)"
ANCHOR="Object/S3 semantics NOT probed here"
LEDGER_TOKEN="minio brick2 annotate-healed"
J2MARK="DEFECT-HEALED-BY-K4"
say(){ printf '  %s\n' "$*"; }
hc_body(){ curl -s -o "$2" -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }

# [N1] re-measure console placement read-only
RF="/tmp/aether-minio-root.$$.body"
LIVE=$(hc_body http://127.0.0.1:9010/minio/health/live "$RF"); : >"$RF"
RDY=$(hc_body  http://127.0.0.1:9010/minio/health/ready "$RF"); : >"$RF"
ROOT=$(hc_body http://127.0.0.1:9010/ "$RF")
IMG=$(podman inspect minio --format '{{.Config.Image}}' 2>/dev/null || echo '?')
say "[N1] live=$LIVE ready=$RDY root=$ROOT image=$IMG"

PLACE="UNKNOWN"; DETAIL="console placement unconfirmed by 9010-root probe."
if grep -qiE '<\?xml|<Error|AccessDenied|<ListAllMyBuckets' "$RF"; then
  PLACE="UI_ABSENT"
  DETAIL="9010/ answers as the S3 endpoint (XML/AccessDenied); web console NOT co-served; 9011 not listening."
elif [ "$ROOT" = 200 ] && grep -qiE '<html|<title|console|MinIO' "$RF"; then
  PLACE="UI_ON_API"
  DETAIL="9010/ returns HTML; web console co-served on API port 9000 (host 9010); 9011->9001 publish unused."
fi
rm -f "$RF"
say "[N1] console placement := $PLACE ($DETAIL)"

case "$PLACE" in
  UI_ON_API)
    NOTE="# $MARKER: web console co-served on API port 9000 (host 9010) per measured 9010/ HTML; 9011->9001 publish unused and harmless. Do NOT override Exec to force a split console: J1 logs show Bitnami first-run mc setup (bg start, mc alias, stop, restart) that Exec would bypass. Console later only via supported env verified in docs, never guessed. live=$LIVE ready=$RDY root=$ROOT image=$IMG."
    ;;
  UI_ABSENT)
    NOTE="# $MARKER: 9010/ answers as S3 endpoint (root=$ROOT, XML/AccessDenied); web console NOT co-served; 9011 not listening. S3 API green (live=$LIVE ready=$RDY) is the steel thread and is all Lane-A needs. Do NOT override Exec (would bypass J1 first-run mc setup). Console, if wanted later, via supported env verified in docs, not guessed. image=$IMG."
    ;;
  *)
    NOTE="# $MARKER: console placement unconfirmed (live=$LIVE ready=$RDY root=$ROOT). S3 API steel thread governs. Do NOT override Exec (would bypass J1 first-run mc setup); revisit console via supported env verified in docs. image=$IMG."
    ;;
esac

NOTE_FILE="/tmp/aether-minio-note.$$.txt"
printf '%s\n' "$NOTE" > "$NOTE_FILE"

# [N2] Python patcher: substring-anchor, comment-prefixed, atomic, idempotent, --check capable
python3 - "$UNIT" "$ANCHOR" "$MARKER" "$NOTE_FILE" "$BAK" "$DRY" <<'PY'
import sys, os, difflib, tempfile, shutil
unit, anchor, marker, notefile, bak, dry = sys.argv[1:7]
dry = (dry == "1")

if not os.path.isfile(unit):
    print("  [N2] ABORT: unit missing; untouched."); sys.exit(0)

with open(unit, "r", encoding="utf-8") as f:
    text = f.read()

if marker in text:
    print("  [N2] unit already annotated (no-op)."); sys.exit(0)

lines = text.splitlines(keepends=True)
idx = next((i for i, l in enumerate(lines) if anchor in l), None)
if idx is None:
    print(f"  [N2] ABORT: anchor not found; unit untouched. anchor={anchor!r}"); sys.exit(0)

note = open(notefile, encoding="utf-8").read().rstrip("\n")
if not note.startswith("#"):
    note = "# " + note

new_lines = lines[:]
new_lines.insert(idx + 1, note + "\n")

if dry:
    print("  [N2-dry] proposed diff (no write):")
    for d in difflib.unified_diff(lines, new_lines, fromfile=unit, tofile=unit + ".proposed", lineterm=""):
        print("    " + d.rstrip("\n"))
    sys.exit(0)

if not os.path.isfile(bak):
    shutil.copy2(unit, bak)
    print(f"  [N2] safety copy created -> {os.path.basename(bak)}")
else:
    print(f"  [N2] using existing safety copy -> {os.path.basename(bak)}")

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(unit) or ".", prefix=".minio.container.", text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("".join(new_lines))
    os.replace(tmp, unit)
    print("  [N2] unit annotated via Python (comment-prefixed, anchor-substring, atomic).")
except Exception as e:
    if os.path.exists(tmp):
        os.unlink(tmp)
    print(f"  [N2] ABORT write failed: {e}; temp cleaned.")
sys.exit(0)
PY
rm -f "$NOTE_FILE"

if [ "$DRY" = 1 ]; then
  say "[RESULT] DRY-RUN complete; no files changed."
  exit 0
fi

# [N3] annotation gate
ANNOT=no
if grep -qF "$MARKER" "$UNIT" 2>/dev/null; then
  LINE=$(grep -F "$MARKER" "$UNIT" | head -n1)
  if [[ "$LINE" == '#'* ]] && grep -qF "$ANCHOR" "$UNIT"; then
    ANNOT=yes
    say "[N3] annotation gate OK (marker present, comment-prefixed, anchor intact)."
  else
    say "[N3] annotation gate BAD: inserted line is not a comment or anchor missing."
  fi
else
  say "[N3] marker absent (patcher no-op/abort)."
fi

# [N4] append-only ledger correction (sentinel IS in payload)
if ! grep -qF "$LEDGER_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | CORRECTION | $LEDGER_TOKEN | APPEND-ONLY | J2 [K4] sed failed: unescaped '/' in anchor delimiter and NOTE lacked leading '#'; sed aborted before write so unit stayed clean. K4 heals with Python substring-anchor insert, comment-prefixed note, atomic write, existing .pre-J2.bak honored. Re-measured live=$LIVE ready=$RDY root=$ROOT place=$PLACE image=$IMG. |" >> "$IDX"
  say "[N4] ledger correction appended."
else
  say "[N4] ledger correction already present."
fi
grep -qF "$LEDGER_TOKEN" "$IDX" 2>/dev/null && say "[N4] suppression proof: '$LEDGER_TOKEN' present." || say "[N4] WARNING: sentinel missing."

# [N5] mark defective J2 script header-only (do not rewrite its logic)
if [ -f "$J2" ] && ! grep -qF "$J2MARK" "$J2"; then
  python3 - "$J2" "$J2MARK" <<'PY'
import sys, os, tempfile
p, mark = sys.argv[1], sys.argv[2]
with open(p, encoding="utf-8") as f:
    lines = f.read().splitlines(keepends=True)
hdr = f"# {mark}: J2 [K4] sed used /anchor/ while anchor contained '/', and NOTE lacked leading '#'; both would skip/corrupt annotation. K4 Python patcher is authoritative for unit annotation. Header-only; J2 logic untouched.\n"
lines.insert(0, hdr)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p) or ".", prefix=".j2.", text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("".join(lines))
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  say "[N5] J2 marked defective-healed (header only)."
else
  say "[N5] J2 already marked or absent."
fi

# [N6] final steel-thread + annotation decision
STEEL=no; [ "$LIVE" = 200 ] && STEEL=yes
if [ "$ANNOT" = yes ] && [ "$STEEL" = yes ]; then
  say "[RESULT] MINIO GREEN + annotation healed; console placement=$PLACE; next brick: weaviate."
elif [ "$STEEL" = yes ]; then
  say "[RESULT] MINIO steel-thread green but annotation not confirmed (ANNOT=$ANNOT); inspect [N3] before weaviate."
else
  say "[RESULT] MINIO steel-thread NOT green (live=$LIVE); do not advance; re-run J1/I poll."
fi
exit 0
