#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
built_app="$project_dir/dist/Cappy.app"
system_app="/Library/Input Methods/Cappy.app"
user_app="$HOME/Library/Input Methods/Cappy.app"

if [[ -d "$system_app" && -w "$system_app" ]]; then
    installed_app="$system_app"
else
    installed_app="$user_app"
    mkdir -p "${installed_app:h}"
fi

# Stop the old input-method process before replacing its executable. Keeping the
# bundle identifier and mode identifier stable preserves the user's selection.
killall Cappy 2>/dev/null || true

if [[ -d "$installed_app" ]]; then
    rm -rf "$installed_app/Contents"
fi
ditto "$built_app" "$installed_app"
xattr -cr "$installed_app"
"$installed_app/Contents/MacOS/Cappy" --register-input-source

# These per-user services immediately reload input-method metadata and artwork.
# The selected input method is launched again automatically on the next key event.
killall TextInputMenuAgent 2>/dev/null || true
# The Fn switcher and inline cursor badge have separate artwork caches.
killall TextInputSwitcher 2>/dev/null || true
killall CursorUIViewService 2>/dev/null || true
# Keep the IMK connection broker running. Killing it during an update invalidates
# connections held by already-running clients; switching input sources alone may
# not recreate those connections. Only Cappy itself needs to restart.

echo "Installed and refreshed $installed_app"
