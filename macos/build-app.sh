#!/bin/sh
# Builds Agentz.app into .build/. Usage: build-app.sh [debug|release]
set -eu

config=${1:-release}
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
swift build --package-path "$dir" -c "$config"
bin=$(swift build --package-path "$dir" -c "$config" --show-bin-path)
app="$dir/.build/Agentz.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/agentz" "$app/Contents/MacOS/agentz"
# Ghostty's shell integration and terminfo, found through Bundle.main.
cp -R "$bin"/*.bundle "$app/Contents/Resources/"
cp "$dir/Resources/Agentz.icns" "$app/Contents/Resources/Agentz.icns"
cp "$dir/Info.plist" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
