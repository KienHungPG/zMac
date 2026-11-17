# zMac

Một app menu bar cho macOS gộp 7 app thành một, viết để nhẹ nhất có thể. Miễn phí, mã nguồn mở (MIT).

| Module | Thay cho | Làm gì |
|---|---|---|
| Chuyển cửa sổ | AltTab | ⌥Tab duyệt từng cửa sổ, ⌥\` cửa sổ của app hiện tại, tuỳ chọn thay ⌘Tab |
| Chia cửa sổ | Rectangle | ⌃⌥ + phím: nửa, góc, phần ba, phóng to, căn giữa, chuyển màn hình; kéo ra mép để xếp |
| Lịch sử clipboard | Maccy | ⌘⇧C mở lịch sử, tìm, ghim, dán; bỏ qua mật khẩu |
| Màn hình | BetterDisplay | Độ sáng màn ngoài (DDC hoặc làm tối bằng phần mềm), độ phân giải, HiDPI |
| Pin | AlDente | Giới hạn sạc, sailing, chống nóng, xả về ngưỡng, sạc đầy một lần |
| Âm thanh | FineTune | Âm lượng và loa riêng từng app, đổi thiết bị vào ra |
| Notch | NotchNook | Nhạc đang phát (mọi trình phát, kể cả trình duyệt, có ảnh bìa), kệ file, báo pin khi cắm sạc |
| Giữ máy thức | Amphetamine | Không cho máy ngủ trong khoảng thời gian chọn |

## Nhẹ đến đâu

Đo trên MacBook Air M4 (macOS 26.5), bật cả 8 module, máy đang rảnh:

| | zMac |
|---|---|
| Bộ nhớ (footprint), chỉ có icon menu bar | 16 đến 20 MB |
| Bộ nhớ khi mở cửa sổ Cài đặt | khoảng 39 MB |
| CPU khi rảnh | 0,0% (thỉnh thoảng một mẫu 1 đến 2%) |
| Kích thước app | 2,3 MB (app + daemon + adapter đọc nhạc) |
| Liệt kê cửa sổ cho ⌥Tab | 4,4 ms cho 11 cửa sổ từ 9 app |
| Tiến trình đọc nhạc đang phát (khi bật Notch) | khoảng 6 MB, 0% CPU |

Cùng máy, cùng lúc, các app gốc đang chạy: AltTab 307 MB, Maccy 295 MB, NotchNook 50 MB.
So sánh này chưa hoàn toàn ngang nhau: AltTab giữ ảnh chụp cửa sổ, Maccy giữ lịch sử của bạn, còn lịch sử của zMac lúc đo đang rỗng.

Vì sao nhẹ (chi tiết ở [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- Một tiến trình thay cho 7: dùng chung runtime Swift, AppKit, SwiftUI.
- Module tắt thì không được tạo. Module không hợp máy thì tự ẩn: Mac không pin không có khoá sạc, macOS dưới 14.2 không có âm lượng từng app.
- Phím tắt dùng Carbon hotkey, không dùng CGEventTap, nên phím bạn gõ không đi qua zMac.
- Chạy theo sự kiện (IOKit, CoreAudio, NSWorkspace, distributed notification). Chỉ clipboard phải kiểm tra định kỳ, và nhịp kiểm tra tự giãn khi máy rảnh.
- Âm lượng từng app chỉ tạo tap âm thanh khi app đó khác 100%.
- Notch lúc thu gọn chỉ có một tracking area: không theo dõi chuột toàn cục, không timer.
- Nhạc đang phát do một tiến trình nhỏ riêng đẩy sang khi có thay đổi, chỉ chạy khi bật Notch.
- Khoá sạc chạy trong daemon root rất nhỏ (`ProcessType=Background`), chỉ thức dậy khi pin đổi.
- Cửa sổ, popover, bảng huỷ view khi đóng.
- Build riêng cho chip của máy (arm64), strip ký hiệu.

## Build và cài

Chỉ cần Command Line Tools (`xcode-select --install`), không cần Xcode.

```bash
./scripts/make-signing-cert.sh   # một lần: chứng chỉ ký cố định, để macOS giữ quyền qua các lần build
./build.sh                       # build release, đóng gói build/zMac.app
./build.sh run                   # build rồi mở
./build.sh install               # build, cài /Applications/zMac.app rồi mở
./scripts/test.sh                # chạy test (swift-testing)
.build/debug/zMac --diagnose     # in thông tin phần cứng, màn hình, pin, âm thanh, cửa sổ
```

Không có chứng chỉ thì `build.sh` ký ad-hoc. App vẫn chạy được, nhưng sau mỗi lần build macOS sẽ coi là app mới và bắt cấp lại quyền.

## Quyền cần cấp

| Quyền | Dùng cho | Bắt buộc |
|---|---|---|
| Trợ năng (Accessibility) | Chuyển cửa sổ, chia cửa sổ, dán từ clipboard, nút phát nhạc | Có, cho các tính năng đó |
| Ghi âm thanh hệ thống | Âm lượng từng app (macOS hỏi lần đầu bạn chỉnh) | Chỉ khi dùng |
| Ghi màn hình | Ảnh xem trước trong ⌥Tab (mặc định tắt) | Không |
| Mật khẩu admin (một lần) | Cài daemon khoá sạc | Chỉ khi dùng giới hạn sạc |

## Khoá sạc

Cài trong Cài đặt → Pin → "Cài". Daemon `com.zmac.helper` nằm ở `/Library/PrivilegedHelperTools`, launchd giữ nó chạy.
Trên máy này nó dùng key SMC `CHTE` (chặn sạc) và `CHIE` (ngắt adapter để xả). M1 đời đầu dùng `CH0B`/`CH0C`.
Bấm "Gỡ" là daemon trả SMC về mặc định rồi tự xoá. Nếu cần gỡ tay:

```bash
sudo launchctl bootout system/com.zmac.helper
sudo /Library/PrivilegedHelperTools/com.zmac.helper restore
sudo rm -f /Library/PrivilegedHelperTools/com.zmac.helper /Library/LaunchDaemons/com.zmac.helper.plist
```

## Dữ liệu lưu ở đâu

- Cài đặt: `defaults read com.zmac.app`
- Lịch sử clipboard: `~/Library/Application Support/zMac/Clipboard/` (`history.json` và ảnh PNG)
- Chính sách sạc: `/Library/Application Support/zMac/battery-policy.json` (daemon ghi)

## Hạn chế đã biết

- Nhạc đang phát: từ macOS 15.4 app bên thứ ba không gọi thẳng MediaRemote được, nên Notch đọc qua mediaremote-adapter (chạy `/usr/bin/perl`). Nếu bản macOS sau chặn cả cách này, Notch lùi về Music và Spotify, không có ảnh bìa.
- ⌥Tab chỉ thấy cửa sổ ở Space hiện tại, cộng cửa sổ thu nhỏ và app đang ẩn.
- Màn hình ảo / mở khoá HiDPI cho màn 1440p (như BetterDisplay) chưa có.
- Âm lượng tổng cho loa HDMI (không có âm lượng phần cứng) chưa có.
- EQ từng app (FineTune) chưa có.
- Chưa có tự cập nhật.

## Tham khảo

- [HyperMac](https://github.com/mrgoose000000-gif/HyperMac) (GPL-3.0): tham khảo cách dùng các key SMC, không chép code.
- yabai (MIT): cách đưa đúng một cửa sổ lên trước bằng SkyLight.
- MonitorControl (MIT): định dạng gói DDC/CI trên Apple Silicon.
- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD 3-Clause): dùng nguyên mã để đọc nhạc đang phát, nhúng ở `Vendor/MediaRemoteAdapter`.

## Giấy phép

MIT, xem [LICENSE](LICENSE). Miễn phí; ai cũng được dùng, sửa và phân phối lại, chỉ cần giữ dòng bản quyền.
