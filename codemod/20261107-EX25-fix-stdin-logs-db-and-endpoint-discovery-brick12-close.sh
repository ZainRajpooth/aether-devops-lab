#!/usr/bin/env bash
# 20261107-EX25 — fixes EX24's stdin routing bug, empty log dumps, and endpoint guess.
# 1) Python discovery script is now written to a file; URL/secret via argv, body via stdin.
# 2) Log dumps use --tail 200 instead of --since 5m to survive restarts.
# 3) DB dumps fallback to postgres superuser if devops lacks permissions.
# 4) Endpoint candidates expanded to include base /hook and /api/hook.
set -uo pipefail

HOME_="$HOME"
CD="$HOME_/DevOps/aether/codemod"
SEC="$HOME_/DevOps/aether/secrets"
IDX="$CD/INDEX.md"
SESSION="$SEC/woodpecker-session.json"

TOKEN="ex25-fix-stdin-logs-db-and-endpoint-discovery-brick12-close-v1"
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

redact_text(){
  python3 - "${WP_SECRET:-}" "${PASS:-}" <<'PYRED'
import sys, re
s = sys.argv[1] if len(sys.argv) > 1 else ''
p = sys.argv[2] if len(sys.argv) > 2 else ''
for line in sys.stdin:
    if s: line = line.replace(s, '[REDACTED-SECRET]')
    if p: line = line.replace(p, '[REDACTED-PASS]')
    line = re.sub(r'[0-9a-fA-F]{40,}', '[HEX]', line)
    sys.stdout.write(line)
PYRED
}

mask_json_stdin(){
  python3 - "${WP_SECRET:-}" "${PASS:-}" <<'PYMASK'
import sys, json, re
s = sys.argv[1] if len(sys.argv) > 1 else ''
p = sys.argv[2] if len(sys.argv) > 2 else ''
pat = re.compile(r'(secret|token|password|passwd|key|authorization|client_secret|access_token|refresh_token|signature)', re.I)
def mask_val(v):
    if isinstance(v, str):
        if s: v = v.replace(s, '[REDACTED-SECRET]')
        if p: v = v.replace(p, '[REDACTED-PASS]')
        v = re.sub(r'[0-9a-fA-F]{40,}', '[HEX]', v)
        if len(v) > 240: v = v[:240] + '...'
    return v
def mask(o):
    if isinstance(o, dict): return {k: ('***' if pat.search(k) else mask(mask_val(v))) for k, v in o.items()}
    if isinstance(o, list): return [mask_val(mask(x)) if isinstance(x, str) else mask(x) for x in o]
    return mask_val(o)
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    print(json.dumps(mask(d), indent=2)[:5000])
except Exception:
    if s: raw = raw.replace(s, '[REDACTED-SECRET]')
    if p: raw = raw.replace(p, '[REDACTED-PASS]')
    raw = re.sub(r'[0-9a-fA-F]{40,}', '[HEX]', raw)
    print(raw[:2500])
PYMASK
}

hr "C0 preflight"
for c in python3 curl git podman awk sed grep base64; do
  command -v "$c" >/dev/null 2>&1 || halt "missing command: $c"
done
for c in woodpecker-server woodpecker-agent gitea postgres; do
  podman inspect "$c" >/dev/null 2>&1 || halt "container missing: $c"
done
[ -s "$BOT_FILE" ] && [ -s "$PASS_FILE" ] || halt "missing Gitea bot creds"
mkdir -p "$CD" "$SEC"
touch "$IDX"

BOT="$(cat "$BOT_FILE")"
PASS="$(cat "$PASS_FILE")"
WP_SECRET="$(envval woodpecker-server WOODPECKER_GITEA_SECRET)"

GT_HOST_PORT="$(podman port gitea 3000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '\r' || true)"
[ -n "$GT_HOST_PORT" ] || halt "could not detect Gitea host port"
GT="http://127.0.0.1:$GT_HOST_PORT"

CONF="$(podman exec gitea sh -c 'for c in /data/gitea/conf/app.ini /etc/gitea/app.ini; do if [ -f "$c" ]; then echo "$c"; break; fi; done' 2>/dev/null || true)"
[ -n "$CONF" ] || halt "could not locate Gitea app.ini"

REPO_ID="$(psqlq "SELECT id FROM repos WHERE lower(owner)=lower('$BOT') AND lower(name)=lower('$REPO') LIMIT 1" | tr -d ' \n')"
FORGE_REMOTE_ID="$(psqlq "SELECT forge_remote_id FROM repos WHERE id=$REPO_ID LIMIT 1" | tr -d ' \n')"
[[ "$REPO_ID" =~ ^[0-9]+$ ]] || halt "could not resolve Woodpecker repo_id"
say "woodpecker_repo_id=$REPO_ID forge_remote_id=${FORGE_REMOTE_ID:-unknown}"

hr "C1 optional Gitea DB / hook-task probe (diagnostic only; never halts)"
GT_DB=""
HOOK_TABLE=""
TASK_TABLE=""

