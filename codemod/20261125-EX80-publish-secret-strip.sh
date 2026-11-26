#!/usr/bin/env bash
# EX80 verifier. Verdicts from exit codes / structured fields only.
set -uo pipefail
A="$HOME/DevOps/aether"; CACHE="$HOME/.cache/aether"; GL="gitleaks_8.21.2_linux_x64.tar.gz"
grep -q '\*.pem' "$A/.woodpecker.yml" && echo "  sanitize find extended: PASS" || { echo "[HALT] find"; exit 1; }
[ "$(grep -c 'TOKEN="ex6' "$A/codemod/20261115-EX64a-disk-reclaim.sh" "$A/codemod/20261115-EX65-observability.sh" | awk -F: '{s+=$2} END{print s+0}')" = 0 ] \
  && echo "  ledger vars de-keyworded: PASS" || { echo "[HALT] keyword vars"; exit 1; }
git -C "$A" ls-remote origin main >/dev/null 2>&1 && echo "  aether origin usable: PASS" || { echo "[HALT] origin"; exit 1; }
SHA=$(git -C "$A" rev-parse HEAD); RH=$(git -C "$A" ls-remote origin main | awk '{print $1}')
[ "$SHA" = "$RH" ] && echo "  remote HEAD == local: PASS" || { echo "[HALT] HEAD mismatch"; exit 1; }
W=$(mktemp -d); mkdir -p "$W/.publish" "$W/out"
for d in docs infra codemod; do [ -d "$A/$d" ] && cp -a "$A/$d" "$W/.publish/"; done
for f in README.md .woodpecker.yml; do [ -f "$A/$f" ] && cp -a "$A/$f" "$W/.publish/"; done
find "$W/.publish" -type f \( -name '*.env' -o -name '*.pass' -o -name '*.token' -o -name '*.bak' -o -name '*.pre-*' -o -name '*.pem' -o -name '*.key' -o -name '*.db' -o -name '*.sqlite' \) -delete
while IFS= read -r rel; do [ -n "$rel" ] && rm -f "$W/.publish/$rel"; done < "$A/infra/publish-blocklist.txt" 2>/dev/null
podman run --rm -v "$W/.publish":/src:ro -v "$A/infra":/infra:ro -v "$CACHE":/cache:ro -v "$W/out":/out \
  docker.io/alpine:latest sh -c "tar -xzf /cache/$GL -C /usr/local/bin gitleaks; cp -a /src /scan; gitleaks detect --config /infra/publish-allowlist.toml --no-git --source /scan --report-format json --report-path /out/f.json >/out/log 2>&1; echo \$? > /out/rc"
RC=$(cat "$W/out/rc" 2>/dev/null || echo 99)
CNT=$(python3 -c "import json,os; p='$W/out/f.json'; print(len(json.load(open(p))) if os.path.exists(p) else 0)" 2>/dev/null || echo NA)
rm -rf "$W"
[ "$RC" = 0 ] && [ "$CNT" = 0 ] && echo "  gitleaks RC=0 count=0: PASS" || { echo "[HALT] scan RC=$RC CNT=$CNT"; exit 1; }
T=$(tr -d '\r\n' < "$A/secrets/woodpecker-pat.token")
curl -s --max-time 8 -H "Authorization: Bearer $T" "http://127.0.0.1:8000/api/repos/2/pipelines?perPage=10" -o /tmp/ex80v.json
python3 -c "
import json,sys
d=json.load(open('/tmp/ex80v.json'))
m=[p for p in (d if isinstance(d,list) else []) if p.get('commit')=='$SHA']
ok=bool(m) and m[0].get('status')=='success'
print('  CI success for HEAD:','PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)" || { echo "[HALT] CI"; exit 1; }
echo "  DEBT: portainer runtime data belongs in a podman volume, not infra/ working tree"
echo "[RESULT] EX80 VERIFY PASS"
