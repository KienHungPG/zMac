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
// - Ảnh xem trước: tuỳ chọn, ScreenCaptureKit chụp nền sau khi HUD đã hiện.

struct SwitcherItem: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let title: String
    let appName: String
    let icon: NSImage?
    let isMinimized: Bool
    let isHidden: Bool
}

@MainActor @Observable
final class SwitcherState {
    var items: [SwitcherItem] = []
    var selected = 0
    var thumbnails: [CGWindowID: NSImage] = [:]
    var showThumbnails = false
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
    var showThumbnails = Pref.bool("switcher.thumbnails", false) {
        didSet { Pref.set("switcher.thumbnails", showThumbnails) }
    }
    var includeMinimized = Pref.bool("switcher.minimized", true) {
        didSet { Pref.set("switcher.minimized", includeMinimized) }
    }
    var includeHidden = Pref.bool("switcher.hidden", true) {
        didSet { Pref.set("switcher.hidden", includeHidden) }
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
    @ObservationIgnored private var appOrder: [pid_t] = []
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
        if active { move(reverse ? -1 : 1); return }
        guard AXIsProcessTrusted() else { Permissions.shared.requestAccessibility(); return }

        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let items = collect(onlyPid: appOnly ? frontPid : nil)
        guard !items.isEmpty else { return }
        state.items = items
        state.thumbnails = [:]
        state.showThumbnails = showThumbnails && CGPreflightScreenCaptureAccess()
        state.selected = items.count > 1 ? (reverse ? items.count - 1 : 1) : 0
        holdMods = combo.eventModifiers.subtracting(.shift)
        active = true
        generation += 1

        // Đã nhả phím (bấm nhanh): chuyển ngay.
        if !NSEvent.modifierFlags.isSuperset(of: holdMods) { commit(); return }

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
            if let b = AX.element(item.element, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(b, kAXPressAction as CFString)
            }
            state.items.removeAll { $0.id == item.id }
        case .minimize:
            AX.setBool(item.element, kAXMinimizedAttribute, true)
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

        struct Raw { let id: CGWindowID; let el: AXUIElement; let title: String; let minimized: Bool }
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
            lock.lock()
            perApp[i] = found
            lock.unlock()
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
    }

    static func focus(_ item: SwitcherItem) {
        let app = NSRunningApplication(processIdentifier: item.pid)
        if item.isHidden { app?.unhide() }
        if item.isMinimized { AX.setBool(item.element, kAXMinimizedAttribute, false) }
        if !PrivateAPI.focus(pid: item.pid, windowID: item.id) { app?.activate() }
        AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
    }

    // MARK: HUD

    private var cardWidth: CGFloat { state.showThumbnails ? 220 : 128 }

    private func showPanel() {
        guard active else { return }
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            p.becomesKeyOnlyIfNeeded = true
            let h = NSHostingView(rootView: SwitcherView(state: state, cardWidth: { [weak self] in self?.cardWidth ?? 128 },
                                                         onSelect: { [weak self] i in self?.select(i) }))
            p.contentView = h
            panel = p
            host = h
        }
        resizePanel()
        panel?.orderFrontRegardless()
        if state.showThumbnails { loadThumbnails(generation: generation) }
    }

    private func resizePanel() {
        guard let panel, let host else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        state.columns = max(1, min(state.items.count, Int((vf.width * 0.9 - 28) / (cardWidth + 10))))
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        size.width = min(size.width, vf.width * 0.95)
        size.height = min(size.height, vf.height * 0.9)
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08,
                              width: size.width, height: size.height), display: true)
    }

    private func loadThumbnails(generation gen: Int) {
        let targets = state.items.prefix(30).map { $0.id }
        let width = cardWidth * 2
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            for id in targets {
                guard let self, self.generation == gen else { return }
                guard let w = byID[id], w.frame.width > 1 else { continue }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(width)
                cfg.height = Int(width * w.frame.height / w.frame.width)
                cfg.showsCursor = false
                guard let img = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { continue }
                if self.generation == gen { self.state.thumbnails[id] = NSImage(cgImage: img, size: .zero) }
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
            Section(L("Hiển thị", "Appearance")) {
                Toggle(L("Gồm cửa sổ thu nhỏ", "Include minimized windows"),
                       isOn: Binding(get: { self.includeMinimized }, set: { self.includeMinimized = $0 }))
                Toggle(L("Gồm app đang ẩn", "Include hidden apps"),
                       isOn: Binding(get: { self.includeHidden }, set: { self.includeHidden = $0 }))
                Toggle(L("Ảnh xem trước cửa sổ", "Window previews"),
                       isOn: Binding(get: { self.showThumbnails }, set: { self.showThumbnails = $0 }))
                if showThumbnails && !Permissions.shared.screenRecording {
                    PermissionRow(title: L("Cần quyền Ghi màn hình", "Screen Recording needed"),
                                  detail: L("Không có quyền thì chỉ hiện biểu tượng app.", "Without it only app icons are shown."),
                                  granted: false) { Permissions.shared.requestScreenRecording() }
                }
                Text(L("Tắt ảnh xem trước thì HUD hiện tức thì và không chụp màn hình.",
                       "With previews off the HUD appears instantly and never captures the screen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - View HUD

struct SwitcherView: View {
    let state: SwitcherState
    let cardWidth: () -> CGFloat
    let onSelect: (Int) -> Void

    var body: some View {
        let w = cardWidth()
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: 10), count: max(state.columns, 1)), spacing: 10) {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { i, item in
                SwitcherCard(item: item, selected: i == state.selected, width: w,
                             thumbnail: state.showThumbnails ? (state.thumbnails[item.id] ?? NSImage()) : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(i) }
                    .onHover { if $0 { state.selected = i } }
            }
        }
        .padding(14)
        .background(VisualEffectBlur(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 18)))
        .fixedSize()
    }
}

struct SwitcherCard: View {
    let item: SwitcherItem
    let selected: Bool
    let width: CGFloat
    let thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            if let thumbnail {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25))
                    if thumbnail.size.width > 0 {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                    } else if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                    }
                }
                .frame(width: width - 12, height: (width - 12) * 0.62)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 5) {
                    if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11))
            } else {
                if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 64, height: 64) }
                Text(item.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 28, alignment: .top)
            }
        }
        .opacity(item.isMinimized || item.isHidden ? 0.6 : 1)
        .padding(6)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.35) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .foregroundStyle(.white)
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
