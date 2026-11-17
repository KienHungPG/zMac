import AppKit

// zMac: app menu bar. Mỗi tính năng là một module (Modules.swift), chỉ module đang bật mới được tạo.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.shared.startObserving()
        ModuleManager.shared.startEnabled()
        statusBar = StatusBarController()
        Updater.shared.start()   // chỉ kiểm tra nếu người dùng đã bật

        // SIGTERM / SIGINT (pkill, build.sh) vẫn đi qua applicationWillTerminate để module dọn dẹp
        // (trả ⌘Tab hệ thống, trả gamma màn hình, gỡ tap âm thanh).
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }

        if !UserDefaults.standard.bool(forKey: "app.onboarded") {
            UserDefaults.standard.set(true, forKey: "app.onboarded")
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ModuleManager.shared.stopAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }
}

if CommandLine.arguments.contains("--diagnose") {
    MainActor.assumeIsolated { Diagnostics.run() }
    exit(0)
}

#if DEBUG
// Chỉ bản debug: vẽ giao diện ra PNG để xem khi sửa (UIPreview.swift).
if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated { UIPreview.run(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
// Chỉ bản debug: đo CPU của một hoạt hình (UIPreview.swift). zMac --bench-anim waveform|pet|none GIÂY
if let i = CommandLine.arguments.firstIndex(of: "--bench-anim"), CommandLine.arguments.count > i + 2 {
    MainActor.assumeIsolated {
        UIPreview.benchAnimation(CommandLine.arguments[i + 1], seconds: Double(CommandLine.arguments[i + 2]) ?? 8)
    }
    exit(0)
}
// Chỉ bản debug: tìm lời một bài trên lrclib.net (Lyrics.swift). zMac --lyrics "Tên bài" "Ca sĩ" [album] [giây]
if let i = CommandLine.arguments.firstIndex(of: "--lyrics"), CommandLine.arguments.count > i + 2 {
    let a = CommandLine.arguments
    let q = LyricsStore.Query(title: a[i + 1], artist: a[i + 2], album: a.count > i + 3 ? a[i + 3] : "",
                              duration: a.count > i + 4 ? Double(a[i + 4]) : nil)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        switch try? await LyricsStore.fetch(q) {
        case .synced(let lines)?: print("có mốc thời gian, \(lines.count) dòng:"); lines.prefix(4).forEach { print("  \($0.time)s \($0.text)") }
        case .plain(let t)?: print("không mốc thời gian:", t.prefix(120))
        case .instrumental?: print("bài không lời")
        case nil: print("không tìm thấy (hoặc lỗi mạng)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}
// Chỉ bản debug: thử server socket của Claude Code với hook thật (Claude.swift).
if let i = CommandLine.arguments.firstIndex(of: "--claude-selftest") {
    let seconds = CommandLine.arguments.count > i + 1 ? Double(CommandLine.arguments[i + 1]) ?? 10 : 10
    MainActor.assumeIsolated { ClaudeModule.selfTest(seconds: seconds) }
    exit(0)
}
#endif

// Chỉ một zMac chạy cùng lúc (vd bản trong build/ và bản trong /Applications): hai bản sẽ trùng phím tắt,
// hai notch, hai HUD ⌥⇥. flock tự nhả khi tiến trình thoát, kể cả khi crash.
let instanceLock: Int32 = {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/zMac")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return open((dir as NSString).appendingPathComponent("zMac.lock"), O_CREAT | O_RDWR, 0o600)
}()
if instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
    log.notice("zMac đã chạy (pid khác giữ khoá), bản này thoát")
    print("zMac đang chạy rồi, bản này thoát.")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
