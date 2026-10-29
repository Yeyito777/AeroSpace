#!/bin/sh

set -u

st_launch="${ST_AEROSPACE_LAUNCH:-$HOME/Applications/st.app/Contents/Resources/bin/st-aerospace-launch}"
notes="${NOTES_DIR:-$HOME/Notes}"

if [ ! -x "$st_launch" ]; then
	printf 'st-aerospace-launch is not installed at %s\n' "$st_launch" >&2
	exit 1
fi
mkdir -p "$notes" || exit 1

# GUI launch agents may not inherit the interactive zsh PATH.
PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
export PATH

exec "$st_launch" --cwd "$notes" -T notes -e nvim main.md
