#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/dist/AutoCaps.app"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$project_dir"
swift build -c "$configuration"
binary_path="$(swift build -c "$configuration" --show-bin-path)/AutoCaps"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_path" "$app_dir/Contents/MacOS/AutoCaps"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
# An explicit stable designated requirement prevents each ad-hoc local rebuild
# from looking like an unrelated application to macOS TCC permission services.
codesign --force --sign - \
    --requirements '=designated => identifier "com.local.AutoCaps"' \
    "$app_dir"
echo "$app_dir"
