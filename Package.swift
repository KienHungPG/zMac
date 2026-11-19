// swift-tools-version:5.10
import PackageDescription

// zMac: một app menu bar thay cho AltTab, Maccy, BetterDisplay, AlDente, NotchNook, Rectangle, FineTune.
// Build bằng Command Line Tools (không cần Xcode). Xem build.sh và docs/ARCHITECTURE.md.
let package = Package(
    name: "zMac",
    platforms: [.macOS(.v14)],
    targets: [
        // C: SMC (cấu trúc phải đúng layout của AppleSMC), dùng chung cho app và helper.
        .target(name: "CSMC", path: "Sources/CSMC"),
        // Giao thức XPC + kiểu dữ liệu dùng chung app <-> helper.
        .target(name: "ZMacShared", dependencies: ["CSMC"], path: "Sources/ZMacShared"),
        // App menu bar.
        .executableTarget(
            name: "zMac",
            dependencies: ["ZMacShared"],
            path: "Sources/zMac",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("GameController"),
            ]
        ),
        // Daemon root nhỏ: giữ ngưỡng sạc kể cả khi app không chạy. Chạy theo sự kiện, không timer.
        .executableTarget(
            name: "zmac-helper",
            dependencies: ["ZMacShared"],
            path: "Sources/zmac-helper",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Hook PermissionRequest của Claude Code: chuyển yêu cầu sang notch qua Unix socket. Chỉ Foundation.
        .executableTarget(name: "zmac-claude-hook", path: "Sources/zmac-claude-hook"),
        // swift-testing. Chỉ có Command Line Tools thì chạy bằng scripts/test.sh (thêm đường dẫn Testing.framework).
        .testTarget(name: "zMacTests", dependencies: ["zMac", "ZMacShared"], path: "Tests/zMacTests"),
    ]
)
