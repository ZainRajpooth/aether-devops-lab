#!/usr/bin/env bash
# 20261104-EG — READ-ONLY, SECRET-FREE harvest. Ends the guessing loop by taking the exact
# login-companion wiring from the BINARY's own --help (ground truth), not from recall.
# Mutates NOTHING: CLI --help never connects to the DB; the ROPC probe sends a FAKE password
# and prints only the error TYPE (capability signal), never a token/secret. Robust F1 parser
# reports LENGTHS only (never values); on parse-fail it prints REDACTED structure.
set -uo pipefail
HOME_="$HOME"
SEC="$HOME_/DevOps/aether/secrets"
ZIT_DIR="$HOME_/DevOps/aether/infra/zitadel"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
TOKEN="eg-readonly-cli-help-harvest-v1"
B="http://127.0.0.1:8082"
CORE_IMG="ghcr.io/zitadel/zitadel:latest"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
MKEY="$(cat "$SEC/zitadel-masterkey" 2>/dev/null || true)"
PGPASS="$(grep '^POSTGRES_PASSWORD=' "$SEC/postgres.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
redact(){ awk -v a="$MKEY" -v b="$PGPASS" '{ if ((a!=""&&index($0,a))||(b!=""&&index($0,b))) print "    [REDACTED-LINE]"; else print }'; }

hr "G0 robust credential parse (LENGTHS only; redacted structure on fail)"
LOG_FILE="$(ls -1t "$ZIT_DIR"/setup-ec-*.log 2>/dev/null | head -1)"
[ -n "$LOG_FILE" ] || LOG_FILE="$(ls -1t "$ZIT_DIR"/setup-*.log 2>/dev/null | head -1)"
[ -n "$LOG_FILE" ] || { say "[HALT] no setup log found"; exit 1; }
say "log = $LOG_FILE"
# tolerant per-key capture: works for 'Login name: X' / 'Username: X' / '"loginName":"X"' / '"username":"X"'
U_RE='"?(loginName|login_name|Login name|login name|Username|username)"?[[:space:]]*[:=][[:space:]]*"?[^",}]+'
P_RE='"?(password|Password|PASSWORD)"?[[:space:]]*[:=][[:space:]]*"?[^",}]+'
USER_VAL="$(grep -aoE "$U_RE" "$LOG_FILE" 2>/dev/null | head -1 | sed -E 's/.*[:=][[:space:]]*"?//; s/[",}]+$//')"
PASS_VAL="$(grep -aoE "$P_RE" "$LOG_FILE" 2>/dev/null | grep -avE 'masterkey|secret|csr|jwt|policy|hashed|hash' | head -1 | sed -E 's/.*[:=][[:space:]]*"?//; s/[",}]+$//')"
UL=${#USER_VAL}; PL=${#PASS_VAL}
PARSE_OK=no; [ "$UL" -ge 3 ] && [ "$PL" -ge 4 ] && PARSE_OK=yes
say "user_len=$UL pass_len=$PL PARSE_OK=$PARSE_OK  (values NOT printed)"
if [ "$PARSE_OK" != yes ]; then
  say "--- REDACTED structure of credential-bearing lines (so the parser can be fixed from form, not guess) ---"
  grep -naiE 'login[ _-]?name|username|password' "$LOG_FILE" 2>/dev/null \
    | sed -E 's/([:=][[:space:]]*).*/\1***MASKED***/' | head -12 | sed 's/^/    /' || say "    (none)"
fi

hr "G1 ROPC capability probe (FAKE password; prints error TYPE only; no secret, no state)"
# wrong-password ROPC distinguishes: unauthorized_client/unsupported_grant_type => ROPC NOT allowed (use CLI);
# invalid_grant => client+grant ARE allowed, only the pw is wrong (=> API path viable in EG2).
PROBE="$(curl -sS -m 10 -X POST "$B/oauth/v2/token" \
  -d "grant_type=password" -d "username=__probe__" -d "password=__probe_wrong__" \
  -d "scope=openid" -d "client_id=console" 2>/dev/null || true)"
PCODE="$(printf '%s' "$PROBE" | grep -oE '"error"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
[ -z "$PCODE" ] && PCODE="(no-error-field)"
ROPC=no
case "$PCODE" in invalid_grant|invalid_request) ROPC=yes;; esac   # grant/client accepted -> only creds bad
say "ROPC_probe error='$PCODE' => ROPC_VIABLE=$ROPC  (console client tested; EG2 will also try a first-party client if needed)"

hr "G2 CLI help harvest (read-only; the literals EG2 is built from)"
cli(){ podman run --rm "$CORE_IMG" "$@" 2>&1 | redact; }   # --help never opens the DB
say "--- top-level commands ---"
cli --help 2>/dev/null | sed -n '1,80p' | sed 's/^/    /' || cli help 2>/dev/null | sed -n '1,80p' | sed 's/^/    /' || say "    (top help failed)"
GROUPS="setup start start-from-init migrate instance user machine service project client role feature settings secret key pat login idp org system admin management auth"
for g in $GROUPS; do
  H="$(cli "$g" --help 2>/dev/null || true)"
  [ -z "$H" ] && H="$(cli help "$g" 2>/dev/null || true)"
  if [ -n "$H" ]; then
    say "### '$g' --help ###"
    printf '%s\n' "$H" | sed -n '1,40p' | sed 's/^/    /'
    # second level for groups likely to nest the ops we need
    case "$g" in
      instance|user|project|settings|feature)
        for sub in $(printf '%s\n' "$H" | grep -oE '^[[:space:]]+[a-z][a-z0-9-]+' | awk '{print $1}' | sort -u | head -6); do
          H2="$(cli "$g" "$sub" --help 2>/dev/null || true)"
          [ -n "$H2" ] && { say "#### '$g $sub' --help ####"; printf '%s\n' "$H2" | sed -n '1,30p' | sed 's/^/      /'; }
        done ;;
    esac
  fi
done
say "READ: EG2 needs the literal subcommand+flags for (1) create machine/service user + emit KEY, (2) grant role IAM_LOGIN_CLIENT, (3) set instance feature loginV2 + baseUri. Those are now in the dump above (or G1 says use the API instead)."

hr "G3 synthesis (read-only; nothing changed)"
say "G0 PARSE_OK=$PARSE_OK  -> if no, the redacted structure above fixes the parser; EG2 re-derives creds internally either way."
say "G1 ROPC_VIABLE=$ROPC   -> yes: EG2 bootstraps via HTTP API (token from real ROPC over loopback); no: EG2 bootstraps via CLI (masterkey->DB), exact cmds from G2."
say "G2 dump               -> supplies the EXACT login-companion env-var name + SA/role/feature subcommands so EG2 has ZERO recalled strings."
say "[RESULT] EG COMPLETE - paste the G1 line + the ENTIRE G2 section; EG2 (the final working deploy) is built from those literals, not from my memory."

hr "G4 ledger (INFO, append-only)"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | R | %s | GATE=INFO | EG read-only harvest: owned EF F1 label bug + 3 architectural corrections (SA-with-IAM_LOGIN_CLIENT != machine PAT; live loginV2 feature baseUri != config.yaml; bootstrap must be CLI/masterkey or API-if-ROPC). G0 parse_ok=%s; G1 ROPC_viable=%s; G2 dumped binary --help for exact SA/role/feature/env literals so EG2 has zero recalled strings. No mutations; no secrets sent (fake-pw probe). |\n' \
    "$(date +%F)" "$TOKEN" "$PARSE_OK" "$ROPC" >> "$IDX"
  say "ledger row appended (INFO)"
fi
exit 0
