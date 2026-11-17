#!/bin/bash
# ./build.sh            build release, đóng gói build/zMac.app
# ./build.sh run        build rồi mở build/zMac.app
# ./build.sh install    build, cài /Applications/zMac.app rồi mở
#
# Biến môi trường:
#   ZMAC_SIGN_IDENTITY   tên chứng chỉ ký (mặc định "zMac Local Signing", tạo bằng scripts/make-signing-cert.sh)
#   ZMAC_UNIVERSAL=1     build cả arm64 và x86_64 (mặc định chỉ build cho chip của máy đang dùng)
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${ZMAC_SIGN_IDENTITY:-zMac Local Signing}"
if [ "${ZMAC_UNIVERSAL:-0}" = 1 ]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=(--arch "$(uname -m)")
fi

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

# mediaremote-adapter (Vendor/MediaRemoteAdapter, BSD 3-Clause): đọc "Đang phát" từ macOS 15.4.
# /usr/bin/perl nạp framework này, xem NowPlayingAdapter.swift. Chỉ build lại khi mã nguồn hoặc kiến trúc đổi.
MRA=Vendor/MediaRemoteAdapter
MRA_FW=.build/MediaRemoteAdapter.framework
MRA_BIN="$MRA_FW/Versions/A/MediaRemoteAdapter"
CLANG_ARCHS=()
for a in "${ARCHS[@]}"; do [ "$a" = --arch ] || CLANG_ARCHS+=(-arch "$a"); done
WANT_ARCHS="$(printf '%s\n' "${CLANG_ARCHS[@]}" | grep -v '^-arch$' | sort | tr '\n' ' ')"
HAVE_ARCHS="$( { lipo -archs "$MRA_BIN" 2>/dev/null || true; } | tr ' ' '\n' | { grep . || true; } | sort | tr '\n' ' ')"
if [ ! -f "$MRA_BIN" ] || [ "$WANT_ARCHS" != "$HAVE_ARCHS" ] || [ -n "$(find "$MRA" -newer "$MRA_BIN" -type f | head -1)" ]; then
    rm -rf "$MRA_FW"
    mkdir -p "$MRA_FW/Versions/A/Resources"
    clang -fobjc-arc -fvisibility=default -dynamiclib -Os "${CLANG_ARCHS[@]}" -mmacosx-version-min=14.0 \
        -I"$MRA/include" -I"$MRA/src" "$MRA"/src/adapter/*.m "$MRA"/src/private/*.m "$MRA"/src/utility/*.m \
        -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
        -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter -o "$MRA_BIN"
    strip -x "$MRA_BIN"
    cp "$MRA/Info.plist" "$MRA_FW/Versions/A/Resources/Info.plist"
    ln -s A "$MRA_FW/Versions/Current"
    ln -s Versions/Current/MediaRemoteAdapter "$MRA_FW/MediaRemoteAdapter"
    ln -s Versions/Current/Resources "$MRA_FW/Resources"
fi

APP=build/zMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/zMac" "$APP/Contents/MacOS/zMac"
cp "$BIN/zmac-helper" "$APP/Contents/MacOS/zmac-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/helper-install.sh "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
cp -R "$MRA_FW" "$APP/Contents/Frameworks/"
cp "$MRA/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$MRA/LICENSE" "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
# Bỏ ký hiệu cục bộ: binary nhỏ hơn, nạp nhanh hơn.
strip -x "$APP/Contents/MacOS/zMac" "$APP/Contents/MacOS/zmac-helper"

# Ký bằng chứng chỉ cố định để macOS giữ quyền (Trợ năng, Ghi âm thanh) qua các lần build.
# Không có chứng chỉ thì ký ad-hoc: chạy được nhưng mỗi lần build lại phải cấp quyền.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    SIGN="$IDENTITY"
else
    SIGN="-"
    echo "⚠️  Chưa có chứng chỉ \"$IDENTITY\", ký ad-hoc. Chạy scripts/make-signing-cert.sh một lần để giữ quyền qua các lần build."
fi
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "$SIGN" --identifier com.zmac.helper "$APP/Contents/MacOS/zmac-helper"
codesign --force --sign "$SIGN" "$APP"
echo "→ $APP (ký: $SIGN, $(du -sh "$APP" | cut -f1 | tr -d ' '))"

stop_running() {
    pkill -x zMac || true
    for _ in $(seq 30); do pgrep -x zMac >/dev/null || break; sleep 0.1; done
}

case "${1:-}" in
run)
    stop_running
    open "$APP"
    ;;
install)
    stop_running
    rm -rf /Applications/zMac.app
    cp -R "$APP" /Applications/zMac.app
    echo "→ đã cài /Applications/zMac.app"
    open /Applications/zMac.app
    ;;
esac
