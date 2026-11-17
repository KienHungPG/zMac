import AppKit
import IOKit.ps
import Observation
import SwiftUI
import UniformTypeIdentifiers
import ZMacShared

// Notch kiểu NotchNook.
// - Lúc thu gọn: một panel đúng bằng notch, chỉ có NSTrackingArea. Không global mouse monitor, không timer.
// - Rê chuột vào: phóng cửa sổ ra kích thước mở ngay (trong suốt) rồi animate hình đen trong SwiftUI.
//   Thu lại: animate hình nhỏ lại rồi mới thu cửa sổ. Cây view lúc mở bị gỡ khỏi view tree khi thu gọn.
// - Nhạc: distributed notification của Music / Spotify. Điều khiển bằng phím media (mọi trình phát).
// - Báo pin khi cắm sạc: IOPS run loop source (theo sự kiện).

@MainActor @Observable
final class NotchModule: ZModule {
    static let id = "notch"
    static var name: String { "Notch" }
    static let replaces = "NotchNook"
    static let symbol = "rectangle.topthird.inset.filled"
    static var summary: String {
        L("Rê chuột vào notch để xem nhạc đang phát, điều khiển nhạc, để tạm file. Báo pin khi cắm sạc.",
          "Hover the notch for now playing and media controls, and a shelf for files. Shows battery when you plug in.")
    }
    static var defaultEnabled: Bool { MainActor.assumeIsolated { Hardware.notchScreen != nil } }

    enum Tab { case nowPlaying, shelf }

    // MARK: Cài đặt

    var showOnNonNotch = Pref.bool("notch.fakeNotch", false) {
        didSet { Pref.set("notch.fakeNotch", showOnNonNotch); rebuild() }
    }
    var chargingHUD = Pref.bool("notch.chargingHUD", true) {
        didSet { Pref.set("notch.chargingHUD", chargingHUD) }
    }
    var liveActivity = Pref.bool("notch.liveActivity", true) {
        didSet { Pref.set("notch.liveActivity", liveActivity); if !open { updateLayout() } }
    }
    var hoverDelay = Pref.double("notch.hoverDelay", 0.08) {
        didSet { Pref.set("notch.hoverDelay", hoverDelay) }
    }

    // MARK: Trạng thái (view đọc)

    /// Trạng thái logic: đang mở hay không.
    private(set) var open = false
    /// Trạng thái view: đổi trong withAnimation để nội dung và hình animate cùng nhau.
    private(set) var contentOpen = false
    private(set) var shapeSize: CGSize = .zero
    var tab: Tab = .nowPlaying
    private(set) var hudPercent: Int?
    private(set) var track: NowPlayingTrack?
    private(set) var shelf: [URL] = []
    private(set) var battery: BatterySnapshot?
    private(set) var dropTargeted = false
    private(set) var notchWidth: CGFloat = 0
    private(set) var notchHeight: CGFloat = 0
    private(set) var hasTarget = false

    // MARK: Nội bộ

    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var host: NotchHostingView?
    /// Tâm ngang của notch và mép trên màn hình (toạ độ Cocoa toàn cục).
    @ObservationIgnored private var anchor = CGPoint.zero
    @ObservationIgnored private var expandWork: DispatchWorkItem?
    @ObservationIgnored private var collapseWork: DispatchWorkItem?
    @ObservationIgnored private var resizeWork: DispatchWorkItem?
    @ObservationIgnored private var hudWork: DispatchWorkItem?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var lastExternal: Bool?
    @ObservationIgnored private let nowPlaying = NowPlayingMonitor()

    init() {}

    func start() {
        loadShelf()
        battery = BatteryReader.snapshot()
        lastExternal = battery?.externalConnected
        nowPlaying.onChange = { [weak self] t in self?.trackChanged(t) }
        nowPlaying.start()
        startPower()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuild()
    }

    func stop() {
        nowPlaying.stop()
        nowPlaying.onChange = nil
        stopPower()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for w in [expandWork, collapseWork, resizeWork, hudWork] { w?.cancel() }
        expandWork = nil; collapseWork = nil; resizeWork = nil; hudWork = nil
        closePanel()
        NotchIcons.cache.removeAll()
        track = nil
        hasTarget = false
    }

    // MARK: Kích thước

    var wingWidth: CGFloat { notchHeight + 14 }
    var showsLiveActivity: Bool { liveActivity && track?.isPlaying == true }

    var collapsedSize: CGSize {
        let wide = hudPercent != nil || showsLiveActivity
        return CGSize(width: notchWidth + (wide ? 2 * wingWidth : 0), height: notchHeight)
    }

    var expandedSize: CGSize {
        CGSize(width: max(540, notchWidth + 300), height: notchHeight + 150)
    }

