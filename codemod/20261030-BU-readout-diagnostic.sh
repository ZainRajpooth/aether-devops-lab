#!/usr/bin/env bash
# 20261030-BU — PURE READ-ONLY outage diagnostic. Mutates nothing.
# Purpose: after the lost-screen BT run + probe showing broad outage + woodpecker flapping
#          + empty ledger, classify every service authoritatively and capture the real
#          crash logs (systemd journal, which survives --rm) + one VERBOSE in-network DNS probe.
# Sections:
#   U0 session/lingering/system state (explains mass user-service stop if applicable)
#   U1 per-unit table: is-active/enabled/NRestarts/Result/ExecMainStatus/LoadState + container state + VERDICT
#   U2 failed-units list
#   U3 podman ps -a + network inspect aether + network backend + aardvark-dns units
#   U4 journals (last 24 lines) for every unit whose VERDICT != UP
#   U5 VERBOSE DNS probe (resolv.conf + getent + rc + stderr) for gitea and woodpecker-server
#   U6 dns-wait mode (strict vs warn), env-key presence (names only, never values), /etc/hosts shadow
#   U7 computed VERDICT summary
# Safety: no sudo; no start/stop/restart; no pull; no run except ONE bounded diagnostic alpine;
#         no secret echo; no file writes outside /tmp.
# Hard rules: multi-line if/then/fi only; no heredoc inside $( ); no backticks as substitution.
set -uo pipefail

A="$HOME/DevOps/aether"
CD="$A/codemod"
DNS_SCRIPT="$A/infra/scripts/aether-dns-wait.sh"
WP_ENV="$A/secrets/woodpecker.env"
GITEA_ENV="$A/secrets/gitea.env"
NET="aether"
ALPINE="docker.io/library/alpine:latest"

SERVICES="postgres gitea grafana n8n litellm llama-embed woodpecker-server woodpecker-agent traefik"

hr(){ printf '\n========== %s ==========\n' "$*"; }
say(){ printf '  %s\n' "$*"; }
norm(){ local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }

act(){ norm "$(systemctl --user is-active "$1.service" 2>/dev/null || true)"; }
en(){  norm "$(systemctl --user is-enabled "$1.service" 2>/dev/null || true)"; }
nr(){  norm "$(systemctl --user show "$1.service" -p NRestarts --value 2>/dev/null || true)"; }
rs(){  norm "$(systemctl --user show "$1.service" -p Result --value 2>/dev/null || true)"; }
ms(){  norm "$(systemctl --user show "$1.service" -p ExecMainStatus --value 2>/dev/null || true)"; }
ls(){  norm "$(systemctl --user show "$1.service" -p LoadState --value 2>/dev/null || true)"; }
ss(){  norm "$(systemctl --user show "$1.service" -p SubState --value 2>/dev/null || true)"; }
cst(){ norm "$(podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null || true)"; }
cdt(){ norm "$(podman inspect "$1" --format 'exit={{.State.ExitCode}} err={{.State.Error}} nets={{json .NetworkSettings.Networks}}' 2>/dev/null || true)"; }

