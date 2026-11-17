#!/bin/bash
# ./scripts/make-dmg.sh   build release rồi đóng gói website/download/zMac.dmg + latest.json cho trang tải.
#
# Trang web đọc latest.json để hiện phiên bản, dung lượng, chip hỗ trợ và mã SHA-256.
# Muốn bản chạy cả Mac Intel: ZMAC_UNIVERSAL=1 ./scripts/make-dmg.sh (nhớ thử trên máy Intel trước).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh

OUT=website/download
DMG="$OUT/zMac.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Ảnh đĩa gồm app và lối tắt tới Applications để người dùng kéo thả.
cp -R build/zMac.app "$STAGE/"
cp LICENSE "$STAGE/LICENSE.txt"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$OUT"
rm -f "$DMG"
hdiutil create -quiet -volname zMac -srcfolder "$STAGE" -format UDZO "$DMG"

PLIST=Resources/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
ARCHS="$(lipo -archs build/zMac.app/Contents/MacOS/zMac)"
SIZE="$(stat -f%z "$DMG")"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

cat > "$OUT/latest.json" <<EOF
{
  "version": "$VERSION",
  "build": "$BUILD",
  "file": "zMac.dmg",
  "size": $SIZE,
  "sha256": "$SHA",
  "minimumSystemVersion": "$MINOS",
  "archs": "$ARCHS",
  "date": "$(date +%F)"
}
EOF

echo "→ $DMG ($VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '), $ARCHS)"
echo "  sha256 $SHA"