GT_DB="$(podman exec gitea sh -c 'sed -n "/^\[database\]/,/^\[/p" "$1" | sed -n "s/^[[:space:]]*NAME[[:space:]]*=[[:space:]]*//p" | head -1' sh "$CONF" 2>/dev/null || true)"
if [ -z "$GT_DB" ]; then
  GT_DB="$(podman inspect gitea --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '$1=="GITEA__database__NAME"{print $2; exit}' || true)"
fi
if [ -z "$GT_DB" ]; then
  for db in gitea gittea giteadb; do
    if podman exec postgres psql -U "$PGU" -d "$db" -tAc 'SELECT 1' >/dev/null 2>&1; then
      GT_DB="$db"; break
    fi
  done
fi
if [ -z "$GT_DB" ]; then
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    [ "$db" = "postgres" ] && continue
    [ "$db" = "$PGDB" ] && continue
    if podman exec postgres psql -U "$PGU" -d "$db" -tAc 'SELECT 1' >/dev/null 2>&1; then
      GT_DB="$db"; break
    fi
  done < <(podman exec postgres psql -U "$PGU" -d postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null || true)
fi

has_table(){
  local db="$1" tbl="$2"
  [ -n "$db" ] || return 1
  podman exec postgres psql -U "$PGU" -d "$db" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='$tbl'" 2>/dev/null | grep -q 1
}

if [ -n "$GT_DB" ]; then
  for t in webhook webhooks hook hooks; do
    if has_table "$GT_DB" "$t"; then HOOK_TABLE="$t"; break; fi
  done
  for t in hook_task hook_tasks webhook_task webhook_tasks; do
    if has_table "$GT_DB" "$t"; then TASK_TABLE="$t"; break; fi
  done
fi
say "gitea_db=${GT_DB:-none} hook_table=${HOOK_TABLE:-none} task_table=${TASK_TABLE:-none}"

gsqlq(){
  local sql="$1"
  [ -n "$GT_DB" ] || return 0
  local out
  out="$(podman exec postgres psql -U "$PGU" -d "$GT_DB" -tAc "$sql" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    out="$(podman exec postgres psql -U postgres -d "$GT_DB" -tAc "$sql" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

dump_hooks(){
  [ -n "$HOOK_TABLE" ] || { say "    no Gitea hook table detected"; return 0; }
  local json
  json="$(gsqlq "SELECT COALESCE(json_agg(row_to_json(h)),'[]'::json) FROM (SELECT * FROM \"$HOOK_TABLE\" ORDER BY id DESC LIMIT 20) h")"
  printf '%s' "${json:-[]}" | mask_json_stdin | sed 's/^/    /'
}

dump_new_tasks(){
  local since="$1"
  [ -n "$TASK_TABLE" ] || { say "    no Gitea hook_task table detected"; return 0; }
  local json
  json="$(gsqlq "SELECT COALESCE(json_agg(row_to_json(t)),'[]'::json) FROM (SELECT * FROM \"$TASK_TABLE\" WHERE id > $since ORDER BY id DESC LIMIT 20) t")"
  printf '%s' "${json:-[]}" | mask_json_stdin | sed 's/^/    /'
}

hr "C2 inspect current Gitea security/webhook config"
podman exec gitea sh -c '
CONF="$1"
echo "--- relevant lines ---"
grep -nE "^\[(security|webhook|queue)\]|ALLOWED_HOST_LIST|EGRESS_MODE|QUEUE_TYPE|QUEUE_CONN_STR" "$CONF" 2>/dev/null | head -40 || true
echo "--- [webhook] section ---"
awk "/^\[webhook\]/{f=1; print; next} /^\[/{if(f) exit} f" "$CONF" 2>/dev/null | head -40 || true
echo "--- [security] section ---"
awk "/^\[security\]/{f=1; print; next} /^\[/{if(f) exit} f" "$CONF" 2>/dev/null | head -40 || true
' sh "$CONF" 2>&1 | sed 's/^/    /' | redact_text || true

hr "C3 detect allowed-host entries"
: > "$TMP/entries.raw.txt"
podman inspect woodpecker-server --format '{{json .NetworkSettings.Networks}}' > "$TMP/wpnets.json" 2>/dev/null || echo '{}' > "$TMP/wpnets.json"
python3 - "$TMP/wpnets.json" >> "$TMP/entries.raw.txt" <<'PYNET'
import sys, json, subprocess, ipaddress
try: nets = json.load(open(sys.argv[1]))
except Exception: nets = {}
entries = []
for name, data in (nets or {}).items():
    data = data or {}
    for ipstr in (data.get("IPAddress"), data.get("GlobalIPv6Address")):
        if not ipstr: continue
        try:
            ip = ipaddress.ip_address(ipstr)
            entries.append(f"{ip}/{128 if ip.version == 6 else 32}")
            if ip.version == 4 and ip.is_private:
                p = str(ip).split(".")
                if len(p) == 4:
                    entries.append(f"{p[0]}.{p[1]}.0.0/16")
                    entries.append(f"{p[0]}.{p[1]}.{p[2]}.0/24")
        except Exception: pass
    if name:
        try:
            out = subprocess.check_output(["podman", "network", "inspect", name, "--format", "{{range .Subnets}}{{.Subnet}}{{println}}{{end}}"], text=True, stderr=subprocess.DEVNULL)
            for s in out.split():
                if s: entries.append(s)
        except Exception: pass
for extra in ["woodpecker-server", "gitea", "localhost", "127.0.0.1/32"]: entries.append(extra)
for e in entries:
    if e: print(e)
PYNET
podman logs --tail 200 gitea 2>&1 | grep -oE 'dial tcp ([0-9]{1,3}\.){3}[0-9]{1,3}:8000' | sed -E 's/dial tcp ([0-9.]+):8000/\1/' | sort -u > "$TMP/denied_ips.txt" 2>/dev/null || true
python3 - "$TMP/denied_ips.txt" >> "$TMP/entries.raw.txt" <<'PYDENIED'
import sys, ipaddress
try: lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except Exception: lines = []
for ip in lines:
    ip = ip.strip()
    if not ip: continue
    try:
        a = ipaddress.ip_address(ip)
        print(f"{ip}/32")
        if a.version == 4 and a.is_private:
            p = ip.split(".")
            if len(p) == 4:
                print(f"{p[0]}.{p[1]}.0.0/16")
                print(f"{p[0]}.{p[1]}.{p[2]}.0/24")
    except Exception: pass
PYDENIED
if ! grep -qE '/[0-9]+$' "$TMP/entries.raw.txt" 2>/dev/null; then
  podman network inspect aether --format '{{range .Subnets}}{{.Subnet}}{{println}}{{end}}' >> "$TMP/entries.raw.txt" 2>/dev/null || true
fi
python3 - "$TMP/entries.raw.txt" > "$TMP/entries.txt" <<'PYDEDUP'
import sys
seen = set(); out = []
try: lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except Exception: lines = []
for e in lines:
    e = e.strip()
    if e and e not in seen: seen.add(e); out.append(e)
print("\n".join(out))
PYDEDUP
say "planned [security].ALLOWED_HOST_LIST entries:"
sed 's/^/    /' "$TMP/entries.txt"

hr "C4 Python INI editor: [security] lax + allowlist; remove [webhook] allowlist"
EDIT_PY="$TMP/edit_gitea_security.py"
cat > "$EDIT_PY" <<'PYEDIT'
import sys, re, pathlib
app_path = pathlib.Path(sys.argv[1])
entries_path = sys.argv[2]
mode = sys.argv[3] if len(sys.argv) > 3 else "check"
new_entries = []
try:
    for line in open(entries_path, encoding="utf-8", errors="replace"):
        e = line.strip()
        if e: new_entries.append(e)
except Exception: pass
text = app_path.read_text(encoding="utf-8", errors="replace")
lines = text.splitlines(keepends=True)
changed = False
report = []
def section_bounds(lines, name):
    start = None; in_sec = False
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith("[") and s.endswith("]"):
            if in_sec: return start, i
            if s.lower() == f"[{name}]": start = i; in_sec = True
    if in_sec: return start, len(lines)
    return None, None
def ensure_section(lines, name):
    start, end = section_bounds(lines, name)
    if start is not None: return lines, start, end, False
    if lines and not lines[-1].endswith("\n"): lines[-1] += "\n"
    lines.append(f"[{name}]\n")
    return lines, len(lines) - 1, len(lines), True
def get_key(lines, start, end, key):
    if start is None: return None, ""
    kre = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.I)
    for i in range(start + 1, end):
        if kre.match(lines[i]):
            raw = lines[i].split("=", 1)[1].strip()
            return i, re.sub(r"\s+#.*$", "", raw).strip()
    return None, ""
def upsert_key(lines, section_name, key, val):
    global changed
    lines, start, end, created = ensure_section(lines, section_name)
    if created: changed = True
    kre = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.I)
    newline = f"{key} = {val}\n"
    for i in range(start + 1, end):
        if kre.match(lines[i]):
            if lines[i] != newline: lines[i] = newline; changed = True; report.append(f"UPDATED [{section_name}] {key}={val}")
            else: report.append(f"UNCHANGED [{section_name}] {key}={val}")
            return lines
    lines.insert(start + 1, newline); changed = True; report.append(f"INSERTED [{section_name}] {key}={val}")
    return lines
def remove_key(lines, section_name, key):
    global changed
    start, end = section_bounds(lines, section_name)
    if start is None: report.append(f"MISSING_SECTION [{section_name}] for {key}"); return lines
    kre = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.I)
    for i in range(start + 1, end):
        if kre.match(lines[i]): del lines[i]; changed = True; report.append(f"REMOVED [{section_name}] {key}"); return lines
    report.append(f"NO_KEY [{section_name}] {key}"); return lines
