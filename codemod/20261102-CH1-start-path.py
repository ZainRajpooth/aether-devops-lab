import sys; sys.path.insert(0, sys.argv[2])
from ch_lib import apply_reps
SU_RET = "    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()\n"
HELPERS = SU_RET + '''

def su_tolerant(args, timeout=300):
    """su() that converts subprocess.TimeoutExpired into rc=124 instead of raising.
    Units with ExecStartPre guards (dns-wait) legitimately exceed 30 s; a raw
    TimeoutExpired aborts the whole bulk batch (CH1 heal)."""  # AETHER_SU_TOLERANT
    try:
        return su(args, timeout=timeout)
    except Exception as exc:
        return (124, "", f"{type(exc).__name__}: {exc}")

_AETHER_BOOT_PRIORITY = (
    ("postgres", 10), ("redis", 20), ("minio", 25), ("weaviate", 30),
    ("prometheus", 35), ("node-exporter", 36), ("mailpit", 38),
    ("llama-embed", 40), ("litellm", 50), ("n8n", 60), ("gitea", 70),
    ("grafana", 80), ("woodpecker-server", 90), ("woodpecker-agent", 95),
    ("traefik", 99),
)

def aether_start_order(names):
    """Dependency-first ordering for bulk start/restart (CH1 heal)."""  # AETHER_START_ORDER_DEF
    def key(n):
        low = str(n).lower()
        for needle, prio in _AETHER_BOOT_PRIORITY:
            if needle in low:
                return (prio, low)
        return (500, low)
    return sorted(names, key=key)
'''
CA_OLD = '''                if unit:
                    rc2, o2, e2 = su([verb, unit])
                    if rc2 == 0:
                        out.append(f"{n}: systemd {verb} ok ({unit})")
                        continue
'''
CA_NEW = '''                if unit:
                    rc2, o2, e2 = su_tolerant([verb, unit], timeout=300)  # AETHER_CG_CONT_TOLERANT
                    if rc2 == 0:
                        out.append(f"{n}: systemd {verb} ok ({unit})")
                        continue
                    if rc2 == 124:
                        out.append(f"{n}: {verb} dispatched to {unit}; still initializing (ExecStartPre guard) - see Quadlets page")
                        continue
'''
BC_OLD = '        if action == "prune":\n'
BC_NEW = '        if action in ("start", "restart"):\n            names = aether_start_order(names)  # AETHER_START_ORDER_V1\n' + BC_OLD
UF_OLD = '''            if unit:
                rc, o, e = su(["start", unit])
                if rc == 0:
                    return f"{name}: started via systemd user unit {unit}"
'''
UF_NEW = '''            if unit:
                rc, o, e = su_tolerant(["start", unit], timeout=300)  # AETHER_CG_FALLBACK_TOLERANT
                if rc == 0:
                    return f"{name}: started via systemd user unit {unit}"
                if rc == 124:
                    return f"{name}: start dispatched to {unit}; still initializing (ExecStartPre guard) - refresh Quadlets page"
'''
apply_reps(sys.argv[1], [(SU_RET, HELPERS, "AETHER_SU_TOLERANT"), (CA_OLD, CA_NEW, "AETHER_CG_CONT_TOLERANT"), (BC_OLD, BC_NEW, "AETHER_START_ORDER_V1"), (UF_OLD, UF_NEW, "AETHER_CG_FALLBACK_TOLERANT")], "CH1")