    /// Vị trí notch: màn có notch thật, hoặc notch giả ở giữa mép trên màn chính (nếu bật).
    private static func geometry(fake: Bool) -> (midX: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat)? {
        if let s = Hardware.notchScreen, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, r.minX > l.maxX {
            return ((l.maxX + r.minX) / 2, s.frame.maxY, r.minX - l.maxX, s.safeAreaInsets.top)
        }
        guard fake, let s = NSScreen.screens.first else { return nil }
        let menu = s.frame.maxY - s.visibleFrame.maxY
        return (s.frame.midX, s.frame.maxY, 180, menu > 0 ? menu : NSStatusBar.system.thickness + 2)
    }

    // MARK: Cửa sổ

    private func rebuild() {
        guard let g = Self.geometry(fake: showOnNonNotch) else {
            closePanel()
            hasTarget = false
            return
        }
        hasTarget = true
        notchWidth = g.width
        notchHeight = g.height
        anchor = CGPoint(x: g.midX, y: g.top)
        if panel == nil { makePanel() }
        for w in [expandWork, collapseWork, resizeWork] { w?.cancel() }
        open = false
        contentOpen = false
        shapeSize = collapsedSize
        setWindow(shapeSize)
        panel?.orderFrontRegardless()
    }

    private func makePanel() {
        let p = NotchPanel()
        let h = NotchHostingView(rootView: NotchRootView(model: self))
        h.sizingOptions = []   // không để SwiftUI tự đổi kích thước cửa sổ
        h.onEnter = { [weak self] in self?.mouseEntered() }
        h.onExit = { [weak self] in self?.mouseExited() }
        p.contentView = h
        panel = p
        host = h
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil   // cắt vòng tham chiếu view -> module
        panel?.close()
        panel = nil
        host = nil
    }

