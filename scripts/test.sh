#!/bin/bash
# Chạy test (swift-testing). Command Line Tools có Testing.framework nhưng không nằm trong đường tìm mặc định,
# và module chạy test do SwiftPM tự sinh chỉ nhận cờ từ dòng lệnh, nên phải truyền ở đây.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
# CLT mới để lib_TestingInterop.dylib ở usr/lib, ngoài thư mục Frameworks.
U=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [ -d "$F/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
    exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" \
        -Xlinker -rpath -Xlinker "$U" "$@"
fi
exec swift test "$@"
