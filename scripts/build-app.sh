#!/bin/bash
# Builds build/SlurmBar.app for Apple Silicon, signed ad hoc. Needs only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product SlurmBar
app=build/SlurmBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SlurmBar "$app/Contents/MacOS/SlurmBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "built $app"
