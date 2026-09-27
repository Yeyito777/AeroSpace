#!/bin/sh

set -eu

CDPATH=
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/st-aerospace-launcher-test.$$
mkdir -p "$tmp/home" "$tmp/bin"
tmp=$(cd "$tmp" && pwd -P)
log=$tmp/aerospace.log
pids=$tmp/st.pids
ready=$tmp/ready
reveal_log=$tmp/reveal.log
mkdir -p "$ready"

cleanup()
{
	if [ -f "$pids" ]; then
		while IFS= read -r pid; do
			kill "$pid" 2>/dev/null || true
		done < "$pids"
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

cat > "$tmp/bin/st" <<'EOF'
#!/bin/sh
printf 'managed %s %s\n' "$$" "${ST_AEROSPACE_MANAGED:-}" >> "$FAKE_REVEAL_LOG"
printf '%s\n' "$PWD" > "$FAKE_ST_READY_DIR/$$.cwd"
printf '%s\n' "${ST_INHERIT_VIRTUAL_ENV-}" > "$FAKE_ST_READY_DIR/$$.venv"
trap 'printf "reveal %s\n" "$$" >> "$FAKE_REVEAL_LOG"' USR1
printf '%s\n' "$$" >> "$FAKE_ST_PIDS"
: > "$FAKE_ST_READY_DIR/$$"
while :; do
	sleep 0.05
done
EOF

cat > "$tmp/bin/aerospace" <<'EOF'
#!/bin/sh
set -eu

command=$1
shift
case "$command" in
	list-workspaces)
		printf 'TEST\n'
		;;
	list-windows)
		if [ "${1:-}" = --focused ]; then
			printf '%s\n' "${FAKE_FOCUSED:-}"
			exit 0
		fi
		pid=
		while [ "$#" -gt 0 ]; do
			if [ "$1" = --pid ]; then
				pid=$2
				break
			fi
			shift
		done
		[ -n "$pid" ] || exit 64
		printf 'query %s\n' "$pid" >> "$FAKE_AEROSPACE_LOG"
		[ -f "$FAKE_ST_READY_DIR/$pid" ] && kill -0 "$pid" 2>/dev/null &&
			printf '%s\n' "$pid"
		;;
	move-node-to-workspace)
		[ "$1" = --window-id ]
		printf 'move %s %s\n' "$2" "$3" >> "$FAKE_AEROSPACE_LOG"
		;;
	focus)
		[ "$1" = --window-id ]
		printf 'focus %s\n' "$2" >> "$FAKE_AEROSPACE_LOG"
		;;
	*)
		exit 64
		;;
esac
EOF

chmod +x "$tmp/bin/st" "$tmp/bin/aerospace"
export FAKE_ST_PIDS="$pids"
export FAKE_AEROSPACE_LOG="$log"
export FAKE_ST_READY_DIR="$ready"
export FAKE_REVEAL_LOG="$reveal_log"

run_launcher()
{
	HOME=$tmp/home \
	AEROSPACE_BIN=$tmp/bin/aerospace \
	ST_BINARY=$tmp/bin/st \
	ST_AEROSPACE_POLL_INTERVAL=0.001 \
	"$repo/scripts/st-aerospace-launch" "$@"
}

launch_count=12
launcher_pids=
launch_number=0
while [ "$launch_number" -lt "$launch_count" ]; do
	run_launcher &
	launcher_pids="$launcher_pids $!"
	launch_number=$((launch_number + 1))
done
for launcher_pid in $launcher_pids; do
	wait "$launcher_pid"
done

attempt=0
while [ "$attempt" -lt 200 ]; do
	reveal_count=$(awk '$1 == "reveal" { count++ } END { print count + 0 }' \
		"$reveal_log")
	[ "$reveal_count" -eq "$launch_count" ] && break
	attempt=$((attempt + 1))
	sleep 0.01
done

focus_ids=$(awk '$1 == "focus" { print $2 }' "$log")
focus_count=$(printf '%s\n' "$focus_ids" | awk 'NF { count++ } END { print count + 0 }')
unique_focus_count=$(printf '%s\n' "$focus_ids" | sort -u | awk 'NF { count++ } END { print count + 0 }')
move_count=$(awk '$1 == "move" && $3 == "TEST" { count++ } END { print count + 0 }' "$log")

