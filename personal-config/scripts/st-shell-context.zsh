# Source from the end of ~/.zshrc. Only publish Python virtualenv identity,
# never the whole shell environment (which may contain credentials).
[[ $TERM == st* ]] || return 0

function _st_restore_virtualenv {
  local environment=${ST_INHERIT_VIRTUAL_ENV-}
  unset ST_INHERIT_VIRTUAL_ENV
  if [[ -n $environment && -f $environment/bin/activate ]]; then
    source "$environment/bin/activate"
  fi
}
_st_restore_virtualenv

function _st_publish_shell_context {
  (
    umask 077
    local directory="$HOME/.cache/st-shell-context"
    local context="$directory/$PPID-$$.venv"
    mkdir -p -- "$directory" || return
    # Atomic replacement also clears the previous venv after deactivate.
    print -r -- "${VIRTUAL_ENV-}" > "$context.tmp" &&
      mv -f -- "$context.tmp" "$context"
  )
}

function _st_clear_shell_context {
  rm -f -- "$HOME/.cache/st-shell-context/$PPID-$$.venv"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _st_publish_shell_context
add-zsh-hook preexec _st_publish_shell_context
add-zsh-hook chpwd _st_publish_shell_context
add-zsh-hook zshexit _st_clear_shell_context
_st_publish_shell_context
