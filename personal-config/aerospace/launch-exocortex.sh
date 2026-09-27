#!/bin/sh

set -u

aerospace="${AEROSPACE_BIN:-/opt/homebrew/bin/aerospace}"
st_binary="${ST_BINARY:-$HOME/Applications/st.app/Contents/MacOS/st}"
exocortex="${EXOCORTEX_BIN:-$HOME/.local/bin/exocortex}"
project="${EXOCORTEX_DIR:-$HOME/Desktop/Exocortex}"
poll_interval="${ST_AEROSPACE_POLL_INTERVAL:-0.05}"
max_attempts="${ST_AEROSPACE_MAX_ATTEMPTS:-80}"

if [ ! -x "$aerospace" ]; then
	printf 'AeroSpace is not installed at %s\n' "$aerospace" >&2
	exit 1
fi
if [ ! -x "$st_binary" ]; then
	printf 'st is not installed at %s\n' "$st_binary" >&2
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

target_workspace=$("$aerospace" list-workspaces --focused | sed -n '1p')
if [ -z "$target_workspace" ]; then
	printf 'Could not determine the focused AeroSpace workspace\n' >&2
	exit 1
fi

# GUI launch agents may not inherit the interactive zsh PATH.  Exocortex's
# launcher resolves its own project and invokes Bun, so expose both explicitly.
PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
export PATH

cd "$project" || exit 1
ST_AEROSPACE_MANAGED=1 nohup "$st_binary" -T exocortex -e "$exocortex" "$@" \
	</dev/null >/dev/null 2>&1 &
st_pid=$!

window_id=
attempt=0
while [ "$attempt" -lt "$max_attempts" ]; do
	window_id=$("$aerospace" list-windows --monitor all --pid "$st_pid" \
		--format '%{window-id}' 2>/dev/null | sed -n '1p')
	if [ -n "$window_id" ]; then
		break
	fi
	attempt=$((attempt + 1))
	sleep "$poll_interval"
done

if [ -z "$window_id" ]; then
	kill "$st_pid" 2>/dev/null || true
	printf 'AeroSpace did not register the Exocortex st window for PID %s\n' \
		"$st_pid" >&2
	exit 1
fi

if ! "$aerospace" move-node-to-workspace --window-id "$window_id" \
	"$target_workspace" >/dev/null 2>&1; then
	kill "$st_pid" 2>/dev/null || true
	printf 'AeroSpace could not move Exocortex window %s to workspace %s\n' \
		"$window_id" "$target_workspace" >&2
	exit 1
fi

if ! "$aerospace" focus --window-id "$window_id" >/dev/null 2>&1; then
	kill "$st_pid" 2>/dev/null || true
	printf 'AeroSpace could not focus Exocortex window %s\n' "$window_id" >&2
	exit 1
fi

# Managed st windows remain transparent until AeroSpace finishes layout and
# focus.  SIGUSR1 completes that handshake without a timing guess.
if ! kill -USR1 "$st_pid" 2>/dev/null; then
	printf 'Exocortex st process %s exited before reveal\n' "$st_pid" >&2
	exit 1
fi
