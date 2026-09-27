#!/bin/zsh

set -u

aerospace="/opt/homebrew/bin/aerospace"
target_workspace="$("$aerospace" list-workspaces --focused | head -n 1)"
focused_window_id="$("$aerospace" list-windows --focused --format '%{window-id}' 2>/dev/null | head -n 1)"

if [[ -z "$target_workspace" || -z "$focused_window_id" ]]; then
  exit 0
fi

"$aerospace" close --quit-if-last-window --window-id "$focused_window_id" >/dev/null 2>&1 || exit 0

for _ in {1..10}; do
  sleep 0.03
  "$aerospace" workspace "$target_workspace" >/dev/null 2>&1 || true
done
