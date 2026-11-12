#!/usr/bin/env bash
# 20261029-L-weaviate-brick3.sh — replayable, POLL-CORRECTED (M1). Gate = ready(unauth) 200; schema(INFO).
# Parity note (M1): lock.running_id is an IMAGE ID (config digest), NOT a pullable manifest digest; for a
#   :latest-captured service the only pullable parity is :latest (newer than captured by design). Do NOT
#   attempt @<image-id> pulls (=> 'manifest schema unsupported'). Volume pairs read from the source unit.
set -uo pipefail
A="$HOME/DevOps/aether"; QD="$A/infra/quadlet"; SYS="$HOME/.config/containers/systemd"
hc(){ curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || true; }
while IFS=: read -r nm d; do [ -z "$nm" ] && continue; podman volume exists "$nm" 2>/dev/null || podman volume create "$nm" >/dev/null; done < <(grep '^Volume=' "$QD/weaviate.container" | sed 's/^Volume=//')
install -D -m 644 "$QD/weaviate.container" "$SYS/weaviate.container"
systemctl --user daemon-reload; systemctl --user enable weaviate.service 2>/dev/null||true; systemctl --user start weaviate.service
R=""; SEQ=""
for i in $(seq 1 30); do R=$(hc http://127.0.0.1:8080/v1/.well-known/ready); [ -z "$R" ] && R=000; SEQ+="$R "; [ "$R" = 200 ] && break; sleep 3; done
[ "$R" = 200 ] && echo "  [GATE PASS] weaviate ready=200 seq=[$SEQ]" || { echo "  [GATE FAIL] ready=$R seq=[$SEQ]"; exit 1; }