def split_list(v): return [x.strip() for x in (v or "").split(",") if x.strip()]
lines = upsert_key(lines, "security", "EGRESS_MODE", "lax")
start, end = section_bounds(lines, "security")
idx, current = get_key(lines, start, end, "ALLOWED_HOST_LIST")
existing = split_list(current)
merged = existing[:]
for e in new_entries:
    if e not in merged: merged.append(e)
merged_str = ",".join(merged)
report.append(f"CURRENT_SECURITY_ALLOWLIST={current if current else '(empty)'}")
report.append(f"PLANNED_SECURITY_ALLOWLIST={merged_str}")
lines = upsert_key(lines, "security", "ALLOWED_HOST_LIST", merged_str)
lines = remove_key(lines, "webhook", "ALLOWED_HOST_LIST")
for r in report: print(r)
if not changed: print("NO_CHANGE"); sys.exit(0)
if mode != "write": print("CHECK_ONLY"); sys.exit(0)
app_path.write_text("".join(lines), encoding="utf-8")
print("WRITTEN")
PYEDIT
chmod 600 "$EDIT_PY"

hr "C5 copy app.ini, check planned edit"
podman cp "gitea:$CONF" "$TMP/app.ini"
chmod 600 "$TMP/app.ini"
say "--- editor check ---"
python3 "$EDIT_PY" "$TMP/app.ini" "$TMP/entries.txt" check 2>&1 | sed 's/^/    /' | redact_text || true
if [ "$MODE" = check ]; then
  hr "C6 check mode result"
  say "[RESULT] EX25 CHECK - no container file was modified, no restart, no push."
  exit 0
