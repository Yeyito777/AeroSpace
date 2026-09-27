#!/bin/zsh

set -u

aerospace="/opt/homebrew/bin/aerospace"
st_binary="$HOME/Applications/st.app/Contents/MacOS/st"
st_bundle_id="io.yeyito.st"
target_workspace="$("$aerospace" list-workspaces --focused | head -n 1)"

before_ids="$("$aerospace" list-windows --monitor all --app-bundle-id "$st_bundle_id" --format '%{window-id}' 2>/dev/null || true)"

if [[ ! -x "$st_binary" ]]; then
  print -u2 -- "st is not installed at $st_binary"
  exit 1
fi

# Launch the app binary from $HOME so the new shell inherits the same default
# working directory as Apple Terminal. AeroSpace focuses it after registration.
cd "$HOME" || exit 1
nohup "$st_binary" </dev/null >/dev/null 2>&1 &!

new_window_id=""
for _ in {1..80}; do
  current_ids="$("$aerospace" list-windows --monitor all --app-bundle-id "$st_bundle_id" --format '%{window-id}' 2>/dev/null || true)"

  for id in ${(f)current_ids}; do
    if ! print -r -- "$before_ids" | grep -qx -- "$id"; then
      new_window_id="$id"
      break 2
    fi
  done

  sleep 0.05
done

if [[ -n "$new_window_id" ]]; then
  "$aerospace" move-node-to-workspace --window-id "$new_window_id" "$target_workspace" >/dev/null 2>&1 || true
  "$aerospace" workspace "$target_workspace" >/dev/null 2>&1 || true
  "$aerospace" focus --window-id "$new_window_id" >/dev/null 2>&1 || true
else
  "$aerospace" workspace "$target_workspace" >/dev/null 2>&1 || true
fi
