#!/bin/bash
# ./scripts/make-release.sh   đóng gói một bản phát hành có chữ ký cho tự cập nhật.
#
# Làm: build (qua make-dmg.sh: DMG + latest.json cho trang web), nén app thành build/release/zMac-X.Y.Z.zip,
# ký Ed25519 thành .zip.sig, kiểm lại chữ ký, rồi IN lệnh `gh release create` để bạn tự chạy.
# Script không tự phát hành gì.
#
# Cần: Resources/update-public-key.txt và khoá bí mật (~/.zmac/update-key), tạo một lần bằng
#   swift scripts/update-sign.swift genkey
# Nhớ tăng CFBundleShortVersionString / CFBundleVersion trong Resources/Info.plist trước.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -s Resources/update-public-key.txt ] || { echo "Thiếu Resources/update-public-key.txt (swift scripts/update-sign.swift genkey)"; exit 1; }

./scripts/make-dmg.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
OUT=build/release
ZIP="$OUT/zMac-$VERSION.zip"
mkdir -p "$OUT"
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --sequesterRsrc --keepParent build/zMac.app "$ZIP"
swift scripts/update-sign.swift sign "$ZIP" > "$ZIP.sig"
swift scripts/update-sign.swift verify "$ZIP" "$ZIP.sig"

echo "→ $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' ')) + chữ ký"
echo
echo "Phát hành (tự chạy khi đã sẵn sàng):"
echo "  gh release create v$VERSION \"$ZIP\" \"$ZIP.sig\" website/download/zMac.dmg --title \"zMac $VERSION\" --notes \"...\""