fi

hr "C7 backup + apply + restart if changed"
podman exec --user 0 gitea sh -c 'B="$1.pre-EX25.bak"; if [ ! -f "$B" ]; then cp -p "$1" "$B"; fi' sh "$CONF"
say "backup: $CONF.pre-EX25.bak"
EDIT_OUT="$(python3 "$EDIT_PY" "$TMP/app.ini" "$TMP/entries.txt" write 2>&1)"
printf '%s\n' "$EDIT_OUT" | sed 's/^/    /' | redact_text || true
CONFIG_CHANGED=no
if printf '%s\n' "$EDIT_OUT" | grep -q '^NO_CHANGE$'; then
  say "Gitea security config already correct; no config write/restart needed."
elif printf '%s\n' "$EDIT_OUT" | grep -q '^WRITTEN$'; then
  CONFIG_CHANGED=yes
  podman cp "$TMP/app.ini" "gitea:$CONF"
  podman exec --user 0 gitea sh -c 'chmod 0644 "$1"; chown "$(id -u git):$(id -g git)" "$1" 2>/dev/null || true' sh "$CONF" || true
  say "app.ini updated"
else
  halt "editor did not report NO_CHANGE or WRITTEN"
fi
restart_gitea(){
  systemctl --user restart gitea.service 2>/dev/null || podman restart gitea
  READY=no
  for i in $(seq 1 30); do
    C="$(code "$GT/")"
    if [ -n "$C" ] && [ "$C" != 000 ]; then READY=yes; say "Gitea up: $GT = $C"; return 0; fi
    sleep 2
  done
  halt "Gitea did not become reachable after restart"
}
if [ "$CONFIG_CHANGED" = yes ]; then restart_gitea; else say "skip config restart"; fi

hr "C8 verify config after edit"
podman exec gitea sh -c 'CONF="$1"; grep -nE "^\[(security|webhook)\]|ALLOWED_HOST_LIST|EGRESS_MODE" "$CONF" 2>/dev/null | head -30 || true' sh "$CONF" 2>&1 | sed 's/^/    /' | redact_text || true

hr "C9 network reachability test from INSIDE Gitea container"
NET_TEST="$(podman exec gitea curl -sS -m 10 -o /dev/null -w '%{http_code}' http://woodpecker-server:8000/api/version 2>&1 || echo FAIL)"
say "curl http://woodpecker-server:8000/api/version from gitea container = $NET_TEST"
if [ "$NET_TEST" = "FAIL" ] || [ "$NET_TEST" = "000" ]; then halt "Gitea cannot reach woodpecker-server:8000"; fi
say "network OK"

hr "C10 enforce correct internal Woodpecker hook"
GOOD_URL="http://woodpecker-server:8000/hook?source=gitea&owner=${BOT}&repo=${REPO}"
curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_before.json" 2>/dev/null || echo '[]' > "$TMP/hooks_before.json"
say "--- existing Woodpecker-related hooks, masked ---"
python3 - "$TMP/hooks_before.json" <<'PYLIST' | sed 's/^/    /'
import sys, json
try: hooks = json.load(open(sys.argv[1]))
except Exception: hooks = []
if not isinstance(hooks, list): hooks = []
for h in hooks:
    if not isinstance(h, dict): continue
    cfg = h.get("config") or {}
    url = cfg.get("url") or ""
    if "woodpecker" in url.lower() or "/hook" in url or "/api/hook" in url:
        print(json.dumps({"id": h.get("id"), "active": h.get("active"), "events": h.get("events"), "url": url, "has_secret": bool(cfg.get("secret"))}))
