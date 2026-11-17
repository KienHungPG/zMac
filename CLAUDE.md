# CLAUDE.md

zMac: app menu bar macOS gộp AltTab, Rectangle, Maccy, BetterDisplay, AlDente, FineTune, NotchNook. Mục tiêu số một là nhẹ.
Đọc `docs/ARCHITECTURE.md` trước khi sửa.

## Build

- Chỉ có Command Line Tools (không Xcode). `swift build` để kiểm tra biên dịch; `./build.sh` đóng gói `build/zMac.app`;
  `./build.sh run` / `install` để chạy thử.
- Test: `./scripts/test.sh` (swift-testing; cần cờ dòng lệnh vì CLT không đặt Testing.framework trong đường tìm mặc định).
- `.build/debug/zMac --diagnose` in thông tin phần cứng và trạng thái từng module mà không mở giao diện.
- Build phải sạch cảnh báo.
- Trang tải: `website/` (tĩnh, deploy Vercel). `./scripts/make-dmg.sh` đóng gói `website/download/zMac.dmg` + `latest.json`.
  Xem `website/README.md`.
- `Vendor/MediaRemoteAdapter` (BSD 3-Clause, mã của người khác, không sửa) được `build.sh` build bằng clang để Notch
  đọc nhạc đang phát. Cập nhật theo `Vendor/MediaRemoteAdapter/VENDORED.md`.

## Quy tắc

- Chuỗi giao diện song ngữ qua `L("tiếng Việt", "English")`, viết tự nhiên. Comment ngắn bằng tiếng Việt.
- Module mới: class `@MainActor @Observable` theo `ZModule`, thêm vào `ModuleManager.types`. `stop()` phải gỡ mọi thứ `start()` tạo.
- Không timer lặp, không poll, không `CGEventTap`. Dùng sự kiện hệ thống. Xem 6 nguyên tắc trong `docs/ARCHITECTURE.md`.
- View ẩn phải bị huỷ (đặt `contentView` / `contentViewController` = nil khi đóng).
- API riêng nạp bằng `PrivateAPI.sym` (dlsym) và luôn có đường lùi.
- Logic chạy bằng root (`ChargeLogic`) phải có test; đổi giao thức helper thì tăng `HelperConstants.version`.

## Không tự làm khi chưa hỏi

- Cài / gỡ daemon (`helper-install.sh`), ghi SMC, chạy `scripts/make-signing-cert.sh` (đụng keychain).
- Commit, push, tạo release.
- Nếu chạy thử app: ghi lại `defaults read com.zmac.app` và `~/Library/Application Support/zMac` trước, dọn những gì lần chạy thử tạo ra sau.
