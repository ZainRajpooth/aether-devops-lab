#!/usr/bin/env python3
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding="utf-8"); orig = t; done = []; warns = []

BLOCK = '''# AETHER_COL_CAP_GLOBAL (CL2): cap EVERY QTableView column at import time so
# resizeColumnsToContents can never push the window minimum past the screen.
# Receiver-agnostic -> cannot miss a callsite (the CK regex did; this fixes it).
from PyQt6.QtWidgets import QTableView as _AETHER_QTV
if not getattr(_AETHER_QTV, "_aether_capped", False):
    _AETHER_ORIG_RCTC = _AETHER_QTV.resizeColumnsToContents
    def _aether_capped_rctc(self):
        _AETHER_ORIG_RCTC(self)
        try:
            for _c in range(self.columnCount()):
                if self.columnWidth(_c) > 380:
                    self.setColumnWidth(_c, 380)
        except Exception:
            pass
    _AETHER_QTV.resizeColumnsToContents = _aether_capped_rctc
    _AETHER_QTV._aether_capped = True

'''
if "AETHER_COL_CAP_GLOBAL" not in t:
    m = re.search(r'(?m)^class MainWindow\b', t)
    if m:
        t = t[:m.start()] + BLOCK + t[m.start():]
        done.append("colcap_global")
    else:
        warns.append("class-MainWindow-anchor-missing")

if t != orig:
    p.write_text(t, encoding="utf-8")
print("CL2: changed=" + (",".join(done) if done else "none"))
if warns: print("CL2: warnings=" + "; ".join(warns), file=sys.stderr)
sys.exit(0)