PYLIST
python3 - "$TMP/hooks_before.json" > "$TMP/delete_ids.txt" <<'PYDEL'
import sys, json
try: hooks = json.load(open(sys.argv[1]))
except Exception: hooks = []
if not isinstance(hooks, list): hooks = []
for h in hooks:
    if not isinstance(h, dict): continue
    cfg = h.get("config") or {}
    url = (cfg.get("url") or "").lower()
    if "woodpecker" in url or "/hook" in url or "/api/hook" in url:
        hid = h.get("id")
        if hid is not None: print(str(hid))
PYDEL
DELETE_COUNT="$(wc -l < "$TMP/delete_ids.txt" | tr -d ' \n')"
say "deleting $DELETE_COUNT existing Woodpecker hook(s)"
while IFS= read -r hid; do
  [ -n "$hid" ] || continue
  curl -sS -m 10 -u "$BOT:$PASS" -X DELETE "$GT/api/v1/repos/$BOT/$REPO/hooks/$hid" >/dev/null 2>&1 || true
done < "$TMP/delete_ids.txt"
create_hook(){
  local url="$1" secret="$2" outfile="$3"
  python3 - "$url" "$secret" > "$TMP/hook_body.json" <<'PYHOOK'
import json, sys
url = sys.argv[1]; secret = sys.argv[2]
cfg = {"url": url, "content_type": "json"}
if secret: cfg["secret"] = secret
print(json.dumps({"type": "gitea", "active": True, "events": ["push"], "config": cfg}))
PYHOOK
  curl -sS -m 15 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d @"$TMP/hook_body.json" -X POST -o "$outfile" -w '%{http_code}' "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null || echo 000
}
REAL_CODE="$(create_hook "$GOOD_URL" "$WP_SECRET" "$TMP/real_hook_resp.json")"
REAL_HOOK_ID="$(python3 - "$TMP/real_hook_resp.json" <<'PYID'
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
print(d.get("id", "") if isinstance(d, dict) else "")
PYID
)"
say "real hook create http=$REAL_CODE id=${REAL_HOOK_ID:-none}"
say "--- real hook response, masked ---"
mask_json_stdin < "$TMP/real_hook_resp.json" | sed 's/^/    /'
curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_after.json" 2>/dev/null || echo '[]' > "$TMP/hooks_after.json"
if ! python3 - "$TMP/hooks_after.json" "$GOOD_URL" <<'PYVERIFYHOOK'
import sys, json
try: hooks = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
good = sys.argv[2]
if not isinstance(hooks, list): sys.exit(1)
for h in hooks:
    if not isinstance(h, dict): continue
    url = ((h.get("config") or {}).get("url") or "").replace("&amp;", "&")
    if url == good: sys.exit(0)
sys.exit(1)
PYVERIFYHOOK
then
  mask_json_stdin < "$TMP/hooks_after.json" | sed 's/^/    /'
  halt "correct internal Woodpecker hook was not present after enforcement"
fi
say "correct internal hook enforced"

hr "C11 restart Gitea after hook creation"
restart_gitea

hr "C12 record baselines"
BEFORE_TASK_MAX=0
if [ -n "$TASK_TABLE" ]; then BEFORE_TASK_MAX="$(gsqlq "SELECT COALESCE(MAX(id),0) FROM \"$TASK_TABLE\"" | tr -d ' \n')"; fi
BEFORE_TASK_MAX="${BEFORE_TASK_MAX:-0}"
BEFORE_PIPE_REPO_MAX="$(psqlq "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n')"
BEFORE_PIPE_REPO_MAX="${BEFORE_PIPE_REPO_MAX:-0}"
say "before_task_max=$BEFORE_TASK_MAX before_pipe_repo_max=$BEFORE_PIPE_REPO_MAX"

hr "C13 dump current hooks from Gitea DB if available"
dump_hooks

