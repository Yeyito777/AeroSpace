#!/bin/sh

set -u

st_launch="${ST_AEROSPACE_LAUNCH:-$HOME/Applications/st.app/Contents/Resources/bin/st-aerospace-launch}"
exocortex="${EXOCORTEX_BIN:-$HOME/.local/bin/exocortex}"
project="${EXOCORTEX_DIR:-$HOME/Desktop/Exocortex}"

if [ ! -x "$st_launch" ]; then
	printf 'st-aerospace-launch is not installed at %s\n' "$st_launch" >&2
	exit 1
fi
if [ ! -x "$exocortex" ]; then
	printf 'Exocortex is not installed at %s\n' "$exocortex" >&2
	exit 1
fi
if [ ! -d "$project" ]; then
	printf 'Exocortex project is not available at %s\n' "$project" >&2
	exit 1
fi

# GUI launch agents may not inherit the interactive zsh PATH.  Exocortex's
# launcher resolves its own project and invokes Bun, so expose both explicitly.
PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
export PATH

# The st launcher places, focuses and reveals the window on the focused
# workspace (from a warm spare when one is waiting) and forwards this PATH.
exec "$st_launch" --cwd "$project" -T exocortex -e "$exocortex" "$@"
