import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit
import SwiftUI

// Chuyển cửa sổ kiểu AltTab.
// - Liệt kê cửa sổ bằng AX song song theo app (DispatchQueue.concurrentPerform), thứ tự theo z-order thật.
// - Bấm nhanh (nhả phím trước 60 ms) thì chuyển luôn, không vẽ HUD.
// - HUD dùng lại một panel; khi ẩn thì xoá dữ liệu để cây view gần như rỗng.
// - Ba kiểu HUD (`SwitcherStyle`): ảnh xem trước, biểu tượng app, tiêu đề. Chỉ kiểu ảnh xem trước chụp màn hình:
//   ScreenCaptureKit chụp nền sau khi HUD đã hiện.
// - Space khác: AX không trả về, danh sách lấy từ WindowServer. Phần tử AX nhớ từ lần liệt kê trước
//   (lúc cửa sổ còn ở Space đang hiện) để có tiêu đề và dùng W / M; chưa gặp thì không có phần tử.

struct SwitcherItem: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement?
    let title: String
    let appName: String
    let icon: NSImage?
    let isMinimized: Bool
    let isHidden: Bool
}

/// Ba kiểu HUD: lưới ảnh xem trước, hàng biểu tượng app (chỉ ô đang chọn có tiêu đề), danh sách tiêu đề.
enum SwitcherStyle: String, CaseIterable, Identifiable {
    case thumbnails, icons, titles

    var id: String { rawValue }

    var name: String {
        switch self {
        case .thumbnails: L("Ảnh xem trước", "Thumbnails")
        case .icons: L("Biểu tượng app", "App Icons")
        case .titles: L("Tiêu đề", "Titles")
        }
    }

    var detail: String {
        switch self {
        case .thumbnails: L("Thấy nội dung cửa sổ", "See what's in each window")
        case .icons: L("Gọn như ⌘⇥ của macOS", "Compact, like macOS ⌘⇥")
        case .titles: L("Danh sách dễ đọc", "An easy-to-read list")
        }
    }

    /// Chưa chọn kiểu nào: người đã bật công tắc "Ảnh xem trước" cũ giữ ảnh xem trước, còn lại dùng biểu tượng.
    static func initial(stored: String?, legacyThumbnails: Bool) -> SwitcherStyle {
        if let stored, let s = SwitcherStyle(rawValue: stored) { return s }
        return legacyThumbnails ? .thumbnails : .icons
    }

    /// Bề rộng một ô trong HUD.
    var cellWidth: CGFloat {
        switch self {
        case .thumbnails: 220
        case .icons: 92
        case .titles: 380
        }
    }

    /// Chiều cao một dòng của kiểu Tiêu đề.
    static let rowHeight: CGFloat = 32

    var hSpacing: CGFloat { self == .icons ? 6 : 10 }
    var vSpacing: CGFloat { self == .titles ? 3 : 10 }
    /// Lề trong của HUD.
    var inset: CGFloat { self == .titles ? 10 : 16 }

    /// Số cột cho `count` cửa sổ trong vùng `area`. Lưới lấp theo chiều ngang;
    /// danh sách tiêu đề một cột, chỉ thêm cột khi dài quá chiều cao màn hình.
    func columns(count: Int, area: CGSize) -> Int {
        guard count > 0 else { return 1 }
        let fitW = max(1, Int((area.width - 2 * inset + hSpacing) / (cellWidth + hSpacing)))
        guard self == .titles else { return min(count, fitW) }
        let fitH = max(1, Int((area.height - 2 * inset + vSpacing) / (Self.rowHeight + vSpacing)))
        return min(fitW, (count + fitH - 1) / fitH)
    }
}

@MainActor @Observable
final class SwitcherState {
    var items: [SwitcherItem] = []
    var selected = 0
    var thumbnails: [CGWindowID: NSImage] = [:]
    var style: SwitcherStyle = .icons
    var columns = 6
}

@MainActor @Observable
final class SwitcherModule: ZModule {
    static let id = "switcher"
    static var name: String { L("Chuyển cửa sổ", "Window Switcher") }
    static let replaces = "AltTab"
    static let symbol = "rectangle.on.rectangle"
    static var summary: String {
        L("Chuyển giữa từng cửa sổ (không chỉ từng app) bằng ⌥Tab, có thể thay luôn ⌘Tab.",
          "Switch between individual windows (not just apps) with ⌥Tab, optionally replacing ⌘Tab.")
    }

