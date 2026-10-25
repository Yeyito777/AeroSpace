#!/bin/sh

set -eu

CDPATH=
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
# Not $TMPDIR: on macOS it is so long that the spares' control socket paths
# would exceed the 104-byte sun_path limit.
tmp=/tmp/st-aerospace-launcher-test.$$
mkdir -p "$tmp/home" "$tmp/bin"
tmp=$(cd "$tmp" && pwd -P)
log=$tmp/aerospace.log
pids=$tmp/st.pids
ready=$tmp/ready
reveal_log=$tmp/reveal.log
events=$tmp/events
slot=$tmp/home/.runtime/st/spare
mkdir -p "$ready"
: > "$log"
: > "$pids"
: > "$reveal_log"
: > "$events"

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

# A spare like `st --spare`: publish the slot, serve one spawn request on the
# control socket, then "open" the window, which AeroSpace reports as an event.
cat > "$tmp/bin/st" <<'EOF'
#!/bin/sh
runtime=$HOME/.runtime/st
slot=$runtime/spare
case "${1:-}" in
	--spare) ;;
	--spare-slot) slot=$2 ;;
	*) exit 64 ;;
esac
printf '%s\n' "$$" >> "$FAKE_ST_PIDS"
dir=$runtime/st-$$
mkdir -p "$dir"
# Not `nc -lU`: macOS nc in listen mode drops unread input when the sender
# closes right after writing (requests carry a ~3 KiB environment).
perl -MIO::Socket::UNIX -e '
	my $server = IO::Socket::UNIX->new(Type => SOCK_STREAM(),
	    Local => $ARGV[0], Listen => 1) or die "listen: $!";
	my $client = $server->accept or die "accept: $!";
	local $/;
	my $request = <$client>;
	open(my $out, ">", $ARGV[1]) or die "open: $!";
	print $out $request;
' "$dir/control.sock" "$dir/request" &
listener=$!
printf '%s\n' "$listener" >> "$FAKE_ST_PIDS"
while [ ! -S "$dir/control.sock" ]; do sleep 0.01; done
stamp=$(stat -f '%i:%m' "$0" 2>/dev/null || stat -c '%i:%Y' "$0")
printf '%s %s %s\n' "$$" "$$" "$stamp" > "$slot.$$.tmp"
if ! ln "$slot.$$.tmp" "$slot" 2>/dev/null; then
	rm -f "$slot.$$.tmp"
	kill "$listener"
	exit 0
fi
rm -f "$slot.$$.tmp"
trap 'printf "reveal %s\n" "$$" >> "$FAKE_REVEAL_LOG"' USR1
wait "$listener"
tr '\0' '\n' < "$dir/request" > "$dir/fields"
# Like st, ignore a request that does not end with its end field.
[ "$(tail -n 1 "$dir/fields")" = end ] || exit 65
sed -n '1p' "$dir/fields" > "$FAKE_ST_READY_DIR/$$.command"
sed -n 's/^cwd=//p' "$dir/fields" > "$FAKE_ST_READY_DIR/$$.cwd"
sed -n 's/^env=ST_INHERIT_VIRTUAL_ENV=//p' "$dir/fields" > "$FAKE_ST_READY_DIR/$$.venv"
sed -n 's/^PATH=//p' "$dir/fields" > "$FAKE_ST_READY_DIR/$$.path"
sed -n 's/^ST_TEST_LAUNCHER_ONLY=//p' "$dir/fields" > "$FAKE_ST_READY_DIR/$$.marker"
sed -n 's/^title=//p' "$dir/fields" > "$FAKE_ST_READY_DIR/$$.title"
sed -n 's/^arg=//p' "$dir/fields" > "$FAKE_ST_READY_DIR/$$.args"
: > "$FAKE_ST_READY_DIR/$$"
printf '{"_event":"window-detected","appBundleId":"io.yeyito.st","appName":"st","windowId":%s,"workspace":"%s"}\n' \
	"$$" "$(cat "$FAKE_DETECT_WORKSPACE")" >> "$FAKE_EVENTS"
