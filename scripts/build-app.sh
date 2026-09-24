#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/dist/Cappy.app"
xcode_configuration="${configuration:u}"
derived_data="$project_dir/.build/xcode"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$project_dir"
xcodebuild \
    -project "$project_dir/Cappy.xcodeproj" \
    -scheme Cappy \
    -configuration "$xcode_configuration" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null
rm -rf "$app_dir"
mkdir -p "$project_dir/dist"
ditto "$derived_data/Build/Products/$xcode_configuration/Cappy.app" "$app_dir"

codesign --force --sign - \
    --requirements '=designated => identifier "com.efekoy.inputmethod.Cappy"' \
    "$app_dir"
echo "$app_dir"
