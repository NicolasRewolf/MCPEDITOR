#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kit-studio-icon.XXXXXX")"
trap 'rm -rf "$ICON_STAGE"' EXIT
ICONSET="$ICON_STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PROJECT_DIR/Assets/AppIcon.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$PROJECT_DIR/Assets/AppIcon.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/Assets/AppIcon.icns"
