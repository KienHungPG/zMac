import AppKit
import ApplicationServices
import Darwin
import Observation
import os
import ZMacShared

// MARK: - Ngôn ngữ

enum Lang: String, CaseIterable {
    case system, vi, en
    static var current: Lang {
        Lang(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "system") ?? .system
    }
    var isVietnamese: Bool {
        switch self {
        case .vi: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("vi") ?? false
        }
    }
}

/// Ngôn ngữ giao diện đang dùng. View SwiftUI gọi L() trong body nên tự vẽ lại khi đổi, không cần mở lại app.
@Observable
final class LangState {
    static let shared = LangState()
    private(set) var isVietnamese = Lang.current.isVietnamese

    #if DEBUG
    /// Chỉ cho `--render-ui`: đổi ngôn ngữ mà không ghi defaults.
    func previewSet(vietnamese: Bool) { isVietnamese = vietnamese }
    #endif

    @MainActor func apply(_ lang: Lang) {
        Pref.set("app.language", lang.rawValue)
        isVietnamese = lang.isVietnamese
        MainMenu.install()   // menu AppKit không tự vẽ lại
    }
}

/// Chuỗi song ngữ.
func L(_ vi: String, _ en: String) -> String { LangState.shared.isVietnamese ? vi : en }

let log = Logger(subsystem: "com.zmac.app", category: "app")

// MARK: - UserDefaults gọn

enum Pref {
    static let d = UserDefaults.standard
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
    static func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
    static func string(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
    static func set(_ k: String, _ v: Any?) {
        #if DEBUG
        if UIPreview.active { return }   // --render-ui không được ghi defaults
        #endif
        d.set(v, forKey: k)
    }

    static func codable<T: Codable>(_ k: String, _ def: T) -> T {
        guard let data = d.data(forKey: k), let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
        return v
    }
    static func setCodable<T: Codable>(_ k: String, _ v: T) {
        #if DEBUG
        if UIPreview.active { return }
        #endif
        d.set(try? JSONEncoder().encode(v), forKey: k)
    }
}

// MARK: - Phần cứng

/// Thông tin máy, dùng để tự ẩn module không hợp (máy không pin, không notch, macOS cũ…).
enum Hardware {
    static let model: String = sysctlString("hw.model") ?? "Mac"
    static let chip: String = sysctlString("machdep.cpu.brand_string") ?? "?"
    static let memoryGB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    static let performanceCores: Int = sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
    static let efficiencyCores: Int = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
    static let hasBattery: Bool = BatteryReader.hasInternalBattery

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Màn hình có notch (MacBook 2021+).
    @MainActor static var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }

    static var supportsProcessTaps: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }
}

// MARK: - Quyền

@MainActor @Observable
final class Permissions {
    static let shared = Permissions()
    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    private var observer: NSObjectProtocol?

    /// macOS phát distributed notification khi danh sách Accessibility đổi: không cần poll.
    func startObserving() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            // Thông báo đến trước khi TCC cập nhật xong.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { Permissions.shared.refresh() }
            }
        }
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(opts)
        if !accessibility { openSettings("Privacy_Accessibility") }
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
        refresh()
    }

    func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - API riêng của macOS (nạp động, thiếu thì tính năng tự lùi về cách công khai)

enum PrivateAPI {
    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    // AX element -> CGWindowID
    typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let axGetWindow = sym(nil, "_AXUIElementGetWindow", AXGetWindowFn.self)

    // Đưa đúng cửa sổ lên trước (cách yabai, MIT).
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    static let getProcessForPID = sym(nil, "GetProcessForPID", GetProcessForPIDFn.self)
    static let setFrontProcess = sym(skyLight, "_SLPSSetFrontProcessWithOptions", SetFrontProcessFn.self)
    static let postEventRecord = sym(skyLight, "SLPSPostEventRecordTo", PostEventRecordFn.self)

