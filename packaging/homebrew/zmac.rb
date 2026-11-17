# Cask Homebrew của zMac. Sinh bởi scripts/make-cask.sh trong repo KienHungPG/zMac, đừng sửa tay.
cask "zmac" do
  version "0.2.0"
  sha256 "140481f5173668166f0d31f297488ce2a96585144049d296da95f3485015a592"

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
