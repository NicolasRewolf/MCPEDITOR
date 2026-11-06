#!/bin/bash
# Signed and notarized delivery, for selling outside the Mac App Store.
#
# Not run yet: it needs an Apple Developer Program membership. Steps it expects,
# done once by hand (see docs/LAUNCH.md, « Apple ») :
#   1. A "Developer ID Application" certificate installed in the login keychain.
#      Check: security find-identity -v -p codesigning
#   2. A notarytool profile stored in the keychain:
#      xcrun notarytool store-credentials kitstudio-notary \
#        --apple-id <apple id> --team-id <TEAMID> --password <app-specific password>
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Nicolas Doucet (TEAMID)" \
#   NOTARY_PROFILE=kitstudio-notary bash scripts/release-signed.sh
#
# It reuses build-app.sh (tests, arm64 build, bundle), then replaces the ad hoc
# signature with Developer ID + hardened runtime, notarizes and staples the app and
# the disk image, and rebuilds the release manifest over the delivered files.
set -euo pipefail
: "${DEVELOPER_ID:?Set DEVELOPER_ID to the Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
DIST="$PROJECT_DIR/dist"
APP="$DIST/MPC Kit Studio.app"
ZIP="$DIST/MPC-Kit-Studio-Apple-Silicon.zip"
DMG="$DIST/MPC-Kit-Studio-Apple-Silicon.dmg"

bash scripts/build-app.sh

# The app uses no sandbox entitlement: files are opened by the person, audio only plays.
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize the app through a zip, then staple the ticket to the app itself.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Rebuild the disk image around the stapled app, sign, notarize and staple it too.
rm -f "$DMG"
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kit-studio-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
ditto "$APP" "$DMG_STAGE/MPC Kit Studio.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "MPC Kit Studio" -srcfolder "$DMG_STAGE" -format UDZO "$DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# Gatekeeper's own verdict, as a downloaded copy would get it.
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

python3 scripts/release-manifest.py create "$DIST"
python3 scripts/release-manifest.py verify "$DIST"
echo "Livraison signée et notarisée : $DMG"
