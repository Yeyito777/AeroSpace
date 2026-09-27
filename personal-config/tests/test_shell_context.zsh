#!/bin/zsh
set -eu

repo=${0:A:h:h}
tmp=$(mktemp -d)
tmp=${tmp:A}
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home"
export TERM=st-256color
mkdir -p "$HOME"
venv="$tmp/project with spaces/venv"
python3 -m venv --without-pip "$venv"
original_path=$PATH
export ST_INHERIT_VIRTUAL_ENV="$venv"
source "$repo/scripts/st-shell-context.zsh"
context="$HOME/.cache/st-shell-context/$PPID-$$.venv"

[[ $VIRTUAL_ENV == "$venv" ]]
[[ $(command -v python) == "$venv/bin/python" ]]
[[ $(python -c 'import sys; print(sys.prefix)') == "$venv" ]]
(( $+functions[deactivate] ))
(( ! $+ST_INHERIT_VIRTUAL_ENV ))
[[ $(<"$context") == "$venv" ]]
[[ $(stat -f '%Lp' "$context") == 600 ]]

# Resourcing is safe and doesn't register duplicate hooks.
source "$repo/scripts/st-shell-context.zsh"
matching_hooks=(${(M)precmd_functions:#_st_publish_shell_context})
[[ ${#matching_hooks} == 1 ]]
# Drive publication explicitly for the remaining assertions.
add-zsh-hook -d preexec _st_publish_shell_context
deactivate
_st_publish_shell_context
[[ -z ${VIRTUAL_ENV-} && $PATH == "$original_path" ]]
[[ -z $(<"$context") ]]

# Activation after startup is recorded, then normal shell exit removes state.
source "$venv/bin/activate"
_st_publish_shell_context
[[ $(<"$context") == "$venv" ]]
_st_clear_shell_context
[[ ! -e $context ]]
deactivate

export ST_INHERIT_VIRTUAL_ENV="$tmp/nonexistent"
_st_restore_virtualenv
[[ -z ${VIRTUAL_ENV-} ]]
(( ! $+ST_INHERIT_VIRTUAL_ENV ))
print 'st shell context activation, deactivation, privacy and cleanup tests passed'