if [ "$focus_count" -ne "$launch_count" ] ||
	[ "$unique_focus_count" -ne "$launch_count" ] ||
	[ "$move_count" -ne "$launch_count" ]; then
	printf 'launcher did not independently target every st process:\n' >&2
	cat "$log" >&2
	exit 1
fi

for window_id in $focus_ids; do
	if ! grep -q "^query $window_id\$" "$log"; then
		printf 'focused window %s was not selected by its owning PID\n' "$window_id" >&2
		exit 1
	fi
	if ! grep -q "^managed $window_id 1$" "$reveal_log"; then
		printf 'st process %s was not started in managed reveal mode\n' \
			"$window_id" >&2
		exit 1
	fi
	if ! grep -q "^reveal $window_id$" "$reveal_log"; then
		printf 'st process %s did not receive its reveal handshake\n' \
			"$window_id" >&2
		exit 1
	fi
done

printf 'AeroSpace launcher concurrency and reveal handshake test passed\n'

check_directory()
{
	expected=$1
	shift
	run_launcher "$@"
	pid=$(tail -n 1 "$pids")
	actual=$(cat "$ready/$pid.cwd")
	if [ "$actual" != "$expected" ]; then
		printf 'Expected cwd <%s>, got <%s>\n' "$expected" "$actual" >&2
		exit 1
	fi
}

# No focus and non-terminal focus both retain the normal home-directory launch.
export FAKE_FOCUSED=
check_directory "$tmp/home" --inherit-cwd
export FAKE_FOCUSED="com.apple.finder $$"
check_directory "$tmp/home" --inherit-cwd

# Real parent/PTY-child stand-in: only the child changes directory, so reading
# the terminal parent's cwd would fail this test. Include spaces and punctuation.
directory="$tmp/project with spaces ' and \$"
mkdir -p "$directory"
sh -c 'sh -c '\''cd "$1"; exec sleep 60'\'' sh "$1" & wait' sh "$directory" &
terminal_pid=$!
printf '%s\n' "$terminal_pid" >> "$pids"
attempt=0
child_pid=
while [ "$attempt" -lt 100 ]; do
	child_pid=$(/usr/bin/pgrep -P "$terminal_pid" | sed -n '1p')
	if [ -n "$child_pid" ]; then
		actual=$(/usr/sbin/lsof -a -p "$child_pid" -d cwd -Fn 2>/dev/null |
			sed -n 's/^n//p')
		[ "$actual" = "$directory" ] && break
	fi
	attempt=$((attempt + 1))
	sleep 0.01
done
[ -n "$child_pid" ]
printf '%s\n' "$child_pid" >> "$pids"
export FAKE_FOCUSED="io.yeyito.st $terminal_pid"
check_directory "$directory" --inherit-cwd
venv="$directory/venv with spaces"
mkdir -p "$venv/bin" "$tmp/home/.cache/st-shell-context"
: > "$venv/bin/activate"
context="$tmp/home/.cache/st-shell-context/$terminal_pid-$child_pid.venv"
printf '%s\n' "$venv" > "$context"
check_directory "$directory" --inherit-cwd
[ "$(cat "$ready/$pid.venv")" = "$venv" ]
# The original shortcut must still open at home even with a terminal focused.
check_directory "$tmp/home"
[ -z "$(cat "$ready/$pid.venv")" ]
# Other windows must not inherit the previously focused terminal's venv.
export FAKE_FOCUSED="com.apple.finder $$"
check_directory "$tmp/home" --inherit-cwd
[ -z "$(cat "$ready/$pid.venv")" ]
export FAKE_FOCUSED="io.yeyito.st $terminal_pid"
# Deactivation and a deleted venv both launch a clean shell.
printf '\n' > "$context"
check_directory "$directory" --inherit-cwd
[ -z "$(cat "$ready/$pid.venv")" ]
printf '%s\n' "$venv/missing" > "$context"
check_directory "$directory" --inherit-cwd
[ -z "$(cat "$ready/$pid.venv")" ]
kill "$child_pid" "$terminal_pid" 2>/dev/null || true
wait "$terminal_pid" 2>/dev/null || true
check_directory "$tmp/home" --inherit-cwd
printf 'AeroSpace launcher cwd inheritance and fallback tests passed\n'
