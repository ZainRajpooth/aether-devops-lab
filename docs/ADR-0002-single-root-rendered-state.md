# ADR-0002: single-root rendered-state platform
Status: accepted. Supersedes two-repo+stow symlink model.
Decision: ONE git root (~/DevOps/aether); quadlet SOURCES in infra/quadlet; aetherctl COPIES them to
~/.config/containers/systemd (rendered state); hash-convergence gate makes drift/missing loud.
Copies (not symlinks) because repo relocation must never dangle links (portability requirement).
Secrets outside repo (~/.config/aether/secrets.env, 0600). Data in gitignored binds.
Multi-line programs run FROM FILES, never pasted into interactive shells.
