#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/dist/Cappy.app"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$project_dir"
swift build -c "$configuration"
binary_path="$(swift build -c "$configuration" --show-bin-path)/Cappy"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_path" "$app_dir/Contents/MacOS/Cappy"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/Cappy.tiff" "$app_dir/Contents/Resources/Cappy.tiff"
codesign --force --sign - \
    --requirements '=designated => identifier "com.efekoy.Cappy"' \
    "$app_dir"
echo "$app_dir"
