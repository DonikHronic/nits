#!/bin/bash
# Builds build/Nits.app. Pass --install to also copy it to /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Nits.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Nits "$APP/Contents/MacOS/Nits"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    swift Scripts/make_icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run locally and to hold an Accessibility grant.
# Note that macOS ties that grant to the exact build, so it must be re-approved after rebuilding.
codesign --force --sign - --identifier app.nits.Nits "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Nits 2>/dev/null || true
    rm -rf /Applications/Nits.app
    cp -R "$APP" /Applications/Nits.app
    open /Applications/Nits.app
    echo "Installed and launched /Applications/Nits.app"
fi
