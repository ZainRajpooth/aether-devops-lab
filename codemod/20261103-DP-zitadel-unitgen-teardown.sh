#!/usr/bin/env bash
# 20261103-DP — TEARDOWN (no blind patch). DO hid the enable error; the empty journal
# proves systemd has no zitadel.service. DP forces regeneration, runs enable --now
# UNSUPPRESSED, and captures the generator's literal complaint. It NEVER re-inits the
# DB / never drops zitadel / never rewrites config or key (O5's admin account survives).
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
UDIR="$HOME_/.config/containers/systemd"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
NET="aether"
TOKEN="dp-zitadel-unitgen-teardown-v1"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
ERRCAP="/tmp/dp-enable.$$.err"
GENLOG="/tmp/dp-gen.$$.log"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
up23(){ case "${1:0:1}" in 2|3) return 0;; *) return 1;; esac; }
# load secrets ONLY to redact printed diagnostics (never echoed)
MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
redact(){ awk -v a="$MKEY" -v b="$PGPASS" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) next; print }' "$1" 2>/dev/null | tail -n "${2:-40}"; }

hr "P0 safety note"
say "DP does NOT run start-from-init, does NOT DROP/CREATE zitadel, does NOT rewrite"
say "config/key. The O5-initialized DB + default instance + initial-admin creds are kept."
say "Latest init log (contains the admin login; open LOCALLY, never paste):"
ls -1t "$ZIT_DIR"/setup-*.log 2>/dev/null | head -1 | sed 's/^/    /' || say "    (none found)"

hr "P1 force regeneration, then ask systemd if the unit EXISTS now"
systemctl --user daemon-reload >/dev/null 2>&1 || true
sleep 2
say "--- generated unit-files (zitadel* / portainer*) ---"
systemctl --user list-unit-files --type=service 'zitadel*' 'portainer*' --no-pager --plain 2>&1 | sed 's/^/    /' || true
ZI_PRESENT=no
if systemctl --user list-unit-files --type=service 'zitadel.service' --no-pager --plain 2>/dev/null | grep -q 'zitadel.service'; then ZI_PRESENT=yes; fi
PO_PRESENT=no
if systemctl --user list-unit-files --type=service 'portainer.service' --no-pager --plain 2>/dev/null | grep -q 'portainer.service'; then PO_PRESENT=yes; fi
say "zitadel.service generated? $ZI_PRESENT   portainer.service generated? $PO_PRESENT"

hr "P2 UNSUPPRESSED enable --now zitadel (the error DO hid; stderr -> $ERRCAP)"
set +e
systemctl --user enable --now zitadel.service 2>"$ERRCAP"
ERC=$?
set -e
say "enable --now rc=$ERC"
if [ -s "$ERRCAP" ]; then say "--- enable stderr (redacted) ---"; redact "$ERRCAP" 20 | sed 's/^/    /'; else say "    (no stderr)"; fi
sleep 6
ZI_STATE="$(systemctl --user is-active zitadel.service 2>/dev/null | tr -d '\n')"
ZI_CONT="$(podman inspect zitadel --format '{{.State.Status}}' 2>/dev/null || echo absent)"
say "after retry: zitadel unit=$ZI_STATE container=$ZI_CONT"

