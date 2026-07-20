#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
APP="$ROOT/dist/Leaf Native.app"
STAGING="$ROOT/dist/dmg"
DMG="$ROOT/dist/Leaf-Native-${VERSION}.dmg"
ZIP="$ROOT/dist/Leaf-Native-${VERSION}-macOS.zip"
CHECKSUMS="$ROOT/dist/SHA256SUMS.txt"

"$ROOT/scripts/build-app.sh"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG" "$ZIP" "$CHECKSUMS"
hdiutil create \
    -volname "Leaf Native" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

cd "$ROOT/dist"
shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > "$CHECKSUMS"
rm -rf "$STAGING"

echo "$DMG"
echo "$ZIP"
echo "$CHECKSUMS"

