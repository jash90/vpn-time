#!/bin/bash
# Builds, notarises and publishes a GitHub release of VPN Time.
#
# Needs a stored notarytool profile once per machine:
#   xcrun notarytool store-credentials vpn-time \
#     --apple-id <your-apple-id> --team-id H2X8YGN869 --password <app-specific-password>
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh v1.1.0 [notes-file]}"
NOTES="${2:-}"
PROFILE="${NOTARY_PROFILE:-vpn-time}"
APP="build/VPN Time.app"
ZIP="build/VPN-Time-$VERSION.zip"

./build.sh

if ! codesign -dv "$APP" 2>&1 | grep -q 'TeamIdentifier=H2X8YGN869'; then
  echo "error: bundle is not Developer ID signed — notarisation would be rejected" >&2
  exit 1
fi

echo "== submitting for notarisation =="
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "== stapling =="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip so the published archive carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== publishing =="

if [ -n "$NOTES" ]; then
  gh release create "$VERSION" "$ZIP" --title "VPN Time $VERSION" --notes-file "$NOTES"
else
  gh release create "$VERSION" "$ZIP" --title "VPN Time $VERSION" --generate-notes
fi
