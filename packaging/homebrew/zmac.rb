# Cask Homebrew của zMac. Sinh bởi scripts/make-cask.sh trong repo KienHungPG/zMac, đừng sửa tay.
cask "zmac" do
  version "0.2.0"
  sha256 "c7f290bb291461c4ec3ca595354cfa44bf5602527fa1b7e2a66c921670c1e063"

  url "https://github.com/KienHungPG/zMac/releases/download/v#{version}/zMac.dmg"
  name "zMac"
  desc "Window switcher, snapping, clipboard history, notch and more in one menu bar app"
  homepage "https://zmac-website.vercel.app/"

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
