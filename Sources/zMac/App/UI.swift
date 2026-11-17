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
        // Nhớ vị trí icon khi người dùng ⌘-kéo nó trên thanh menu (không thì mỗi lần mở lại nằm sát notch).
        item.autosaveName = "zMac"
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "zMac")
            b.image?.isTemplate = true
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.delegate = self
        // Nền tối cố định: popover cùng bộ với trang web và cửa sổ Cài đặt.
        popover.appearance = NSAppearance(named: .darkAqua)
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
    /// Đọc một lần lúc mở bảng, không theo dõi liên tục.
    private let memoryMB = ProcessStats.current().footprintMB

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ZBrandMark(size: 22)
                Text("zMac").font(.system(size: 15, weight: .bold))
                Text(String(format: "%.0f MB", memoryMB))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .help(L("Bộ nhớ zMac đang dùng", "Memory zMac is using"))
                Spacer()
                CircleIconButton(symbol: "gearshape.fill", help: L("Cài đặt", "Settings")) {
                    SettingsWindowController.shared.show()
                }
                CircleIconButton(symbol: "power", help: L("Thoát", "Quit")) { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            UpdateBanner()

            let views = quickViews
            if views.isEmpty {
                Text(L("Chưa bật tính năng nào có bảng nhanh.", "No enabled feature has quick controls."))
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).zCard()
            }
            ForEach(views, id: \.id) { v in
                let hue = ZTheme.hue(v.id)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        ZTile(symbol: v.symbol, hue: hue, size: 22)
                        Text(v.name).font(.system(size: 12.5, weight: .semibold))
                    }
                    v.view
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zCard()
                .tint(hue.base)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(LinearGradient(colors: [ZTheme.navyTop.opacity(0.92), ZTheme.navyBottom.opacity(0.97)],
                                   startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }

    private var quickViews: [(id: String, name: String, symbol: String, view: AnyView)] {
        manager.types.compactMap { t in
            guard let m = manager.running[t.id], let v = m.quickView() else { return nil }
            return (t.id, t.name, t.symbol, v)
        }
    }
}

