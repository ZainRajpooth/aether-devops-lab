#!/usr/bin/env bash
# 20261031-BZ — fix aether-dns-wait.sh stale aardvark-dns state and restart traefik.
# Supersedes the dns-wait installed by BY. Root cause: heal_aardvark() used invalid
# `podman network reload $NET` (expects container name, rc=125) and did not clear
# $XDG_RUNTIME_DIR/.../networks/aardvark-dns, so netavark thought the dead daemon
# was still running and never respawned it -> getent 10s timeout -> systemd kills
# ExecStartPre. Fix: pkill + rm -rf $rt/aardvark-dns, let next podman run trigger
# netavark to spawn fresh daemon. Then reset/restart traefik and gate proxied :8888.
set -uo pipefail

A="$HOME/DevOps/aether"
DNS_SCRIPT="$A/infra/scripts/aether-dns-wait.sh"
IDX="$A/codemod/INDEX.md"
TOKEN="bz-dns-wait-stale-state-heal-v1"

say(){ printf '  %s\n' "$*"; }
halt(){ printf '[HALT] %s\n' "$*" >&2; exit 0; }

if [ ! -f "$DNS_SCRIPT" ]; then
  halt "missing $DNS_SCRIPT"
fi

say "=== [Z1] rewrite aether-dns-wait.sh heal_aardvark() ==="
cat > "$DNS_SCRIPT" <<'DWEOF'
#!/usr/bin/env bash
# aether-dns-wait.sh — BZ durable guard (fixes stale aardvark-dns state).
set -uo pipefail
NET="${AETHER_NET:-aether}"
ALPINE="${AETHER_ALPINE:-docker.io/library/alpine:latest}"
TRIES="${AETHER_DNS_TRIES:-90}"
DELAY="${AETHER_DNS_DELAY:-1}"
PROBE_TIMEOUT="${AETHER_DNS_PROBE_TIMEOUT:-25}"
ALLOW_LOOPBACK="${AETHER_DNS_ALLOW_LOOPBACK:-0}"
CANARY="${AETHER_DNS_CANARY:-postgres}"
hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "usage: aether-dns-wait.sh HOST [HOST...]" >&2
  exit 2
fi
_pt(){
  if command -v timeout >/dev/null 2>&1; then
    timeout "$PROBE_TIMEOUT" "$@"
  else
    "$@"
  fi
}
ge_addr(){
  local name="$1"
  local a
  a="$(_pt podman run --rm --network "$NET" "$ALPINE" getent hosts "$name" 2>/dev/null | awk 'NR==1{print $1}')"
  printf '%s' "$a"
}
resolves(){
  local name="$1"
  local a
  a="$(ge_addr "$name")"
  if [ -z "$a" ]; then return 1; fi
  case "$a" in
    127.*|::1|localhost)
      if [ "$ALLOW_LOOPBACK" = 1 ]; then return 0; fi
      return 1
      ;;
    *) return 0 ;;
  esac
}
heal_aardvark(){
  if resolves "$CANARY"; then return 0; fi
  
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks"
  
  # Kill any existing aardvark-dns processes owned by us
  pkill -u "$(id -u)" -x aardvark-dns >/dev/null 2>&1 || true
  
  # Clear stale aardvark-dns state and network state so netavark respawns it
  rm -rf "$rt/aardvark-dns" 2>/dev/null || true
  rm -rf "$rt/$NET" 2>/dev/null || true
  
  sleep 1
  
  # The next resolves() will trigger netavark to respawn aardvark-dns
  if resolves "$CANARY"; then return 0; fi
  
  return 1
}
if ! heal_aardvark; then
  echo "dns-wait: CANARY '$CANARY' unresolved after heal" >&2
  exit 1