    static let defaultNext = KeyCombo(kVK_Tab, KeyCombo.opt)
    static let defaultAppWindows = KeyCombo(kVK_ANSI_Grave, KeyCombo.opt)

    var replaceCmdTab = Pref.bool("switcher.cmdTab", false) {
        didSet { Pref.set("switcher.cmdTab", replaceCmdTab); registerHotkeys() }
    }
    var style = SwitcherStyle.initial(stored: Pref.d.string(forKey: "switcher.style"),
                                      legacyThumbnails: Pref.bool("switcher.thumbnails", false)) {
        didSet {
            Pref.set("switcher.style", style.rawValue)
            if style != .thumbnails { thumbCache = [:] }   // không dùng nữa thì bỏ ảnh khỏi bộ nhớ
        }
    }
    var includeMinimized = Pref.bool("switcher.minimized", true) {
        didSet { Pref.set("switcher.minimized", includeMinimized) }
    }
    var includeHidden = Pref.bool("switcher.hidden", true) {
        didSet { Pref.set("switcher.hidden", includeHidden) }
    }
    var includeOtherSpaces = Pref.bool("switcher.allSpaces", true) {
        didSet {
            Pref.set("switcher.allSpaces", includeOtherSpaces)
            if !includeOtherSpaces { elementCache = [:] }
        }
    }

    @ObservationIgnored private let state = SwitcherState()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var host: NSHostingView<SwitcherView>?
    @ObservationIgnored private var hotkeys: [UInt32] = []
    @ObservationIgnored private var sessionKeys: [UInt32] = []
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var holdMods: NSEvent.ModifierFlags = []
    @ObservationIgnored private var active = false
    @ObservationIgnored private var showWork: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    /// Ảnh xem trước lần trước (chỉ kiểu Ảnh xem trước): mở HUD là có ảnh ngay, rồi chụp lại ở nền.
    @ObservationIgnored private var thumbCache: [CGWindowID: NSImage] = [:]
    /// Phiên này có chụp ảnh xem trước không (kiểu Ảnh xem trước và đã có quyền Ghi màn hình).
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private var appOrder: [pid_t] = []
    /// Phần tử AX của các cửa sổ đã gặp, để dùng khi cửa sổ sang Space khác. Mỗi lần liệt kê đủ thì dựng lại (bỏ cửa sổ đã đóng).
    @ObservationIgnored private var elementCache: [CGWindowID: AXUIElement] = [:]
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init() {}

