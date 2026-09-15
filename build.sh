#!/bin/bash
# Builds the release binary and assembles the ad-hoc signed .app bundle in build/.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/VPN Time.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bundle/Info.plist "$APP/Contents/Info.plist"
cp bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/VPNTime "$APP/Contents/MacOS/vpntime"

codesign --force --deep -s - "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|flags'

echo "built: $APP"