to_int(){
  local v
  v="$(norm "${1:-0}")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

verdict(){
  local a="$1" c="$2" n="$3" r="$4"
  n="$(to_int "$n")"
  if [ "$a" = active ] && [ "$c" = running ]; then printf 'UP'; return; fi
  if [ "$a" = active ] && [ "$c" = absent ]; then
    if [ "$n" -gt 0 ]; then printf 'CRASH-LOOPING'; else printf 'STARTING-OR-FLAP'; fi
    return
  fi
  if [ "$a" = active ] && [ "$c" = exited ]; then printf 'EXITED-RUNNING-UNIT'; return; fi
  if [ "$a" = activating ] || [ "$a" = deactivating ] || [ "$a" = reloading ]; then
    printf 'TRANSIENT(%s/%s)' "$a" "$c"; return
  fi
  if [ "$a" = failed ]; then printf 'FAILED(result=%s)' "$r"; return; fi
  if [ "$c" = exited ]; then printf 'EXITED'; return; fi
  if [ "$a" = inactive ]; then printf 'STOPPED'; return; fi
  printf 'UNKNOWN(a=%s c=%s n=%s)' "$a" "$c" "$n"
}

# ===================== [U0] session / lingering / system =====================
hr "U0 session / lingering / user-manager state"
say "user=$(id -un) uid=$(id -u)"
say "is-system-running=$(norm "$(systemctl --user is-system-running 2>/dev/null || true)")"
if command -v loginctl >/dev/null 2>&1; then
  loginctl show-user "$(id -un)" 2>/dev/null | grep -Ei '^(Linger|State|TimestampMonotonic)=' | sed 's/^/  loginctl: /' || say "  loginctl: (no properties)"
else
  say "  loginctl: not available"
fi
say "sessions (who):"
who 2>/dev/null | sed 's/^/    /' || say "    (none)"

# ===================== [U1] per-unit table + verdict =====================
hr "U1 per-unit state + verdict"
printf '  %-20s %-10s %-9s %-4s %-9s %-5s %-9s %-9s %s\n' \
  "UNIT" "ACTIVE" "ENABLED" "NR" "RESULT" "MAINST" "LOAD" "CONTAINER" "VERDICT"
declare -A CLS
for s in $SERVICES; do
  a="$(act "$s")"; e="$(en "$s")"; n="$(nr "$s")"; r="$(rs "$s")"
  m="$(ms "$s")"; l="$(ls "$s")"; c="$(cst "$s")"
  v="$(verdict "$a" "$c" "$n" "$r")"
  CLS["$s"]="$v"
  printf '  %-20s %-10s %-9s %-4s %-9s %-5s %-9s %-9s %s\n' \
    "$s" "${a:-?}" "${e:-?}" "${n:-0}" "${r:-none}" "${m:-?}" "${l:-?}" "${c:-absent}" "$v"
done

# ===================== [U2] failed units =====================
hr "U2 systemd user failed units"
systemctl --user list-units --state=failed --no-pager 2>/dev/null | sed 's/^/    /' || say "    (none / command failed)"

# ===================== [U3] podman containers + network + dns plugin =====================
hr "U3 podman ps -a"
podman ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | sed 's/^/    /' || say "    (podman ps -a failed)"

hr "U3 network backend + aether inspect (head)"
say "network_backend=$(norm "$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)")"
say "dns_plugin=$(norm "$(podman info --format '{{.Host.DNSPlugin}}' 2>/dev/null || true)")"
podman network inspect "$NET" >"/tmp/aether-bu-net.$$" 2>"/tmp/aether-bu-net-err.$$" || true
head -c 1500 "/tmp/aether-bu-net.$$" 2>/dev/null | sed 's/^/    net: /' || true
head -c 600 "/tmp/aether-bu-net-err.$$" 2>/dev/null | sed 's/^/    net-err: /' || true
rm -f "/tmp/aether-bu-net.$$" "/tmp/aether-bu-net-err.$$" 2>/dev/null || true

hr "U3 aardvark-dns / podman dns helper units"
for u in "podman-aardvark-dns@$NET.service" "podman-aardvark-dns.service" "podman.socket"; do
  say "  $u active=$(act2 "$(systemctl --user is-active "$u" 2>/dev/null || true)")" 2>/dev/null \
    || say "  $u active=$(norm "$(systemctl --user is-active "$u" 2>/dev/null || true)")"
done
# act2 not defined; recompute cleanly:
for u in "podman-aardvark-dns@$NET.service" "podman-aardvark-dns.service"; do
  say "  (recheck) $u = $(norm "$(systemctl --user is-active "$u" 2>/dev/null || true)")"
done

# per-container network attachment for the outage set
hr "U3 container network attachment (outage set)"
for s in gitea grafana n8n woodpecker-server woodpecker-agent traefik; do
  say "  $s -> $(cdt "$s")"
done

# ===================== [U4] journals for non-UP units =====================
hr "U4 journals (last 24 lines) for every unit whose VERDICT != UP"
for s in $SERVICES; do
  v="${CLS[$s]}"
  case "$v" in
    UP) continue ;;
  esac
  printf '\n  ---- journal: %s.service  (verdict=%s) ----\n' "$s" "$v"
  journalctl --user -u "$s.service" -n 24 --no-pager -o short-iso 2>/dev/null | sed 's/^/      j: /' \
    || say "      (journalctl failed for $s)"
done

# ===================== [U5] VERBOSE in-network DNS probe =====================
hr "U5 verbose in-network DNS probe (the crux of BT [T3] 'none')"
if ! podman image exists "$ALPINE" 2>/dev/null; then
  say "  alpine image absent; skipping live probe (would require pull)"