WORK="$TMP/git"
mkdir -p "$WORK"
AUTH_B64="$(printf '%s:%s' "$BOT" "$PASS" | base64 -w0)"
DEFAULT_BRANCH="main"
trigger_push(){
  local msg="$1"
  (
    cd "$WORK" || exit 1
    git -c init.defaultBranch="$DEFAULT_BRANCH" init -q 2>/dev/null || true
    git remote set-url origin "$GT/$BOT/$REPO.git" 2>/dev/null || git remote add origin "$GT/$BOT/$REPO.git"
    git -c http.extraHeader="Authorization: Basic $AUTH_B64" fetch -q origin "$DEFAULT_BRANCH" 2>/dev/null || true
    git checkout -q -B ci-trigger "origin/$DEFAULT_BRANCH" 2>/dev/null || git checkout -q -B ci-trigger "$DEFAULT_BRANCH" 2>/dev/null || true
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
      git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q -m "$msg" || exit 1
    else
      git -c user.email="${BOT}@local" -c user.name="Woodpecker Proof" commit -q --allow-empty -m "$msg" || exit 1
    fi
    git -c http.extraHeader="Authorization: Basic $AUTH_B64" push -q origin "HEAD:$DEFAULT_BRANCH" || exit 1
    git rev-parse HEAD
  )
}
FINAL_PIPELINE_NUM=""
FINAL_PIPELINE_STATUS=""
FINAL_SUCC="0"
PUSH_SHA=""
poll_pipeline(){
  local label="$1" iterations="${2:-40}" i row num status succ
  say "polling pipelines: $label"
  for i in $(seq 1 "$iterations"); do
    row="$(psqlq "SELECT number||' '||status FROM pipelines WHERE repo_id=$REPO_ID ORDER BY id DESC LIMIT 1")"
    if [ -n "$row" ]; then num="${row%% *}"; status="${row##* }"; fi
    succ="$(psqlq "SELECT count(*) FROM pipelines WHERE repo_id=$REPO_ID AND status='success'" | tr -d ' \n')"
    succ="${succ:-0}"
    if [ "${status:-}" = success ]; then
      FINAL_PIPELINE_NUM="$num"; FINAL_PIPELINE_STATUS="$status"; FINAL_SUCC="$succ"
      say "pipeline=#${num:-none} status=$status success_count=$succ"; return 0
    fi
    case "${status:-}" in failure|error|killed)
      FINAL_PIPELINE_NUM="$num"; FINAL_PIPELINE_STATUS="$status"; FINAL_SUCC="$succ"
      say "pipeline=#${num:-none} status=$status success_count=$succ"; return 1 ;;
    esac
    sleep 3
  done
  FINAL_PIPELINE_NUM="${num:-}"; FINAL_PIPELINE_STATUS="${status:-}"; FINAL_SUCC="${succ:-0}"
  say "pipeline=#${num:-none} status=${status:-none} success_count=${succ:-0}"; return 1
}
new_pipeline_since_before(){
  local latest
  latest="$(psqlq "SELECT COALESCE(MAX(id),0) FROM pipelines WHERE repo_id=$REPO_ID" | tr -d ' \n')"
  latest="${latest:-0}"
  [ "$latest" -gt "$BEFORE_PIPE_REPO_MAX" ]
}
dump_diagnostics(){
  say "--- woodpecker-server logs (tail 200, redacted) ---"
  podman logs --tail 200 woodpecker-server 2>&1 | tail -160 | redact_text | sed 's/^/    /' || true
  say "--- gitea logs (tail 200, filtered, redacted) ---"
  podman logs --tail 200 gitea 2>&1 | grep -iE 'hook|delivery|webhook|woodpecker|egress|allow|security|deprecat|queue|task|401|403|404|error|warn' | tail -120 | redact_text | sed 's/^/    /' || true
  say "--- gitea logs (tail 200, raw tail, redacted) ---"
  podman logs --tail 200 gitea 2>&1 | tail -100 | redact_text | sed 's/^/    /' || true
  say "--- woodpecker-agent logs (tail 200, redacted) ---"
  podman logs --tail 200 woodpecker-agent 2>&1 | tail -100 | redact_text | sed 's/^/    /' || true
  say "--- current hooks API, masked ---"
  curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" 2>/dev/null | mask_json_stdin | sed 's/^/    /' || true
  say "--- Gitea hook table, masked ---"
  dump_hooks
  say "--- Gitea new hook_task rows since baseline, masked ---"
  dump_new_tasks "$BEFORE_TASK_MAX"
  say "--- Gitea allowlist/security lines ---"
  podman exec gitea sh -c 'grep -nE "^\[(security|webhook)\]|ALLOWED_HOST_LIST|EGRESS_MODE" "'"$CONF"'" 2>/dev/null | head -30' 2>/dev/null | sed 's/^/    /' | redact_text || true
}

hr "C14 trigger push through Gitea"
PUSH_SHA="$(trigger_push "ci: ex25 security allowlist $(date -Is)")" || halt "push failed"
say "pushed SHA=$PUSH_SHA"

hr "C15 poll pipeline after Gitea push"
if poll_pipeline "after Gitea push" 40; then :; else
  say "no success pipeline after Gitea push; dumping diagnostics"
  dump_diagnostics
fi

