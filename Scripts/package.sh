#!/bin/bash
# Builds the app and packs it into a disk image for distribution: build/Nits-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Nits-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

# The image shows the app next to a shortcut to Applications, so installing is one drag.
cp -R build/Nits.app "$STAGING/Nits.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Nits $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -quiet "$DMG"
echo "Packaged $DMG"
