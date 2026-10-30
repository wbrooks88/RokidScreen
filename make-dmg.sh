#!/bin/bash
# Build Rokid Screen and package it as a drag-to-Applications disk image:
# build/RokidScreen-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
APP="build/Rokid Screen.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/RokidScreen-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Rokid Screen" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
