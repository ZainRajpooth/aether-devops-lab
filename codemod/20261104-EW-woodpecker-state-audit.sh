#!/usr/bin/env bash
# 20261104-EW — READ-ONLY audit of Woodpecker CI + Gitea state for Brick 12.
# Inspects env vars (redacted), API reachability, and agent logs. No mutations.
set -uo pipefail
say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
redact_val(){ sed -E 's/(_SECRET|_PASSWORD|_TOKEN|_CLIENT_SECRET|_KEY)=.*/\1=***REDACTED***/I'; }

hr "W0 Woodpecker Server Env & API"
podman inspect woodpecker-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -iE 'WOODPECKER_|GITEA|HOST|AGENT|PORT' | redact_val | sed 's/^/    /' || say "    inspect failed"
SV_CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/api/version 2>/dev/null || echo 000)"
SV_TRAEFIK="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H 'Host: woodpecker.aether.local' http://127.0.0.1:8888/api/version 2>/dev/null || echo 000)"
say "server API (localhost:8000) = $SV_CODE"
say "server API (traefik woodpecker.aether.local:8888) = $SV_TRAEFIK"

hr "W1 Woodpecker Agent Env & Logs"
podman inspect woodpecker-agent --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -iE 'WOODPECKER_|SERVER|AGENT|BACKEND' | redact_val | sed 's/^/    /' || say "    inspect failed"
say "agent recent logs (last 8 lines):"
podman logs woodpecker-agent 2>&1 | tail -8 | sed 's/^/    /' || true

hr "W2 Gitea API & Webhook capability"
GT_CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/v1/version 2>/dev/null || echo 000)"
GT_TRAEFIK="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H 'Host: gitea.aether.local' http://127.0.0.1:8888/api/v1/version 2>/dev/null || echo 000)"
say "gitea API (localhost:3000) = $GT_CODE"
say "gitea API (traefik gitea.aether.local:8888) = $GT_TRAEFIK"

hr "W3 synthesis"
say "If server API = 200 and agent logs show 'connected to server' or 'starting backend', the CI plane is live."
say "If server API = 000 or 404, Traefik routing or port publishing needs fixing before EX."
say "[RESULT] EW COMPLETE - paste W0-W2 verbatim; EX (repo+webhook+build) is built from these facts."
exit 0
