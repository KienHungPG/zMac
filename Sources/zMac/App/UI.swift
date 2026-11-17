import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Menu bar

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    override init() {
        super.init()
        MainMenu.install()
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "zMac")
            b.image?.isTemplate = true
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.delegate = self
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if popover.isShown { popover.performClose(nil); return }
        // Tạo view mỗi lần mở, huỷ khi đóng: bảng ẩn không tốn RAM, không layout.
        let host = NSHostingController(rootView: QuickPanel())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Cài đặt…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Thoát zMac", "Quit zMac"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
}

/// App menu bar (accessory) vẫn cần menu Edit để ⌘C / ⌘V chạy trong ô nhập liệu.
enum MainMenu {
    @MainActor static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Thoát zMac", "Quit zMac"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: L("Đóng", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }
}

struct QuickPanel: View {
    var manager = ModuleManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("zMac").font(.headline)
                Spacer()
                Button { SettingsWindowController.shared.show() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(L("Cài đặt", "Settings"))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help(L("Thoát", "Quit"))
            }
            let views = quickViews
            if views.isEmpty {
                Text(L("Chưa bật tính năng nào có bảng nhanh.", "No enabled feature has quick controls."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(views, id: \.id) { v in
                VStack(alignment: .leading, spacing: 6) {
                    Label(v.name, systemImage: v.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    v.view
                }
                if v.id != views.last?.id { Divider() }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var quickViews: [(id: String, name: String, symbol: String, view: AnyView)] {
        manager.types.compactMap { t in
            guard let m = manager.running[t.id], let v = m.quickView() else { return nil }
            return (t.id, t.name, t.symbol, v)
        }
    }
}

// MARK: - Cửa sổ Cài đặt

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(_ selection: String = "general") {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "zMac"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.minSize = NSSize(width: 700, height: 480)
            w.contentViewController = NSHostingController(rootView: SettingsRoot(selection: selection))
            w.setContentSize(NSSize(width: 820, height: 600))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Giải phóng toàn bộ cây SwiftUI khi đóng.
        window?.contentViewController = nil
        window = nil
    }
}

struct SettingsRoot: View {
    @State var selection: String?
    var manager = ModuleManager.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(L("Chung", "General"), systemImage: "gearshape").tag("general")
                Label(L("Hiệu năng", "Performance"), systemImage: "gauge.with.dots.needle.33percent").tag("performance")
                Section(L("Tính năng", "Features")) {
                    ForEach(manager.types.map { ModuleRef($0) }) { ref in
                        HStack {
                            Label(ref.type.name, systemImage: ref.type.symbol)
                            Spacer()
                            Circle()
                                .fill(ref.type.unavailableReason != nil ? Color.clear
                                      : manager.running[ref.id] != nil ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                        }
                        .tag(ref.id)
                        .opacity(ref.type.unavailableReason == nil ? 1 : 0.5)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            switch selection ?? "general" {
            case "general": GeneralPane()
            case "performance": PerformancePane()
            case let id:
                if let t = manager.types.first(where: { $0.id == id }) { ModulePane(type: t) } else { GeneralPane() }
            }
        }
    }
}

struct ModuleRef: Identifiable {
    let type: any ZModule.Type
    let id: String
    @MainActor init(_ t: any ZModule.Type) { type = t; id = t.id }
}

struct ModulePane: View {
    let type: any ZModule.Type
    var manager = ModuleManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: type.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(type.name).font(.title2.weight(.semibold))
                    Text(L("Thay cho ", "Replaces ") + type.replaces).font(.callout).foregroundStyle(.secondary)
                    Text(type.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if type.unavailableReason == nil {
                    Toggle("", isOn: Binding(
                        get: { manager.running[type.id] != nil },
                        set: { manager.setEnabled(type, $0) }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                }
            }
            .padding(20)
            if manager.running[type.id] != nil {
                ConflictBanner(apps: manager.runningConflicts(type.id))
            }
            Divider()
            if let reason = type.unavailableReason {
                Placeholder(symbol: "exclamationmark.triangle", text: reason)
            } else if let m = manager.running[type.id] {
                m.settingsView()
            } else {
                Placeholder(symbol: "power", text: L("Tính năng đang tắt nên không tốn tài nguyên. Bật để chỉnh cài đặt.",
                                                     "This feature is off and uses no resources. Turn it on to configure."))
            }
        }
        .id(type.id)
    }
}

/// Cảnh báo app gốc vẫn đang chạy, kèm nút thoát nó.
struct ConflictBanner: View {
    @State var apps: [NSRunningApplication]

    var body: some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(apps, id: \.processIdentifier) { app in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text((app.localizedName ?? "?") + L(" đang chạy, có thể trùng phím tắt hoặc giao diện với zMac.",
                                                             " is running and may clash with zMac's shortcuts or UI."))
                            .font(.callout)
                        Spacer()
                        Button(L("Thoát ", "Quit ") + (app.localizedName ?? "")) {
                            app.terminate()
                            apps.removeAll { $0.processIdentifier == app.processIdentifier }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
    }
}

struct Placeholder: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Form chuẩn cho trang cài đặt module.
func moduleForm<Content: View>(@ViewBuilder _ content: () -> Content) -> AnyView {
    AnyView(Form { content() }.formStyle(.grouped))
}

// MARK: - Trang Chung

struct GeneralPane: View {
    var perms = Permissions.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = Lang.current
    @State private var loginError: String?

    var body: some View {
        Form {
            Section(L("Quyền", "Permissions")) {
                PermissionRow(title: L("Trợ năng (Accessibility)", "Accessibility"),
                              detail: L("Cần cho chuyển cửa sổ, chia cửa sổ, dán từ lịch sử clipboard.",
                                        "Needed for the window switcher, window snapping and pasting from history."),
                              granted: perms.accessibility) { perms.requestAccessibility() }
                PermissionRow(title: L("Ghi màn hình (tuỳ chọn)", "Screen Recording (optional)"),
                              detail: L("Chỉ cần nếu bật ảnh xem trước trong bộ chuyển cửa sổ.",
                                        "Only needed for window previews in the switcher."),
                              granted: perms.screenRecording) { perms.requestScreenRecording() }
            }
            let clashes = ModuleManager.shared.running.keys.sorted().flatMap { ModuleManager.shared.runningConflicts($0) }
            if !clashes.isEmpty {
                Section(L("App bị thay thế vẫn đang chạy", "Replaced apps still running")) {
                    ConflictBanner(apps: clashes)
                    Text(L("zMac đã làm việc của các app này. Thoát chúng để tránh trùng phím tắt và tiết kiệm RAM.",
                           "zMac already does their job. Quit them to avoid shortcut clashes and save memory."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Chung", "General")) {
                Toggle(L("Mở cùng máy", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Picker(L("Ngôn ngữ", "Language"), selection: $language) {
                    Text(L("Theo hệ thống", "System")).tag(Lang.system)
                    Text("Tiếng Việt").tag(Lang.vi)
                    Text("English").tag(Lang.en)
                }
                .onChange(of: language) { _, v in Pref.set("app.language", v.rawValue) }
                if language != Lang.current || (language == .system) != (Lang.current == .system) {
                    Text(L("Mở lại app để đổi ngôn ngữ.", "Relaunch the app to apply.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Máy này", "This Mac")) {
                LabeledContent(L("Kiểu máy", "Model"), value: Hardware.model)
                LabeledContent("Chip", value: Hardware.chip)
                LabeledContent(L("Nhân CPU", "CPU cores"), value: "\(Hardware.performanceCores)P + \(Hardware.efficiencyCores)E")
                LabeledContent("RAM", value: "\(Hardware.memoryGB) GB")
                LabeledContent(L("Pin", "Battery"), value: Hardware.hasBattery ? L("Có", "Yes") : L("Không", "No"))
                LabeledContent("Notch", value: Hardware.notchScreen != nil ? L("Có", "Yes") : L("Không", "No"))
                Text(L("Tính năng không hợp với máy (vd khoá sạc trên Mac không pin) tự ẩn và không chạy.",
                       "Features that don't fit this Mac (e.g. charge limit on a Mac without battery) are hidden and never run."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(L("Cấp quyền", "Grant"), action: action) }
        }
    }
}

// MARK: - Trang Hiệu năng

struct PerformancePane: View {
    @State private var stats = ProcessStats.current()
    @State private var cpuPercent = 0.0
    @State private var wakeupsPerSec = 0.0
    @State private var timer: Timer?
    @State private var last: (ProcessStats, Date)?
    var manager = ModuleManager.shared

    var body: some View {
        Form {
            Section(L("zMac lúc này", "zMac right now")) {
                LabeledContent(L("Bộ nhớ (footprint)", "Memory (footprint)"), value: String(format: "%.1f MB", stats.footprintMB))
                LabeledContent("CPU", value: String(format: "%.1f %%", cpuPercent))
                LabeledContent(L("Đánh thức CPU khi rảnh", "Idle wakeups"), value: String(format: "%.1f /s", wakeupsPerSec))
                LabeledContent(L("Số luồng", "Threads"), value: "\(stats.threads)")
                LabeledContent(L("Module đang chạy", "Running modules"), value: "\(manager.running.count) / \(manager.types.count)")
                Text(L("Số liệu đo trong lúc trang này mở, nên CPU sẽ cao hơn lúc bình thường một chút.",
                       "Measured while this page is open, so CPU reads slightly higher than usual."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Vì sao nhẹ", "Why it's light")) {
                Bullet(L("Một tiến trình thay cho 7 app: dùng chung runtime Swift, AppKit, SwiftUI.",
                         "One process instead of seven apps: one shared Swift, AppKit and SwiftUI runtime."))
                Bullet(L("Module tắt thì không được tạo: không phím tắt, không listener, không bộ nhớ.",
                         "Disabled modules are never created: no shortcuts, listeners or memory."))
                Bullet(L("Phím tắt Carbon thay vì CGEventTap: phím bạn gõ không đi qua zMac.",
                         "Carbon hotkeys instead of a CGEventTap: your typing never passes through zMac."))
                Bullet(L("Chạy theo sự kiện (IOKit, CoreAudio, NSWorkspace), không vòng lặp kiểm tra. Riêng clipboard phải kiểm tra định kỳ và tự giãn nhịp khi máy rảnh.",
                         "Event driven (IOKit, CoreAudio, NSWorkspace), no polling loops. Only the clipboard is polled, and it slows down when you're idle."))
                Bullet(L("Âm lượng từng app chỉ tạo tap âm thanh khi khác 100%.",
                         "Per-app volume only creates an audio tap when an app isn't at 100%."))
                Bullet(L("Khoá sạc chạy trong daemon nhỏ, nên vẫn giữ ngưỡng khi app tắt.",
                         "Charge limiting runs in a tiny daemon, so it keeps working even when the app is closed."))
                Bullet(L("Cửa sổ, bảng, popover huỷ view khi đóng.", "Windows, panels and popovers destroy their views when closed."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            last = (ProcessStats.current(), Date())
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
            timer?.tolerance = 0.5
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func tick() {
        let now = ProcessStats.current()
        let t = Date()
        if let (prev, at) = last {
            let dt = max(t.timeIntervalSince(at), 0.1)
            cpuPercent = max(0, (now.cpuSeconds - prev.cpuSeconds) / dt * 100)
            wakeupsPerSec = Double(now.idleWakeups &- prev.idleWakeups) / dt
        }
        stats = now
        last = (now, t)
    }
}

struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