else
  for tgt in gitea woodpecker-server postgres; do
    o="/tmp/aether-bu-dns-$tgt.out"; r="/tmp/aether-bu-dns-$tgt.err"
    if command -v timeout >/dev/null 2>&1; then
      timeout 30 podman run --rm --network "$NET" "$ALPINE" \
        sh -c "printf '== resolv.conf ==\n'; cat /etc/resolv.conf 2>&1; printf '== hosts ==\n'; cat /etc/hosts 2>&1; printf '== getent %s ==\n' '$tgt'; getent hosts '$tgt'; printf 'rc=%s\n' \$?" \
        >"$o" 2>"$r"
      rc=$?
    else
      podman run --rm --network "$NET" "$ALPINE" \
        sh -c "printf '== resolv.conf ==\n'; cat /etc/resolv.conf 2>&1; printf '== hosts ==\n'; cat /etc/hosts 2>&1; printf '== getent %s ==\n' '$tgt'; getent hosts '$tgt'; printf 'rc=%s\n' \$?" \
        >"$o" 2>"$r"
      rc=$?
    fi
    printf '\n  ---- probe: %s  (podman-run-rc=%s) ----\n' "$tgt" "$rc"
    head -c 1200 "$o" 2>/dev/null | sed 's/^/      out: /' || true
    head -c 800  "$r" 2>/dev/null | sed 's/^/      err: /' || true
    rm -f "$o" "$r" 2>/dev/null || true
  done
fi

# ===================== [U6] config integrity (names only, never values) =====================
hr "U6 dns-wait mode + env-key presence + /etc/hosts shadow"
if [ -f "$DNS_SCRIPT" ]; then
  if grep -q 'WARN host' "$DNS_SCRIPT" 2>/dev/null; then
    say "  dns-wait mode = WARN (BR left it permissive; BT [T4] strict-restore NOT confirmed)"
  elif grep -q 'rejecting' "$DNS_SCRIPT" 2>/dev/null; then
    say "  dns-wait mode = STRICT"
  else
    say "  dns-wait mode = UNKNOWN"
  fi
else
  say "  dns-wait script MISSING: $DNS_SCRIPT"
fi

for f in "$WP_ENV" "$GITEA_ENV"; do
  if [ -f "$f" ]; then say "  env present: $f (mode=$(stat -c '%a' "$f" 2>/dev/null || echo ?))"; else say "  env MISSING: $f"; fi
done
say "  woodpecker.env keys present (names only):"
for k in WOODPECKER_GRPC_SECRET WOODPECKER_AGENT_SECRET WOODPECKER_DATABASE_DATASOURCE WOODPECKER_GITEA_CLIENT WOODPECKER_GITEA_SECRET WOODPECKER_BACKEND DOCKER_HOST WOODPECKER_SERVER WOODPECKER_GRPC_ADDR; do
  if grep -q "^${k}=." "$WP_ENV" 2>/dev/null; then say "    YES $k"; else say "    no  $k"; fi
done
say "  gitea.env keys present (names only):"
for k in GITEA_ADMIN_USER GITEA__database__PASSWD GITEA_DB_PASSWORD; do
  if grep -q "^${k}=." "$GITEA_ENV" 2>/dev/null; then say "    YES $k"; else say "    no  $k"; fi
done

say "  /etc/hosts bare-internal-name shadow (must be empty):"
grep -En '^[[:space:]]*(127\.|::1).*\b(gitea|woodpecker-server|grafana|n8n|postgres|litellm)\b' /etc/hosts 2>/dev/null | sed 's/^/    SHADOW: /' || say "    none (clean)"

# ===================== [U7] verdict summary =====================
hr "U7 VERDICT SUMMARY"
n_up=0; n_flap=0; n_stop=0; n_fail=0; n_other=0
for s in $SERVICES; do
  v="${CLS[$s]}"
  case "$v" in
    UP) n_up=$((n_up+1)) ;;
    CRASH-LOOPING|STARTING-OR-FLAP|EXITED-RUNNING-UNIT) n_flap=$((n_flap+1)) ;;
    STOPPED|EXITED) n_stop=$((n_stop+1)) ;;
    FAILED*) n_fail=$((n_fail+1)) ;;
    *) n_other=$((n_other+1)) ;;
  esac
  printf '  %-20s %s\n' "$s" "$v"
done
printf '\n  totals: UP=%d FLAPPING=%d STOPPED/EXITED=%d FAILED=%d OTHER=%d\n' \
  "$n_up" "$n_flap" "$n_stop" "$n_fail" "$n_other"

if [ "$n_flap" -gt 0 ]; then
  say "  >>> At least one service is FLAPPING. Do NOT rerun BT blind; read U4 journals for the fatal line."
fi
if [ "$n_up" -lt 6 ]; then
  say "  >>> Control plane is NOT fully up (UP=%d of 9). Traefik/Woodpecker cannot be proven green yet." "$n_up"
fi
say "  [READ-ONLY COMPLETE] no state changed by this script."
exit 0
