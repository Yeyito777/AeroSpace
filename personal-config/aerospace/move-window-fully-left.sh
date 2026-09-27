#!/bin/sh

set -u

aerospace="/opt/homebrew/bin/aerospace"
window_id="$($aerospace list-windows --focused --format '%{window-id}' 2>/dev/null | sed -n '1p')"

if [ -z "$window_id" ]; then
  exit 0
fi

# Keep the original window as the target while AeroSpace normalizes the tree
# between moves. The command fails exactly when the workspace edge is reached.
while "$aerospace" move --window-id "$window_id" \
    --boundaries workspace --boundaries-action fail left >/dev/null 2>&1; do
  :
done

"$aerospace" focus --window-id "$window_id" >/dev/null 2>&1 || true
