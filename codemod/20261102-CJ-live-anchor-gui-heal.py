#!/usr/bin/env python3
import sys, re, pathlib

path = pathlib.Path(sys.argv[1])
t = path.read_text(encoding="utf-8")
orig = t
changes = []
warns = []

def mark(name):
    changes.append(name)

# ------------------------------------------------------------------ 1) tolerant systemctl + ordering helpers
if "AETHER_SU_TOLERANT" not in t:
    anchor = "    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()\n"
    idx = t.find(anchor)
    if idx != -1:
        insert_at = idx + len(anchor)
        helpers = '''
def su_tolerant(args, timeout=300):
    """su() that converts TimeoutExpired into rc=124 instead of raising."""  # AETHER_SU_TOLERANT
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
    """Dependency-first ordering for bulk start/restart."""  # AETHER_START_ORDER_DEF
    def key(n):
        low = str(n).lower()
        for needle, prio in _AETHER_BOOT_PRIORITY:
            if needle in low:
                return (prio, low)
        return (500, low)
    return sorted(names, key=key)
'''
        t = t[:insert_at] + helpers + t[insert_at:]
        mark("helpers")
    else:
        warns.append("helpers-anchor-missing")

# ------------------------------------------------------------------ 2) cont_action: tolerant unit start/restart
if "AETHER_CG_CONT_TOLERANT" not in t:
    old_line = "rc2, o2, e2 = su([verb, unit])"
    idx = t.find(old_line)
    if idx != -1:
        line_start = t.rfind("\n", 0, idx) + 1
        indent = t[line_start:idx]
        new_block = (
            f'{indent}if verb in ("start", "restart"):\n'
            f'{indent}    su(["reset-failed", unit])\n'
            f'{indent}rc2, o2, e2 = su_tolerant([verb, unit], timeout=300)  # AETHER_CG_CONT_TOLERANT\n'
        )
        t = t[:line_start] + new_block + t[idx + len(old_line) + 1:]
        pos = t.find("AETHER_CG_CONT_TOLERANT")
        cont = t.find("continue\n", pos)
        if cont != -1:
            eol = t.find("\n", cont) + 1
            line_start2 = t.rfind("\n", 0, cont) + 1
            indent2 = t[line_start2:cont]
            insert = (
                f'{indent2}if rc2 == 124:\n'
                f'{indent2}    out.append(f"{{n}}: {{verb}} dispatched to {{unit}}; still initializing (ExecStartPre guard) - see Quadlets page")\n'
                f'{indent2}    continue\n'
            )
            t = t[:eol] + insert + t[eol:]
            mark("cont_action")
        else:
            warns.append("cont_action-continue-not-found")
    else:
        warns.append("cont_action-anchor-missing")

# ------------------------------------------------------------------ 3) bulk_cont: dependency ordering
if "AETHER_START_ORDER_V1" not in t:
    m = re.search(r'(?m)^(\s*)if action == "prune":\s*$', t)
    if m:
        indent = m.group(1)
        insert = (
            f'{indent}if action in ("start", "restart"):\n'
            f'{indent}    names = aether_start_order(names)  # AETHER_START_ORDER_V1\n'
        )
        t = t[:m.start()] + insert + t[m.start():]
        mark("bulk_order")
    else:
        warns.append("bulk_order-anchor-missing")

# ------------------------------------------------------------------ 4) unit_start_with_fallback: tolerant start
if "AETHER_CG_FALLBACK_TOLERANT" not in t:
    old_line = 'rc, o, e = su(["start", unit])'
    idx = t.find(old_line)
    if idx != -1:
        line_start = t.rfind("\n", 0, idx) + 1
        indent = t[line_start:idx]
        new_block = (
            f'{indent}su(["reset-failed", unit])  # AETHER_RESET_FAILED_START\n'
            f'{indent}rc, o, e = su_tolerant(["start", unit], timeout=300)  # AETHER_CG_FALLBACK_TOLERANT\n'
        )
        t = t[:line_start] + new_block + t[idx + len(old_line) + 1:]
        pos = t.find("AETHER_CG_FALLBACK_TOLERANT")
        ret = t.find('return f"{name}: started via systemd user unit {unit}"', pos)
        if ret != -1:
            eol = t.find("\n", ret) + 1
            line_start2 = t.rfind("\n", 0, ret) + 1
            indent2 = t[line_start2:ret]
            insert = (
                f'{indent2}if rc == 124:\n'
                f'{indent2}    return f"{{name}}: start dispatched to {{unit}}; still initializing (ExecStartPre guard) - refresh Quadlets page"\n'
            )
            t = t[:eol] + insert + t[eol:]
            mark("fallback")
        else:
            warns.append("fallback-return-not-found")
    else:
        warns.append("fallback-anchor-missing")

# ------------------------------------------------------------------ 5) confirm() crash guard
if "AETHER_CONFIRM_GUARD" not in t:
    old = '''    def confirm(self, title, text):
        return QMessageBox.question(self, title, text,
                                    QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                    QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes
'''
    new = '''    def confirm(self, title, text):
        try:
            return QMessageBox.question(self, title, text,
                                        QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                        QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes
        except Exception as exc:
            try:
                self.status_lbl.setText(f"Confirm dialog suppressed ({type(exc).__name__}); action cancelled safely.")
            except Exception:
                pass
            return False  # AETHER_CONFIRM_GUARD
'''
    if old in t:
        t = t.replace(old, new, 1)
        mark("confirm_guard")
    else:
        m = re.search(
            r"(?m)^    def confirm\(self, title, text\):\n        return QMessageBox\.question\(self, title, text,\n.*?== QMessageBox\.StandardButton\.Yes\n",
            t,
            re.S,
        )
        if m:
            t = t[:m.start()] + new + t[m.end():]
            mark("confirm_guard_regex")
        else:
            warns.append("confirm-anchor-missing")

