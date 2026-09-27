#!/usr/bin/env python3
"""Snapshot an explicit allowlist of personal AeroSpace files, never dotfiles wholesale."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="write the snapshot (default: list only)")
    args = parser.parse_args()
    home = Path.home()
    destination = Path(__file__).resolve().parent
    files = {".aerospace.toml": "aerospace.toml"}
    for name in (
        "close-window-stay-workspace.sh",
        "create-numeric-workspace.sh",
        "delete-numeric-workspace.sh",
        "launch-exocortex.sh",
        "move-window-fully-left.sh",
        "numeric-workspace-step.sh",
        "open-spotlight.jxa",
        "open-terminal-current-workspace.sh",
        "raycast-current-workspace.swift",
        "type-em-dash.sh",
    ):
        files[f".config/aerospace/{name}"] = f"aerospace/{name}"
    for name in ("st-aerospace-launch", "st-shell-context.zsh"):
        files[f"Applications/st.app/Contents/Resources/bin/{name}"] = f"scripts/{name}"
    for name in ("test_aerospace_launcher.sh", "test_shell_context.zsh"):
        files[f"Desktop/st/tests/{name}"] = f"tests/{name}"
    for name in (
        "com.yeyito.swap-command-option.plist",
        "com.yeyito.aerospace.raycast-workspace.plist",
    ):
        files[f"Library/LaunchAgents/{name}"] = f"launchagents/{name}"

    # Fail before writing anything if a required source is missing.
    for source in files:
        if not (home / source).is_file():
            parser.error(f"missing required source: ~/{source}")

    manifest = {}
    for source, target in sorted(files.items()):
        print(f"~/{source} -> {target}")
        if args.write:
            output = destination / target
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(home / source, output)
            manifest[target] = {
                "source": f"~/{source}",
                "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            }
    if args.write:
        (destination / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )


if __name__ == "__main__":
    main()
