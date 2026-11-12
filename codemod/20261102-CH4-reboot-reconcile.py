import sys; sys.path.insert(0, sys.argv[2])
from ch_lib import apply_reps
E_OLD = '            su(["enable"] + unit_list)\n'
E_NEW = ('            enabled_ok = 0\n'
         '            skipped = []\n'
         '            for u in unit_list:  # AETHER_REBOOT_PERUNIT\n'
         '                rc, _, _ = su(["enable", u])\n'
         '                if rc == 0:\n'
         '                    enabled_ok += 1\n'
         '                else:\n'
         '                    skipped.append(u)\n')
M_OLD = '            msg = f"Enabled {len(unit_list)} unit(s) at boot."\n'
M_NEW = ('            msg = f"Enabled {enabled_ok} unit(s) at boot."\n'
         '            if skipped:\n'
         '                msg += f" Skipped {len(skipped)} not-enableable: {chr(44).join(skipped[:4])}"\n')
D_OLD = '        su(["disable"] + unit_list)\n'
D_NEW = ('        disabled_ok = 0\n'
         '        for u in unit_list:  # AETHER_REBOOT_PERUNIT_DIS\n'
         '            rc, _, _ = su(["disable", u])\n'
         '            if rc == 0:\n'
         '                disabled_ok += 1\n'
         '        return f"Disabled {disabled_ok} unit(s) at boot (Podman will sleep)."\n')
apply_reps(sys.argv[1], [(E_OLD, E_NEW, "AETHER_REBOOT_PERUNIT"), (M_OLD, M_NEW, "AETHER_REBOOT_MSG"), (D_OLD, D_NEW, "AETHER_REBOOT_PERUNIT_DIS")], "CH4")