    func start() {
        registerHotkeys()
        // Thứ tự app dùng gần nhất: theo sự kiện, không poll.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appOrder.removeAll { $0 == pid }
                self.appOrder.insert(pid, at: 0)
                if self.appOrder.count > 64 { self.appOrder.removeLast() }
            }
        }
    }

    func stop() {
        thumbCache = [:]
        elementCache = [:]
        cancel()
        HotKeyCenter.shared.unregister(hotkeys)
        hotkeys = []
        setSystemCmdTab(enabled: true)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        panel?.close()
        panel = nil
        host = nil
    }

    // MARK: Phím tắt

    private func registerHotkeys() {
        HotKeyCenter.shared.unregister(hotkeys)
        hotkeys = []
        let hc = HotKeyCenter.shared
        if let next = Shortcuts.combo("switcher.next", Self.defaultNext) {
            hotkeys.append(hc.register(next) { [weak self] in self?.trigger(combo: next, reverse: false, appOnly: false) })
            var rev = next
            rev.mods |= KeyCombo.shift
            hotkeys.append(hc.register(rev) { [weak self] in self?.trigger(combo: next, reverse: true, appOnly: false) })
        }
        if let app = Shortcuts.combo("switcher.app", Self.defaultAppWindows) {
            hotkeys.append(hc.register(app) { [weak self] in self?.trigger(combo: app, reverse: false, appOnly: true) })
        }
        if replaceCmdTab {
            let cmdTab = KeyCombo(kVK_Tab, KeyCombo.cmd)
            setSystemCmdTab(enabled: false)
            hotkeys.append(hc.register(cmdTab) { [weak self] in self?.trigger(combo: cmdTab, reverse: false, appOnly: false) })
            hotkeys.append(hc.register(KeyCombo(kVK_Tab, KeyCombo.cmd | KeyCombo.shift)) { [weak self] in
                self?.trigger(combo: cmdTab, reverse: true, appOnly: false)
            })
        } else {
            setSystemCmdTab(enabled: true)
        }
    }

    /// Tắt ⌘Tab của hệ thống khi thay thế; luôn bật lại khi module dừng / app thoát.
    private func setSystemCmdTab(enabled: Bool) {
        let disabledByUs = Pref.bool("switcher.cmdTabDisabled", false)
        if enabled && !disabledByUs { return }
        guard let f = PrivateAPI.setSymbolicHotKeyEnabled else { return }
        _ = f(1, enabled)   // ⌘Tab
        _ = f(2, enabled)   // ⌘⇧Tab
        Pref.set("switcher.cmdTabDisabled", !enabled)
    }

    private func registerSessionKeys() {
        let m = KeyCombo.carbonMods(holdMods)
        let hc = HotKeyCenter.shared
        let keys: [(Int, UInt32, () -> Void)] = [
            (kVK_LeftArrow, m, { [weak self] in self?.move(-1) }),
            (kVK_RightArrow, m, { [weak self] in self?.move(1) }),
            (kVK_UpArrow, m, { [weak self] in self?.moveRow(-1) }),
            (kVK_DownArrow, m, { [weak self] in self?.moveRow(1) }),
            (kVK_Escape, m, { [weak self] in self?.cancel() }),
            (kVK_Return, m, { [weak self] in self?.commit() }),
            (kVK_ANSI_Q, m, { [weak self] in self?.act(.quit) }),
            (kVK_ANSI_W, m, { [weak self] in self?.act(.close) }),
            (kVK_ANSI_M, m, { [weak self] in self?.act(.minimize) }),
            (kVK_ANSI_H, m, { [weak self] in self?.act(.hide) }),
        ]
        sessionKeys = keys.map { hc.register(KeyCombo($0.0, $0.1), $0.2) }
    }

    // MARK: Phiên chuyển

    private func trigger(combo: KeyCombo, reverse: Bool, appOnly: Bool) {
        log.notice("switcher: phím tắt, active=\(self.active, privacy: .public)")
        if active {
            // Phiên trước bị kẹt (lỡ mất sự kiện thả ⌥, HUD không còn hiện): bỏ nó, mở phiên mới.
            let stuck = showWork == nil && panel?.isVisible != true
            if !stuck { move(reverse ? -1 : 1); return }
            log.notice("switcher: phiên trước bị kẹt, mở lại")
            endSession()
        }
        guard AXIsProcessTrusted() else {
            log.notice("switcher: chưa có quyền Trợ năng")
            Permissions.shared.requestAccessibility()
            return
        }

        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let items = collect(onlyPid: appOnly ? frontPid : nil)
        log.notice("switcher: \(items.count, privacy: .public) cửa sổ")
        guard !items.isEmpty else { return }
        state.items = items
        state.style = style
        capturing = style == .thumbnails && CGPreflightScreenCaptureAccess()
        state.thumbnails = capturing ? thumbCache : [:]
        state.selected = items.count > 1 ? (reverse ? items.count - 1 : 1) : 0
        holdMods = combo.eventModifiers.subtracting(.shift)
        active = true
        generation += 1

        // Đã nhả phím (bấm nhanh): chuyển ngay.
        if !NSEvent.modifierFlags.isSuperset(of: holdMods) {
            log.notice("switcher: thả phím nhanh, chuyển luôn không hiện HUD")
            commit()
            return
        }

        installMonitors()
        registerSessionKeys()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showPanel() } }
        showWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: w)
    }

    private func installMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                if !e.modifierFlags.isSuperset(of: self.holdMods) { self.commit() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) {
            monitors.append(l)
        }
    }

    private func endSession() {
        showWork?.cancel()
        showWork = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        HotKeyCenter.shared.unregister(sessionKeys)
        sessionKeys = []
        active = false
        generation += 1
        panel?.orderOut(nil)
        state.items = []
        state.thumbnails = [:]
    }

    private func commit() {
        guard active else { return }
        let item = state.items.indices.contains(state.selected) ? state.items[state.selected] : nil
        log.notice("switcher: chọn \(self.state.selected, privacy: .public)/\(self.state.items.count, privacy: .public), pid \(item?.pid ?? 0, privacy: .public), app đang trước pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, privacy: .public)")
        endSession()
        if let item { Self.focus(item) }
    }

    func cancel() {
        guard active else { return }
        endSession()
    }

    private func move(_ d: Int) {
        guard !state.items.isEmpty else { return }
        state.selected = (state.selected + d + state.items.count) % state.items.count
    }

    private func moveRow(_ d: Int) {
        let n = state.items.count, c = max(state.columns, 1)
        guard n > c else { return }
        let next = state.selected + d * c
        if next >= 0 && next < n { state.selected = next }
    }

    private func select(_ i: Int) {
        state.selected = i
        commit()
    }

    private enum Action { case quit, close, minimize, hide }

    private func act(_ a: Action) {
        guard state.items.indices.contains(state.selected) else { return }
        let item = state.items[state.selected]
        let app = NSRunningApplication(processIdentifier: item.pid)
        switch a {
        case .quit:
            app?.terminate()
            state.items.removeAll { $0.pid == item.pid }
        case .close:
            // Cửa sổ ở Space khác chưa từng gặp: không có phần tử AX để bấm nút đóng.
            guard let el = item.element else { return }
            if let b = AX.element(el, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(b, kAXPressAction as CFString)
            }
            state.items.removeAll { $0.id == item.id }
        case .minimize:
            if let el = item.element { AX.setBool(el, kAXMinimizedAttribute, true) }
            return
        case .hide:
            app?.hide()
            return
        }
        if state.items.isEmpty { cancel(); return }
        state.selected = min(state.selected, state.items.count - 1)
        resizePanel()
    }

    // MARK: Liệt kê cửa sổ

    private func collect(onlyPid: pid_t?) -> [SwitcherItem] {
        let me = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && (onlyPid == nil || $0.processIdentifier == onlyPid)
        }
        // Z-order thật của các cửa sổ đang hiện (trước -> sau).
        var zOrder: [CGWindowID: Int] = [:]
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for (i, w) in list.enumerated() where (w[kCGWindowLayer as String] as? Int) == 0 {
                if let n = w[kCGWindowNumber as String] as? Int { zOrder[CGWindowID(n)] = i }
            }
        }

        // Space khác (gồm app toàn màn hình): AX không trả về, lấy danh sách từ WindowServer.
        let elsewhere = includeOtherSpaces ? (PrivateAPI.windowsOnHiddenSpaces() ?? [:]) : [:]
        // Chỉ đọc từ các luồng liệt kê; AXUIElement gọi được từ luồng nền (như phần tử AX lấy trong vòng lặp).
        nonisolated(unsafe) let cache = elementCache
        // Chưa từng gặp thì không có phần tử AX: tiêu đề lấy từ WindowServer, cần quyền Ghi màn hình.
        let canReadNames = !elsewhere.isEmpty && CGPreflightScreenCaptureAccess()

        struct Raw { let id: CGWindowID; let el: AXUIElement?; let title: String; let minimized: Bool }
        var perApp = [[Raw]](repeating: [], count: apps.count)
        let pids = apps.map(\.processIdentifier)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let axApp = AXUIElementCreateApplication(pids[i])
            AXUIElementSetMessagingTimeout(axApp, 0.08)
            var found: [Raw] = []
            for w in AX.elements(axApp, kAXWindowsAttribute) {
                let sub = AX.attr(w, kAXSubroleAttribute, String.self) ?? ""
                guard sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole,
                      let id = PrivateAPI.windowID(of: w) else { continue }
                let title = AX.attr(w, kAXTitleAttribute, String.self) ?? ""
                let min = AX.attr(w, kAXMinimizedAttribute, Bool.self) ?? false
                found.append(Raw(id: id, el: w, title: title, minimized: min))
            }
            let seen = Set(found.map(\.id))
            for id in elsewhere[pids[i]] ?? [] where !seen.contains(id) {
                let el = cache[id]
                var title = el.flatMap { AX.attr($0, kAXTitleAttribute, String.self) } ?? ""
                if el == nil, canReadNames,
                   let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first {
                    title = info[kCGWindowName as String] as? String ?? ""
                }
                found.append(Raw(id: id, el: el, title: title, minimized: false))
            }
            lock.lock()
            perApp[i] = found
            lock.unlock()
        }
        if includeOtherSpaces {
            // Liệt kê đủ thì dựng lại từ đầu: cửa sổ đã đóng tự rơi khỏi bộ nhớ.
            var next = onlyPid == nil ? [:] : elementCache
            for raws in perApp {
                for r in raws where next[r.id] == nil {
                    guard let el = r.el else { continue }
                    if cache[r.id] == nil { AXUIElementSetMessagingTimeout(el, 0.08) }   // app treo thì không chờ lâu
                    next[r.id] = el
                }
            }
            elementCache = next
        }

        var result: [(key: Int, item: SwitcherItem)] = []
        for (i, app) in apps.enumerated() {
            let hidden = app.isHidden
            if hidden && !includeHidden { continue }
            let mru = appOrder.firstIndex(of: app.processIdentifier) ?? appOrder.count
            for (j, r) in perApp[i].enumerated() {
                if r.minimized && !includeMinimized { continue }
                let key = zOrder[r.id] ?? (10_000 + mru * 100 + j)
                let name = app.localizedName ?? "?"
                result.append((key, SwitcherItem(id: r.id, pid: app.processIdentifier, element: r.el,
                                                  title: r.title.isEmpty ? name : r.title, appName: name,
                                                  icon: app.icon, isMinimized: r.minimized, isHidden: hidden)))
            }
        }
        return result.sorted { $0.key < $1.key }.map(\.item)
    }

    /// zMac --diagnose: đo thời gian liệt kê (không in tiêu đề cửa sổ).
    static func diagnose() {
        guard AXIsProcessTrusted() else { print("  cửa sổ: chưa có quyền Trợ năng"); return }
        let m = SwitcherModule()
        _ = m.collect(onlyPid: nil)   // lần đầu: nạp AX
        let t0 = Date()
        let items = m.collect(onlyPid: nil)
        let ms = Date().timeIntervalSince(t0) * 1000
        let perApp = Dictionary(grouping: items, by: \.appName).map { "\($0.key) \($0.value.count)" }.sorted()
        print(String(format: "  cửa sổ: %d cửa sổ từ %d app, liệt kê mất %.1f ms", items.count, perApp.count, ms))
        print("    " + perApp.joined(separator: ", "))
        if let other = PrivateAPI.windowsOnHiddenSpaces() {
            let ids = Set(other.values.joined())
            print("    ở Space khác: \(items.filter { ids.contains($0.id) }.count) cửa sổ"
                  + (m.includeOtherSpaces ? "" : " (đang tắt trong Cài đặt)"))
        } else {
            print("    ở Space khác: thiếu API, chỉ thấy Space hiện tại")
        }
    }

    static func focus(_ item: SwitcherItem) {
        let app = NSRunningApplication(processIdentifier: item.pid)
        if item.isHidden { app?.unhide() }
        if item.isMinimized, let el = item.element { AX.setBool(el, kAXMinimizedAttribute, false) }
        // Cửa sổ ở Space khác: thành key window thì macOS chuyển sang Space của nó.
        if !PrivateAPI.focus(pid: item.pid, windowID: item.id) { app?.activate() }
        if let el = item.element { AXUIElementPerformAction(el, kAXRaiseAction as CFString) }
    }

    // MARK: HUD

    private func showPanel() {
        guard active else { return }
        showWork = nil
        // ⌥ đã thả trong lúc chờ (có thể trước khi monitor kịp cài): chuyển luôn, không hiện HUD.
        if !NSEvent.modifierFlags.isSuperset(of: holdMods) { commit(); return }
        log.notice("switcher: hiện HUD")
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            p.becomesKeyOnlyIfNeeded = true
            let h = NSHostingView(rootView: SwitcherView(state: state, onSelect: { [weak self] i in self?.select(i) }))
            p.contentView = h
            panel = p
            host = h
        }
        resizePanel()
        panel?.orderFrontRegardless()
        if capturing { loadThumbnails(generation: generation) }
    }

    private func resizePanel() {
        guard let panel, let host else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        state.columns = state.style.columns(count: state.items.count, area: CGSize(width: vf.width * 0.9, height: vf.height * 0.85))
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        size.width = min(size.width, vf.width * 0.95)
        size.height = min(size.height, vf.height * 0.9)
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08,
                              width: size.width, height: size.height), display: true)
    }

    private func loadThumbnails(generation gen: Int) {
        let targets = state.items.prefix(30).map { $0.id }
        let width = SwitcherStyle.thumbnails.cellWidth * 2
        // Bỏ ảnh của cửa sổ đã đóng.
        let live = Set(state.items.map { $0.id })
        thumbCache = thumbCache.filter { live.contains($0.key) }
        Task { [weak self] in
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            } catch {
                log.error("switcher: không lấy được danh sách cửa sổ để chụp: \(error.localizedDescription, privacy: .public)")
                return
            }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            // Chụp song song: HUD chỉ hiện trong lúc giữ ⌥, chụp lần lượt thường không kịp.
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in targets {
                    guard let w = byID[id], w.frame.width > 1 else { continue }
                    let cfg = SCStreamConfiguration()
                    cfg.width = Int(width)
                    cfg.height = Int(width * w.frame.height / w.frame.width)
                    cfg.showsCursor = false
                    let filter = SCContentFilter(desktopIndependentWindow: w)
                    group.addTask {
                        do {
                            return (id, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg))
                        } catch {
                            log.error("switcher: chụp cửa sổ \(id) lỗi: \(error.localizedDescription, privacy: .public)")
                            return (id, nil)
                        }
                    }
                }
                for await (id, img) in group {
                    guard let self, let img else { continue }
                    let image = NSImage(cgImage: img, size: .zero)
                    self.thumbCache[id] = image
                    if self.generation == gen { self.state.thumbnails[id] = image }
                }
            }
        }
    }

    // MARK: Cài đặt

    func settingsView() -> AnyView {
        moduleForm {
            if !Permissions.shared.accessibility {
                Section {
                    PermissionRow(title: L("Cần quyền Trợ năng", "Accessibility needed"),
                                  detail: L("Để đọc danh sách cửa sổ và chuyển cửa sổ.", "To list and focus windows."),
                                  granted: false) { Permissions.shared.requestAccessibility() }
                }
            }
            Section(L("Phím tắt", "Shortcuts")) {
                HStack {
                    Text(L("Mọi cửa sổ (thêm ⇧ để đi ngược)", "All windows (add ⇧ to go back)"))
                    Spacer()
                    ShortcutField(id: "switcher.next", defaultCombo: Self.defaultNext) { [weak self] in self?.registerHotkeys() }
                }
                HStack {
                    Text(L("Cửa sổ của app hiện tại", "Windows of the current app"))
                    Spacer()
                    ShortcutField(id: "switcher.app", defaultCombo: Self.defaultAppWindows) { [weak self] in self?.registerHotkeys() }
                }
                Toggle(L("Thay luôn ⌘Tab của macOS", "Replace macOS ⌘Tab"),
                       isOn: Binding(get: { self.replaceCmdTab }, set: { self.replaceCmdTab = $0 }))
                Text(L("Trong lúc giữ phím: ← → ↑ ↓ để chọn, Q thoát app, W đóng cửa sổ, M thu nhỏ, H ẩn app, Esc huỷ.",
                       "While holding: ← → ↑ ↓ to pick, Q quits the app, W closes, M minimizes, H hides, Esc cancels."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Giao diện", "Appearance")) {
                SwitcherStylePicker(selection: Binding(get: { self.style }, set: { self.style = $0 }))
                if style == .thumbnails && !Permissions.shared.screenRecording {
                    PermissionRow(title: L("Cần quyền Ghi màn hình", "Screen Recording needed"),
                                  detail: L("Chưa có quyền thì mỗi thẻ hiện biểu tượng app thay cho ảnh.",
                                            "Until then each card shows the app icon instead of a preview."),
                                  granted: false) { Permissions.shared.requestScreenRecording() }
                }
                Text(L("Ảnh xem trước chụp từng cửa sổ mỗi lần mở HUD. Biểu tượng app và Tiêu đề hiện tức thì, không chụp màn hình.",
                       "Thumbnails capture each window every time the HUD opens. App Icons and Titles appear instantly and never capture the screen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Cửa sổ", "Windows")) {
                Toggle(L("Gồm cửa sổ ở Space khác", "Include windows on other Spaces"),
                       isOn: Binding(get: { self.includeOtherSpaces }, set: { self.includeOtherSpaces = $0 }))
                Toggle(L("Gồm cửa sổ thu nhỏ", "Include minimized windows"),
                       isOn: Binding(get: { self.includeMinimized }, set: { self.includeMinimized = $0 }))
                Toggle(L("Gồm app đang ẩn", "Include hidden apps"),
                       isOn: Binding(get: { self.includeHidden }, set: { self.includeHidden = $0 }))
            }
        }
    }
}

// MARK: - View HUD

struct SwitcherView: View {
    let state: SwitcherState
    let onSelect: (Int) -> Void

    var body: some View {
        let style = state.style
        let cols = max(state.columns, 1)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(style.cellWidth), spacing: style.hSpacing), count: cols),
                  spacing: style.vSpacing) {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { i, item in
                cell(item, selected: i == state.selected, column: i % cols, columns: cols)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(i) }
                    .onHover { if $0 { state.selected = i } }
            }
        }
        .padding(style.inset)
        .zFloatingPanel(radius: style == .titles ? 18 : 24)
        .fixedSize()
    }

    @ViewBuilder
    private func cell(_ item: SwitcherItem, selected: Bool, column: Int, columns: Int) -> some View {
        switch state.style {
        case .thumbnails: SwitcherThumbnailCard(item: item, selected: selected, image: state.thumbnails[item.id])
        case .icons: SwitcherIconCell(item: item, selected: selected, column: column, columns: columns)
        case .titles: SwitcherTitleRow(item: item, selected: selected)
        }
    }
}