struct CircleIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hover ? 0.18 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Cửa sổ Cài đặt

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(_ selection: String = "general") {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "zMac"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(ZTheme.navy)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.minSize = NSSize(width: 700, height: 480)
            let host = NSHostingController(rootView: SettingsRoot(selection: selection))
            // Không để cửa sổ tự giãn theo chiều cao "lý tưởng" của Form (có thể cao cả màn hình).
            host.sizingOptions = []
            w.contentViewController = host
            w.setContentSize(NSSize(width: 780, height: 560))
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
    @State var selection: String
    var manager = ModuleManager.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ZBackdrop())
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .tint(ZTheme.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                ZBrandMark(size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text("zMac").font(.system(size: 14, weight: .bold))
                    Text(L("Phiên bản ", "Version ") + Self.version)
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 8).padding(.top, 40).padding(.bottom, 12)

            row("general", L("Chung", "General"), "gearshape.fill", ZTheme.slate, running: nil)
            row("performance", L("Hiệu năng", "Performance"), "gauge.with.dots.needle.67percent", ZTheme.slate, running: nil)

            Text(L("Tính năng", "Features"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
            ForEach(manager.types.map { ModuleRef($0) }) { ref in
                row(ref.id, ref.type.name, ref.type.symbol, ZTheme.hue(ref.id),
                    running: ref.type.unavailableReason != nil ? nil : manager.running[ref.id] != nil)
                    .opacity(ref.type.unavailableReason == nil ? 1 : 0.45)
            }
            Spacer(minLength: 12)
            Text(L("\(manager.running.count)/\(manager.types.count) tính năng đang chạy",
                   "\(manager.running.count)/\(manager.types.count) features running"))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 10).padding(.bottom, 16)
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.2))
    }

    private func row(_ id: String, _ title: String, _ symbol: String, _ hue: ZTheme.Hue, running: Bool?) -> some View {
        let selected = selection == id
        return Button { selection = id } label: {
            HStack(spacing: 10) {
                ZTile(symbol: symbol, hue: hue, size: 20)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
                Spacer()
                if let running {
                    Circle().fill(running ? ZTheme.green.light : Color.white.opacity(0.18)).frame(width: 6, height: 6)
                        .help(running ? L("Đang chạy", "Running") : L("Đang tắt", "Off"))
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.11 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case "general": GeneralPane()
        case "performance": PerformancePane()
        case let id:
            if let t = manager.types.first(where: { $0.id == id }) { ModulePane(type: t) } else { GeneralPane() }
        }
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

struct ModuleRef: Identifiable {
    let type: any ZModule.Type
    let id: String
    @MainActor init(_ t: any ZModule.Type) { type = t; id = t.id }
}

/// Đầu trang: ô icon lớn, tên, dòng phụ theo màu, mô tả, và điều khiển bên phải (nếu có).
struct PaneHeader<Trailing: View>: View {
    let symbol: String
    let hue: ZTheme.Hue
    let title: String
    var subtitle: String?
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(alignment: .center, spacing: 12) {
            ZTile(symbol: symbol, hue: hue, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(hue.light)
                }
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
        .background {
            ZStack {
                shape.fill(.white.opacity(0.05))
                RadialGradient(colors: [hue.base.opacity(0.24), .clear], center: .topLeading, startRadius: 0, endRadius: 300)
                    .clipShape(shape)
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 2)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(symbol: String, hue: ZTheme.Hue, title: String, subtitle: String? = nil, detail: String? = nil) {
        self.init(symbol: symbol, hue: hue, title: title, subtitle: subtitle, detail: detail) { EmptyView() }
    }
}

struct ModulePane: View {
    let type: any ZModule.Type
    var manager = ModuleManager.shared

    var body: some View {
        let hue = ZTheme.hue(type.id)
        VStack(spacing: 0) {
            PaneHeader(symbol: type.symbol, hue: hue, title: type.name,
                       subtitle: L("Thay cho ", "Replaces ") + type.replaces, detail: type.summary) {
                if type.unavailableReason == nil {
                    Toggle("", isOn: Binding(
                        get: { manager.running[type.id] != nil },
                        set: { manager.setEnabled(type, $0) }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                }
            }
            if manager.running[type.id] != nil {
                ConflictBanner(apps: manager.runningConflicts(type.id))
            }
            if let reason = type.unavailableReason {
                Placeholder(symbol: "exclamationmark.triangle", hue: hue, text: reason)
            } else if let m = manager.running[type.id] {
                m.settingsView()
            } else {
                Placeholder(symbol: "power", hue: hue,
                            text: L("Tính năng đang tắt nên không tốn tài nguyên. Bật công tắc ở trên để dùng và chỉnh cài đặt.",
                                    "This feature is off and uses no resources. Turn on the switch above to use and configure it."))
            }
        }
        .tint(hue.base)
        .id(type.id)
    }
}

/// Cảnh báo app gốc vẫn đang chạy, kèm nút thoát nó.
struct ConflictBanner: View {
    @State var apps: [NSRunningApplication]
    /// Trong Form (trang Chung): không vẽ thẻ riêng.
    var inForm = false

    var body: some View {
        if !apps.isEmpty {
            let list = VStack(alignment: .leading, spacing: 8) {
                ForEach(apps, id: \.processIdentifier) { app in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ZTheme.orange.light)
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
            if inForm {
                list
            } else {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                list.padding(12)
                    .background(shape.fill(ZTheme.orange.base.opacity(0.12)))
                    .overlay(shape.strokeBorder(ZTheme.orange.base.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal, 20).padding(.top, 12)
            }
        }
    }
}

struct Placeholder: View {
    let symbol: String
    var hue: ZTheme.Hue = ZTheme.slate
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            ZTile(symbol: symbol, hue: hue, size: 40).opacity(0.55).saturation(0.4)
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Form chuẩn cho trang cài đặt module: nền trong suốt để thấy nền xanh than của cửa sổ.
func moduleForm<Content: View>(@ViewBuilder _ content: () -> Content) -> AnyView {
    AnyView(Form { content() }.formStyle(.grouped).scrollContentBackground(.hidden).zCompactForm())
}

// MARK: - Trang Chung

struct GeneralPane: View {
    var perms = Permissions.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = Lang.current
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: "gearshape.fill", hue: ZTheme.slate, title: L("Chung", "General"),
                       detail: L("Quyền, mở cùng máy, ngôn ngữ và thông tin máy này.",
                                 "Permissions, launch at login, language and this Mac."))
            form
        }
    }

    private var form: some View {
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
                    ConflictBanner(apps: clashes, inForm: true)
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
                .onChange(of: language) { _, v in LangState.shared.apply(v) }
            }
            UpdateSection()
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
        .scrollContentBackground(.hidden)
        .zCompactForm()
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(granted ? ZTheme.green.light : ZTheme.orange.light)
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
        VStack(spacing: 0) {
            PaneHeader(symbol: "gauge.with.dots.needle.67percent", hue: ZTheme.slate, title: L("Hiệu năng", "Performance"),
                       detail: L("Số liệu đo trong lúc trang này mở, nên CPU sẽ cao hơn lúc bình thường một chút.",
                                 "Measured while this page is open, so CPU reads slightly higher than usual."))
            HStack(spacing: 10) {
                StatCard(value: String(format: "%.1f MB", stats.footprintMB), label: L("Bộ nhớ", "Memory"), hue: ZTheme.blue)
                StatCard(value: String(format: "%.1f%%", cpuPercent), label: "CPU", hue: ZTheme.green)
                StatCard(value: String(format: "%.1f/s", wakeupsPerSec), label: L("Đánh thức CPU", "Idle wakeups"), hue: ZTheme.orange)
                StatCard(value: "\(manager.running.count)/\(manager.types.count)", label: L("Tính năng chạy", "Features on"),
                         hue: ZTheme.purple)
            }
            .padding(.horizontal, 20).padding(.top, 12)
            Form {
                Section(L("Vì sao nhẹ", "Why it's light")) {
                    Bullet(L("Một tiến trình thay cho 7 app: dùng chung runtime Swift, AppKit, SwiftUI.",
                             "One process instead of seven apps: one shared Swift, AppKit and SwiftUI runtime."))
                    Bullet(L("Tính năng tắt thì không được tạo: không phím tắt, không listener, không bộ nhớ.",
                             "Disabled features are never created: no shortcuts, listeners or memory."))
                    Bullet(L("Phím tắt Carbon thay vì CGEventTap: phím bạn gõ không đi qua zMac. Chỉ phím âm lượng, độ sáng đi qua một tap riêng để hiện trên notch.",
                             "Carbon hotkeys instead of a CGEventTap: your typing never passes through zMac. Only the volume and brightness keys go through a dedicated tap so they can show on the notch."))
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
            .scrollContentBackground(.hidden)
            .zCompactForm()
        }
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

struct StatCard: View {
    let value: String
    let label: String
    let hue: ZTheme.Hue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 17, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .zCard()
        .overlay(alignment: .topTrailing) {
            Circle().fill(hue.gradient).frame(width: 8, height: 8).padding(12)
        }
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

extension View {
    /// Form gọn: chữ 12 pt, công tắc và ô chọn cỡ nhỏ, như các trang cài đặt nhỏ gọn của macOS.
    func zCompactForm() -> some View {
        controlSize(.small).font(.system(size: 12))
    }
}