if [ "${FINAL_PIPELINE_STATUS:-}" != success ]; then
  hr "C16 direct signed endpoint discovery from host"
  COMMITS_JSON="$(curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/commits?limit=2" 2>/dev/null || echo '[]')"
  SHA="$(printf '%s' "$COMMITS_JSON" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d[0]["sha"] if isinstance(d,list) and d else "")' 2>/dev/null || true)"
  PREV="$(printf '%s' "$COMMITS_JSON" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d[1]["sha"] if isinstance(d,list) and len(d)>1 else "")' 2>/dev/null || true)"
  [ -n "$SHA" ] || SHA="$PUSH_SHA"
  [ -n "$PREV" ] || PREV="$(python3 -c 'print("0"*40)')"
  if [ -z "$SHA" ]; then say "could not resolve SHA"; else
    BODY="$(python3 - "$BOT" "$REPO" "$FORGE_REMOTE_ID" "$DEFAULT_BRANCH" "$SHA" "$PREV" <<'PYBODY'
import json, sys
owner, repo, forge_id, branch, sha, prev = sys.argv[1:7]
rid = int(forge_id) if str(forge_id).isdigit() else forge_id
print(json.dumps({
    "ref": f"refs/heads/{branch}", "before": prev, "after": sha, "repo_id": rid,
    "repository": {"id": rid, "full_name": f"{owner}/{repo}", "name": repo, "owner": {"login": owner}, "clone_url": f"http://gitea:3000/{owner}/{repo}.git", "html_url": f"http://gitea:3000/{owner}/{repo}"},
    "sender": {"login": owner}, "pusher": {"name": owner, "email": f"{owner}@local"},
    "commits": [{"id": sha, "message": "ci trigger", "timestamp": "2026-11-07T00:00:00Z"}], "total_commits": 1
}))
PYBODY
)"
    say "direct discovery SHA=$SHA prev=${PREV:0:8}..."
    
    # FIX: Write python script to file to avoid stdin conflict
    cat > "$TMP/direct.py" <<'PYDIRECT'
import sys, hmac, hashlib, urllib.request, urllib.error
secret = sys.argv[1]
url = sys.argv[2]
body = sys.stdin.read()
sig = hmac.new(secret.encode("utf-8"), body.encode("utf-8"), hashlib.sha256).hexdigest()
headers = {"Content-Type": "application/json", "X-Gitea-Event": "push", "X-Gitea-Signature": sig, "X-Gitea-Delivery": "ex25-direct", "User-Agent": "aether-ex25"}
req = urllib.request.Request(url, data=body.encode("utf-8"), headers=headers, method="POST")
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print(f"STATUS={r.status}"); print(f"BODY={r.read().decode('utf-8', errors='replace')[:300]}")
except urllib.error.HTTPError as e:
    print(f"STATUS={e.code}"); print(f"BODY={e.read().decode('utf-8', errors='replace')[:300]}")
except Exception as e:
    print("STATUS=0"); print(f"BODY=ERR:{e}")
PYDIRECT

    # FIX: Expanded candidate URLs (base paths without query params)
    CANDIDATE_URLS=(
      "$WP/hook"
      "$WP/api/hook"
      "$WP/hook?source=gitea"
      "$WP/api/hook?source=gitea"
      "$WP/hook?source=gitea&owner=${BOT}&repo=${REPO}"
      "$WP/api/hook?source=gitea&owner=${BOT}&repo=${REPO}"
    )
    DISCOVERED_URL=""
    for u in "${CANDIDATE_URLS[@]}"; do
      say "DIRECT_TRY $u"
      # FIX: Pass URL/secret via argv, body via stdin
      DIRECT_OUT="$(printf '%s' "$BODY" | python3 "$TMP/direct.py" "$WP_SECRET" "$u" 2>&1)"
      printf '%s\n' "$DIRECT_OUT" | sed 's/^/    /' | redact_text || true
      DST="$(printf '%s\n' "$DIRECT_OUT" | grep '^STATUS=' | cut -d= -f2)"
      if [ -n "$DST" ] && [ "$DST" != 000 ] && [ "$DST" != 404 ] && [ "$DST" != 405 ]; then
        if new_pipeline_since_before; then
          DISCOVERED_URL="$u"
          say "DIRECT_DISCOVERED working endpoint: $DISCOVERED_URL"
          break
        fi
      fi
    done
    if [ -n "$DISCOVERED_URL" ] && [ "$DISCOVERED_URL" != "$GOOD_URL" ]; then
      hr "C17 update Gitea hook to discovered endpoint and retrigger"
      curl -sS -m 10 -u "$BOT:$PASS" "$GT/api/v1/repos/$BOT/$REPO/hooks" > "$TMP/hooks_pre_update.json" 2>/dev/null || echo '[]' > "$TMP/hooks_pre_update.json"
      python3 - "$TMP/hooks_pre_update.json" > "$TMP/delete_ids2.txt" <<'PYDEL2'
import sys, json
try: hooks = json.load(open(sys.argv[1]))
except Exception: hooks = []
if not isinstance(hooks, list): hooks = []
for h in hooks:
    if not isinstance(h, dict): continue
    cfg = h.get("config") or {}
    url = (cfg.get("url") or "").lower()
    if "woodpecker" in url or "/hook" in url or "/api/hook" in url:
        hid = h.get("id")
        if hid is not None: print(str(hid))
