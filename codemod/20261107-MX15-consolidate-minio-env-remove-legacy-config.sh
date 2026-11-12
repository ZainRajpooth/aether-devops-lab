#!/usr/bin/env bash
# 20261107-MX15 — Consolidate MinIO env to ~/DevOps/aether/secrets/aether.env
# and safely remove /home/dev/.config/aether/.
#
# Steps:
#   1) Backup both env files.
#   2) Merge any unique keys from .config/aether/secrets.env into aether.env.
#   3) Update minio.container Quadlet to use ONLY EnvironmentFile=aether.env.
#   4) Reload systemd, restart MinIO, verify API/Console.
#   5) If healthy, prompt to delete /home/dev/.config/aether/.
#
# No data loss. Secrets masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"

TOKEN="mx15-consolidate-minio-env-remove-legacy-config-v1"
CONTAINER="${MINIO_CONTAINER:-minio}"
SERVICE="${MINIO_SERVICE:-minio.service}"
QUADLET="$HOME_/.config/containers/systemd/minio.container"

TARGET_ENV="$SEC/aether.env"
LEGACY_ENV="/home/dev/.config/aether/secrets.env"
LEGACY_DIR="/home/dev/.config/aether"

STAMP="$(date +%Y%m%d-%H%M%S)"
BAK_TARGET="${TARGET_ENV}.pre-mx15.${STAMP}.bak"
BAK_LEGACY="${LEGACY_ENV}.pre-mx15.${STAMP}.bak"
BAK_QUADLET="${QUADLET}.pre-mx15.${STAMP}.bak"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

mkdir -p "$CD" "$SEC"
touch "$IDX"

ledger(){
  local gate="$1" desc="$2" row_token="${TOKEN}:${gate}"
  if ! grep -qF "$row_token" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=%s | %s |\n' "$(date +%F)" "$row_token" "$gate" "$desc" >> "$IDX"
    say "ledger row appended: $row_token"
  fi
}

mask_stream(){
  python3 - <<'PYMASK'
import sys, re
kv = re.compile(r"([A-Za-z0-9_]*(?:PASSWORD|SECRET|KEY|TOKEN|AUTH|CREDENTIAL|PRIVATE|ENCRYPTION|MASTER)[A-Za-z0-9_]*)=([^\s\"']+)")
jwt = re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")
def repl(m): return f"{m.group(1)}=[REDACTED len={len(m.group(2))}]"
for line in sys.stdin:
    line = kv.sub(repl, line)
    line = jwt.sub("[JWT]", line)
    sys.stdout.write(line)
PYMASK
}

http_code(){
  local c
  c="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true)"
  printf '%s\n' "${c:-000}"
}

hr "X0 preflight"
for c in python3 curl podman awk sed grep systemctl diff cp mv rm; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
podman inspect "$CONTAINER" >/dev/null 2>&1 || halt "container missing: $CONTAINER"
[ -f "$QUADLET" ] || halt "missing quadlet: $QUADLET"
[ -f "$TARGET_ENV" ] || halt "missing target env: $TARGET_ENV"
[ -f "$LEGACY_ENV" ] || {
  say "Legacy env file not found: $LEGACY_ENV"
  say "Nothing to merge/remove. Exiting."
  ledger "SKIP" "MX15 legacy env file already absent"
  exit 0
}

say "target env: $TARGET_ENV"
say "legacy env: $LEGACY_ENV"
say "quadlet:    $QUADLET"

hr "X1 backups"
cp -p "$TARGET_ENV" "$BAK_TARGET"; chmod 600 "$BAK_TARGET"
say "backed up target: $BAK_TARGET"

cp -p "$LEGACY_ENV" "$BAK_LEGACY"; chmod 600 "$BAK_LEGACY"
say "backed up legacy: $BAK_LEGACY"

cp -p "$QUADLET" "$BAK_QUADLET"; chmod 600 "$BAK_QUADLET"
say "backed up quadlet: $BAK_QUADLET"

hr "X2 merge unique keys from legacy to target"
python3 - "$TARGET_ENV" "$LEGACY_ENV" > "$TMP/merged.env" <<'PYMERGE'
import sys

target_path, legacy_path = sys.argv[1], sys.argv[2]

def parse_env(path):
    d = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip()
    except Exception:
        pass
    return d

