#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift test
swift build --configuration release --product KitStudio --arch arm64
BIN_DIR="$(swift build --configuration release --arch arm64 --show-bin-path)"
APP="$PROJECT_DIR/dist/MPC Kit Studio.app"
rm -rf "$PROJECT_DIR/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KitStudio" "$APP/Contents/MacOS/KitStudio"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KitStudio</string>
<key>CFBundleIdentifier</key><string>com.nicolasrewolf.mpckitstudio</string>
<key>CFBundleName</key><string>MPC Kit Studio</string>
<key>CFBundleDisplayName</key><string>MPC Kit Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PROJECT_DIR/dist/MPC-Kit-Studio-Apple-Silicon.zip"
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kit-studio-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
ditto "$APP" "$DMG_STAGE/MPC Kit Studio.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "MPC Kit Studio" -srcfolder "$DMG_STAGE" \
    -format UDZO "$PROJECT_DIR/dist/MPC-Kit-Studio-Apple-Silicon.dmg"
echo "Application prête : $PROJECT_DIR/dist/MPC-Kit-Studio-Apple-Silicon.dmg"
