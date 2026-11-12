import sys; sys.path.insert(0, sys.argv[2])
from ch_lib import apply_reps
OLD = '''    def confirm(self, title, text):
        return QMessageBox.question(self, title, text,
                                    QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                    QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes
'''
NEW = '''    def confirm(self, title, text):
        try:
            return QMessageBox.question(self, title, text,
                                        QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                        QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes
        except Exception as exc:
            # CH2 crash-guard: a cosmetic scrim/Qt-object fault must NEVER abort the
            # process (PyQt6 qFatal's on exceptions escaping C++-connected slots).
            self.status_lbl.setText(f"Confirm dialog suppressed ({type(exc).__name__}); action cancelled safely.")
            return False  # AETHER_CONFIRM_GUARD
'''
apply_reps(sys.argv[1], [(OLD, NEW, "AETHER_CONFIRM_GUARD")], "CH2")
