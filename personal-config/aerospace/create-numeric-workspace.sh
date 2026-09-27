#!/bin/sh

set -u

aerospace="${AEROSPACE_BIN:-/opt/homebrew/bin/aerospace}"
current="$($aerospace list-workspaces --focused 2>/dev/null | sed -n '1p')"

case "$current" in
  ''|*[!0-9]*) exit 0 ;;
esac

# Snapshot before moving. Process later workspaces from right to left so each
# destination is vacated before the workspace immediately before it arrives.
numbered_workspaces="$($aerospace list-workspaces --all 2>/dev/null | \
  awk '/^[0-9]+$/ { print $0 }' | sort -rn)"
window_map="$($aerospace list-windows --all \
  --format '%{workspace}|%{window-id}' 2>/dev/null)"

for source_workspace in $numbered_workspaces; do
  if [ "$source_workspace" -le "$current" ]; then
    continue
  fi

  destination_workspace=$((source_workspace + 1))
  source_window_ids="$(printf '%s\n' "$window_map" | \
    awk -F '|' -v workspace="$source_workspace" \
      '$1 == workspace { print $2 }')"

  for window_id in $source_window_ids; do
    "$aerospace" move-node-to-workspace --window-id "$window_id" \
      "$destination_workspace" >/dev/null 2>&1 || exit 1
  done
done

"$aerospace" workspace "$((current + 1))" >/dev/null 2>&1