    // Bật / tắt phím tắt hệ thống (⌘Tab = 1, ⌘⇧Tab = 2).
    typealias SetSymbolicHotKeyFn = @convention(c) (Int32, Bool) -> CGError
    static let setSymbolicHotKeyEnabled = sym(skyLight, "SLSSetSymbolicHotKeyEnabled", SetSymbolicHotKeyFn.self)
        ?? sym(nil, "CGSSetSymbolicHotKeyEnabled", SetSymbolicHotKeyFn.self)

    // Độ sáng màn hình tích hợp.
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    static let getBrightness = sym(displayServices, "DisplayServicesGetBrightness", GetBrightnessFn.self)
    static let setBrightness = sym(displayServices, "DisplayServicesSetBrightness", SetBrightnessFn.self)

    static func windowID(of el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let f = axGetWindow, f(el, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Kích hoạt app và đưa cửa sổ `wid` lên làm key window, kể cả khi app mình không active (macOS 14+).
    static func focus(pid: pid_t, windowID wid: CGWindowID) -> Bool {
        guard let getPSN = getProcessForPID, let setFront = setFrontProcess, let post = postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        guard setFront(&psn, wid, 0x200) == .success else { return false }   // kCPSUserGenerated
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var w = wid
        withUnsafeBytes(of: &w) { raw in for i in 0..<4 { bytes[0x3c + i] = raw[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
        return true
    }

    // Cửa sổ ở các Space đang không hiện (cách yabai, MIT). AX chỉ trả về cửa sổ của Space đang hiện.
    typealias MainConnectionFn = @convention(c) () -> Int32
    typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopyWindowsWithTagsFn = @convention(c) (Int32, Int32, CFArray, Int32, UnsafeMutablePointer<UInt64>,
                                                      UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
    typealias WindowQueryFn = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    typealias WindowQueryResultFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias IteratorAdvanceFn = @convention(c) (CFTypeRef) -> Bool
    typealias IteratorU64Fn = @convention(c) (CFTypeRef) -> UInt64
    typealias IteratorU32Fn = @convention(c) (CFTypeRef) -> UInt32
    typealias IteratorPIDFn = @convention(c) (CFTypeRef) -> pid_t
    static let mainConnectionID = sym(skyLight, "SLSMainConnectionID", MainConnectionFn.self)
    static let copyManagedDisplaySpaces = sym(skyLight, "SLSCopyManagedDisplaySpaces", CopyDisplaySpacesFn.self)
    static let copyWindowsWithTags = sym(skyLight, "SLSCopyWindowsWithOptionsAndTags", CopyWindowsWithTagsFn.self)
    static let windowQuery = sym(skyLight, "SLSWindowQueryWindows", WindowQueryFn.self)
    static let windowQueryResult = sym(skyLight, "SLSWindowQueryResultCopyWindows", WindowQueryResultFn.self)
    static let iteratorAdvance = sym(skyLight, "SLSWindowIteratorAdvance", IteratorAdvanceFn.self)
    static let iteratorTags = sym(skyLight, "SLSWindowIteratorGetTags", IteratorU64Fn.self)
    static let iteratorAttributes = sym(skyLight, "SLSWindowIteratorGetAttributes", IteratorU32Fn.self)
    static let iteratorParent = sym(skyLight, "SLSWindowIteratorGetParentID", IteratorU32Fn.self)
    static let iteratorWindowID = sym(skyLight, "SLSWindowIteratorGetWindowID", IteratorU32Fn.self)
    static let iteratorPID = sym(skyLight, "SLSWindowIteratorGetPID", IteratorPIDFn.self)

    static var canListOtherSpaces: Bool {
        mainConnectionID != nil && copyManagedDisplaySpaces != nil && copyWindowsWithTags != nil && windowQuery != nil
            && windowQueryResult != nil && iteratorAdvance != nil && iteratorTags != nil && iteratorAttributes != nil
            && iteratorParent != nil && iteratorWindowID != nil && iteratorPID != nil
    }

    /// Space không phải Space đang hiện của màn hình nào (gồm Space toàn màn hình).
    static func hiddenSpaceIDs(_ displays: [[String: Any]]) -> [Int] {
        displays.flatMap { d -> [Int] in
            let current = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            return (d["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["ManagedSpaceID"] as? Int }.filter { $0 != current }
        }
    }

    /// Cửa sổ thật: không có cửa sổ cha (loại thanh công cụ con), đang đặt trong Space (loại cửa sổ phụ đã ẩn).
    static func isUserWindow(parent: UInt32, attributes: UInt32, tags: UInt64) -> Bool {
        parent == 0 && (attributes & 0x2 != 0 || tags & 0x400000000000000 != 0) && tags & 0x1 != 0
    }

    /// Cửa sổ ở các Space đang không hiện, theo pid. nil khi thiếu API (gọi nơi lùi về chỉ Space hiện tại).
    static func windowsOnHiddenSpaces() -> [pid_t: [CGWindowID]]? {
        guard let conn = mainConnectionID, let copySpaces = copyManagedDisplaySpaces, let copyWindows = copyWindowsWithTags,
              let query = windowQuery, let queryResult = windowQueryResult, let advance = iteratorAdvance,
              let tagsOf = iteratorTags, let attributesOf = iteratorAttributes, let parentOf = iteratorParent,
              let idOf = iteratorWindowID, let pidOf = iteratorPID else { return nil }
        let cid = conn()
        guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let spaces = hiddenSpaceIDs(displays)
        guard !spaces.isEmpty else { return [:] }
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        // 0x2: cửa sổ đang đặt trong Space, không gồm cửa sổ thu nhỏ (AX đã trả về những cửa sổ đó).
        guard let list = copyWindows(cid, 0, spaces as CFArray, 0x2, &setTags, &clearTags)?.takeRetainedValue(),
              CFArrayGetCount(list) > 0,
              let q = query(cid, list, Int32(CFArrayGetCount(list)))?.takeRetainedValue(),
              let it = queryResult(q)?.takeRetainedValue() else { return [:] }
        var out: [pid_t: [CGWindowID]] = [:]
        while advance(it) {
            guard isUserWindow(parent: parentOf(it), attributes: attributesOf(it), tags: tagsOf(it)) else { continue }
            out[pidOf(it), default: []].append(idOf(it))
        }
        return out
    }
}

// MARK: - AX tiện ích

enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String, _ type: T.Type = T.self) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success,
              let arr = v as? [AnyObject] else { return [] }
        return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func point(_ el: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success, let v else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success, let v else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Khung cửa sổ theo toạ độ AX (gốc trên-trái màn hình chính).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setPoint(_ el: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }

    static func setSize(_ el: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
    }

    static func setBool(_ el: AXUIElement, _ name: String, _ on: Bool) {
        AXUIElementSetAttributeValue(el, name as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    static func focusedWindow() -> (AXUIElement, pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute) else { return nil }
        return (w, app.processIdentifier)
    }
}

// MARK: - Toạ độ

enum Coords {
    /// Chiều cao màn hình chính (gốc toạ độ Cocoa).
    @MainActor static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cocoa (gốc dưới-trái) <-> AX / CG (gốc trên-trái). Phép đổi đối xứng.
    @MainActor static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    @MainActor static func screen(containing axRect: CGRect) -> NSScreen? {
        let r = flip(axRect)
        let center = CGPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { $0.frame.intersection(r).area < $1.frame.intersection(r).area }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Số liệu tiến trình (chứng minh "nhẹ")

struct ProcessStats {
    var footprintMB: Double
    var cpuSeconds: Double
    var idleWakeups: UInt64
    var threads: Int

    static func current() -> ProcessStats {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        } == 0
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let secs = ticks * Double(tb.numer) / Double(tb.denom) / 1e9
        return ProcessStats(
            footprintMB: ok ? Double(info.ri_phys_footprint) / 1_048_576 : 0,
            cpuSeconds: ok ? secs : 0,
            idleWakeups: ok ? info.ri_pkg_idle_wkups : 0,
            threads: threadCount()
        )
    }

    private static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}

// MARK: - Debounce nhỏ (gom các lần gọi dồn dập, vd kéo thanh trượt)

@MainActor
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    init(_ delay: TimeInterval) { self.delay = delay }
    func call(_ f: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: f)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    func cancel() { work?.cancel(); work = nil }
}
