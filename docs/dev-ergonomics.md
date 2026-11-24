# Dev ergonomics runbook (EX64b)

Central Python environments live in ~/.venvs (override: AETHER_VENV_ROOT).
Creation uses uv against the local pyenv interpreter, so no interpreter is downloaded.

    venv new <name> [python-path]   create
    venv ls                         list
    venv path <name>                print path
    venv rm <name>                  delete
    va <name>                       activate (shell function)
    vd                              deactivate
    aether                          cd to the lab

Managed shell block: ~/.bashrc between the AETHER ERGONOMICS markers.
It is idempotent; re-running the codemod replaces the block, never duplicates it.
starship and direnv were already wired and are deliberately not re-initialised.
Aliases: bat->batcat, ll/lt via eza. fzf bindings sourced from the Ubuntu examples path.
tmux: ~/.tmux.conf, no plugins, prefix r reloads, | and - split in the current path.
Editor: aether.code-workspace excludes data/backups/.publish from watching and search.

Rollback: cp ~/.bashrc.pre-ex64b.bak ~/.bashrc; rm -f ~/.tmux.conf ~/.local/bin/venv
