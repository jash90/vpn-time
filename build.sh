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

# Shipped inside the bundle so an in-app update can refresh the tracker scripts
# in ~/.local/bin and swap the bundle once the app has quit.
mkdir -p "$APP/Contents/Resources/scripts"
install -m 755 scripts/vpn-track.sh scripts/vpn-report.sh "$APP/Contents/Resources/scripts/"
install -m 755 bundle/update-helper.sh "$APP/Contents/Resources/update-helper.sh"

# A Developer ID signature gives the app a stable code identity. TCC ties the
# Apple Events permission used to close Tunnelblick to that identity, so an
# ad-hoc build has to be re-authorised after every rebuild. Falls back to ad-hoc
# when no Developer ID certificate is in the keychain.
# Matched by SHA-1 hash, not by name: two Developer ID certificates can carry
# the same common name, and codesign refuses an ambiguous name.
# Order: VPNTIME_SIGN_IDENTITY, then APPLE_SIGNING_IDENTITY (exported by the
# caller or read from ~/.config/local-release/apple.env), then the first
# Developer ID certificate in the keychain.
LOCAL_RELEASE_ENV="${LOCAL_RELEASE_ENV:-$HOME/.config/local-release/apple.env}"
if [ -z "${VPNTIME_SIGN_IDENTITY:-}" ] && [ -z "${APPLE_SIGNING_IDENTITY:-}" ] \
  && [ -f "$LOCAL_RELEASE_ENV" ]; then
  APPLE_SIGNING_IDENTITY="$(
    # shellcheck disable=SC1090
    . "$LOCAL_RELEASE_ENV" >/dev/null 2>&1 && printf '%s' "${APPLE_SIGNING_IDENTITY:-}"
  )"
fi

IDENTITY="${VPNTIME_SIGN_IDENTITY:-${APPLE_SIGNING_IDENTITY:-$(
  security find-identity -v -p codesigning \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application:.*/\1/p' \
    | head -1
)}}"

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
