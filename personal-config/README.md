# Personal AeroSpace setup

Snapshot of the configuration used with the
`personal/focus-and-hang-fixes` branch of this fork. The application's fork
code is in the normal repository source directories; these are the personal
settings and companion helpers, not a replacement for the upstream defaults.

## Contents

- `aerospace.toml`: exact current `~/.aerospace.toml`.
- `aerospace/`: source files from `~/.config/aerospace`, including older
  helpers retained locally. The current TOML determines which shortcuts run.
- `scripts/`: the installed st launcher and zsh venv-context hook, also
  maintained in the separate [st fork](https://github.com/Yeyito777/yeyito-term).
- `tests/`: launcher and shell-context regression tests from that st checkout.
- `launchagents/`: Command/Option swap and Raycast workspace-helper setup.
- `manifest.json`: original source paths and SHA-256 hashes of snapshot files.

No credentials, full shell configuration, Karabiner configuration, cache/state
files, backup files, logs, or compiled binaries are included.

## Main shortcuts

Names below are AeroSpace's logical modifiers. With the included Command ↔
Option mapping, `alt` means the **physical Command key**.

| Shortcut | Action |
| --- | --- |
| Alt+Shift+Enter | New st terminal in `$HOME` |
| Alt+Shift+Space | New st in the focused st child's local working directory, reactivating its Python venv when available; otherwise normal launch |
| Alt+Shift+L | Exocortex in a new st window |
| Alt+Shift+; | Exocortex over the `whale` SSH alias |
| Alt+O / Alt+D / Alt+Shift+D | Insert/delete numeric workspaces |
| Alt+Enter | Move the focused window to the far-left edge |
| Ctrl+Minus | Type an em dash |

## Restore

These are machine-specific files. Review them first and back up your existing
configuration. Replace `/Users/yeyito` in the TOML, scripts and launch agents
if your home directory differs. AeroSpace executable paths in bindings must
be absolute; `~` is not expanded there.

1. Install this AeroSpace fork and the native macOS st fork. The st launcher
   requires the managed-window reveal handshake (`ST_AEROSPACE_MANAGED` and
   `SIGUSR1`), so it is not compatible with an arbitrary stock st build.
2. Copy `aerospace.toml` to `~/.aerospace.toml` and the contents of
   `aerospace/` to `~/.config/aerospace/`. Preserve executable permissions.
3. Copy `scripts/st-aerospace-launch` and `scripts/st-shell-context.zsh` to
   `~/Applications/st.app/Contents/Resources/bin/`.
4. Add the following at the **end** of `~/.zshrc`:

   ```zsh
   [[ -r "$HOME/Applications/st.app/Contents/Resources/bin/st-shell-context.zsh" ]] &&
     source "$HOME/Applications/st.app/Contents/Resources/bin/st-shell-context.zsh"
   ```

   Source that file once in existing shells, or open new terminals. The hook
   publishes only `VIRTUAL_ENV` in private per-shell files, not secrets or the
   full environment. The new shell sources the venv's `bin/activate`, retaining
   a working `deactivate`. It does not clone arbitrary shell functions, Conda
   environments, or a remote SSH environment.
5. Optionally restore the launch agents to `~/Library/LaunchAgents/` and load
   them with `launchctl bootstrap gui/$(id -u) PATH_TO_PLIST`. The key-swap
   agent changes both left and right Command/Option keys system-wide.
   Before loading the Raycast agent, compile its helper:

   ```sh
   swiftc ~/.config/aerospace/raycast-current-workspace.swift \
     -o ~/.config/aerospace/raycast-current-workspace
   ```

6. Run `aerospace reload-config`.

Exocortex shortcuts additionally depend on `~/.local/bin/exocortex`,
`~/Desktop/Exocortex`, Bun, and (for the remote shortcut) a configured `whale`
SSH alias. The em-dash helper requires macOS automation/accessibility
permissions. The Raycast helper requires Raycast and AeroSpace.

## Refresh and verify

From this repository root:

```sh
python3 personal-config/sync-from-home.py         # list the explicit allowlist
python3 personal-config/sync-from-home.py --write # refresh snapshots and hashes
sh personal-config/tests/test_aerospace_launcher.sh
zsh -f personal-config/tests/test_shell_context.zsh
```

Tests require macOS; the venv test also requires Python 3. Review the Git diff
before committing: this is a public repository.
