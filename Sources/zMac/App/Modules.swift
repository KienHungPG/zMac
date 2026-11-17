import AppKit
import Observation
import SwiftUI
import ZMacShared

/// Một tính năng của zMac. Module chỉ được khởi tạo khi bật; tắt là gỡ hết (phím tắt, listener, cửa sổ)
/// và giải phóng object, nên module tắt không tốn RAM / CPU.
@MainActor
protocol ZModule: AnyObject {
    static var id: String { get }
    static var name: String { get }
    /// App mà module thay thế, hiện trong Cài đặt.
    static var replaces: String { get }
    static var symbol: String { get }
    static var summary: String { get }
    static var defaultEnabled: Bool { get }
    /// nil = máy hỗ trợ. Có giá trị = lý do module bị ẩn trên máy này.
    static var unavailableReason: String? { get }

    init()
    func start()
    func stop()
    func settingsView() -> AnyView
    /// Phần hiện trong bảng menu bar (nil = không có).
    func quickView() -> AnyView?
}

extension ZModule {
    static var defaultEnabled: Bool { true }
    static var unavailableReason: String? { nil }
    func quickView() -> AnyView? { nil }
}

@MainActor @Observable
final class ModuleManager {
    static let shared = ModuleManager()

    /// Thứ tự hiện trong Cài đặt và bảng menu bar.
    let types: [any ZModule.Type] = [
        SwitcherModule.self,
        SnapModule.self,
        ClipboardModule.self,
        DisplayModule.self,
        BatteryModule.self,
        AudioModule.self,
        NotchModule.self,
        KeepAwakeModule.self,
    ]

    private(set) var running: [String: any ZModule] = [:]

    func isEnabled(_ t: any ZModule.Type) -> Bool {
        t.unavailableReason == nil && Pref.bool("module.\(t.id)", t.defaultEnabled)
    }

    func setEnabled(_ t: any ZModule.Type, _ on: Bool) {
        Pref.set("module.\(t.id)", on)
        on ? start(t) : stop(t)
    }

    func startEnabled() {
        for t in types where isEnabled(t) { start(t) }
    }

    func stopAll() {
        for t in types.reversed() { stop(t) }
    }

    func module<T: ZModule>(_ t: T.Type) -> T? { running[t.id] as? T }

    /// Tên app gốc mà module thay thế. Chạy song song sẽ trùng phím tắt / trùng panel notch.
    static let conflicts: [String: [String]] = [
        "switcher": ["AltTab", "HyperMac"],
        "snap": ["Rectangle", "Rectangle Pro", "Magnet", "HyperMac"],
        "clipboard": ["Maccy", "HyperMac"],
        "display": ["BetterDisplay", "MonitorControl", "HyperMac"],
        "battery": ["AlDente", "HyperMac"],
        "audio": ["FineTune", "SoundSource"],
        "notch": ["NotchNook", "Notch", "Alcove", "boring.notch"],
    ]

    /// App xung đột đang chạy (đọc khi mở trang Cài đặt, không theo dõi nền).
    func runningConflicts(_ id: String) -> [NSRunningApplication] {
        guard let names = Self.conflicts[id] else { return [] }
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let n = app.localizedName, app.processIdentifier != getpid() else { return false }
            return names.contains(n)
        }
    }

    private func start(_ t: any ZModule.Type) {
        guard running[t.id] == nil, t.unavailableReason == nil else { return }
        let m = t.init()
        running[t.id] = m
        m.start()
        log.info("bật module \(t.id, privacy: .public)")
    }

    private func stop(_ t: any ZModule.Type) {
        guard let m = running.removeValue(forKey: t.id) else { return }
        m.stop()
        log.info("tắt module \(t.id, privacy: .public)")
    }
}

// MARK: - Chẩn đoán dòng lệnh: zMac --diagnose

@MainActor
enum Diagnostics {
    static func run() {
        func line(_ s: String) { print(s) }
        line("zMac diagnose")
        line("  máy: \(Hardware.model), \(Hardware.chip), \(Hardware.memoryGB) GB, \(Hardware.performanceCores)P+\(Hardware.efficiencyCores)E")
        line("  macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        line("  pin trong: \(Hardware.hasBattery), notch: \(Hardware.notchScreen != nil), process tap: \(Hardware.supportsProcessTaps)")
        line("  quyền: accessibility=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess())")
        line("  API riêng: axGetWindow=\(PrivateAPI.axGetWindow != nil) setFront=\(PrivateAPI.setFrontProcess != nil) " +
             "postEvent=\(PrivateAPI.postEventRecord != nil) symbolicHotKey=\(PrivateAPI.setSymbolicHotKeyEnabled != nil) " +
             "brightness=\(PrivateAPI.getBrightness != nil)")
        line("  module:")
        for t in ModuleManager.shared.types {
            line("    \(t.id): \(t.unavailableReason.map { "không hỗ trợ (\($0))" } ?? "hỗ trợ")")
        }
        for extra in diagnosticHooks { extra() }
        let s = ProcessStats.current()
        line(String(format: "  tiến trình: %.1f MB, %d luồng", s.footprintMB, s.threads))
    }

    /// Module đăng ký thêm thông tin chẩn đoán ở đây (pin, màn hình, âm thanh).
    static var diagnosticHooks: [@MainActor () -> Void] {
        [SwitcherModule.diagnose, DisplayModule.diagnose, BatteryModule.diagnose, AudioModule.diagnose]
    }
}
