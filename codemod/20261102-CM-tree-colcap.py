#!/usr/bin/env python3
import sys, re, pathlib

p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
orig = t
done = []
warns = []

BLOCK = '''# AETHER_COL_CAP_TREE (CM): cap QTableView AND QTreeView/QTreeWidget columns.
# This closes the CK/CL2 gap where some widgets were not QTableView.
from PyQt6.QtWidgets import QTableView as _AETHER_QTV_CM, QTreeView as _AETHER_QTR_CM

def _aether_install_col_cap_cm(cls):
    if getattr(cls, "_aether_capped_cm", False):
        return
    orig = cls.resizeColumnsToContents
    def capped(self):
        orig(self)
        try:
            for c in range(self.columnCount()):
                if self.columnWidth(c) > 380:
                    self.setColumnWidth(c, 380)
        except Exception:
            pass
    cls.resizeColumnsToContents = capped
    cls._aether_capped_cm = True

for _cls_cm in (_AETHER_QTV_CM, _AETHER_QTR_CM):
    _aether_install_col_cap_cm(_cls_cm)

'''

if "AETHER_COL_CAP_TREE" not in t:
    m = re.search(r'(?m)^class MainWindow\b', t)
    if m:
        t = t[:m.start()] + BLOCK + t[m.start():]
        done.append("tree_colcap")
    else:
        warns.append("class-MainWindow-anchor-missing")

if t != orig:
    p.write_text(t, encoding="utf-8")

print("CM: changed=" + (",".join(done) if done else "none"))
if warns:
    print("CM: warnings=" + "; ".join(warns), file=sys.stderr)
sys.exit(0)
