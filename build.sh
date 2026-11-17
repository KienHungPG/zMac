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

APP=build/zMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/zMac" "$APP/Contents/MacOS/zMac"
cp "$BIN/zmac-helper" "$APP/Contents/MacOS/zmac-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/helper-install.sh "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
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
