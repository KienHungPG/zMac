#!/bin/bash
# ./scripts/make-release.sh   chuẩn bị một bản phát hành. Script không tự phát hành gì, chỉ IN lệnh để bạn tự chạy.
#
# Làm:
# 1. make-dmg.sh: build, website/download/zMac.dmg + latest.json cho trang tải.
# 2. make-cask.sh: packaging/homebrew/zmac.rb (cask trỏ tới zMac.dmg của GitHub Release v<phiên bản>).
# 3. Có khoá cập nhật thì nén app thành build/release/zMac-X.Y.Z.zip, ký Ed25519 (.zip.sig) và kiểm lại.
#    Chưa có khoá thì bỏ qua: bản này vẫn tải được (trang web, Homebrew) nhưng tự cập nhật trong app không thấy nó.
# 4. Lấy ghi chú của phiên bản từ CHANGELOG.md vào build/release/notes-X.Y.Z.md.
#
# Trước khi chạy: tăng CFBundleShortVersionString / CFBundleVersion trong Resources/Info.plist, thêm mục mới
# vào CHANGELOG.md và website/changelog.json.
# Khoá cập nhật tạo một lần bằng `swift scripts/update-sign.swift genkey` (hỏi chủ repo trước).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
grep -q "^## $VERSION\$" CHANGELOG.md || { echo "CHANGELOG.md chưa có mục '## $VERSION'"; exit 1; }
grep -q "\"version\": \"$VERSION\"" website/changelog.json || { echo "website/changelog.json chưa có bản $VERSION"; exit 1; }

./scripts/make-dmg.sh
./scripts/make-cask.sh

OUT=build/release
mkdir -p "$OUT"
NOTES="$OUT/notes-$VERSION.md"
# Từ dòng "## X.Y.Z" tới mục kế tiếp, bỏ chính dòng tiêu đề.
awk -v v="## $VERSION" '$0 == v { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md > "$NOTES"

ASSETS="website/download/zMac.dmg"
if [ -s Resources/update-public-key.txt ]; then
    ZIP="$OUT/zMac-$VERSION.zip"
    rm -f "$ZIP" "$ZIP.sig"
    ditto -c -k --sequesterRsrc --keepParent build/zMac.app "$ZIP"
    swift scripts/update-sign.swift sign "$ZIP" > "$ZIP.sig"
    swift scripts/update-sign.swift verify "$ZIP" "$ZIP.sig"
    echo "→ $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' ')) + chữ ký"
    ASSETS="\"$ZIP\" \"$ZIP.sig\" $ASSETS"
else
    echo "! Chưa có khoá cập nhật: bỏ qua zip có chữ ký, tự cập nhật trong app sẽ không thấy bản này."
fi
echo "→ $NOTES"
echo
echo "Phát hành (tự chạy khi đã sẵn sàng):"
echo "  gh release create v$VERSION $ASSETS --title \"zMac $VERSION\" --notes-file \"$NOTES\""
echo
echo "Cập nhật Homebrew (repo KienHungPG/homebrew-tap):"
echo "  cp packaging/homebrew/zmac.rb <thư mục homebrew-tap>/Casks/zmac.rb, rồi commit và push repo đó."
