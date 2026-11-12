import sys, pathlib
def apply_reps(path, reps, tag):
    p = pathlib.Path(path)
    t = p.read_text(encoding="utf-8")
    orig = t
    done = []
    for old, new, marker in reps:
        if marker in t:
            continue
        if old not in t:
            sys.stderr.write("%s: anchor missing: %r\n" % (tag, old[:70]))
            sys.exit(2)
        t = t.replace(old, new, 1)
        done.append(marker)
    if t != orig:
        p.write_text(t, encoding="utf-8")
    print("%s: %s" % (tag, ",".join(done) if done else "no-op (already patched)"))
