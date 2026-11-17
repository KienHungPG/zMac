#!/bin/bash
# Cài / gỡ zmac-helper (daemon root giữ ngưỡng sạc). App gọi qua osascript "with administrator privileges".
#   helper-install.sh install <đường dẫn zmac-helper trong zMac.app>
#   helper-install.sh uninstall
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL=com.zmac.helper
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
DATA="/Library/Application Support/zMac"

case "${1:-}" in
install)
    SRC="${2:-}"
    if [ -z "$SRC" ] || [ ! -f "$SRC" ] || [ -L "$SRC" ]; then
        echo "zmac-helper không hợp lệ: $SRC" >&2
        exit 1
    fi
    # Bản cũ nhận SIGTERM thì trả SMC về mặc định; bản mới đọc lại chính sách đã lưu và áp lại.
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    mkdir -p /Library/PrivilegedHelperTools
    install -o root -g wheel -m 755 "$SRC" "$BIN"
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    cat > "$TMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string><string>daemon</string></array>
    <key>MachServices</key>
    <dict><key>$LABEL</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <!-- Background: launchd xếp lịch ưu tiên thấp, chạy trên nhân tiết kiệm điện. -->
    <key>ProcessType</key><string>Background</string>
    <key>StandardErrorPath</key><string>/var/log/zmac-helper.log</string>
</dict>
</plist>
EOF
    install -o root -g wheel -m 644 "$TMP" "$PLIST"
    launchctl bootstrap system "$PLIST"
    echo "SUCCESS"
    ;;
uninstall)
    # bootout gửi SIGTERM: helper cho sạc lại và bật adapter trước khi thoát.
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    if [ -x "$BIN" ]; then "$BIN" restore >/dev/null 2>&1 || true; fi
    rm -f "$BIN" "$PLIST"
    rm -rf "$DATA"
    echo "SUCCESS"
    ;;
*)
    echo "dùng: $0 install <zmac-helper> | uninstall" >&2
    exit 2
    ;;
esac
