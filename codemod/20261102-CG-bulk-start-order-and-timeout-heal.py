import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t
changed = []

# ---- 1) helpers: su_tolerant + dependency-first ordering (insert after su()'s return)
SU_ANCHOR = "    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()\n"
HELPERS = (
    "\n"
    "def su_tolerant(args, timeout=300):\n"
    "    \"\"\"su() that converts subprocess.TimeoutExpired into rc=124 instead of raising.\n"
    "    Units with ExecStartPre guards (dns-wait) can legitimately exceed 30 s; a raw\n"
    "    TimeoutExpired aborts the whole bulk batch (CG heal).\"\"\"  # AETHER_SU_TOLERANT\n"
    "    try:\n"
    "        return su(args, timeout=timeout)\n"
    "    except Exception as exc:\n"
    "        return (124, \"\", f\"{type(exc).__name__}: {exc}\")\n"
    "\n"
    "_AETHER_BOOT_PRIORITY = (\n"
    "    (\"postgres\", 10), (\"redis\", 20), (\"minio\", 25), (\"weaviate\", 30),\n"
    "    (\"prometheus\", 35), (\"node-exporter\", 36), (\"mailpit\", 38),\n"
    "    (\"llama-embed\", 40), (\"litellm\", 50), (\"n8n\", 60), (\"gitea\", 70),\n"
    "    (\"grafana\", 80), (\"woodpecker-server\", 90), (\"woodpecker-agent\", 95),\n"
    "    (\"traefik\", 99),\n"
    ")\n"
    "\n"
    "def aether_start_order(names):\n"
    "    \"\"\"Dependency-first ordering for bulk start/restart (CG heal).\"\"\"  # AETHER_START_ORDER_DEF\n"
    "    def key(n):\n"
    "        low = str(n).lower()\n"
    "        for needle, prio in _AETHER_BOOT_PRIORITY:\n"
    "            if needle in low:\n"
    "                return (prio, low)\n"
    "        return (500, low)\n"
    "    return sorted(names, key=key)\n"
)
if "AETHER_SU_TOLERANT" not in t:
    if SU_ANCHOR not in t:
        sys.stderr.write("CG: anchor missing: su() return line\n"); sys.exit(2)
    t = t.replace(SU_ANCHOR, SU_ANCHOR + HELPERS, 1)
    changed.append("helpers")

# ---- 2) cont_action: tolerant unit verb + 124 messaging
CA_OLD = (
    "                if unit:\n"
    "                    rc2, o2, e2 = su([verb, unit])\n"
    "                    if rc2 == 0:\n"
    "                        out.append(f\"{n}: systemd {verb} ok ({unit})\")\n"
    "                        continue\n"
)
CA_NEW = (
    "                if unit:\n"
    "                    rc2, o2, e2 = su_tolerant([verb, unit], timeout=300)  # AETHER_CG_CONT_TOLERANT\n"
    "                    if rc2 == 0:\n"
    "                        out.append(f\"{n}: systemd {verb} ok ({unit})\")\n"
    "                        continue\n"
    "                    if rc2 == 124:\n"
    "                        out.append(f\"{n}: {verb} dispatched to {unit}; still initializing (ExecStartPre guard) - see Quadlets page\")\n"
    "                        continue\n"
)
if "AETHER_CG_CONT_TOLERANT" not in t:
    if CA_OLD not in t:
        sys.stderr.write("CG: anchor missing: cont_action su([verb, unit])\n"); sys.exit(2)
    t = t.replace(CA_OLD, CA_NEW, 1)
    changed.append("cont_action")

# ---- 3) bulk_cont: dependency-ordered names for start/restart
BC_ANCHOR = "        if action == \"prune\":\n"
BC_INS = "        if action in (\"start\", \"restart\"):\n            names = aether_start_order(names)  # AETHER_START_ORDER_V1\n"
if "AETHER_START_ORDER_V1" not in t:
    if BC_ANCHOR not in t:
        sys.stderr.write("CG: anchor missing: bulk_cont prune branch\n"); sys.exit(2)
    t = t.replace(BC_ANCHOR, BC_INS + BC_ANCHOR, 1)
    changed.append("bulk_order")

# ---- 4) unit_start_with_fallback: tolerant start + 124 messaging
UF_OLD = (
    "            if unit:\n"
    "                rc, o, e = su([\"start\", unit])\n"
    "                if rc == 0:\n"
    "                    return f\"{name}: started via systemd user unit {unit}\"\n"
)
UF_NEW = (
    "            if unit:\n"
    "                rc, o, e = su_tolerant([\"start\", unit], timeout=300)  # AETHER_CG_FALLBACK_TOLERANT\n"
    "                if rc == 0:\n"
    "                    return f\"{name}: started via systemd user unit {unit}\"\n"
    "                if rc == 124:\n"
    "                    return f\"{name}: start dispatched to {unit}; still initializing (ExecStartPre guard) - refresh Quadlets page\"\n"
)
if "AETHER_CG_FALLBACK_TOLERANT" not in t:
    if UF_OLD not in t:
        sys.stderr.write("CG: anchor missing: unit_start_with_fallback su start\n"); sys.exit(2)
    t = t.replace(UF_OLD, UF_NEW, 1)
    changed.append("fallback")

if t != orig:
    p.write_text(t, encoding="utf-8")
print("CG: changed=%s" % (",".join(changed) if changed else "none (already patched)"))
sys.exit(0)
