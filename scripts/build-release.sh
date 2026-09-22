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
cat > "$STAGING/READ ME FIRST.txt" <<'EOF'
Leaf Native - First Launch

This build is ad-hoc signed (not Apple-notarized yet), so macOS
Gatekeeper blocks the first launch.

Do ONE of the following after dragging Leaf Native into Applications:

  1. Right-click "Leaf Native" in Applications and choose Open,
     then click Open again in the dialog.

  2. Or open Terminal and run:

       xattr -dr com.apple.quarantine "/Applications/Leaf Native.app"

Either step only needs to be done once. After that the app opens
normally and can update itself from the app menu.
EOF

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

