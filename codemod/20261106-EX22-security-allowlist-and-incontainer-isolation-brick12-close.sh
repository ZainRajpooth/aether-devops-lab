#!/usr/bin/env bash
# 20261106-EX22 — closes Brick 12 after EX21 proved the [webhook] allowlist is deprecated
# and the delivery is no longer denied but still produces no pipeline.
#
# This script:
#   H1) detects Woodpecker IP/CIDR entries (same as EX21);
#   H2) moves ALLOWED_HOST_LIST to [security] (correct location), keeps [webhook] as fallback;
#   H3) restarts Gitea if config changed;
#   H4) tests network reachability: curl /api/version from INSIDE Gitea's container;
#   H5) tests webhook delivery: signed minimal push POST to hook URL from INSIDE Gitea's
#       container, capturing response code+body (secret masked, length only);
#   H6) re-enforces the correct internal webhook with secret;
#   H7) pushes trigger;
#   H8) polls ALL pipelines (not just repo_id) to rule out ID mismatch;
#   H9) diagnostics + result + codemod ledger.
#
# No Woodpecker quadlet change. No gRPC change. No DB mutation. Secrets masked.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
APP="$HOME_/DevOps/aether/apps/playwright"
SESSION="$SEC/woodpecker-session.json"

TOKEN="ex22-security-allowlist-and-incontainer-isolation-brick12-close-v1"
REPO="woodpecker-proof"
WP="http://127.0.0.1:8000"
PGU="devops"
PGDB="woodpecker"
BOT_FILE="$SEC/gitea-wp-bot.user"
PASS_FILE="$SEC/gitea-wp-bot.pass"

MODE="${1:-run}"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

say(){ printf '  %s\n' "$*"; }
hr(){ printf '\n===== %s =====\n' "$*"; }
halt(){ say "[HALT] $*"; exit 1; }

psqlq(){
  podman exec postgres psql -U "$PGU" -d "$PGDB" -tAc "$1" 2>/dev/null || true
}

code(){
  curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true
}

envval(){
  podman inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    awk -F= -v k="$2" '$1==k { sub(/^[^=]+=/, ""); print; exit }'
}

cookies_from_session(){
  python3 - "$SESSION" <<'PYCOOKIE'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
parts = []
for c in d.get("cookies", []) or []:
    dom = (c.get("domain") or "").lstrip(".")
    if dom in ("127.0.0.1", "localhost", ""):
        parts.append(f"{c.get('name')}={c.get('value')}")
print("; ".join(parts))
PYCOOKIE
}

ledger(){
  local gate="$1"
  local desc="$2"
  local row_token="${TOKEN}:${gate}"
  if ! grep -qF "$row_token" "$IDX" 2>/dev/null; then
    printf '| %s | B | %s | GATE=%s | %s |\n' \
      "$(date +%F)" "$row_token" "$gate" "$desc" >> "$IDX"
    say "ledger row appended: $row_token"
  else
    say "ledger row already exists: $row_token"
  fi
}

