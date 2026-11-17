# Kiến trúc zMac

## Tiến trình

```
zMac.app (người dùng, menu bar, LSUIElement)
 ├─ Contents/MacOS/zMac          app: mọi module chạy chung một tiến trình
 ├─ Contents/MacOS/zmac-helper   daemon pin, được cài ra /Library/PrivilegedHelperTools
 ├─ Contents/MacOS/zmac-claude-hook   hook PermissionRequest của Claude Code (Claude Code gọi, không phải zMac)
 ├─ Contents/Frameworks/MediaRemoteAdapter.framework   đọc "Đang phát" (Vendor/MediaRemoteAdapter, BSD 3-Clause)
 └─ Contents/Resources/helper-install.sh, mediaremote-adapter.pl

com.zmac.helper (root, launchd, ProcessType=Background)
 └─ XPC Mach service "com.zmac.helper"  <──  zMac (BatteryModule)

/usr/bin/perl mediaremote-adapter.pl … stream   (tiến trình con, chỉ khi module Notch bật)
 └─ JSON qua stdout  ──>  zMac (NowPlayingAdapter)

claude (Claude Code) ── PermissionRequest ──> zmac-claude-hook
 └─ một dòng JSON qua ~/Library/Application Support/zMac/claude.sock (0600)  ──>  zMac (ClaudeModule)
    <── {"behavior":"allow|deny|none", "updatedPermissions"?} khi người dùng bấm trên notch
~/.claude.json (Claude Code tự lưu cachedUsageUtilization)  ──kqueue──>  zMac (ClaudeModule: hạn mức 5h / 7d)
```

Từ macOS 15.4 chỉ tiến trình của Apple đọc được MediaRemote. `/usr/bin/perl` là tiến trình của Apple: nó nạp
framework đi kèm app và đẩy bài đang phát (kèm ảnh bìa) ra stdout mỗi khi có thay đổi. Khoảng 6 MB, 0% CPU khi rảnh.
Adapter không chạy được thì notch lùi về distributed notification của Music / Spotify. Cách build và cập nhật:
`Vendor/MediaRemoteAdapter/VENDORED.md`.

Hook Claude Code: zMac không chạy (không có socket) thì hook thoát 0 ngay (khoảng 10 ms), không in gì, Claude Code
hỏi trong terminal như thường. Hook chỉ in quyết định khi người dùng bấm Cho phép / Từ chối; hết 520 s (dưới timeout
540 s ghi trong settings.json) thì tự thoát. Người dùng trả lời trong terminal thì Claude Code huỷ hook, socket đóng,
thẻ trên notch tự mất. Hook chỉ được ghi vào `~/.claude/settings.json` khi bấm "Kết nối" (sao lưu thành
`settings.json.zmac-backup`), "Gỡ kết nối" chỉ bỏ đúng mục có `zmac-claude-hook`.

Hạn mức 5 giờ / 7 ngày (gói Pro / Max): Claude Code tự gọi API lấy số và lưu ở `cachedUsageUtilization` trong
`~/.claude.json`. zMac chỉ theo dõi file đó bằng `DispatchSource.makeFileSystemObjectSource` (gom các lần ghi sát nhau,
mở lại khi file bị thay), không đọc Keychain, không gọi mạng, chạy với cả bản VS Code (bản này không chạy statusLine,
nên không lấy số từ statusLine được). Số có thể chậm vài chục phút theo nhịp làm mới của Claude Code. Lúc đặt lại
được hẹn đúng một lần bằng `asyncAfter(wallDeadline:)`, không timer lặp. Thử server mà không cần notch:
`ZMAC_CLAUDE_SOCKET=/đường/dẫn.sock .build/debug/zMac --claude-selftest 10` rồi đưa JSON vào `.build/debug/zmac-claude-hook`
với cùng biến môi trường. Thêm `ZMAC_CLAUDE_CONFIG=/file.json` để thử phần theo dõi hạn mức với một file giả.

Chỉ một zMac chạy cùng lúc: `main.swift` giữ `flock` trên `~/Library/Application Support/zMac/zMac.lock` (tự nhả khi
thoát hay crash). Bản mở sau tự thoát trước khi đăng ký phím tắt hay notch. Các cờ dòng lệnh (`--diagnose`,
`--render-ui`…) chạy trước bước này nên vẫn dùng được khi app đang chạy.

Daemon chỉ nhận kết nối từ app có bundle id `com.zmac.app` và ký cùng chứng chỉ với nó
(`setCodeSigningRequirement`). Nếu daemon ký ad-hoc, nó chỉ kiểm bundle id.

