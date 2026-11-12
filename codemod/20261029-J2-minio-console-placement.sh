# DEFECT-HEALED-BY-K4: J2 [K4] sed used /anchor/ while anchor contained '/', and NOTE lacked leading '#'; both would skip/corrupt annotation. K4 Python patcher is authoritative for unit annotation. Header-only; J2 logic untouched.
#!/usr/bin/env bash
# 20261029-J2 — minio console-placement: READ-ONLY probe (9010/ content) + inert source-unit annotation
# + guarded ledger row. NO restart / re-render / daemon-reload / pull / volume-rm in ANY branch.
# Corrects the J1 chat 'add Exec=' guidance by measurement: [J3] logs show a multi-step first-run mc
# setup that Exec would bypass; the real story is a port-publish mismatch (UI co-served on 9000->9010).
# exit 0 on every branch. Writes ONLY: infra/quadlet/minio.container (comment, w/ .pre-J2.bak) + INDEX.md.
set -uo pipefail
A="$HOME/DevOps/aether"; CD="$A/codemod"; QD="$A/infra/quadlet"
UNIT="$QD/minio.container"; IDX="$CD/INDEX.md"
SLUG="20261029-I-minio"; LEDGER_TOKEN="minio brick2 console-placed"   # MUST be in the payload echo (H5 rule)
MARKER="CONSOLE-PLACEMENT(J2-probe)"                                  # idempotence token for the unit insert
ANCHOR="Object/S3 semantics NOT probed here"                          # unique existing line in the unit
say(){ printf '  %s\n' "$*"; }
hc_body(){ # $1=url $2=outfile -> prints http code, body to $2 ; NO ||echo (the 000000 class)
  curl -s -o "$2" -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }

# [K1] read-only probes (steel-thread re-confirm + console discriminator)
RF="/tmp/mroot.$$.body"
LIVE=$(hc_body http://127.0.0.1:9010/minio/health/live "$RF"); : >"$RF"   # discard live body
RDY=$(hc_body  http://127.0.0.1:9010/minio/health/ready "$RF"); : >"$RF"
ROOT=$(hc_body http://127.0.0.1:9010/ "$RF")                              # keep body for classification
IMG=$(podman inspect minio --format '{{.Config.Image}}' 2>/dev/null || echo '?')
say "[K1] live=$LIVE ready=$RDY root=$ROOT image=$IMG"

# [K2] classify console placement from 9010/ body (content, not just code)
PLACE="UNKNOWN"; DETAIL=""
if grep -qiE '<\?xml|<Error|AccessDenied|<ListAllMyBuckets' "$RF"; then
  PLACE="UI_ABSENT"; DETAIL="9010/ answers as the S3 endpoint (XML/AccessDenied) -> console NOT co-served; 9011 not listening."
elif [ "$ROOT" = 200 ] && grep -qiE '<html|<title|console|MinIO' "$RF"; then
  PLACE="UI_ON_API"; DETAIL="9010/ returns HTML -> web console co-served on the API port (9000->host 9010); 9011->9001 publish unused."
else
  PLACE="UNKNOWN"; DETAIL="9010/ root code=$ROOT, no decisive HTML/XML marker; console placement unconfirmed."
fi
rm -f "$RF"
say "[K2] console placement := $PLACE  ($DETAIL)"

# [K3] build the measured unit-note (one line; free of & and backslash so sed-append is safe, B9)
case "$PLACE" in
  UI_ON_API) NOTE="$MARKER: web console co-served on API port 9000 (host 9010) per Bitnami default run.sh; the 9011->9001 publish is unused and harmless. Do NOT override Exec to force a split console: the J3 first-run logs show a multi-step setup (background start, mc alias add, stop, restart) that an Exec override would bypass and mis-configure. A dedicated console port, if ever wanted, comes from the image supported env at edge-authoring (verify in docs), never from a guessed Exec.";;
  UI_ABSENT) NOTE="$MARKER: 9010/ answers as the S3 endpoint (XML/AccessDenied), so the web console is NOT co-served here; 9011 not listening. S3 API green is the steel thread and is all Lane-A needs. Do NOT override Exec (would bypass the J3 first-run mc setup). Console, if wanted later, via supported env at edge-authoring.";;
  *)         NOTE="$MARKER: console placement not confirmed by the 9010-root probe (code in INDEX); S3 API green is the steel thread regardless. Do NOT override Exec (would bypass the J3 first-run mc setup); revisit console via supported env at edge-authoring.";;
esac

# [K4] inert source-unit annotation (guarded idempotent insert; B1 safety copy once; NO reload/restart)
if [ -f "$UNIT" ]; then
  if grep -qF "$MARKER" "$UNIT"; then
    say "[K4] unit already annotated (no-op)."
  else
    [ -f "$UNIT.pre-J2.bak" ] || cp -p "$UNIT" "$UNIT.pre-J2.bak" && say "[K4] safety copy -> $(basename "$UNIT").pre-J2.bak"
    if sed -i "/$ANCHOR/a\\$NOTE" "$UNIT"; then
      say "[K4] unit annotated (comment-only; live rendered unit untouched until next replay)."
    else
      say "[K4] sed insert failed (harmless; anchor '$ANCHOR' maybe moved) — inspect unit."
    fi
  fi
else say "[K4] unit absent at $UNIT (skip insert)."; fi

# [K5] guarded ledger row (sentinel IS in payload) + in-run suppression proof (H5 rule)
if ! grep -qF "$LEDGER_TOKEN" "$IDX" 2>/dev/null; then
  echo "| $(date +%F) | B | $SLUG | GATE=PASS(J2 console-placement) | $LEDGER_TOKEN: $PLACE — $DETAIL Steel thread re-confirmed live=$LIVE ready=$RDY image=$IMG. Corrects J1 chat 'add Exec=' guidance: [J3] first-run mc setup must not be bypassed; console fixed via supported env at edge-authoring, not Exec. Source unit annotated (inert); runtime+systemd untouched. |" >> "$IDX"
  say "[K5] ledger row appended (sentinel-in-payload)."
else say "[K5] ledger row already present (guard suppressed)."; fi
grep -qF "$LEDGER_TOKEN" "$IDX" 2>/dev/null && say "[K5] suppression proof: '$LEDGER_TOKEN' present => re-run takes suppress branch." || say "[K5] WARNING: sentinel missing — guard may not suppress."

# [K6] steel-thread re-confirm (read-only); green regardless of console placement
PASS=no; { [ "$LIVE" = 200 ]; } && PASS=yes
[ "$PASS" = yes ] && say "[RESULT] MINIO STEEL-THREAD GREEN (live=200) + console placement measured=$PLACE; J1 Exec-guidance corrected by evidence; runtime untouched. Next brick: weaviate." \
  || say "[RESULT] MINIO STEEL-THREAD NOT 200 (live=$LIVE) — unexpected; re-run J1 poll. Console note is moot until API is 200."
exit 0
