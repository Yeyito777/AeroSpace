#!/bin/sh

set -u

st_launch="${ST_AEROSPACE_LAUNCH:-$HOME/Applications/st.app/Contents/Resources/bin/st-aerospace-launch}"
whale_cal="${WHALE_CAL_BIN:-$HOME/.local/bin/whale-cal}"

if [ ! -x "$st_launch" ]; then
	printf 'st-aerospace-launch is not installed at %s\n' "$st_launch" >&2
	exit 1
fi
if [ ! -x "$whale_cal" ]; then
	printf 'Whale Cal is not installed at %s\n' "$whale_cal" >&2
	exit 1
fi

# GUI launch agents may not inherit the interactive zsh PATH.  whale-cal runs
# Bun from PATH, so expose it explicitly.
PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
export PATH

exec "$st_launch" --cwd "$HOME" -T cal -e "$whale_cal" "$@"
