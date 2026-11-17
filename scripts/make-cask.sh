#!/bin/bash
# ./scripts/make-cask.sh   sinh packaging/homebrew/zmac.rb (cask Homebrew) cho bản trong Resources/Info.plist.
#
# Cask tải zMac.dmg từ GitHub Release v<phiên bản>, nên DMG đính kèm release phải đúng là website/download/zMac.dmg
# (cùng mã SHA-256). Chạy sau make-dmg.sh; make-release.sh tự gọi script này.
# Người dùng cài bằng: brew install --cask kienhungpg/tap/zmac
# (repo KienHungPG/homebrew-tap, file Casks/zmac.rb là bản chép của file sinh ra ở đây).
set -euo pipefail
cd "$(dirname "$0")/.."

DMG=website/download/zMac.dmg
[ -f "$DMG" ] || { echo "Chưa có $DMG (chạy ./scripts/make-dmg.sh trước)"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
OUT=packaging/homebrew/zmac.rb
mkdir -p "$(dirname "$OUT")"

cat > "$OUT" <<RUBY
# Cask Homebrew của zMac. Sinh bởi scripts/make-cask.sh trong repo KienHungPG/zMac, đừng sửa tay.
cask "zmac" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/KienHungPG/zMac/releases/download/v#{version}/zMac.dmg"
  name "zMac"
  desc "Window switcher, snapping, clipboard history, notch and more in one menu bar app"
  homepage "https://zmac.vercel.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "zMac.app"

  # zMac chưa được Apple công chứng (notarize): bỏ cờ quarantine để mở được ngay lần đầu.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/zMac.app"]
  end

  # Daemon giới hạn sạc (nếu đã cài): launchd gửi SIGTERM, daemon cho sạc lại rồi mới thoát.
  uninstall launchctl: "com.zmac.helper",
            quit:      "com.zmac.app",
            delete:    [
              "/Library/LaunchDaemons/com.zmac.helper.plist",
              "/Library/PrivilegedHelperTools/com.zmac.helper",
            ]

  zap trash: [
    "/Library/Application Support/zMac",
    "~/Library/Application Support/zMac",
    "~/Library/Preferences/com.zmac.app.plist",
  ]
end
RUBY

echo "→ $OUT ($VERSION, sha256 $SHA)"
