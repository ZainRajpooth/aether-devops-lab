#!/usr/bin/env bash
# Replay/verify for BB: ensure healed n8n is active and steel thread green.
set -uo pipefail
A="$HOME/DevOps/aether"
UNIT_SRC="$A/infra/systemd/n8n.service"
UNIT_INST="$HOME/.config/systemd/user/n8n.service"
install -D -m 644 "$UNIT_SRC" "$UNIT_INST"
systemctl --user daemon-reload
systemctl --user enable n8n.service >/dev/null 2>&1 || true
systemctl --user start n8n.service
HZ=no
for i in $(seq 1 120); do
  B="$(curl -s --max-time 5 http://127.0.0.1:5678/healthz 2>/dev/null || true)"
  if printf '%s' "$B" | grep -q '"status":"ok"'; then
    HZ=yes
    break
  fi
  sleep 2
done
D="$(podman exec n8n node -e 'fetch("http://litellm:4000/v1/embeddings",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+process.env.LITELLM_MASTER_KEY},body:JSON.stringify({model:"local-embed",input:"BB replay"})}).then(r=>r.json()).then(d=>{var e=(d&&d.data&&d.data[0]&&d.data[0].embedding)||[];console.log("DIMS="+e.length)}).catch(()=>{console.log("DIMS=0")})' 2>&1 || true)"
D="$(printf '%s' "$D" | sed -n 's/.*DIMS=\([0-9][0-9]*\).*/\1/p' | head -n1)"
if [ "$HZ" = yes ] && [ "${D:-0}" -gt 0 ]; then
  echo "  [GATE PASS] n8n healthz=ok dims=$D"
else
  echo "  [GATE FAIL] n8n healthz=$HZ dims=${D:-0}"
  exit 1
fi