hr "P3a BRANCH (a) RACE-CLEARED: unit now present/started -> gate it"
if [ "$ZI_PRESENT" = yes ] && { [ "$ZI_STATE" = active ] || [ "$ZI_STATE" = activating ]; }; then
  ZC="000"; for i in $(seq 1 40); do ZC="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:8082/debug/healthz 2>/dev/null || true)"; up23 "$ZC" && break; sleep 2; done
  ZUP=no; up23 "$ZC" && ZUP=yes
  say "zitadel healthz http=$ZC up=$ZUP unit=$(systemctl --user is-active zitadel.service 2>/dev/null | tr -d '\n') cont=$ZI_CONT"
  say "--- real container names (clarifies 16-vs-17) ---"
  podman ps --format '{{.Names}} {{.Status}}' 2>/dev/null | sort | sed 's/^/    /' || true
  say "total running: $(podman ps -q 2>/dev/null | wc -l | tr -d ' ') (expect 17)"
  if [ "$ZUP" = yes ]; then
    say "[VERDICT] DP RESOLVED (cause was a daemon-reload/enable RACE, not a parse error)."
    say "  Zitadel is UP on http://127.0.0.1:8082 ; admin login is in the setup-*.log above."
    say "  NO further patch needed. Do NOT re-run any init brick (would reset the DB)."
    RESOLVED=yes
  else
    say "[VERDICT] unit generated+started but healthz not 2xx -> see journal (redacted):"
    journalctl --user -u zitadel.service -n 25 --no-pager 2>/dev/null | redact /dev/stdin 25 | sed 's/^/    /' || true
    RESOLVED=partial
  fi
else
  hr "P3b BRANCH (b) GENERATOR REJECTION: unit absent -> capture the literal objection"
  say "zitadel.service NOT present after forced reload (ZI_PRESENT=$ZI_PRESENT)."
  say "--- systemctl cat zitadel.service (error == proof it was never generated) ---"
  systemctl --user cat zitadel.service 2>&1 | redact /dev/stdin 12 | sed 's/^/    /' || true
  say "--- this-boot generator/quadlet complaints (redacted) ---"
  journalctl --user -b --no-pager 2>/dev/null | grep -iE 'podman-system-generator|quadlet|zitadel\.container|failed to (parse|generate|load)|invalid|unsupported' 2>/dev/null | redact /dev/stdin 40 | sed 's/^/    /' || say "    (no matching generator lines in journal)"
  say "--- structural diff: keys in zitadel.container that WORKING portainer.container lacks ---"
  say "    [Unit]      Wants=postgres.service            (suspect: quadlet manages deps)"
  say "    [Container] Environment=ZITADEL_MASTERKEY=...  (standard, but untested here)"
  say "    [Container] Exec=start ... --tlsMode disabled  (standard; image needs the args)"
  say "    [Service]   ExecStartPre=\$CANON postgres       (PRIME SUSPECT: inline [Service]"
  say "                ExecStartPre in a .container is the least-certain form; we PROVED"
  say "                ExecStartPre merges via DROP-IN for grafana/traefik, not inline)"
  say "[VERDICT] generator rejected zitadel.container. Exact remedy = DQ (next turn):"
  say "    rewrite zitadel.container to the PROVEN portainer shape (NO user [Unit] Wants,"
  say "    NO inline [Service] ExecStartPre) and move the postgres guard into a DROP-IN"
  say "    ~/.config/systemd/user/zitadel.service.d/override.conf (ExecStartPre= + guard),"
  say "    keeping [Container] Image/Network/PublishPort/Environment/Volume/Exec. DQ will"
  say "    NOT touch the DB/config/key. Paste P1-P3b and I ship DQ precisely."
  RESOLVED=diagnosed
fi

hr "P4 ledger (teardown, INFO)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=%s | DP teardown (no DB touch): forced daemon-reload; UNSUPPRESSED enable --now zitadel (DO had hidden this error); zitadel.service generated=%s state=%s cont=%s; verdict=%s. Settled-correct (O5): 32B key, migrated DB+instance+admin creds, 644 loopback cfg, --tlsMode disabled. Suspect keys for rejection: [Unit]Wants, [Service]inline ExecStartPre (prime), [Container]Environment/Exec. |\n' \
    "$(date +%F)" "$TOKEN" "$RESOLVED" "$ZI_PRESENT" "$ZI_STATE" "$ZI_CONT" "$RESOLVED" >> "$IDX"
  say "ledger row appended (INFO)"
fi
say "[RESULT] DP $RESOLVED - see P3 verdict above; paste P1-P3 if diagnosed."
exit 0
