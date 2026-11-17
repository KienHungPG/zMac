# Trang tải zMac

Trang tĩnh (HTML, CSS, JS thuần), deploy lên Vercel. Không framework, không bước build, không tải gì từ bên ngoài.

| File | Vai trò |
|---|---|
| `index.html` | Nội dung. Tiếng Việt viết thẳng trong HTML, tiếng Anh nằm trong `data-en` (nội dung) và `data-en-label` / `data-en-content` (thuộc tính). |
| `style.css` | Giao diện, có chế độ tối theo hệ thống. Màu lấy từ icon app. |
| `main.js` | Đổi ngôn ngữ, đọc `download/latest.json`, demo chia cửa sổ, nút chép. |
| `download/zMac.dmg`, `download/latest.json` | Do `scripts/make-dmg.sh` sinh ra. Đừng sửa tay. |
| `vercel.json` | Header: `.dmg` tải về đúng kiểu, vài header bảo mật. |

## Ra bản mới

```bash
# 1. Tăng CFBundleShortVersionString (và CFBundleVersion) trong Resources/Info.plist
# 2. Build + đóng gói DMG, cập nhật latest.json (trang tự hiện phiên bản, dung lượng, SHA-256)
./scripts/make-dmg.sh
# 3. Deploy
cd website && npx vercel --prod
```

## Xem thử trên máy

```bash
python3 -m http.server 8787 --directory website   # rồi mở http://localhost:8787
```

Mở thẳng `index.html` bằng `file://` thì thông tin bản tải không hiện (trình duyệt chặn `fetch` file cục bộ).

## Deploy lần đầu

Cách 1, Vercel CLI (không cần Git):

```bash
cd website              # quan trọng: chạy trong website/, nếu không sẽ tải cả .build lên
npx vercel login
npx vercel              # bản xem trước; lần đầu hỏi tên dự án, cứ để mặc định
npx vercel --prod       # bản chính thức, ra địa chỉ <tên-dự-án>.vercel.app
```

Cách 2, nối GitHub: đẩy repo lên GitHub, vào vercel.com → Add New → Project → Import repo,
đặt **Root Directory** = `website`, Framework Preset = Other, không có Build Command. Mỗi lần push nhánh chính là tự deploy.
Cách này cần commit cả `website/download/zMac.dmg` vào repo.