t_data = parse_env(target_path)
l_data = parse_env(legacy_path)

# Start with target content
out_lines = []
with open(target_path, "r", encoding="utf-8", errors="replace") as f:
    out_lines.extend(f.readlines())

# Add keys from legacy that are NOT in target
added = []
for k, v in l_data.items():
    if k not in t_data:
        out_lines.append(f"{k}={v}\n")
        added.append(k)

if added:
    sys.stderr.write(f"Merged {len(added)} new keys from legacy: {', '.join(sorted(added))}\n")
else:
    sys.stderr.write("No new keys to merge.\n")

sys.stdout.writelines(out_lines)
PYMERGE

if [ $? -ne 0 ]; then
  halt "merge failed"
fi

mv "$TMP/merged.env" "$TARGET_ENV"
chmod 600 "$TARGET_ENV"
say "updated $TARGET_ENV with merged keys"

hr "X3 update Quadlet to use ONLY target env"
python3 - "$QUADLET" "$TARGET_ENV" <<'PYQUADLET'
import os, sys, tempfile

path, new_env = sys.argv[1], sys.argv[2]

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

start, end = None, len(lines)
for i, l in enumerate(lines):
    s = l.strip()
    if s == "[Container]": start = i
    elif start is not None and i > start and s.startswith("[") and s.endswith("]"):
        end = i; break

body = lines[start+1:end] if start is not None else lines

new_body = []
seen_env = False

for l in body:
    s = l.strip()
    if s.startswith("EnvironmentFile="):
        if not seen_env:
            new_body.append(f"EnvironmentFile={new_env}\n")
            seen_env = True
        # Drop other EnvironmentFile lines
        continue
    new_body.append(l)

if not seen_env:
    new_body.insert(0, f"EnvironmentFile={new_env}\n")

out = lines[:start+1] + new_body + lines[end:] if start is not None else new_body

fd, tmp = tempfile.mkstemp(prefix=".mx15-q-", dir=os.path.dirname(path) or ".")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(out)
    st = os.stat(path)
    os.chmod(tmp, st.st_mode & 0o777)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        try: os.unlink(tmp)
        except Exception: pass
PYQUADLET

say "updated $QUADLET:"
grep '^EnvironmentFile=' "$QUADLET" | sed 's/^/    /' || true

hr "X4 reload systemd and restart MinIO"
systemctl --user daemon-reload
systemctl --user reset-failed "$SERVICE" || true
systemctl --user restart "$SERVICE"

sleep 5

API_HEALTH="$(http_code http://127.0.0.1:9010/minio/health/live)"
CONSOLE_HEALTH="$(http_code http://127.0.0.1:9011/browser)"

say "API health 9010 = $API_HEALTH"
say "Console health 9011 = $CONSOLE_HEALTH"

if [ "$API_HEALTH" != 200 ] || [ "$CONSOLE_HEALTH" != 200 ]; then
  say "--- MinIO logs tail 40 ---"
  podman logs --tail 40 "$CONTAINER" 2>&1 | mask_stream | sed 's/^/    /' || true
  say "ROLLING BACK QUADLET AND ENV"
  cp -p "$BAK_QUADLET" "$QUADLET"
  cp -p "$BAK_TARGET" "$TARGET_ENV"
  systemctl --user daemon-reload
  systemctl --user restart "$SERVICE"
  sleep 5
  ledger "FAIL" "MX15 consolidation failed; rolled back"
  halt "MinIO unhealthy after consolidation; rolled back"
fi

say "[OK] MinIO is healthy with consolidated env"

hr "X5 cleanup legacy config directory?"
say "The following directory is no longer referenced by MinIO:"
say "  $LEGACY_DIR"
printf 'Type YES to permanently remove %s. Anything else keeps it: ' "$LEGACY_DIR" > /dev/tty
IFS= read -r PURGE < /dev/tty
printf '\n' > /dev/tty

if [ "$PURGE" = "YES" ]; then
  rm -rf "$LEGACY_DIR"
  say "removed: $LEGACY_DIR"
  ledger "PASS" "MX15: consolidated MinIO env to aether.env; removed legacy .config/aether/"
else
  say "kept: $LEGACY_DIR"
  ledger "PARTIAL" "MX15: consolidated MinIO env; kept legacy .config/aether/ for safety"
fi

exit 0