    private func setWindow(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let f = NSRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y - size.height,
                       width: size.width.rounded(), height: size.height)
        if panel.frame != f { panel.setFrame(f, display: true) }
        host?.refreshTracking()
    }

    /// Đổi kích thước: cửa sổ nới ra ngay (đủ chứa cả cũ lẫn mới), hình animate, xong mới thu cửa sổ về đúng cỡ.
    private func updateLayout(animated: Bool = true) {
        guard panel != nil else { return }
        let target = open ? expandedSize : collapsedSize
        let union = CGSize(width: max(shapeSize.width, target.width), height: max(shapeSize.height, target.height))
        resizeWork?.cancel()
        setWindow(union)
        let isOpen = open
        let apply = {
            self.shapeSize = target
            self.contentOpen = isOpen
        }
        if animated {
            withAnimation(isOpen ? .spring(response: 0.36, dampingFraction: 0.82) : .easeInOut(duration: 0.22), apply)
        } else {
            apply()
        }
        if union != target {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setWindow(target) } }
            resizeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.4 : 0), execute: w)
        }
    }

    // MARK: Rê chuột

    private func mouseEntered() {
        collapseWork?.cancel()
        collapseWork = nil
        guard !open else { return }
        expandWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setOpen(true) } }
        expandWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(hoverDelay, 0), execute: w)
    }

    private func mouseExited() {
        expandWork?.cancel()
        expandWork = nil
        if open { scheduleCollapse() }
    }

    private func scheduleCollapse(after delay: Double = 0.3) {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.collapseIfIdle() } }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func collapseIfIdle() {
        guard open, let panel else { return }
        // Đang giữ chuột (kéo file ra / vào): chờ thả xong. Chỉ chạy khi đang mở, không phải lúc rảnh.
        if NSEvent.pressedMouseButtons & 1 != 0 || dropTargeted {
            scheduleCollapse(after: 0.3)
            return
        }
        // Chuột vẫn trong panel (vd vừa thả file): chờ mouseExited.
        if panel.frame.contains(NSEvent.mouseLocation) {
            host?.refreshTracking()
            return
        }
        setOpen(false)
    }

    func setOpen(_ value: Bool) {
        guard open != value, panel != nil else { return }
        open = value
        if value { battery = BatteryReader.snapshot() }
        updateLayout()
    }

    // MARK: Kéo thả file

    func setDropTargeted(_ value: Bool) {
        guard dropTargeted != value else { return }
        dropTargeted = value
        if value {
            collapseWork?.cancel()
            tab = .shelf
            setOpen(true)
        } else if open {
            scheduleCollapse(after: 0.5)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = p.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.addToShelf(url) } }
            }
        }
        tab = .shelf
        return accepted
    }

    // MARK: Kệ file

    private func loadShelf() {
        let paths = UserDefaults.standard.stringArray(forKey: "notch.shelf") ?? []
        shelf = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if shelf.count != paths.count { saveShelf() }
    }

    private func saveShelf() {
        UserDefaults.standard.set(shelf.map(\.path), forKey: "notch.shelf")
    }

    func addToShelf(_ url: URL) {
        guard url.isFileURL else { return }
        let u = url.standardizedFileURL
        guard !shelf.contains(where: { $0.path == u.path }) else { return }
        shelf.append(u)
        saveShelf()
    }

    func removeFromShelf(_ url: URL) {
        shelf.removeAll { $0.path == url.path }
        saveShelf()
    }

    func clearShelf() {
        shelf.removeAll()
        saveShelf()
    }

    func airDropShelf() {
        let items = shelf.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !items.isEmpty, let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: items) else { return }
        s.perform(withItems: items)
    }

    // MARK: Nhạc

    private func trackChanged(_ t: NowPlayingTrack?) {
        let wasLive = showsLiveActivity
        track = t
        if !open && wasLive != showsLiveActivity { updateLayout() }
    }

    func playPause() {
        MediaKeys.send(MediaKeys.play)
        nowPlaying.togglePlayingOptimistic()
    }

    func nextTrack() { MediaKeys.send(MediaKeys.next) }
    func previousTrack() { MediaKeys.send(MediaKeys.previous) }

    func openPlayer() {
        guard let id = track?.bundleID, !id.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Nguồn điện

    private func startPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<NotchModule>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { m.powerChanged() }
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        powerSource = src
    }

    private func stopPower() {
        if let s = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            CFRunLoopSourceInvalidate(s)
        }
        powerSource = nil
    }

    private func powerChanged() {
        let b = BatteryReader.snapshot()
        battery = b
        let external = b?.externalConnected ?? false
        if chargingHUD, lastExternal == false, external, let b { showChargingHUD(b.percent) }
        lastExternal = external
    }

    private func showChargingHUD(_ percent: Int) {
        guard panel != nil else { return }
        hudPercent = percent
        if !open { updateLayout() }
        hudWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hudPercent = nil
                if !self.open { self.updateLayout() }
            }
        }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    // MARK: Cài đặt

    func settingsView() -> AnyView {
        moduleForm {
            Section {
                if Hardware.notchScreen == nil {
                    Text(L("Máy này không có notch. Bật tuỳ chọn dưới để hiện một notch giả ở giữa mép trên màn hình chính.",
                           "This Mac has no notch. Turn on the option below to show a virtual notch at the top center of the main screen."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle(L("Hiện notch giả trên màn hình không có notch", "Show a virtual notch on screens without one"),
                       isOn: Binding(get: { self.showOnNonNotch }, set: { self.showOnNonNotch = $0 }))
                Toggle(L("Báo pin khi cắm sạc", "Show battery when plugging in"),
                       isOn: Binding(get: { self.chargingHUD }, set: { self.chargingHUD = $0 }))
                Toggle(L("Hiện app đang phát nhạc hai bên notch", "Show the playing app beside the notch"),
                       isOn: Binding(get: { self.liveActivity }, set: { self.liveActivity = $0 }))
                Picker(L("Chờ trước khi mở", "Delay before opening"),
                       selection: Binding(get: { self.hoverDelay }, set: { self.hoverDelay = $0 })) {
                    Text(L("Không chờ", "None")).tag(0.0)
                    Text("0,08 s").tag(0.08)
                    Text("0,2 s").tag(0.2)
                    Text("0,4 s").tag(0.4)
                }
            }
            Section(L("Kệ file", "File shelf")) {
                LabeledContent(L("Đang để", "Holding"), value: "\(shelf.count) file")
                Button(L("Xoá kệ", "Clear shelf")) { self.clearShelf() }
                    .disabled(shelf.isEmpty)
                Text(L("Kéo file vào notch để để tạm, rồi kéo ra nơi khác khi cần. Kệ chỉ giữ đường dẫn, không chép file.",
                       "Drag files onto the notch to park them, then drag them out where you need them. The shelf only keeps paths, it never copies files."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Nhạc", "Music")) {
                Text(L("Tên bài lấy từ Apple Music và Spotify, theo sự kiện nên không tốn CPU. Nút phát, chuyển bài gửi phím media nên dùng được với mọi trình phát (cần quyền Trợ năng).",
                       "Track info comes from Apple Music and Spotify events, so it costs no CPU. Play and skip send media keys, so they work with any player (needs Accessibility)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Panel và view chứa

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// NSHostingView kèm một tracking area riêng để biết chuột vào / ra notch.
final class NotchHostingView: NSHostingView<NotchRootView> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?

    required init(rootView: NotchRootView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    /// Tạo lại tracking area theo bounds hiện tại. Chuột đang ở trong thì báo trước (assumeInside)
    /// để lần ra sau đó vẫn sinh mouseExited.
    func refreshTracking() {
        if let area { removeTrackingArea(area) }
        var opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        if let w = window, w.frame.contains(NSEvent.mouseLocation) { opts.insert(.assumeInside) }
        let a = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    // SwiftUI cũng có tracking area riêng (hover nút): chỉ phản ứng với area của mình.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === area { onEnter?() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === area { onExit?() }
    }
}
