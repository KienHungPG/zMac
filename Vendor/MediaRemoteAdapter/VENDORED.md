# mediaremote-adapter (vendored)

- Nguồn: https://github.com/ungive/mediaremote-adapter
- Phiên bản: v0.7.7, commit `e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6`
- Giấy phép: BSD 3-Clause, xem `LICENSE` (được chép vào app tại `Contents/Resources/MediaRemoteAdapter-LICENSE.txt`).

## Vì sao cần

Từ macOS 15.4, chỉ tiến trình của Apple mới đọc được MediaRemote (bài đang phát, ảnh bìa).
Adapter chạy `/usr/bin/perl` (tiến trình của Apple), cho nó nạp framework này và đẩy thông tin bài đang phát
ra stdout dạng JSON. zMac đọc luồng đó trong `Sources/zMac/Modules/NowPlayingAdapter.swift`.

## Đã giữ lại

`bin/mediaremote-adapter.pl`, `include/`, `src/adapter`, `src/private`, `src/utility`, `LICENSE`,
và riêng header `src/test/NowPlayingTest.h` (`src/adapter/test.m` cần để biên dịch).
Bỏ chương trình thử (phần còn lại của `src/test`), CMake, Makefile, cấu hình editor. Không sửa mã nguồn.
`Info.plist` là của zMac (framework cần Info.plist để ký).

## Build

`build.sh` build bằng clang của Command Line Tools (không cần CMake), cùng cờ với `CMakeLists.txt` gốc:
`-fobjc-arc -fvisibility=default`, link Foundation, AppKit, UniformTypeIdentifiers.
Ra `.build/MediaRemoteAdapter.framework`, rồi chép vào `Contents/Frameworks/` của app.

## Cập nhật

Lấy tag mới từ repo gốc, chép lại đúng các thư mục trên, sửa phiên bản ở đây và trong `Info.plist`,
rồi chạy `.build/debug/zMac --diagnose` để thấy dòng "đang phát (adapter)" vẫn đọc được.