fi
echo "dns-wait: canary $CANARY resolved on $NET after heal"
for h in "${hosts[@]}"; do
  ok=0
  i=1
  while [ "$i" -le "$TRIES" ]; do
    if resolves "$h"; then ok=1; break; fi
    if [ $((i % 15)) -eq 0 ]; then heal_aardvark >/dev/null 2>&1 || true; fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  if [ "$ok" -ne 1 ]; then
    echo "dns-wait: host '$h' did not resolve non-loopback on '$NET' after $TRIES tries" >&2
    exit 1
  fi
  echo "dns-wait: resolved $h on $NET"
done
exit 0
DWEOF
chmod +x "$DNS_SCRIPT"
if ! bash -n "$DNS_SCRIPT"; then
  halt "new dns-wait failed bash -n"
fi
say "[Z1] durable guard rewritten: pkill + rm -rf aardvark-dns state -> $DNS_SCRIPT"

say "=== [Z2] reset and restart traefik.service ==="
systemctl --user reset-failed traefik.service >/dev/null 2>&1 || true
if ! systemctl --user restart traefik.service; then
  say "[Z2] traefik.service restart returned non-zero (verify via health)"
fi

say "=== [Z3] wait for traefik active + proxied gate ==="
ok=no
for i in $(seq 1 45); do
  if [ "$(systemctl --user is-active traefik.service)" = active ] && \
     [ "$(podman inspect traefik --format '{{.State.Status}}' 2>/dev/null)" = running ]; then
    ok=yes
    break
  fi
  sleep 2
done
if [ "$ok" != yes ]; then
  systemctl --user status --no-pager traefik.service 2>/dev/null | sed 's/^/    unit: /' || true
  journalctl --user -u traefik.service -n 30 --no-pager 2>/dev/null | sed 's/^/    j: /' || true
  halt "Z3 failed: traefik not active+running"
fi
say "[Z3] OK traefik active+running"

hc(){ local u="$1" h="${2:-}"; if [ -n "$h" ]; then curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "$u" 2>/dev/null || echo 000; else curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000; fi; }
wait_http(){
  local url="$1" host="$2" tries="${3:-30}" i code
  for i in $(seq 1 "$tries"); do
    code="$(hc "$url" "$host")"
    if [ "$code" = 200 ]; then return 0; fi
    sleep 2
  done
  return 1
}

P_FAIL=""
wait_http "http://127.0.0.1:8888/api/version" "traefik.aether.local" || P_FAIL="$P_FAIL traefik-api"
wait_http "http://127.0.0.1:8888/api/healthz" "gitea.aether.local" || P_FAIL="$P_FAIL gitea-proxy"
wait_http "http://127.0.0.1:8888/api/health" "woodpecker.aether.local" || P_FAIL="$P_FAIL woodpecker-proxy"
wait_http "http://127.0.0.1:8888/api/health" "grafana.aether.local" || P_FAIL="$P_FAIL grafana-proxy"
wait_http "http://127.0.0.1:8888/healthz" "n8n.aether.local" || P_FAIL="$P_FAIL n8n-proxy"

if [ -n "$P_FAIL" ]; then
  halt "Z3 proxied gate failed:$P_FAIL"
fi
say "[Z3] proxied gate PASS (all 200 through :8888)"

say "=== [Z4] ledger row ==="
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | 20261031-BZ-dns-wait-stale-state-heal | GATE=PASS | %s: fixes BY/BQ traefik start timeout. Root cause: heal_aardvark() used invalid `podman network reload $NET` (expects container name, rc=125) and did not clear /run/user/.../networks/aardvark-dns state dir, so netavark thought the dead daemon was still running and never respawned it, causing getent to time out (10s/try) and systemd to kill ExecStartPre. Fix: pkill + rm -rf $rt/aardvark-dns, letting the next podman run probe trigger netavark to spawn a fresh daemon. traefik restarted, proxied gate all 200. |\n' \
    "$(date +%F)" "$TOKEN" >> "$IDX"
  say "[Z4] BZ row appended."
fi

say "[RESULT] BZ FINALIZED — dns-wait=stale-state-healed traefik=active+running proxied=all200; next: build woodpecker pipeline proof."
exit 0