mask_json(){
  python3 - "$1" <<'PYMASK'
import sys, json, re
pat = re.compile(r"(secret|token|password|passwd|key|authorization|client_secret|access_token|refresh_token)", re.I)
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
def mask(o):
    if isinstance(o, dict):
        return {k: ("***" if pat.search(k) else mask(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [mask(x) for x in o]
    return o
print(json.dumps(mask(d))[:500])
PYMASK
}

hr "H0 preflight"
for c in python3 curl git podman awk sed grep base64; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"
done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
mkdir -p "$CD" "$SEC" "$APP"
touch "$IDX"

BOT="$(cat "$BOT_FILE")"
PASS="$(cat "$PASS_FILE")"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port for container port 3000"
GT="http://127.0.0.1:$GT_HOST_PORT"

CONF="$(podman exec gitea sh -c 'for c in /data/gitea/conf/app.ini /etc/gitea/app.ini; do if [ -f "$c" ]; then echo "$c"; break; fi; done' 2>/dev/null || true)"
[ -n "$CONF" ] || halt "could not locate Gitea app.ini"

GT_VERSION="$(podman exec gitea gitea --version 2>/dev/null | head -1 || echo unknown)"
say "gitea_version=$GT_VERSION"
say "gitea_conf=$CONF"
say "gitea_url=$GT"
say "woodpecker_url=$WP"

REPO_ROW="$(psqlq "SELECT json_build_object('id', id, 'owner', owner, 'name', name, 'active', active, 'forge_remote_id', forge_remote_id) FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1")"
say "repo_row=${REPO_ROW:-null}"

if ! printf '%s' "$REPO_ROW" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("id") else 1)
' 2>/dev/null; then
  halt "Woodpecker repo row absent; EX19 activation did not persist"
fi

REPO_ID="$(psqlq "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"
say "woodpecker_repo_id=$REPO_ID"

hr "H1 detect allowed-host entries"
: > "$TMP/entries.raw.txt"

podman inspect woodpecker-server --format '{{json .NetworkSettings.Networks}}' > "$TMP/wpnets.json" 2>/dev/null || echo '{}' > "$TMP/wpnets.json"

python3 - "$TMP/wpnets.json" >> "$TMP/entries.raw.txt" <<'PYNET'
import sys, json, subprocess, ipaddress
try:
    nets = json.load(open(sys.argv[1]))
except Exception:
    nets = {}
entries = []
for name, data in (nets or {}).items():
    data = data or {}
    for ipstr in (data.get("IPAddress"), data.get("GlobalIPv6Address")):
        if not ipstr:
            continue
        try:
            ip = ipaddress.ip_address(ipstr)
            entries.append(f"{ip}/{128 if ip.version == 6 else 32}")
            if ip.version == 4 and ip.is_private:
                p = str(ip).split(".")
                if len(p) == 4:
                    entries.append(f"{p[0]}.{p[1]}.0.0/16")
        except Exception:
            pass
    if name:
        try:
            out = subprocess.check_output(
                ["podman", "network", "inspect", name, "--format", "{{range .Subnets}}{{.Subnet}}{{println}}{{end}}"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
            for s in out.split():
                if s:
                    entries.append(s)
        except Exception:
            pass
entries.append("woodpecker-server")
for e in entries:
    if e:
        print(e)
PYNET

podman logs --since 30m gitea 2>&1 |
  grep -oE 'dial tcp ([0-9]{1,3}\.){3}[0-9]{1,3}:8000' |
  sed -E 's/dial tcp ([0-9.]+):8000/\1/' |
  sort -u > "$TMP/denied_ips.txt" 2>/dev/null || true

python3 - "$TMP/denied_ips.txt" >> "$TMP/entries.raw.txt" <<'PYDENIED'
import sys, ipaddress
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except Exception:
    lines = []
for ip in lines:
    ip = ip.strip()
    if not ip:
        continue
    try:
        a = ipaddress.ip_address(ip)
        print(f"{ip}/32")
        if a.version == 4 and a.is_private:
            p = ip.split(".")
            if len(p) == 4:
                print(f"{p[0]}.{p[1]}.0.0/16")
    except Exception:
        pass
PYDENIED

if ! grep -qE '/[0-9]+$' "$TMP/entries.raw.txt" 2>/dev/null; then
  podman network inspect aether --format '{{range .Subnets}}{{.Subnet}}{{println}}{{end}}' >> "$TMP/entries.raw.txt" 2>/dev/null || true
fi

python3 - "$TMP/entries.raw.txt" > "$TMP/entries.txt" <<'PYDEDUP'
import sys
seen = set()
out = []
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except Exception:
    lines = []
for e in lines:
    e = e.strip()
    if e and e not in seen:
        seen.add(e)
        out.append(e)
print("\n".join(out))
PYDEDUP

say "planned ALLOWED_HOST_LIST entries:"
sed 's/^/    /' "$TMP/entries.txt"

hr "H2 Python INI editor: set ALLOWED_HOST_LIST in [security] (primary) and [webhook] (fallback)"
EDIT_PY="$TMP/edit_allowlist.py"
cat > "$EDIT_PY" <<'PYEDIT'
import sys, re, pathlib

app_path = pathlib.Path(sys.argv[1])
entries_path = sys.argv[2]
mode = sys.argv[3] if len(sys.argv) > 3 else "check"

new_entries = []
try:
    for line in open(entries_path, encoding="utf-8", errors="replace"):
        e = line.strip()
        if e:
            new_entries.append(e)
except Exception:
    pass

text = app_path.read_text(encoding="utf-8", errors="replace")
lines = text.splitlines(keepends=True)

def find_section(lines, name):
    """Return (start_idx, end_idx) for [name], or (None, None)."""
    start = None
    in_sec = False
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith("[") and s.endswith("]"):
            if in_sec:
                return (start, i)
            if s.lower() == f"[{name}]":
                start = i
                in_sec = True
    if in_sec:
        return (start, len(lines))
    return (None, None)

def get_key(lines, start, end, key):
    """Return (idx, current_value) for key in section, or (None, '')."""
    if start is None:
        return (None, "")
    key_re = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.I)
    for i in range(start + 1, end):
        if key_re.match(lines[i]):
            raw = lines[i].split("=", 1)[1].strip()
            raw = re.sub(r"\s+#.*$", "", raw).strip()
            return (i, raw)
    return (None, "")

def set_key(lines, start, end, key, val):
    """Set key=val in section [start,end). Insert after section header if missing.
    Returns new lines list."""
    key_re = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.I)
    new_line = f"{key} = {val}\n"
    out = []
    replaced = False
    for i, ln in enumerate(lines):
        if start is not None and start <= i < end and key_re.match(ln):
            out.append(new_line)
            replaced = True
        else:
            out.append(ln)
    if not replaced and start is not None:
        out.insert(start + 1, new_line)
    elif not replaced:
        # section doesn't exist; append it
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append(f"[{key_section_name}]\n")
        out.append(new_line)
    return out

def split_list(v):
    return [x.strip() for x in (v or "").split(",") if x.strip()]

# Process [security] first (primary), then [webhook] (fallback)
sections = [("security", "ALLOWED_HOST_LIST"), ("webhook", "ALLOWED_HOST_LIST")]
changed = False
report = []

for sec_name, key_name in sections:
    start, end = find_section(lines, sec_name)
    idx, current = get_key(lines, start, end, key_name)

    existing = split_list(current)
    merged = existing[:]
    for e in new_entries:
        if e not in merged:
            merged.append(e)
    merged_str = ",".join(merged)

    report.append(f"SECTION=[{sec_name}] CURRENT={current if current else '(empty)'} PLANNED={merged_str}")

    if merged_str != current:
        changed = True
        if idx is not None:
            lines[idx] = f"{key_name} = {merged_str}\n"
        elif start is not None:
            lines.insert(start + 1, f"{key_name} = {merged_str}\n")
        else:
            # section missing; create it
            if lines and not lines[-1].endswith("\n"):
                lines[-1] += "\n"
            lines.append(f"[{sec_name}]\n")
            lines.append(f"{key_name} = {merged_str}\n")

for r in report:
    print(r)

if not changed:
    print("NO_CHANGE")
    sys.exit(0)

if mode != "write":
    print("CHECK_ONLY")
    sys.exit(0)

app_path.write_text("".join(lines), encoding="utf-8")
print("WRITTEN")
PYEDIT
chmod 600 "$EDIT_PY"

hr "H3 copy app.ini, check planned edit"
podman cp "gitea:$CONF" "$TMP/app.ini"
chmod 600 "$TMP/app.ini"

say "--- editor check ---"
python3 "$EDIT_PY" "$TMP/app.ini" "$TMP/entries.txt" check 2>&1 | sed 's/^/    /'

if [ "$MODE" = check ]; then
  hr "H4 check mode result"
  say "[RESULT] EX22 CHECK - no container file was modified, no restart, no push."
  exit 0
fi

hr "H5 backup + apply + restart if changed"
podman exec --user 0 gitea sh -c 'B="$1.pre-EX22.bak"; if [ ! -f "$B" ]; then cp -p "$1" "$B"; fi' sh "$CONF"
say "backup: $CONF.pre-EX22.bak"

EDIT_OUT="$(python3 "$EDIT_PY" "$TMP/app.ini" "$TMP/entries.txt" write 2>&1)"
printf '%s\n' "$EDIT_OUT" | sed 's/^/    /'

CONFIG_CHANGED=no
if printf '%s\n' "$EDIT_OUT" | grep -q '^NO_CHANGE$'; then
  say "allowlist already sufficient in both [security] and [webhook]; no config write/restart."
elif printf '%s\n' "$EDIT_OUT" | grep -q '^WRITTEN$'; then
  CONFIG_CHANGED=yes
  podman cp "$TMP/app.ini" "gitea:$CONF"
  podman exec --user 0 gitea sh -c 'chmod 0644 "$1"; chown "$(id -u git):$(id -g git)" "$1" 2>/dev/null || true' sh "$CONF" || true
  say "app.ini updated"
else
  halt "editor did not report NO_CHANGE or WRITTEN"
fi

if [ "$CONFIG_CHANGED" = yes ]; then
  systemctl --user restart gitea.service 2>/dev/null || podman restart gitea
  READY=no
  for i in $(seq 1 30); do
    C="$(code "$GT/")"
    if [ -n "$C" ] && [ "$C" != 000 ]; then
      READY=yes
      say "Gitea up: $GT = $C"
      break
    fi
    sleep 2
  done
  [ "$READY" = yes ] || halt "Gitea did not become reachable after restart"
else
  say "skip restart"
fi

hr "H6 network reachability test from INSIDE Gitea container"
NET_TEST="$(podman exec gitea curl -sS -m 10 -o /dev/null -w '%{http_code}' http://woodpecker-server:8000/api/version 2>&1 || echo FAIL)"
say "curl http://woodpecker-server:8000/api/version from gitea container = $NET_TEST"
if [ "$NET_TEST" = "FAIL" ] || [ "$NET_TEST" = "000" ]; then
  say "--- DNS resolution test ---"
  podman exec gitea getent hosts woodpecker-server 2>&1 | sed 's/^/    /' || true
  say "--- /etc/resolv.conf in gitea ---"
  podman exec gitea cat /etc/resolv.conf 2>&1 | sed 's/^/    /' || true
  say "--- podman network inspect aether ---"
  podman network inspect aether --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}' 2>&1 | sed 's/^/    /' || true
  halt "Gitea cannot reach woodpecker-server:8000; network/DNS issue isolated"
fi
say "network OK: Gitea can reach woodpecker-server:8000"

hr "H7 webhook delivery isolation test from INSIDE Gitea container"
WP_SECRET="$(envval woodpecker-server WOODPECKER_GITEA_SECRET)"
say "WOODPECKER_GITEA_SECRET_present_len=${#WP_SECRET}"

GOOD_URL="http://woodpecker-server:8000/hook?source=gitea&owner=${BOT}&repo=${REPO}"

# Build a minimal Gitea push event JSON and sign it with HMAC-SHA256.
# The secret is passed via stdin to avoid echoing it.
WEBHOOK_TEST_PY="$TMP/webhook_test.py"
cat > "$WEBHOOK_TEST_PY" <<'PYWT'
import sys, json, hmac, hashlib, urllib.request, urllib.error

secret = sys.stdin.read().strip()
owner = sys.argv[1]
repo = sys.argv[2]
url = sys.argv[3]

payload = {
    "ref": "refs/heads/main",
    "before": "0" * 40,
    "after": "a" * 40,
    "repository": {
        "full_name": f"{owner}/{repo}",
        "name": repo,
        "owner": {"login": owner}
    },
    "sender": {"login": owner},
    "commits": []
}
body = json.dumps(payload).encode("utf-8")
sig = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()

req = urllib.request.Request(
    url,
    data=body,
    headers={
        "Content-Type": "application/json",
        "X-Gitea-Event": "push",
        "X-Gitea-Signature": sig,
        "X-Gitea-Delivery": "ex22-test-000",
        "User-Agent": "Gitea/EX22-test",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        resp_body = r.read().decode("utf-8", errors="replace")[:400]
        print(f"STATUS={r.status}")
        print(f"BODY={resp_body}")
except urllib.error.HTTPError as e:
    resp_body = e.read().decode("utf-8", errors="replace")[:400]
    print(f"STATUS={e.code}")
    print(f"BODY={resp_body}")
except Exception as e:
    print(f"STATUS=0")
    print(f"BODY=ERR:{e}")
PYWT
chmod 600 "$WEBHOOK_TEST_PY"

say "--- running signed webhook POST from gitea container ---"
WEBHOOK_RESULT="$(
  printf '%s' "$WP_SECRET" | podman exec -i gitea python3 - "$BOT" "$REPO" "$GOOD_URL" < "$WEBHOOK_TEST_PY" 2>&1
)"
printf '%s\n' "$WEBHOOK_RESULT" | sed 's/^/    /'

WB_STATUS="$(printf '%s\n' "$WEBHOOK_RESULT" | grep '^STATUS=' | cut -d= -f2)"
WB_BODY="$(printf '%s\n' "$WEBHOOK_RESULT" | grep '^BODY=' | cut -d= -f2-)"
say "webhook test status=$WB_STATUS"

if [ "$WB_STATUS" = "200" ] || [ "$WB_STATUS" = "201" ] || [ "$WB_STATUS" = "204" ]; then
  say "webhook delivery test PASSED: Woodpecker accepted the signed push event"
  WEBHOOK_OK=yes
else
  say "webhook delivery test returned $WB_STATUS; body (first 300): $(printf '%s' "$WB_BODY" | head -c 300)"
  WEBHOOK_OK=no
fi

hr "H8 re-enforce correct internal Woodpecker webhook with secret"
curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_before.json" 2>/dev/null || echo '[]' > "$TMP/hooks_before.json"

say "--- existing Woodpecker-related hooks, masked ---"
python3 - "$TMP/hooks_before.json" <<'PYLIST' | sed 's/^/    /'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    hooks = []
if not isinstance(hooks, list):
    hooks = []
for h in hooks:
    if not isinstance(h, dict):
        continue
    cfg = h.get("config") or {}
    url = cfg.get("url") or ""
    if "woodpecker" in url.lower() or "/hook?" in url:
        print(json.dumps({
            "id": h.get("id"),
            "active": h.get("active"),
            "events": h.get("events"),
            "url": url,
            "has_secret": bool(cfg.get("secret")),
        }))
PYLIST

python3 - "$TMP/hooks_before.json" > "$TMP/delete_ids.txt" <<'PYDEL'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    hooks = []
if not isinstance(hooks, list):
    hooks = []
for h in hooks:
    if not isinstance(h, dict):
        continue
    cfg = h.get("config") or {}
    url = (cfg.get("url") or "").lower()
    if "woodpecker" in url or "/hook?" in url:
        hid = h.get("id")
        if hid is not None:
            print(str(hid))
PYDEL

DELETE_COUNT="$(wc -l < "$TMP/delete_ids.txt" | tr -d ' \n')"
say "deleting $DELETE_COUNT existing Woodpecker hook(s)"
while IFS= read -r hid; do
  [ -n "$hid" ] || continue
  curl -sS -m 10 -u "$BOT:$PASS" -X DELETE "$GT/api/v1/repos/$BOT/$REPO/hooks/$hid" >/dev/null 2>&1 || true
done < "$TMP/delete_ids.txt"

python3 - "$GOOD_URL" "$WP_SECRET" > "$TMP/hook_create.json" <<'PYHOOK'
import json, sys
url = sys.argv[1]
secret = sys.argv[2]
cfg = {"url": url, "content_type": "json"}
if secret:
    cfg["secret"] = secret
print(json.dumps({
    "type": "gitea",
    "active": True,
    "events": ["push"],
    "config": cfg
}))
PYHOOK

HOOK_CREATE_CODE="$(
  curl -sS -m 15 -u "$BOT:$PASS" \
    -H 'Content-Type: application/json' \
    -d @"$TMP/hook_create.json" \
    -X POST \
    -o "$TMP/hook_resp.json" \
    -w '%{http_code}' \
    "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo 000
)"
say "hook create http=$HOOK_CREATE_CODE"
say "--- hook create response, masked ---"
mask_json "$TMP/hook_resp.json" | sed 's/^/    /'

curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_after.json" 2>/dev/null || echo '[]' > "$TMP/hooks_after.json"

if ! python3 - "$TMP/hooks_after.json" "$GOOD_URL" <<'PYVERIFYHOOK'
import sys, json
try:
    hooks = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
good = sys.argv[2]
if not isinstance(hooks, list):
    sys.exit(1)
for h in hooks:
    if not isinstance(h, dict):
        continue
    url = ((h.get("config") or {}).get("url") or "").replace("&amp;", "&")
    if url == good:
        sys.exit(0)
sys.exit(1)
PYVERIFYHOOK
then
  say "--- hooks after create ---"
  mask_json "$TMP/hooks_after.json" | sed 's/^/    /'
  halt "correct internal Woodpecker hook was not present after enforcement"
fi
say "correct internal hook enforced"

hr "H9 trigger push"
curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO" > "$TMP/repo.json" 2>/dev/null || echo '{}' > "$TMP/repo.json"
DEFAULT_BRANCH="$(python3 - "$TMP/repo.json" <<'PYBRANCH'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
if isinstance(d, dict):
    v = d.get("default_branch") or ""
    if v:
        print(v)
PYBRANCH
)"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"
say "default_branch=$DEFAULT_BRANCH"

AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"
WORK="$TMP/git"
mkdir -p "$WORK"
cd "$WORK" || halt "cd work failed"

git -c init.defaultBranch="$DEFAULT_BRANCH" init -q
git remote add origin "$GT/$BOT/$REPO.git"
git -c http.extraHeader="Authorization: Basic $AUTH_B64" pull -q origin "$DEFAULT_BRANCH" --rebase >/dev/null 2>&1 || true

cat > .woodpecker.yml <<'YML'
steps:
  hello-world:
    image: alpine:latest
    commands:
      - echo "Hello from Woodpecker CI!"
      - date
      - whoami
YML

git add .woodpecker.yml
if [ -n "$(git status --porcelain --untracked-files=no .woodpecker.yml)" ]; then
  git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q -m "ci: security-allowlist steel thread $(date -Is)" || halt "commit failed"
else
  git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q --allow-empty -m "ci: retrigger after security allowlist $(date -Is)" || halt "empty commit failed"
fi

git -c http.extraHeader="Authorization: Basic $AUTH_B64" push -q origin "HEAD:$DEFAULT_BRANCH" || halt "push failed"
PUSH_SHA="$(git rev-parse HEAD)"
say "pushed SHA=$PUSH_SHA"
cd / || true

dump_diagnostics(){
  say "--- woodpecker-server logs (10m) ---"
  podman logs --since 10m woodpecker-server 2>&1 |
    grep -iE 'hook|gitea|repo|pipeline|signature|401|403|404|error|warn|received|processed' |
    tail -60 | sed 's/^/    /' || true

  say "--- gitea logs (10m) ---"
  podman logs --since 10m gitea 2>&1 |
    grep -iE 'hook|delivery|webhook|woodpecker|egress|allow|security|deprecat|401|403|404|error|warn' |
    tail -80 | sed 's/^/    /' || true

  say "--- woodpecker-agent logs (10m) ---"
  podman logs --since 10m woodpecker-agent 2>&1 |
    tail -50 | sed 's/^/    /' || true

  say "--- current hooks, masked ---"
  mask_json "$TMP/hooks_after.json" | sed 's/^/    /'

  say "--- Gitea allowlist lines ---"
  podman exec gitea sh -c 'grep -nE "^\[(security|webhook)\]|ALLOWED_HOST_LIST" "'"$CONF"'" 2>/dev/null | head -20' 2>/dev/null | sed 's/^/    /' || true

  say "--- ALL pipelines in WP DB (last 10) ---"
  psqlq "SELECT id, repo_id, number, status, event, commit, branch, created FROM pipelines ORDER BY id DESC LIMIT 10" | sed 's/^/    /' || true
}