# ------------------------------------------------------------------ 6) geometry/font persistence helpers
if "AETHER_GEO_HELPERS" not in t:
    m = re.search(r"(?m)^    def init_ui\(self\):\n", t)
    if m:
        helpers = '''    def _restore_window_geometry(self):  # AETHER_GEO_HELPERS
        try:
            self.apply_visual()
        except Exception:
            pass
        geo = self.settings.value("window_geo")
        if geo:
            try:
                self.restoreGeometry(geo)
            except Exception:
                pass
        else:
            self.setWindowState(Qt.WindowState.WindowMaximized)

    def _save_window_geometry(self):
        try:
            self.settings.setValue("window_geo", self.saveGeometry())
        except Exception:
            pass

'''
        t = t[:m.start()] + helpers + t[m.start():]
        mark("geo_helpers")
    else:
        warns.append("geo_helpers-anchor-missing")

if "self._restore_window_geometry()" not in t:
    old = "        self.init_ui()\n"
    if old in t:
        t = t.replace(old, old + "        self._restore_window_geometry()\n", 1)
        mark("geo_restore_call")
    else:
        warns.append("geo_restore_call-anchor-missing")

if "AETHER_GEO_SAVE" not in t:
    m = re.search(r"(?m)^(        self\.settings\.sync\(\)\n        super\(\)\.closeEvent\(event\)\n)", t)
    if m:
        t = t[:m.start()] + "        self._save_window_geometry()  # AETHER_GEO_SAVE\n" + t[m.start():]
        mark("geo_save")
    else:
        warns.append("geo_save-anchor-missing")

if "AETHER_CLAMP_GUARD" not in t:
    old = "    def clamp_to_screen(self):\n        geo = QApplication.primaryScreen().availableGeometry()\n"
    new = (
        "    def clamp_to_screen(self):\n"
        "        if self.settings.value(\"window_geo\"):  # AETHER_CLAMP_GUARD\n"
        "            return\n"
        "        geo = QApplication.primaryScreen().availableGeometry()\n"
    )
    if old in t:
        t = t.replace(old, new, 1)
        mark("clamp_guard")
    else:
        warns.append("clamp_guard-anchor-missing")

if "AETHER_FONT_STARTUP" not in t:
    old = "    app.setStyleSheet(build_qss(theme, fpx))  # AETHER_FONT_APPLY\n    win = MainWindow()\n"
    new = (
        "    app.setStyleSheet(build_qss(theme, fpx))  # AETHER_FONT_APPLY\n"
        "    _startup_font = app.font()\n"
        "    _startup_font.setPixelSize(fpx)\n"
        "    app.setFont(_startup_font)  # AETHER_FONT_STARTUP\n"
        "    win = MainWindow()\n"
    )
    if old in t:
        t = t.replace(old, new, 1)
        mark("font_startup")
    else:
        warns.append("font_startup-anchor-missing")

if "AETHER_GEO_MAX_GUARD" not in t:
    old = "    win.setWindowState(Qt.WindowState.WindowMaximized)\n    win.show()\n"
    new = (
        "    if not st.value(\"window_geo\"):  # AETHER_GEO_MAX_GUARD\n"
        "        win.setWindowState(Qt.WindowState.WindowMaximized)\n"
        "    win.show()\n"
    )
    if old in t:
        t = t.replace(old, new, 1)
        mark("geo_max_guard")
    else:
        warns.append("geo_max_guard-anchor-missing")

# ------------------------------------------------------------------ 7) reboot policy per-unit enable/disable
if "AETHER_REBOOT_PERUNIT" not in t:
    def enable_repl(m):
        ind = m.group(1)
        return (
            f'{ind}for _u in unit_list:  # AETHER_REBOOT_PERUNIT\n'
            f'{ind}    su(["enable", _u])\n'
        )
    t2 = re.sub(r'(?m)^(\s*)su\(\["enable"\] \+ unit_list\)\s*$', enable_repl, t, count=1)
    if t2 != t:
        t = t2
        mark("reboot_enable_perunit")
    else:
        warns.append("reboot_enable-anchor-missing")

if "AETHER_REBOOT_PERUNIT_DIS" not in t:
    def disable_repl(m):
        ind = m.group(1)
        return (
            f'{ind}for _u in unit_list:  # AETHER_REBOOT_PERUNIT_DIS\n'
            f'{ind}    su(["disable", _u])\n'
        )
    t2 = re.sub(r'(?m)^(\s*)su\(\["disable"\] \+ unit_list\)\s*$', disable_repl, t, count=1)
    if t2 != t:
        t = t2
        mark("reboot_disable_perunit")
    else:
        warns.append("reboot_disable-anchor-missing")

# ------------------------------------------------------------------ write
if t != orig:
    path.write_text(t, encoding="utf-8")

print("CJ: changed=" + (",".join(changes) if changes else "none"))
if warns:
    print("CJ: warnings=" + "; ".join(warns), file=sys.stderr)
sys.exit(0)