Tự cập nhật (`App/Updater.swift`, tắt sẵn): GitHub Releases `releases/latest` → `zMac-X.Y.Z.zip` + `.zip.sig`.
Chữ ký Ed25519 (CryptoKit) trên nguyên file zip, khoá công khai `ZMUpdatePublicKey` trong Info.plist (build.sh lấy từ
`Resources/update-public-key.txt`). Kiểm lúc mở app và khi máy thức dậy, tối đa một lần mỗi ngày. Cài: `ditto -x -k`,
kiểm bundle id + phiên bản, rồi `/bin/sh` chờ PID cũ thoát, đổi app (hỏng thì trả bản cũ) và `open`.
Ký và đóng gói: `scripts/update-sign.swift`, `scripts/make-release.sh` (chỉ in lệnh `gh release create`).

## Target SwiftPM

| Target | Vai trò |
|---|---|
| `CSMC` (C) | Đọc/ghi AppleSMC. Struct 80 byte phải đúng layout nên viết bằng C. |
| `ZMacShared` | `SMC`, `BatteryReader`, `BatteryPolicy`, `HelperStatus`, `ChargeLogic` (hàm thuần), giao thức XPC |
| `zMac` | App |
| `zmac-helper` | Daemon |
| `zmac-claude-hook` | Hook PermissionRequest của Claude Code, chỉ Foundation |
| `zMacTests` | swift-testing: `ChargeLogic`, `SnapGeometry`, `NowPlayingAdapter`, `KeyCombo`, Claude, lời bài hát, thú cưng, cập nhật, phím media, pin yếu, link họp |

## Module

Mỗi module là một class `@MainActor @Observable` theo giao thức `ZModule` (`Sources/zMac/App/Modules.swift`):

- `start()` đăng ký phím tắt, listener, cửa sổ; `stop()` gỡ hết. `ModuleManager` chỉ tạo object khi module bật,
  tắt là `stop()` rồi bỏ tham chiếu.
- `unavailableReason`: lý do phần cứng / hệ điều hành không hợp. Có lý do thì module ẩn và không bao giờ chạy.
- `settingsView()` trả về `Form` (dùng `moduleForm {}`), `quickView()` là phần trong popover menu bar.

| File | Module | Cơ chế chính |
|---|---|---|
| `Switcher.swift` | Chuyển cửa sổ | AX liệt kê song song theo app, z-order từ `CGWindowListCopyWindowInfo`, focus qua SkyLight `_SLPSSetFrontProcessWithOptions` |
| `Snap.swift` | Chia cửa sổ | `SnapGeometry` (hàm thuần) + AX set position/size; kéo ra mép bằng global monitor chuột trái |
| `Clipboard.swift` | Clipboard | Kiểm tra `changeCount` với nhịp thích ứng, panel non-activating nhận phím, dán bằng ⌘V giả lập |
| `Display.swift`, `DisplayDDC.swift` | Màn hình | DisplayServices (màn tích hợp), DDC/CI qua IOAVService, gamma (phần mềm), `CGDisplayCopyAllDisplayModes` |
| `Battery.swift` | Pin | IOPS run loop source, XPC tới daemon |
| `Audio.swift`, `AudioTap.swift` | Âm thanh | CoreAudio listener, process tap + aggregate device riêng tư khi cần |
| `Notch.swift`, `NotchViews.swift`, `NotchNowPlaying.swift`, `NowPlayingAdapter.swift` | Notch | NSPanel trên notch (khung cửa sổ có thể lệch trái, canvas SwiftUI luôn căn giữa notch), NSTrackingArea, mediaremote-adapter (stream JSON, gửi lệnh phát / chuyển bài); lùi về distributed notification Music/Spotify và phím media |
| `MediaKeys.swift` | Notch (âm lượng, độ sáng) | Event tap chỉ NX_SYSDEFINED, nuốt phím âm lượng / độ sáng rồi tự chỉnh (CoreAudio, DisplayServices, module Màn hình) và hiện HUD có thanh mức trên notch; phím có ⌘ ⌃ ⌥ trả cho macOS |
| `Calendar.swift` | Lịch | EventKit, chỉ đọc khi notch mở và cột lịch hiện; `EKEventStoreChanged`, `NSCalendarDayChanged` chỉ đánh dấu cũ lúc notch đóng; link Meet / Zoom / Teams / Webex bằng `MeetingLink` (hàm thuần) |
| `Claude.swift` | Claude Code | Unix socket nghe bằng DispatchSource, mỗi yêu cầu giữ kết nối tới khi bấm; giữ notch mở (`setClaudeAttention`) và hiện thẻ duyệt thay tab nhạc. AskUserQuestion hiện câu hỏi kèm lựa chọn, ExitPlanMode hiện kế hoạch; hai công cụ này phải trả `allow` kèm `updatedInput` (input gốc, thêm `answers` dạng câu hỏi → nhãn, chọn nhiều nối ", "), hook chuyển nguyên trường đó. Hạn mức chỉ hiện khi `cachedUsageUtilization.accountUuid` trùng tài khoản đang đăng nhập |
| `Lyrics.swift` | Notch (nút Lời) | lrclib.net qua URLSession ephemeral, chỉ khi đang xem lời (`.task(id:)`), tối đa 5 yêu cầu mỗi bài, cache trong bộ nhớ 30 bài; đổi dòng bằng `TimelineView(.explicit)` |
| `Pet.swift`, `PetSprites.swift` | Thú cưng | Lưới ký tự 14 cột (vẽ nửa trái, lật gương) vẽ bằng Canvas; chỉ số No / Vui tính từ mốc thời gian, không timer; chỉ chuyển động khi tab mở hoặc vài giây sau sự kiện ở notch |
| `KeepAwake.swift` | Giữ máy thức | IOPMAssertion + một hẹn giờ một lần |