while :; do
	sleep 0.05
done
EOF

# Window ids are the owning fake st's PID.
cat > "$tmp/bin/aerospace" <<'EOF'
#!/bin/sh
set -eu

command=$1
shift
case "$command" in
	subscribe)
		printf '{"_event":"focus-changed","windowId":1,"workspace":"TEST"}\n'
		exec tail -n +1 -f "$FAKE_EVENTS"
		;;
	list-workspaces)
		printf 'TEST\n'
		;;
	list-apps)
		printf 'list-apps\n' >> "$FAKE_AEROSPACE_LOG"
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
		if [ -f "$FAKE_ST_READY_DIR/$pid" ] && kill -0 "$pid" 2>/dev/null; then
			printf '%s %s\n' "$pid" "$(cat "$FAKE_DETECT_WORKSPACE")"
		fi
		;;
	move-node-to-workspace)
		[ "$1" = --focus-follows-window ] && [ "$2" = --window-id ]
		printf 'move %s %s\n' "$3" "$4" >> "$FAKE_AEROSPACE_LOG"
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
export FAKE_EVENTS="$events"
# Where AeroSpace places new windows; a file, as spares boot long before use.
export FAKE_DETECT_WORKSPACE="$tmp/detect-workspace"
printf 'TEST\n' > "$FAKE_DETECT_WORKSPACE"

run_launcher()
{
	HOME=$tmp/home \
	AEROSPACE_BIN=$tmp/bin/aerospace \
	ST_BINARY=$tmp/bin/st \
	ST_AEROSPACE_TICK=0.02 \
	ST_AEROSPACE_MAX_TICKS=500 \
	"$repo/scripts/st-aerospace-launch" "$@"
}

# The window of the most recent launch (focused or moved with focus).
launched()
{
	awk '$1 == "focus" || $1 == "move" { id = $2 } END { print id }' "$log"
}

wait_for_reveal()
{
	attempt=0
	while ! grep -q "^reveal $1\$" "$reveal_log"; do
		attempt=$((attempt + 1))
		if [ "$attempt" -gt 200 ]; then
			printf 'st process %s did not receive its reveal handshake\n' "$1" >&2
			exit 1
		fi
		sleep 0.01
	done
}

spare_holder()
{
	holder=
	[ -s "$slot" ] && read -r holder _ < "$slot"
	printf '%s\n' "$holder"
}

