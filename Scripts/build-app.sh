#!/bin/zsh
set -euo pipefail

script_path="${0:A}"
repo_root="${script_path:h:h}"
swift build --package-path "$repo_root" -c release
bin_dir="$(swift build --package-path "$repo_root" -c release --show-bin-path)"
app_dir="$repo_root/build/ThermoBar.app"
expected_app_dir="${repo_root:A}/build/ThermoBar.app"

if [[ "${app_dir:A}" != "$expected_app_dir" || "${app_dir:h}" != "$repo_root/build" ]]; then
    print -ru2 -- "Refusing to delete unexpected app target: $app_dir"
    exit 1
fi

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_root/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/ThermoBar" "$app_dir/Contents/MacOS/ThermoBar"

resource_bundle="$bin_dir/ThermoBar_ThermoBar.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    print -ru2 -- "Missing required resource bundle: $resource_bundle"
    exit 1
fi
ditto "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"

codesign --force --sign - --options runtime --entitlements "$repo_root/Packaging/ThermoBar.entitlements" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
print -r -- "$app_dir"
