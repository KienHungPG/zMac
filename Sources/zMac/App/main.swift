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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
