#!/usr/bin/env python3
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding="utf-8"); orig = t; done = []; warns = []

# 1) cap column-driven growth: rewrite call sites FIRST (helper not yet present -> no recursion)
if "AETHER_COL_CAP" not in t:
    rx = re.compile(r'(?m)^(\s*)([A-Za-z_][A-Za-z0-9_.\[\]"]*)\.resizeColumnsToContents\(\)\s*$')
    t2, n = rx.subn(lambda m: '%sself._aether_capped_resize(%s)' % (m.group(1), m.group(2)), t)
    if n == 0:
        warns.append("colcap-no-callsites")
    t = t2
    helper = '''    def _aether_capped_resize(self, tv):  # AETHER_COL_CAP
        """resizeColumnsToContents + hard per-column cap so table minima can
        never force the window wider than the screen (CK heal)."""
        try:
            tv.resizeColumnsToContents()
            for c in range(tv.columnCount()):
                if tv.columnWidth(c) > 380:
                    tv.setColumnWidth(c, 380)
        except Exception:
            pass

    def _aether_start_clamp_loop(self):  # AETHER_CLAMP_LOOP
        if getattr(self, "_aether_clamp_timer", None) is None:
            self._aether_clamp_timer = QTimer(self)
            self._aether_clamp_timer.timeout.connect(self._aether_clamp_tick)
            self._aether_clamp_timer.start(2500)

    def _aether_clamp_tick(self):
        try:
            st = self.windowState()
            if st & Qt.WindowState.WindowMaximized or st & Qt.WindowState.WindowFullScreen:
                return
            avail = QApplication.primaryScreen().availableGeometry()
            w = min(self.width(), avail.width() - 24)
            h = min(self.height(), avail.height() - 24)
            if w != self.width() or h != self.height():
                self.resize(w, h)
            if self.x() < avail.x() or self.y() < avail.y():
                self.move(max(avail.x(), self.x()), max(avail.y(), self.y()))
        except Exception:
            pass

'''
    anchor = "    def _restore_window_geometry(self):  # AETHER_GEO_HELPERS\n"
    if anchor in t:
        t = t.replace(anchor, helper + anchor, 1); done.append("colcap+clamploop")
    else:
        warns.append("geo-helper-anchor-missing")

# 2) first-open (no saved geo): static fitted size, not maximize; start clamp loop
OLD_ELSE = '''        else:
            self.setWindowState(Qt.WindowState.WindowMaximized)

    def _save_window_geometry(self):
'''
NEW_ELSE = '''        else:
            avail = QApplication.primaryScreen().availableGeometry()
            self.resize(min(1400, avail.width() - 60), min(860, avail.height() - 60))  # AETHER_STATIC_OPEN
        self._aether_start_clamp_loop()

    def _save_window_geometry(self):
'''
if "AETHER_STATIC_OPEN" not in t:
    if OLD_ELSE in t:
        t = t.replace(OLD_ELSE, NEW_ELSE, 1); done.append("static_open")
    else:
        warns.append("static-open-anchor-missing")

# 3) __main__: never auto-maximize on first run; fitted static size instead
OLD_MAIN = '''    if not st.value("window_geo"):  # AETHER_GEO_MAX_GUARD
        win.setWindowState(Qt.WindowState.WindowMaximized)
    win.show()
'''
NEW_MAIN = '''    if not st.value("window_geo"):  # AETHER_STATIC_FIRST_SIZE
        _avail = QApplication.primaryScreen().availableGeometry()
        win.resize(min(1400, _avail.width() - 60), min(860, _avail.height() - 60))
    win.show()
'''
if "AETHER_STATIC_FIRST_SIZE" not in t:
    if OLD_MAIN in t:
        t = t.replace(OLD_MAIN, NEW_MAIN, 1); done.append("static_first_size")
    else:
        warns.append("main-max-anchor-missing")

if t != orig:
    p.write_text(t, encoding="utf-8")
print("CK: changed=" + (",".join(done) if done else "none"))
if warns: print("CK: warnings=" + "; ".join(warns), file=sys.stderr)
sys.exit(0)