## Nguyên tắc tối ưu (giữ khi sửa code)

1. **Không làm gì khi rảnh.** Không timer lặp, không vòng kiểm tra. Dùng sự kiện: IOKit (`IOPSNotificationCreateRunLoopSource`,
   interest notification), CoreAudio property listener, `NSWorkspace` notification, distributed notification,
   `CGDisplayRegisterReconfigurationCallback`, NSTrackingArea.
   Ngoại lệ duy nhất: clipboard (macOS không có sự kiện), 0,5 s khi có thao tác, 2 s khi rảnh trên 30 s, dừng khi màn hình ngủ,
   leeway 50% để gộp lần đánh thức.
   Tiến trình adapter "Đang phát" là tiến trình riêng duy nhất ngoài daemon pin: cũng theo sự kiện, chỉ chạy khi bật Notch,
   `stop()` dừng nó, app thoát thì `stopAll()` dừng theo.
2. **Không nằm trên đường đi của input.** Phím tắt là Carbon hotkey, không dùng `CGEventTap`. Ngoại lệ duy nhất (người
   dùng đồng ý 2026-11-17): `MediaKeyTap` chỉ đăng ký NX_SYSDEFINED để thay HUD âm lượng / độ sáng, phím chữ và chuột
   không đi qua; không thêm loại sự kiện nào khác vào mask. Global monitor chỉ thụ động,
   và chỉ cài khi cần (đang giữ ⌥ trong ⌥Tab, kéo chuột trái cho chia cửa sổ).
3. **Chỉ làm nặng khi người dùng cần.** Tap âm thanh chỉ khi app khác 100% / tắt tiếng / đổi loa. Thumbnail ⌥Tab mặc định tắt.
   I/O DDC trên hàng đợi nền, chỉ gửi giá trị cuối khi kéo thanh trượt.
4. **View ẩn là view chết.** Popover, Cài đặt, bảng clipboard huỷ `contentView` / `contentViewController` khi đóng.
   Notch gỡ cây view lúc mở khi thu gọn. HUD ⌥Tab giữ panel nhưng xoá dữ liệu.
5. **Theo phần cứng.** `Hardware` dò pin, notch, nhân P/E, macOS; SMC key được dò lúc chạy (`CHTE` / `CH0B`, `CHIE` / `CH0I`).
6. **Không để lại hậu quả khi thoát.** SIGTERM đi qua `applicationWillTerminate`: trả ⌘Tab hệ thống, trả gamma, gỡ tap.
   Daemon nhận SIGTERM thì cho sạc lại và bật adapter.

## Đo đạc

- Trang Cài đặt → Hiệu năng: footprint, CPU, idle wakeups/s của chính zMac (chỉ đo khi trang mở).
- Dòng lệnh: `top -l 4 -s 5 -pid $(pgrep -x zMac) -stats pid,cpu,mem,idlew,th` và `footprint $(pgrep -x zMac)`.
- `zMac --diagnose`: phần cứng, API riêng nạp được, màn hình/DDC, pin/SMC, thiết bị âm thanh, thời gian liệt kê cửa sổ.

## API riêng (nạp bằng `dlsym`, thiếu thì lùi về cách công khai)

| API | Dùng cho | Thiếu thì |
|---|---|---|
| `_AXUIElementGetWindow` | AX element → CGWindowID | không có ⌥Tab |
| `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo` | Focus đúng cửa sổ | `NSRunningApplication.activate()` |
| `SLSSetSymbolicHotKeyEnabled` | Tắt ⌘Tab hệ thống khi thay thế | không thay được ⌘Tab |
| `DisplayServicesGet/SetBrightness` | Độ sáng màn tích hợp | không chỉnh màn tích hợp |
| `IOAVServiceCreateWithService`, `IOAVServiceRead/WriteI2C` | DDC/CI | làm tối bằng gamma |
| `responsibility_get_pid_responsible_for_pid` | Gộp helper process về app | dùng pid gốc |
| MediaRemote, qua mediaremote-adapter trong tiến trình perl | Bài đang phát, ảnh bìa, phát / chuyển bài | Music/Spotify qua distributed notification, phím media |
