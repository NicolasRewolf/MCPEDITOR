#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# XCTest and the string catalog compiler come with Xcode, not with the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcrun --find xcstringstool >/dev/null 2>&1 \
        && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift test
# The release build also lists every string it shows, so the catalog can be checked against it.
STRINGS_DIR="$PROJECT_DIR/.build/localized-strings"
swift build --configuration release --product KitStudio --arch arm64 \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS_DIR"
python3 scripts/localization.py check Localization/Localizable.xcstrings "$STRINGS_DIR"
BIN_DIR="$(swift build --configuration release --arch arm64 --show-bin-path)"
APP="$PROJECT_DIR/dist/Kit for MPC3000.app"
rm -rf "$PROJECT_DIR/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KitStudio" "$APP/Contents/MacOS/KitStudio"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
cp -R "$PROJECT_DIR/Notices" "$APP/Contents/Resources/"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# French and English, following the Mac's language; French when neither is preferred.
# The catalog compiles to fr.lproj and en.lproj; AppKit menus, panels and Foundation
# formatters (« Fichier », « 3,3 Mo ») follow the same choice.
xcrun xcstringstool compile Localization/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
for language in fr en; do
    mkdir -p "$APP/Contents/Resources/$language.lproj"
    cat > "$APP/Contents/Resources/$language.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "Kit for MPC3000";
"CFBundleDisplayName" = "Kit for MPC3000";
STRINGS
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>fr</string>
<key>CFBundleLocalizations</key><array><string>fr</string><string>en</string></array>
<key>CFBundleExecutable</key><string>KitStudio</string>
<key>CFBundleIdentifier</key><string>com.nicolasrewolf.mpckitstudio</string>
<key>CFBundleName</key><string>Kit for MPC3000</string>
<key>CFBundleDisplayName</key><string>Kit for MPC3000</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.1</string>
<key>CFBundleVersion</key><string>30</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PROJECT_DIR/dist/Kit-for-MPC3000-Apple-Silicon.zip"
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kit-studio-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
ditto "$APP" "$DMG_STAGE/Kit for MPC3000.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Kit for MPC3000" -srcfolder "$DMG_STAGE" \
    -format UDZO "$PROJECT_DIR/dist/Kit-for-MPC3000-Apple-Silicon.dmg"
python3 scripts/release-manifest.py create "$PROJECT_DIR/dist"
python3 scripts/release-manifest.py verify "$PROJECT_DIR/dist"
echo "Application prête : $PROJECT_DIR/dist/Kit-for-MPC3000-Apple-Silicon.dmg"
