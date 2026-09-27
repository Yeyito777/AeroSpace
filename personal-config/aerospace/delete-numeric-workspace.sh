#!/bin/sh

set -u

aerospace="${AEROSPACE_BIN:-/opt/homebrew/bin/aerospace}"
focus_after="${1:-}"

case "$focus_after" in
  next|previous) ;;
  *) exit 64 ;;
esac

current="$($aerospace list-workspaces --focused 2>/dev/null | sed -n '1p')"
case "$current" in
  ''|*[!0-9]*) exit 0 ;;
esac

# Snapshot the whole operation before changing anything. In particular, a
# window shifted into workspace N must not be shifted again when N is visited.
numbered_workspaces="$($aerospace list-workspaces --all 2>/dev/null | \
  awk '/^[0-9]+$/ { print $0 }' | sort -n)"
window_map="$($aerospace list-windows --all \
  --format '%{workspace}|%{window-id}' 2>/dev/null)"

current_window_ids="$(printf '%s\n' "$window_map" | \
  awk -F '|' -v workspace="$current" '$1 == workspace { print $2 }')"
for window_id in $current_window_ids; do
  "$aerospace" close --quit-if-last-window \
    --window-id "$window_id" >/dev/null 2>&1 || exit 1
done

for source_workspace in $numbered_workspaces; do
  if [ "$source_workspace" -le "$current" ]; then
    continue
  fi

  destination_workspace=$((source_workspace - 1))
  source_window_ids="$(printf '%s\n' "$window_map" | \
    awk -F '|' -v workspace="$source_workspace" \
      '$1 == workspace { print $2 }')"

  for window_id in $source_window_ids; do
    "$aerospace" move-node-to-workspace --window-id "$window_id" \
      "$destination_workspace" >/dev/null 2>&1 || exit 1
  done
done

case "$focus_after" in
  next)
    # The old next workspace has just shifted into the deleted workspace's name.
    target_workspace="$current"
    ;;
  previous)
    if [ "$current" -gt 1 ]; then
      target_workspace=$((current - 1))
    else
      target_workspace=1
    fi
    ;;
esac

"$aerospace" workspace "$target_workspace" >/dev/null 2>&1
