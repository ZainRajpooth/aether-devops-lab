# >>> AETHER ERGONOMICS >>>
export AETHER_VENV_ROOT="$HOME/.venvs"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac
alias bat='batcat'
alias ll='eza -lah --git --icons=never'
alias lt='eza --tree --level=2 --icons=never'
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && . /usr/share/doc/fzf/examples/key-bindings.bash
[ -f /usr/share/doc/fzf/examples/completion.bash ] && . /usr/share/doc/fzf/examples/completion.bash
export FZF_DEFAULT_COMMAND='rg --files --hidden --glob "!.git"'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
va(){ local n="${1:?usage: va <venv-name>}"; local a="$AETHER_VENV_ROOT/$n/bin/activate"; if [ -f "$a" ]; then . "$a"; else echo "no such venv: $n" >&2; return 1; fi; }
vd(){ deactivate 2>/dev/null || true; }
aether(){ cd "$HOME/DevOps/aether" || return 1; }
# <<< AETHER ERGONOMICS <<<