private extension SwitcherItem {
    /// Cửa sổ thu nhỏ, app đang ẩn: vẽ mờ hơn.
    var dimmed: Double { isMinimized || isHidden ? 0.6 : 1 }
}

private extension View {
    /// Khung xanh của ô đang chọn.
    func switcherHighlight(_ on: Bool, radius: CGFloat, line: CGFloat = 2) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(on ? AnyShapeStyle(ZTheme.blue.gradient.opacity(0.32)) : AnyShapeStyle(Color.clear)))
            .overlay(shape.strokeBorder(on ? ZTheme.blue.light.opacity(0.85) : .clear, lineWidth: line))
    }
}

/// Ảnh xem trước: tiêu đề ở trên, ảnh cửa sổ ở dưới. Chưa có ảnh (đang chụp, chưa có quyền) thì hiện biểu tượng app.
struct SwitcherThumbnailCard: View {
    let item: SwitcherItem
    let selected: Bool
    let image: NSImage?

    var body: some View {
        let w = SwitcherStyle.thumbnails.cellWidth
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(item.title).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 2)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                }
            }
            .frame(width: w - 12, height: (w - 12) * 0.62)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .opacity(item.dimmed)
        .padding(6)
        .frame(width: w, alignment: .leading)
        .switcherHighlight(selected, radius: 14)
        .foregroundStyle(.white)
    }
}

