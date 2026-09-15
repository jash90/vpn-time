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

# A Developer ID signature gives the app a stable code identity. TCC ties the
# Apple Events permission used to close Tunnelblick to that identity, so an
# ad-hoc build has to be re-authorised after every rebuild. Falls back to ad-hoc
# when no Developer ID certificate is in the keychain.
# Matched by SHA-1 hash, not by name: two Developer ID certificates can carry
# the same common name, and codesign refuses an ambiguous name.
IDENTITY="${VPNTIME_SIGN_IDENTITY:-$(
  security find-identity -v -p codesigning \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application:.*/\1/p' \
    | head -1
)}"

if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp \
    --entitlements bundle/VPNTime.entitlements \
    -s "$IDENTITY" "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --deep -s - "$APP"
  echo "signed ad-hoc (no Developer ID certificate found)"
fi

codesign -dv "$APP" 2>&1 | grep -E 'Identifier|flags'

echo "built: $APP"