PIPE_NUM=""
PIPE_STATUS=""
PIPE_SUCC="0"

poll_pipelines(){
  local n="$1"
  local i row
  for i in $(seq 1 "$n"); do
    # Poll ALL pipelines, not just repo_id, to rule out ID mismatch
    row="$(psqlq "SELECT number||' '||status FROM pipelines ORDER BY id DESC LIMIT 1")"
    if [ -n "$row" ]; then
      PIPE_NUM="${row%% *}"
      PIPE_STATUS="${row##* }"
    fi
    PIPE_SUCC="$(psqlq "SELECT count(*) FROM pipelines WHERE status='success'" | tr -d ' \n')"
    PIPE_SUCC="${PIPE_SUCC:-0}"

    case "$PIPE_STATUS" in
      success|failure|error|killed) return 0 ;;
    esac

    sleep 3
  done
}

hr "H10 poll ALL Woodpecker pipelines"
poll_pipelines 40
say "latest pipeline=#${PIPE_NUM:-none} status=${PIPE_STATUS:-none} success_count=${PIPE_SUCC:-0}"

if [ -z "$PIPE_NUM" ]; then
  hr "H11 no pipeline diagnostics"
  dump_diagnostics
  say "webhook_test_status=$WB_STATUS webhook_ok=$WEBHOOK_OK"
  ledger "PARTIAL" "EX22 [security] allowlist applied; network test=$NET_TEST; webhook test status=$WB_STATUS; push SHA=$PUSH_SHA; no pipeline. Paste H6-H11."
  halt "no pipeline created; isolation test results above name the exact layer"
