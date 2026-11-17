#!/bin/bash
# Chạy MỘT lần: tạo chứng chỉ ký code tự ký "zMac Local Signing" trong login keychain.
# Ký cố định thì macOS nhận diện app theo bundle id + chứng chỉ, không đòi cấp lại quyền
# (Trợ năng, Ghi âm thanh hệ thống) sau mỗi lần build. Daemon pin cũng dùng chứng chỉ này để chỉ nhận lệnh từ zMac.
# Gỡ: mở Keychain Access, xoá "zMac Local Signing" (cả chứng chỉ và khoá).
set -euo pipefail
NAME="zMac Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "Đã có chứng chỉ \"$NAME\""
    exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
PASS=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Đã tạo chứng chỉ \"$NAME\". Chạy lại ./build.sh."
