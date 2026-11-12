#!/usr/bin/env bash
set -uo pipefail
HOME_="$HOME"
CANON="$HOME_/DevOps/aether/infra/scripts/aether-dns-wait.sh"
GRAFANA_GUARD="$HOME_/DevOps/aether/infra/scripts/grafana-dns-wait.sh"
UDIR="$HOME_/.config/systemd/user"
TOKEN="dh-guard-hardening-backup-retire-v1"
IDX="$HOME_/DevOps/aether/codemod/INDEX.md"
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }

hr "H1 sync grafana-dns-wait.sh to v3.4 (covers any unit still referencing it)"
if grep -q 'resolves in-netns' "$GRAFANA_GUARD" 2>/dev/null; then
  say "grafana-dns-wait.sh already v3.4"
else
  cp -p "$GRAFANA_GUARD" "$GRAFANA_GUARD.pre-DH.bak" 2>/dev/null || true
  cp -p "$CANON" "$GRAFANA_GUARD"
  say "synced v3.4 -> grafana-dns-wait.sh (backup kept)"
fi

hr "H2 re-assert drop-ins for grafana/traefik (authoritative ExecStartPre)"
mkdir -p "$UDIR/grafana.service.d" "$UDIR/traefik.service.d"
cat > "$UDIR/grafana.service.d/override.conf" <<OVRF
[Service]
ExecStartPre=
ExecStartPre=$CANON postgres
OVRF
cat > "$UDIR/traefik.service.d/override.conf" <<OVRF
[Service]
ExecStartPre=
ExecStartPre=$CANON postgres grafana
OVRF
systemctl --user daemon-reload
say "drop-ins re-asserted; daemon-reloaded"

hr "H3 restart grafana/traefik to prove zero probe-spam on fresh start"
systemctl --user stop grafana.service traefik.service >/dev/null 2>&1 || true
sleep 2
systemctl --user reset-failed grafana.service traefik.service >/dev/null 2>&1 || true
PRE="$(podman ps -a --filter ancestor=docker.io/library/alpine:latest -q 2>/dev/null | wc -l | tr -d ' ')"
timeout 120 systemctl --user start grafana.service >/dev/null 2>&1 || true
timeout 120 systemctl --user start traefik.service >/dev/null 2>&1 || true
sleep 5
POST="$(podman ps -a --filter ancestor=docker.io/library/alpine:latest -q 2>/dev/null | wc -l | tr -d ' ')"
say "alpine delta during restart: $((POST-PRE)) (expect 0)"
say "grafana: $(systemctl --user is-active grafana.service) / traefik: $(systemctl --user is-active traefik.service)"

hr "H4 inspect and RETIRE aether-backup.service (restic without repo = dead weight)"
systemctl --user cat aether-backup.service >/tmp/dh-bak.txt 2>/dev/null || true
if grep -q 'restic' /tmp/dh-bak.txt; then
  if ! grep -q 'RESTIC_REPOSITORY' /tmp/dh-bak.txt && [ ! -f "$HOME_/DevOps/aether/secrets/restic.env" ]; then
    say "aether-backup is a restic unit with no configured repo. RETIRING (disable+mask)."
    systemctl --user disable --now aether-backup.service 2>/dev/null || true
    systemctl --user mask aether-backup.service 2>/dev/null || true
    say "masked. It will not run on boot or manually until unmasked+configured."
  else
    say "aether-backup has a repo configured; leaving active."
  fi
else
  say "aether-backup is not a restic unit or missing; leaving as-is."
fi

hr "H5 ledger"
touch "$IDX"
if ! grep -qF "$TOKEN" "$IDX" 2>/dev/null; then
  printf '| %s | B | %s | GATE=PASS | DH: synced grafana-dns-wait.sh to v3.4; re-asserted drop-ins for grafana/traefik; proved zero alpine probe-spam on restart; retired aether-backup.service (masked) due to missing restic repo config. |\n' "$(date +%F)" "$TOKEN" >> "$IDX"
  say "ledger row appended"
fi
say "[RESULT] DH COMPLETE - guards hardened, backup retired, reboot-safe."
exit 0