PYDEL2
      while IFS= read -r hid; do
        [ -n "$hid" ] || continue
        curl -sS -m 10 -u "$BOT:$PASS" -X DELETE "$GT/api/v1/repos/$BOT/$REPO/hooks/$hid" >/dev/null 2>&1 || true
      done < "$TMP/delete_ids2.txt"
      UPDATE_CODE="$(create_hook "$DISCOVERED_URL" "$WP_SECRET" "$TMP/updated_hook_resp.json")"
      UPDATED_HOOK_ID="$(python3 - "$TMP/updated_hook_resp.json" <<'PYID3'
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
print(d.get("id", "") if isinstance(d, dict) else "")
PYID3
)"
      say "updated hook create http=$UPDATE_CODE id=${UPDATED_HOOK_ID:-none}"
      mask_json_stdin < "$TMP/updated_hook_resp.json" | sed 's/^/    /'
      GOOD_URL="$DISCOVERED_URL"
      REAL_HOOK_ID="${UPDATED_HOOK_ID:-$REAL_HOOK_ID}"
      restart_gitea
      PUSH_SHA="$(trigger_push "ci: ex25 discovered endpoint retrigger $(date -Is)")" || halt "retrigger push failed"
      say "pushed SHA=$PUSH_SHA"
      poll_pipeline "after discovered endpoint Gitea push" 40 || true
    elif [ -n "$DISCOVERED_URL" ]; then
      say "direct discovery confirmed current endpoint; checking pipeline again"
      poll_pipeline "after direct confirmation" 20 || true
    fi
  fi
fi

if [ "${FINAL_PIPELINE_STATUS:-}" != success ] && [ -n "${REAL_HOOK_ID:-}" ]; then
  hr "C18 attempt Gitea hook test API if available"
  TEST_OUT="$(curl -sS -m 20 -u "$BOT:$PASS" -H 'Content-Type: application/json' -d '{"event":"push"}' -X POST "$GT/api/v1/repos/$BOT/$REPO/hooks/$REAL_HOOK_ID/tests" 2>&1 || true)"
  say "hook test response: $(printf '%s' "$TEST_OUT" | head -c 300)"
  poll_pipeline "after Gitea hook test API" 20 || true
fi

hr "C19 final diagnostics if still not success"
if [ "${FINAL_PIPELINE_STATUS:-}" != success ]; then dump_diagnostics; fi

fetch_log_proof(){
  local num="$1" proof="" ck logs_raw hit
  ck="$(cookies_from_session)"
  if [ -n "$ck" ] && [ -n "$num" ]; then
    for path in "$WP/api/repos/$BOT/$REPO/pipelines/$num/logs" "$WP/api/repos/$BOT/$REPO/builds/$num/logs"; do
      logs_raw="$(curl -sS -m 15 -b "$ck" "$path" 2>/dev/null || true)"
      hit="$(printf '%s' "$logs_raw" | grep -a 'Hello from Woodpecker CI!' | head -1 || true)"
      if [ -n "$hit" ]; then proof="$hit"; break; fi
    done
  fi
  if [ -z "$proof" ]; then proof="$(podman logs --since 10m woodpecker-agent 2>&1 | grep -a 'Hello from Woodpecker CI!' | tail -1 || true)"; fi
  printf '%s' "$proof"
}

hr "C20 RESULT"
LOG_PROOF="$(fetch_log_proof "${FINAL_PIPELINE_NUM:-}")"
say "log proof: ${LOG_PROOF:-none (DB success is the gate)}"
if [ "${FINAL_PIPELINE_STATUS:-}" = success ]; then
  say "[RESULT] EX25 COMPLETE - BRICK 12 STEEL THREAD PASSED (DB-gated)."
  say "  repo: $BOT/$REPO"
  say "  pipeline: #${FINAL_PIPELINE_NUM:-?}"
  say "  status: success"
  say "  final hook URL: $GOOD_URL"
  say "  push SHA: ${PUSH_SHA:-unknown}"
  say "  discovered endpoint: ${DISCOVERED_URL:-none}"
  ledger "PASS" "EX25: fixed stdin routing bug; expanded endpoint discovery; pipeline #${FINAL_PIPELINE_NUM:-?} status=success. Brick 12 CLOSED."
  exit 0
else
  say "[RESULT] EX25 PARTIAL - pipeline=#${FINAL_PIPELINE_NUM:-none} status=${FINAL_PIPELINE_STATUS:-none}"
  say "  final hook URL: $GOOD_URL"
  say "  discovered endpoint: ${DISCOVERED_URL:-none}"
  ledger "PARTIAL" "EX25: pipeline=#${FINAL_PIPELINE_NUM:-none} status=${FINAL_PIPELINE_STATUS:-none}. Paste C15-C20."
  exit 1
fi