expect_live_spare()
{
	holder=$(spare_holder)
	if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
		printf 'expected a live spare in %s\n' "$slot" >&2
		exit 1
	fi
	if [ -f "$ready/$holder" ]; then
		printf 'spare %s was already claimed\n' "$holder" >&2
		exit 1
	fi
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

focus_ids=$(awk '$1 == "focus" { print $2 }' "$log")
focus_count=$(printf '%s\n' "$focus_ids" | awk 'NF { count++ } END { print count + 0 }')
unique_focus_count=$(printf '%s\n' "$focus_ids" | sort -u | awk 'NF { count++ } END { print count + 0 }')
move_count=$(awk '$1 == "move" { count++ } END { print count + 0 }' "$log")

if [ "$focus_count" -ne "$launch_count" ] ||
	[ "$unique_focus_count" -ne "$launch_count" ] ||
	[ "$move_count" -ne 0 ]; then
	printf 'launcher did not independently target every st process:\n' >&2
	cat "$log" >&2
	exit 1
fi

for window_id in $focus_ids; do
	if [ "$(cat "$ready/$window_id.command")" != spawn ]; then
		printf 'focused window %s was not spawned through its own spare\n' \
			"$window_id" >&2
		exit 1
	fi
	wait_for_reveal "$window_id"
done
# Concurrent launchers race to replace the spare; exactly one wins.
expect_live_spare

printf 'AeroSpace launcher concurrency and reveal handshake test passed\n'

# The next launch claims the waiting spare, then leaves a fresh one.
spare=$(spare_holder)
run_launcher
[ "$(launched)" = "$spare" ]
wait_for_reveal "$spare"
expect_live_spare
[ "$(spare_holder)" != "$spare" ]

# A window AeroSpace placed elsewhere is moved, with focus, to the workspace
# that was focused at invocation time.
printf 'OTHER\n' > "$FAKE_DETECT_WORKSPACE"
run_launcher
printf 'TEST\n' > "$FAKE_DETECT_WORKSPACE"
[ "$(awk '$1 == "focus" || $1 == "move" { last = $1 " " $3 } END { print last }' \
	"$log")" = "move TEST" ]
wait_for_reveal "$(launched)"

# A dead spare's slot is discarded and the launch still succeeds.
holder=$(spare_holder)
kill "$holder"
printf '999999 999999 0:0\n' > "$slot"
before=$(launched)
run_launcher
[ "$(launched)" != "$before" ]
[ "$(launched)" != 999999 ]
wait_for_reveal "$(launched)"
expect_live_spare

# A spare started from a binary that has since been replaced is never used.
holder=$(spare_holder)
read -r _ window _ < "$slot"
printf '%s %s 0:0\n' "$holder" "$window" > "$slot"
run_launcher
[ "$(launched)" != "$holder" ]
attempt=0
while kill -0 "$holder" 2>/dev/null; do
	attempt=$((attempt + 1))
	if [ "$attempt" -gt 200 ]; then
		printf 'outdated spare %s was not stopped\n' "$holder" >&2
		exit 1
	fi
	sleep 0.01
done
expect_live_spare

# Title, command and the caller's environment reach the spawned terminal.
(PATH="$tmp/extra:$PATH"; export ST_TEST_LAUNCHER_ONLY=yes
	run_launcher -T 'a title' -e /bin/echo 'two words')
pid=$(launched)
if [ "$(cat "$ready/$pid.marker")" != yes ]; then
	printf 'launcher environment was not forwarded to %s; request:\n' "$pid" >&2
	cat "$tmp/home/.runtime/st/st-$pid/fields" >&2
	exit 1
fi
[ "$(cat "$ready/$pid.title")" = 'a title' ]
[ "$(sed -n '1p' "$ready/$pid.args")" = /bin/echo ]
[ "$(sed -n '2p' "$ready/$pid.args")" = 'two words' ]
[ "$(sed -n '3p' "$ready/$pid.args")" = '' ]
case "$(cat "$ready/$pid.path")" in
	"$tmp/extra:"*) ;;
	*) printf 'PATH was not forwarded\n' >&2; exit 1 ;;
esac
# A plain launch sends no command, so the spare starts the shell.
run_launcher
[ ! -s "$ready/$(launched).args" ]

# ST_AEROSPACE_KEEP_SPARE=0 leaves nothing running behind.
holder=$(spare_holder)
run_launcher
[ "$(launched)" = "$holder" ]
(export ST_AEROSPACE_KEEP_SPARE=0; run_launcher)
[ ! -e "$slot" ]

printf 'AeroSpace launcher spare reuse, replacement and request tests passed\n'

check_directory()
{
	expected=$1
	shift
	run_launcher "$@"
	pid=$(launched)
	actual=$(cat "$ready/$pid.cwd")
	if [ "$actual" != "$expected" ]; then
		printf 'Expected cwd <%s>, got <%s>\n' "$expected" "$actual" >&2
		exit 1
	fi
}

check_directory "$tmp" --cwd "$tmp"
# A missing directory falls back to home rather than failing the launch.
check_directory "$tmp/home" --cwd "$tmp/missing"

# No focus and non-terminal focus both retain the normal home-directory launch.
export FAKE_FOCUSED=
check_directory "$tmp/home" --inherit-cwd
export FAKE_FOCUSED="com.apple.finder $$"
check_directory "$tmp/home" --inherit-cwd

# The launcher reads the focused shell's cwd with macOS's /usr/sbin/lsof.
# Hosts without it (Linux CI) cannot exercise inheritance; skip, don't fail.
if [ ! -x /usr/sbin/lsof ]; then
	printf 'AeroSpace launcher cwd inheritance tests skipped: no /usr/sbin/lsof\n'
	exit 0
fi

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
