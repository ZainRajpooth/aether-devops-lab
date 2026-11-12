import sys; sys.path.insert(0, sys.argv[2])
from ch_lib import apply_reps
S_OLD = '''            self.status_lbl.setText(
                f"Settings saved: {self.refresh_interval_ms / 1000:g}s, mode {self.update_mode}, "
                f"theme {theme}, font {fpx}px."
            )
'''
S_NEW = S_OLD + '            self.settings.sync()  # AETHER_SETTINGS_SYNC\n'
G_OLD = '        self.settings.setValue("last_page", self.sidebar.currentRow())  # AETHER_SESSION_SAVE\n'
G_NEW = '        self.settings.setValue("window_geo", self.saveGeometry())  # AETHER_GEO_SAVE\n' + G_OLD
I_OLD = '        self.statusBar().showMessage("Aether Podman Command Center X initialized.")\n'
I_NEW = ('        self.apply_visual()\n'
         '        _geo = self.settings.value("window_geo")\n'
         '        if _geo:\n'
         '            self.restoreGeometry(_geo)  # AETHER_GEO_RESTORE\n'
         ) + I_OLD
apply_reps(sys.argv[1], [(S_OLD, S_NEW, "AETHER_SETTINGS_SYNC"), (G_OLD, G_NEW, "AETHER_GEO_SAVE"), (I_OLD, I_NEW, "AETHER_GEO_RESTORE")], "CH3")
