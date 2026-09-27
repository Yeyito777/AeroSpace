#!/bin/zsh

set -u

aerospace="/opt/homebrew/bin/aerospace"
delta="${1:-0}"
current="$("$aerospace" list-workspaces --focused | head -n 1)"

if [[ ! "$current" =~ '^[0-9]+$' || ! "$delta" =~ '^-?[0-9]+$' ]]; then
  exit 0
fi

next=$(( current + delta ))

if (( next < 1 )); then
  exit 0
fi

"$aerospace" workspace "$next" >/dev/null 2>&1 || true
