# Có gì mới trong zMac

Trang web hiện cùng nội dung này ở mục [Phiên bản](https://zmac.vercel.app/#changelog)
(dữ liệu ở `website/changelog.json`, sửa cả hai khi ra bản mới).

## 0.3.0

19/11/2026

**Thêm**

- **Tự cập nhật:** từ bản này zMac tự cập nhật được. Bật trong Cài đặt → Giới thiệu; zMac chỉ cài bản có chữ ký đúng
  khoá của zMac. Bản 0.2.0 trở về trước cần cài tay bản này một lần.
- **Trang Giới thiệu:** phiên bản, cập nhật, hướng dẫn cài đặt, mã nguồn, báo lỗi, giấy phép.
- **Ba kiểu `⌥⇥`:** Ảnh xem trước, Biểu tượng app (gọn như `⌘⇥`), Tiêu đề (danh sách). Chỉ kiểu Ảnh xem trước chụp màn hình.
- **`⌥⇥` ở mọi Space:** thấy cả cửa sổ ở Space khác và app toàn màn hình, chọn là sang đúng Space đó.
- **Pin thiết bị:** AirPods, Beats, tai nghe Bluetooth, chuột và bàn phím Logitech, tay cầm chơi game. Pin hiện trên notch
  khi thiết bị kết nối, kèm cảnh báo khi sắp hết.
- **Trình phát trên màn hình khoá** (tắt sẵn): widget gọn hoặc trình phát đầy đủ kèm lời, ngay dưới đồng hồ.
- **Notch hiện app đang phát âm thanh:** họp Meet, Zoom hay video không báo "Đang phát" vẫn có icon app kèm sóng.
- **Chọn lịch:** bật, tắt từng lịch theo tài khoản; thêm lịch Google qua Tài khoản internet của macOS.
- **Hạn mức Claude lấy thẳng từ Anthropic** (tắt sẵn), số cũ hơn 30 phút hiện mờ. Hook Claude Code tự nối lại khi bị cũ
  hay bị xoá.

**Sửa**

- Tab trình duyệt đã dừng giữ chỗ trên notch trong lúc Spotify hay Nhạc đang phát: giờ notch hiện đúng bài đang phát,
  nút phát và chuyển bài tới đúng app. Ảnh bìa Spotify lấy từ mạng nếu bạn bật.
- Tắt tiếng mà HUD âm lượng vẫn hiện mức cũ: giờ hiện 0%.

## 0.2.0

17/11/2026

**Thêm**

- **Claude Code trên notch:** Claude xin quyền chạy lệnh, sửa file thì notch thả xuống một thẻ Cho phép / Luôn cho phép /
  Từ chối. Claude hỏi lại hay xin duyệt kế hoạch thì chọn câu trả lời ngay trên thẻ. Trả lời trong VS Code hay terminal
  thì thẻ tự biến mất. Hạn mức 5 giờ và 7 ngày nằm ở hàng trên của notch.
- **Lời bài hát:** nút Lời trong trình phát, lời chạy theo nhạc, dòng đang hát sáng lên. Lấy từ lrclib.net, tắt sẵn.
- **Lịch:** tuần này và cuộc họp sắp tới ở cột phải của notch, bấm một lần để vào Meet, Zoom, Teams.
- **Thú cưng:** mèo, cún, slime hay gà con pixel ngồi cạnh notch. Cho ăn, vuốt ve, chơi để lên cấp.
- **Âm lượng, độ sáng trên notch** thay HUD của macOS. Phím độ sáng chỉnh cả màn ngoài và TV.
- **Cảnh báo pin yếu** ở 20%, 10% và 5%.
- **Trình phát nhạc trên notch:** nhạc từ mọi trình phát, kể cả YouTube trên trình duyệt. Ảnh bìa lớn kèm icon app đang
  phát, nền theo màu bài, kéo thanh tiến độ để tua.
- **Cài bằng Homebrew:** `brew install --cask kienhungpg/tap/zmac`.
- **Tự cập nhật từ GitHub** (tắt sẵn): chỉ cài bản có chữ ký Ed25519 đúng.
- Giao diện Cài đặt mới.

**Sửa**

- Hạn mức Claude hiện nhầm số của tài khoản cũ ngay sau khi đổi tài khoản.
- Mở Cài đặt làm zMac thoát (dải phím F1–F20 bị đảo).
- Hai HUD ⌥⇥ chồng nhau khi lỡ mở hai bản zMac: giờ chỉ một bản được chạy.
- Sóng nhạc trên notch tốn khoảng 9% CPU suốt lúc nghe nhạc, giờ còn 0,2%.

## 0.1.0

17/11/2026

**Thêm**

- Bản đầu tiên: chuyển cửa sổ (⌥⇥), chia cửa sổ, lịch sử clipboard, độ sáng và độ phân giải màn hình, giới hạn sạc,
  âm lượng từng app, notch với nhạc đang phát và kệ file, giữ máy thức. Một tiến trình, khoảng 20 MB.