/// Biểu tượng app: như ⌘⇥ của macOS, chỉ ô đang chọn có tiêu đề bên dưới.
/// Tiêu đề được rộng hơn ô (ô bên cạnh không có chữ); ô sát mép HUD thì hẹp lại để chữ không tràn ra ngoài.
struct SwitcherIconCell: View {
    let item: SwitcherItem
    let selected: Bool
    let column: Int
    let columns: Int

    var body: some View {
        let s = SwitcherStyle.icons
        VStack(spacing: 5) {
            Group {
                if let icon = item.icon { Image(nsImage: icon).resizable() } else { Color.clear }
            }
            .frame(width: 64, height: 64)
            .opacity(item.dimmed)
            .padding(10)
            .switcherHighlight(selected, radius: 18)
            Color.clear.frame(height: 15)
        }
        .frame(width: s.cellWidth)
        .overlay(alignment: .bottom) {
            if selected {
                let side = CGFloat(min(column, columns - 1 - column))
                let room = side * (s.cellWidth + s.hSpacing) + s.cellWidth / 2 + s.inset - 6
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: min(room * 2, 260), height: 15)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Tiêu đề: mỗi cửa sổ một dòng, biểu tượng nhỏ và tiêu đề.
struct SwitcherTitleRow: View {
    let item: SwitcherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let icon = item.icon { Image(nsImage: icon).resizable() } else { Color.clear }
            }
            .frame(width: 22, height: 22)
            Text(item.title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .opacity(item.dimmed)
        .padding(.horizontal, 8)
        .frame(width: SwitcherStyle.titles.cellWidth, height: SwitcherStyle.rowHeight)
        .switcherHighlight(selected, radius: 8, line: 1.5)
        .foregroundStyle(.white)
    }
}

// MARK: - Chọn kiểu trong Cài đặt

/// Ba ô chọn kiểu HUD.
struct SwitcherStylePicker: View {
    @Binding var selection: SwitcherStyle

    var body: some View {
        ZChoiceTiles(options: SwitcherStyle.allCases, selection: $selection, hue: ZTheme.hue(SwitcherModule.id),
                     title: { $0.name }, detail: { $0.detail }) { s in
            SwitcherStyleSketch(style: s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [ZTheme.navyTop, ZTheme.navyBottom], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// Hình thu nhỏ của một kiểu HUD.
private struct SwitcherStyleSketch: View {
    let style: SwitcherStyle

    private struct Win { let title: String; let symbol: String; let hue: ZTheme.Hue }

    private var wins: [Win] {
        [Win(title: L("Lịch trình Đà Lạt", "Weekend trip"), symbol: "safari", hue: ZTheme.blue),
         Win(title: L("Việc tuần này", "This week"), symbol: "note.text", hue: ZTheme.orange),
         Win(title: "~/zMac — zsh", symbol: "terminal", hue: ZTheme.green)]
    }

    var body: some View {
        content
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .thumbnails:
            HStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { i in thumbnail(wins[i], selected: i == 1) }
            }
        case .icons:
            HStack(alignment: .top, spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    VStack(spacing: 3) {
                        ZTile(symbol: wins[i].symbol, hue: wins[i].hue, size: 28)
                            .padding(5)
                            .background(highlight(i == 1, radius: 8))
                        Text(i == 1 ? wins[i].title : " ")
                            .font(.system(size: 8, weight: .medium)).lineLimit(1).fixedSize()
                    }
                }
            }
        case .titles:
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 5) {
                        ZTile(symbol: wins[i].symbol, hue: wins[i].hue, size: 12)
                        Text(wins[i].title).font(.system(size: 9)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5)
                    .frame(width: 118, height: 18)
                    .background(highlight(i == 1, radius: 5))
                }
            }
        }
    }

    private func thumbnail(_ w: Win, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ZTile(symbol: w.symbol, hue: w.hue, size: 9)
                Text(w.title).font(.system(size: 7, weight: .semibold)).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(.black.opacity(0.55)).frame(width: 30, height: 4)
                Capsule().fill(.black.opacity(0.25)).frame(width: 44, height: 3)
                RoundedRectangle(cornerRadius: 2).fill(w.hue.gradient).frame(height: 14)
            }
            .padding(5)
            .frame(width: 66, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.9)))
        }
        .padding(4)
        .frame(width: 74)
        .background(highlight(selected, radius: 6))
    }

    private func highlight(_ on: Bool, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape.fill(on ? ZTheme.blue.base.opacity(0.3) : .clear)
            .overlay(shape.strokeBorder(on ? ZTheme.blue.light : .clear, lineWidth: 1.2))
    }
}

/// Nền mờ của macOS (GPU tự làm, không tốn CPU).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