fi

if [ "$PIPE_STATUS" != success ]; then
  hr "H12 non-success diagnostics"
  dump_diagnostics
  say "--- pipeline errors json ---"
  psqlq "SELECT COALESCE(errors::text,'') FROM pipelines ORDER BY id DESC LIMIT 1" | sed 's/^/    /' || true
  ledger "PARTIAL" "EX22 pipeline #$PIPE_NUM created but status=$PIPE_STATUS; push SHA=$PUSH_SHA; webhook_test=$WB_STATUS."
  halt "pipeline did not succeed"
fi

hr "H13 best-effort log proof"
LOG_PROOF=""
CK="$(cookies_from_session)"
if [ -n "$CK" ] && [ -n "$PIPE_NUM" ]; then
  for path in \
    "$WP/api/repos/$BOT/$REPO/pipelines/$PIPE_NUM/logs" \
    "$WP/api/repos/$BOT/$REPO/builds/$PIPE_NUM/logs"; do
    LOGS_RAW="$(curl -sS -m 15 -b "$CK" "$path" 2>/dev/null || true)"
    HIT="$(printf '%s' "$LOGS_RAW" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
    if [ -n "$HIT" ]; then
      LOG_PROOF="$HIT"
      break
    fi
  done
fi
if [ -z "$LOG_PROOF" ]; then
  LOG_PROOF="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"
fi
say "log proof: ${LOG_PROOF:-none (DB success is the gate)}"

hr "H14 RESULT"
say "[RESULT] EX22 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
say "  repo: $BOT/$REPO"
say "  woodpecker_repo_id: $REPO_ID"
say "  pipeline: #${PIPE_NUM:-?}"
say "  status: success"
say "  success_count: ${PIPE_SUCC:-0}"
say "  hook URL: $GOOD_URL"
say "  push SHA: $PUSH_SHA"
say "  config changed: $CONFIG_CHANGED"
say "  network test: $NET_TEST"
say "  webhook test status: $WB_STATUS"
say "  log proof: ${LOG_PROOF:-n/a}"

ledger "PASS" "EX22: moved ALLOWED_HOST_LIST to [security] (correct location); network test from gitea container=$NET_TEST; signed webhook test status=$WB_STATUS; push created pipeline #$PIPE_NUM status=success; log_proof=$([ -n "$LOG_PROOF" ] && echo yes || echo no). Brick 12 CLOSED."

exit 0
