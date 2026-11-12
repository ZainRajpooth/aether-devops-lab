#!/usr/bin/env python3
"""CF patcher: guard _aether_setup_scrim call-sites so a cosmetic overlay can
never abort the PyQt6 app (PyQt6 qFatal's on exceptions escaping C++ slots).
Structural, def-signature scoped, idempotent, single safety copy by caller."""
import sys, re, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
orig = src

MARKER = "# AETHER_SAFE_SCRIM"
HELPER = (
    'def _aether_safe_scrim(dlg):\n'
    '    """Crash-guard: cosmetic scrim must never abort the app (CF heal).\n'
    '    PyQt6 aborts the process when an exception escapes a slot connected to\n'
    '    a C++ signal; _aether_setup_scrim can raise RuntimeError on stale or\n'
    '    deleted QGridLayout objects. Swallow ALL failures: losing a translucent\n'
    '    overlay is cosmetic; losing the process is not."""\n'
    '    try:\n'
    '        _aether_setup_scrim(dlg)\n'
    '    except Exception:\n'
    '        pass\n'
)

call_re = re.compile(r"^(\s*)_aether_setup_scrim\(([^)]*)\)\s*$")
def_re = re.compile(r"^def\s+([A-Za-z_]\w*)\s*\(")

cur_def = None
out = []
replaced = 0
for ln in src.splitlines(keepends=True):
    m = def_re.match(ln)
    if m:
        cur_def = m.group(1)
    if cur_def != "_aether_safe_scrim":
        body = ln.rstrip("\n")
        cm = call_re.match(body)
        if cm and body.rstrip().endswith(")"):
            indent, arg = cm.group(1), cm.group(2)
            out.append("%s_aether_safe_scrim(%s)\n" % (indent, arg))
            replaced += 1
            continue
    out.append(ln)
src = "".join(out)

if MARKER not in src:
    idx = src.find("def _aether_setup_scrim(")
    if idx == -1:
        sys.stderr.write("CF: anchor missing: def _aether_setup_scrim(\n")
        sys.exit(2)
    src = src[:idx] + MARKER + "\n" + HELPER + "\n\n" + src[idx:]

if src != orig:
    path.write_text(src, encoding="utf-8")
    print("CF: replaced %d call-site(s); helper installed" % replaced)
else:
    print("CF: no-op (already patched); replaced=%d" % replaced)
sys.exit(0)
