import AppKit
import IOKit.ps
import Observation
import SwiftUI
import UniformTypeIdentifiers
import ZMacShared

// Notch kiểu NotchNook.
// - Lúc thu gọn: một panel đúng bằng notch, chỉ có NSTrackingArea. Không global mouse monitor, không timer.
//   Nhạc / HUD làm notch phình ra; mặc định chỉ sang trái vì bên phải notch là icon menu bar (sẽ bị che).
//   Cửa sổ vì thế không đối xứng quanh notch: SwiftUI vẽ trên một "canvas" luôn căn giữa notch (NSHostingView
//   đặt trong một view chứa), cửa sổ chỉ là khung cắt. Đổi khung cửa sổ không làm hình nhảy.
// - Rê chuột vào: phóng cửa sổ ra kích thước mở ngay (trong suốt) rồi animate hình đen trong SwiftUI.
//   Thu lại: animate hình nhỏ lại rồi mới thu cửa sổ. Cây view lúc mở bị gỡ khỏi view tree khi thu gọn.
// - Nhạc: distributed notification của Music / Spotify. Điều khiển bằng phím media (mọi trình phát).
// - Báo pin khi cắm sạc, cảnh báo pin yếu: IOPS run loop source (theo sự kiện).
// - Phím âm lượng / độ sáng: MediaKeyTap (chỉ NX_SYSDEFINED) chỉnh rồi hiện mức trên hai cánh, thay HUD macOS.

@MainActor @Observable
final class NotchModule: ZModule {
    static let id = "notch"
    static var name: String { "Notch" }
    static let replaces = "NotchNook"
    static let symbol = "rectangle.topthird.inset.filled"
    static var summary: String {
        L("Rê chuột vào notch để xem nhạc, lời bài hát, lịch, để tạm file. Âm lượng, độ sáng, pin hiện ở hai cánh notch.",
          "Hover the notch for music, lyrics, your calendar and a file shelf. Volume, brightness and battery show beside it.")
    }
    static var defaultEnabled: Bool { MainActor.assumeIsolated { Hardware.notchScreen != nil } }

    enum Tab { case nowPlaying, shelf, pet }

    // MARK: Cài đặt

    var showOnNonNotch = Pref.bool("notch.fakeNotch", false) {
        didSet { Pref.set("notch.fakeNotch", showOnNonNotch); rebuild() }
    }
    var chargingHUD = Pref.bool("notch.chargingHUD", true) {
        didSet { Pref.set("notch.chargingHUD", chargingHUD) }
    }
    /// Phím âm lượng / độ sáng hiện trên notch thay HUD macOS (cần quyền Trợ năng).
    var mediaKeysHUD = Pref.bool("notch.mediaKeys", true) {
        didSet { Pref.set("notch.mediaKeys", mediaKeysHUD); mediaKeysHUD ? startMediaKeys(prompt: true) : stopMediaKeys() }
    }
    var lowBatteryAlert = Pref.bool("notch.lowBattery", true) {
        didSet { Pref.set("notch.lowBattery", lowBatteryAlert); if !lowBatteryAlert { dismissAlert() } }
    }
    /// Mốc báo đầu tiên (%); sau đó báo thêm ở 10% và 5%.
    var lowBatteryLevel = Pref.int("notch.lowBatteryLevel", 20) {
        didSet { Pref.set("notch.lowBatteryLevel", lowBatteryLevel) }
    }
    var liveActivity = Pref.bool("notch.liveActivity", true) {
        didSet { Pref.set("notch.liveActivity", liveActivity); if !open { updateLayout() } }
    }
    /// Hiện hai bên notch, đối xứng (mặc định): trái nhạc, phải thú cưng. Tắt thì chỉ phình sang trái để không che
    /// icon menu bar sát notch.
    var wingsBothSides = Pref.bool("notch.wingsBothSides", true) {
        didSet { Pref.set("notch.wingsBothSides", wingsBothSides); if !open { updateLayout() } }
    }
    var hoverDelay = Pref.double("notch.hoverDelay", 0.08) {
        didSet { Pref.set("notch.hoverDelay", hoverDelay) }
    }
    /// Lời bài hát (lrclib.net). Tắt sẵn vì phải gọi mạng; bấm nút Lời trong trình phát sẽ hỏi bật.
    var lyricsEnabled = Pref.bool("notch.lyrics", false) {
        didSet {
            Pref.set("notch.lyrics", lyricsEnabled)
            if !lyricsEnabled { lyrics.clear() }
        }
    }
    /// Đang xem lời thay cho trình phát (nút Lời).
    var showLyrics = Pref.bool("notch.showLyrics", false) {
        didSet { Pref.set("notch.showLyrics", showLyrics) }
    }
    /// Bấm vào notch mới mở (thay vì rê chuột vào).
    var openOnClick = Pref.bool("notch.openOnClick", false) {
        didSet { Pref.set("notch.openOnClick", openOnClick) }
    }

    // MARK: Trạng thái (view đọc)

    /// Trạng thái logic: đang mở hay không.
    private(set) var open = false
    /// Trạng thái view: đổi trong withAnimation để nội dung và hình animate cùng nhau.
    private(set) var contentOpen = false
    private(set) var shapeSize: CGSize = .zero
    /// Tâm hình lệch so với tâm notch (âm = sang trái).
    private(set) var shapeOffset: CGFloat = 0
    var tab: Tab = .nowPlaying
    /// Thông báo ngắn hai bên notch lúc thu gọn (cắm sạc, âm lượng, độ sáng, hạn mức Claude đặt lại).
    private(set) var hud: NotchHUD?
    /// Thẻ nhắc thả xuống dưới notch (pin yếu).
    private(set) var alert: NotchAlert?
    private(set) var track: NowPlayingTrack?
    private(set) var shelf: [URL] = []
    private(set) var battery: BatterySnapshot?
    private(set) var dropTargeted = false
    private(set) var notchWidth: CGFloat = 0
    private(set) var notchHeight: CGFloat = 0
    private(set) var hasTarget = false
    /// Claude Code đang chờ người dùng duyệt: giữ notch mở tới khi trả lời xong.
    private(set) var claudeAttention = false
    /// Đã nhận phím âm lượng / độ sáng (có quyền Trợ năng).
    private(set) var mediaKeysActive = false

    // MARK: Nội bộ

    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var host: NotchHostingView?
    @ObservationIgnored private var container: NSView?
    /// Tâm ngang của notch và mép trên màn hình (toạ độ Cocoa toàn cục).
    @ObservationIgnored private var anchor = CGPoint.zero
    @ObservationIgnored private var expandWork: DispatchWorkItem?
    @ObservationIgnored private var collapseWork: DispatchWorkItem?
    @ObservationIgnored private var resizeWork: DispatchWorkItem?
    @ObservationIgnored private var hudWork: DispatchWorkItem?
    @ObservationIgnored private var alertWork: DispatchWorkItem?
    @ObservationIgnored private var keyTap: MediaKeyTap?
    @ObservationIgnored private var axObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPercent: Int?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var lastExternal: Bool?
    @ObservationIgnored private let nowPlaying = NowPlayingMonitor()
    @ObservationIgnored let lyrics = LyricsStore()

    init() {}

    func start() {
        loadShelf()
        battery = BatteryReader.snapshot()
        lastExternal = battery?.externalConnected
        lastPercent = battery?.percent
        nowPlaying.onChange = { [weak self] t in self?.trackChanged(t) }
        nowPlaying.start()
        startPower()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuild()
        if mediaKeysHUD { startMediaKeys(prompt: false) }
    }

    func stop() {
        stopMediaKeys()
        ModuleManager.shared.module(ClaudeModule.self)?.passAll()
        claudeAttention = false
        nowPlaying.stop()
        nowPlaying.onChange = nil
        stopPower()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for w in [expandWork, collapseWork, resizeWork, hudWork, alertWork] { w?.cancel() }
        expandWork = nil; collapseWork = nil; resizeWork = nil; hudWork = nil; alertWork = nil
        alert = nil
        closePanel()
        NotchIcons.cache.removeAll()
        NotchIcons.names.removeAll()
        lyrics.clear()
        track = nil
        hasTarget = false
    }

    // MARK: Kích thước

    var wingWidth: CGFloat { notchHeight + 14 }
    var showsLiveActivity: Bool { liveActivity && track?.isPlaying == true }

    /// Bên trái đủ chỗ cho cả hai thứ (ảnh bìa + sóng nhạc, hoặc icon + chữ HUD).
    var leftWingWidth: CGFloat { 2 * wingWidth - 14 }

    /// Thú cưng ngồi cạnh notch khi không có nhạc / HUD.
    var pet: PetModule? {
        guard let p = ModuleManager.shared.module(PetModule.self), p.showInNotch else { return nil }
        return p
    }
    /// Hai bên: thú cưng ngồi bên phải cả khi có nhạc. Chỉ bên trái: nhường chỗ cho nhạc.
    var showsPet: Bool { pet != nil && hud == nil && (wingsBothSides || !showsLiveActivity) }
    var petWingWidth: CGFloat { notchHeight + 20 }

    /// HUD có thanh mức (âm lượng, độ sáng): bên phải đủ chỗ cho thanh (44) và "100%" (to theo chiều cao notch).
    var levelWingWidth: CGFloat { (notchHeight * 2 + 40).rounded() }

    /// Phần phình ra hai bên notch lúc thu gọn.
    var collapsedExtents: (left: CGFloat, right: CGFloat) {
        if let hud {
            if hud.usesWideWings { return wingsBothSides ? (levelWingWidth, levelWingWidth) : (levelWingWidth + 40, 0) }
            return wingsBothSides ? (wingWidth, wingWidth) : (leftWingWidth, 0)
        }
        if wingsBothSides {
            // Đối xứng quanh notch: hai cánh luôn bằng nhau.
            guard showsLiveActivity || showsPet else { return (0, 0) }
            let w = showsPet ? petWingWidth : wingWidth
            return (w, w)
        }
        if showsLiveActivity { return (leftWingWidth, 0) }
        return showsPet ? (petWingWidth, 0) : (0, 0)
    }

    /// Module khác (thú cưng) đổi thứ hiện lúc thu gọn.
    func refreshCollapsed() {
        if tab == .pet && ModuleManager.shared.module(PetModule.self) == nil { tab = .nowPlaying }
        if !open { updateLayout() }
    }

    var collapsedSize: CGSize {
        if alert != nil { return alertSize }
        let e = collapsedExtents
        return CGSize(width: notchWidth + e.left + e.right, height: notchHeight)
    }

    var collapsedOffset: CGFloat {
        if alert != nil { return 0 }
        let e = collapsedExtents
        return (e.right - e.left) / 2
    }

    /// Thẻ nhắc thả xuống: rộng hơn notch một chút, cao thêm một hàng.
    var alertSize: CGSize { CGSize(width: max(notchWidth + 190, 380), height: notchHeight + 62) }

    /// Vùng SwiftUI vẽ: đối xứng quanh notch, đủ chứa mọi trạng thái.
    private var canvasSize: CGSize {
        let side = max((expandedSize.width - notchWidth) / 2, leftWingWidth, levelWingWidth + 40, (alertSize.width - notchWidth) / 2)
        return CGSize(width: notchWidth + 2 * side, height: max(expandedSize.height, notchHeight))
    }

    /// Khoảng ngang của hình so với tâm notch.
    private struct Span: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        var height: CGFloat

        init(size: CGSize, offset: CGFloat) {
            minX = offset - size.width / 2
            maxX = offset + size.width / 2
            height = size.height
        }

        func union(_ o: Span) -> Span {
            var u = self
            u.minX = min(minX, o.minX)
            u.maxX = max(maxX, o.maxX)
            u.height = max(height, o.height)
            return u
        }
    }

    var expandedSize: CGSize {
        let height = notchHeight + 150 + claudeExtraHeight
        // Có cột lịch bên phải: rộng hơn, hàng trên cũng đủ chỗ cho "5h ·· 7d ··".
        if showsCalendar { return CGSize(width: max(720, notchWidth + 500), height: height) }
        // Hàng trên bên phải có thêm "5h ·· 7d ··" thì nới rộng cho đủ chỗ.
        let extra: CGFloat = showsClaudeUsage ? 100 : 0
        return CGSize(width: max(540 + extra, notchWidth + 300 + extra), height: height)
    }

    /// Claude hỏi lại (câu hỏi dài, nhiều lựa chọn) hay xin duyệt kế hoạch: notch cao thêm cho đủ chữ.
    var claudeExtraHeight: CGFloat {
        guard let r = ModuleManager.shared.module(ClaudeModule.self)?.pending.first else { return 0 }
        if !r.questions.isEmpty { return 80 }
        return r.isPlan ? 60 : 0
    }

    /// Thẻ Claude đổi: đang mở thì đổi kích thước theo.
    func refreshExpanded() {
        if open { updateLayout() }
    }

    var calendar: CalendarModule? { ModuleManager.shared.module(CalendarModule.self) }
    var showsCalendar: Bool { calendar != nil }

    var showsClaudeUsage: Bool {
        guard let c = ModuleManager.shared.module(ClaudeModule.self), c.showUsage else { return false }
        return c.usage?.hasLimits == true
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
            // Không còn chỗ hiện thẻ duyệt: trả yêu cầu Claude về terminal.
            ModuleManager.shared.module(ClaudeModule.self)?.passAll()
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
        shapeOffset = collapsedOffset
        setWindow(Span(size: shapeSize, offset: shapeOffset))
        panel?.orderFrontRegardless()
        if claudeAttention { setOpen(true) }
    }

    private func makePanel() {
        let p = NotchPanel()
        let h = NotchHostingView(rootView: NotchRootView(model: self))
        h.sizingOptions = []   // không để SwiftUI tự đổi kích thước cửa sổ
        h.onEnter = { [weak self] in self?.mouseEntered() }
        h.onExit = { [weak self] in self?.mouseExited() }
        h.onMouseDown = { [weak self] in self?.clicked() }
        let c = FlippedView()
        c.addSubview(h)
        p.contentView = c
        panel = p
        host = h
        container = c
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil   // cắt vòng tham chiếu view -> module
        panel?.close()
        panel = nil
        host = nil
        container = nil
    }

    /// Đặt khung cửa sổ, rồi dời canvas để tâm canvas luôn trùng tâm notch trên màn hình.
    private func setWindow(_ span: Span) {
        guard let panel, let host, span.maxX > span.minX, span.height > 0 else { return }
        let minX = (anchor.x + span.minX).rounded()
        let f = NSRect(x: minX, y: anchor.y - span.height, width: (anchor.x + span.maxX).rounded() - minX, height: span.height)
        let canvas = canvasSize
        let hostFrame = NSRect(x: (anchor.x - canvas.width / 2).rounded() - f.minX, y: 0, width: canvas.width, height: canvas.height)
        if host.frame != hostFrame { host.frame = hostFrame }
        if panel.frame != f { panel.setFrame(f, display: true) }
        host.refreshTracking()
    }

    /// Đổi kích thước: cửa sổ nới ra ngay (đủ chứa cả cũ lẫn mới), hình animate, xong mới thu cửa sổ về đúng cỡ.
    private func updateLayout(animated: Bool = true) {
        guard panel != nil else { return }
        let target = open ? expandedSize : collapsedSize
        let targetOffset = open ? 0 : collapsedOffset
        let next = Span(size: target, offset: targetOffset)
        let union = Span(size: shapeSize, offset: shapeOffset).union(next)
        resizeWork?.cancel()
        setWindow(union)
        let isOpen = open
        let apply = {
            self.shapeSize = target
            self.shapeOffset = targetOffset
            self.contentOpen = isOpen
        }
        if animated {
            withAnimation(isOpen ? .spring(response: 0.36, dampingFraction: 0.82) : .easeInOut(duration: 0.22), apply)
        } else {
            apply()
        }
        if union != next {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setWindow(next) } }
            resizeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.4 : 0), execute: w)
        }
    }

    // MARK: Rê chuột

    /// Chế độ bấm để mở: bấm vào notch đang thu gọn thì mở.
    private func clicked() {
        guard openOnClick, !open else { return }
        collapseWork?.cancel()
        collapseWork = nil
        setOpen(true)
    }

    private func mouseEntered() {
        collapseWork?.cancel()
        collapseWork = nil
        guard !open, !openOnClick else { return }
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
        guard open, let panel, !claudeAttention else { return }
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
        if value {
            battery = BatteryReader.snapshot()
            // Mở notch là đã thấy thẻ nhắc: thu lại thì không thả xuống nữa.
            alertWork?.cancel()
            alert = nil
        }
        updateLayout()
    }

    // MARK: Claude Code

    var canShowClaude: Bool { panel != nil }

    func setClaudeAttention(_ on: Bool) {
        guard claudeAttention != on else { return }
        claudeAttention = on
        if on {
            ModuleManager.shared.module(PetModule.self)?.poke()
            expandWork?.cancel()
            collapseWork?.cancel()
            collapseWork = nil
            setOpen(true)
        } else if open {
            scheduleCollapse(after: 0.6)
        }
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
        if t?.title != track?.title || t?.isPlaying != track?.isPlaying {
            ModuleManager.shared.module(PetModule.self)?.poke()
        }
        track = t
        if !open && wasLive != showsLiveActivity { updateLayout() }
    }

    func playPause() {
        nowPlaying.send(.playPause)
        nowPlaying.togglePlayingOptimistic()
    }

    func nextTrack() { nowPlaying.send(.next) }

    var canSeek: Bool { nowPlaying.canSeek }
    func seek(to seconds: Double) { nowPlaying.seek(to: seconds) }
    func previousTrack() { nowPlaying.send(.previous) }

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
        if external, alert != nil { dismissAlert() }
        if chargingHUD, lastExternal == false, external, let b {
            showHUD(NotchHUD(symbol: "bolt.fill", text: "\(b.percent)%", color: ZTheme.green.light))
        }
        if lowBatteryAlert, !external, let b,
           LowBattery.crossed(from: lastPercent, to: b.percent, thresholds: LowBattery.thresholds(lowBatteryLevel)) != nil {
            showAlert(LowBattery.alert(percent: b.percent, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled))
        }
        lastExternal = external
        lastPercent = b?.percent
    }

    // MARK: Thẻ nhắc

    func showAlert(_ value: NotchAlert, seconds: Double = 7) {
        guard panel != nil, !open else { return }
        ModuleManager.shared.module(PetModule.self)?.poke()
        alert = value
        updateLayout()
        alertWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dismissAlert() } }
        alertWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func dismissAlert() {
        alertWork?.cancel()
        alertWork = nil
        guard alert != nil else { return }
        alert = nil
        if !open { updateLayout() }
    }

    // MARK: Phím âm lượng / độ sáng

    /// Cài tap nếu đã có quyền Trợ năng. Chưa có: `prompt` thì xin quyền; tap tự cài khi quyền được cấp.
    private func startMediaKeys(prompt: Bool) {
        if keyTap == nil {
            let t = MediaKeyTap()
            t.onPress = { [weak self] key, fine in self?.mediaKey(key, fine: fine) ?? false }
            keyTap = t
        }
        if keyTap?.start() == true {
            mediaKeysActive = true
            stopAXObserver()
            return
        }
        if prompt { Permissions.shared.requestAccessibility() }
        guard axObserver == nil else { return }
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // Thông báo đến trước khi TCC cập nhật xong.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    guard let self, self.mediaKeysHUD, self.keyTap?.isRunning == false else { return }
                    self.startMediaKeys(prompt: false)
                }
            }
        }
    }

    private func stopMediaKeys() {
        keyTap?.stop()
        keyTap = nil
        mediaKeysActive = false
        stopAXObserver()
    }

    private func stopAXObserver() {
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
    }


    /// Không có chỗ hiện HUD thì để macOS tự xử lý.
    private func mediaKey(_ key: MediaKeyEvent.Key, fine: Bool) -> Bool {
        guard panel != nil else { return false }
        let hud: NotchHUD?
        switch key {
        case .volumeUp, .volumeDown, .mute: hud = MediaKeyActions.volume(key, fine: fine)
        case .brightnessUp, .brightnessDown: hud = MediaKeyActions.brightness(key, fine: fine)
        }
        guard let hud else { return false }
        showHUD(hud, seconds: 1.6)
        return true
    }

    func showHUD(_ value: NotchHUD, seconds: Double = 2.5) {
        guard panel != nil else { return }
        // Bấm liền tay (âm lượng, độ sáng): chỉ đổi số, không chọc thú cưng mỗi lần.
        if hud?.level == nil || value.level == nil { ModuleManager.shared.module(PetModule.self)?.poke() }
        hud = value
        if !open { updateLayout() }
        hudWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hud = nil
                if !self.open { self.updateLayout() }
            }
        }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
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
                Toggle(L("Hiện app đang phát nhạc cạnh notch", "Show the playing app beside the notch"),
                       isOn: Binding(get: { self.liveActivity }, set: { self.liveActivity = $0 }))
                Picker(L("Lúc thu gọn, notch phình ra", "When closed, the notch extends"),
                       selection: Binding(get: { self.wingsBothSides }, set: { self.wingsBothSides = $0 })) {
                    Text(L("Hai bên, cân giữa", "Both sides, centered")).tag(true)
                    Text(L("Chỉ bên trái", "Left side only")).tag(false)
                }
                if wingsBothSides {
                    Text(L("Bên phải notch là icon menu bar nên cánh phải sẽ che các icon sát notch. Giữ ⌘ rồi kéo icon nào cần thấy ra xa notch.",
                           "Menu bar icons sit right of the notch, so the right side covers the ones closest to it. Hold ⌘ and drag any icon you need away from the notch."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(L("Mở notch", "Open the notch"),
                       selection: Binding(get: { self.openOnClick }, set: { self.openOnClick = $0 })) {
                    Text(L("Khi rê chuột vào", "On hover")).tag(false)
                    Text(L("Khi bấm vào", "On click")).tag(true)
                }
                if !openOnClick {
                    Picker(L("Chờ trước khi mở", "Delay before opening"),
                           selection: Binding(get: { self.hoverDelay }, set: { self.hoverDelay = $0 })) {
                        Text(L("Không chờ", "None")).tag(0.0)
                        Text("0,08 s").tag(0.08)
                        Text("0,2 s").tag(0.2)
                        Text("0,4 s").tag(0.4)
                    }
                }
            }
            Section(L("Âm lượng, độ sáng", "Volume and brightness")) {
                Toggle(L("Hiện trên notch thay HUD của macOS", "Show on the notch instead of the macOS HUD"),
                       isOn: Binding(get: { self.mediaKeysHUD }, set: { self.mediaKeysHUD = $0 }))
                if mediaKeysHUD && !mediaKeysActive {
                    HStack {
                        Label(L("Cần quyền Trợ năng để nhận phím", "Needs Accessibility to receive the keys"),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L("Cấp quyền", "Grant")) { Permissions.shared.requestAccessibility() }
                    }
                    .font(.callout)
                }
                Text(L("zMac chỉ nhận phím âm lượng và độ sáng, phím chữ không đi qua zMac. Phím độ sáng chỉnh màn hình đang có con trỏ chuột, kể cả màn ngoài (DDC hoặc làm tối bằng phần mềm). Giữ ⇧⌥ để chỉnh từng nấc nhỏ. Loa không có âm lượng phần cứng (TV qua HDMI) thì chỉnh bằng điều khiển của loa.",
                       "zMac only receives the volume and brightness keys; your typing never passes through it. Brightness keys adjust the screen under the pointer, external ones too (DDC or software dimming). Hold ⇧⌥ for fine steps. Outputs without hardware volume (a TV over HDMI) are set with their own remote."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Pin", "Battery")) {
                Toggle(L("Báo pin khi cắm sạc", "Show battery when plugging in"),
                       isOn: Binding(get: { self.chargingHUD }, set: { self.chargingHUD = $0 }))
                Toggle(L("Cảnh báo pin yếu", "Low battery warning"),
                       isOn: Binding(get: { self.lowBatteryAlert }, set: { self.lowBatteryAlert = $0 }))
                if lowBatteryAlert {
                    Picker(L("Báo lần đầu khi còn", "First warning at"),
                           selection: Binding(get: { self.lowBatteryLevel }, set: { self.lowBatteryLevel = $0 })) {
                        ForEach([30, 20, 15, 10], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Text(L("Sau đó báo thêm ở 10% và 5%. Chỉ báo khi đang dùng pin, cắm sạc là thẻ tự đóng.",
                           "Then again at 10% and 5%. Only on battery; plugging in dismisses it."))
                        .font(.caption).foregroundStyle(.secondary)
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
                Text(L("Đọc bài đang phát và ảnh bìa từ mọi trình phát, kể cả trình duyệt, qua một tiến trình nhỏ (khoảng 6 MB) chỉ chạy khi bật Notch. Nút phát, chuyển bài gửi thẳng tới trình phát đó.",
                       "Reads what's playing, with album art, from any player including browsers, through a small process (about 6 MB) that only runs while Notch is on. Play and skip go straight to that player."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Lời bài hát (nút Lời trong trình phát)", "Lyrics (Lyrics button in the player)"),
                       isOn: Binding(get: { self.lyricsEnabled }, set: { self.lyricsEnabled = $0 }))
                Text(L("Lời lấy từ lrclib.net (miễn phí, mã nguồn mở). zMac chỉ gửi tên bài, ca sĩ, album và độ dài, và chỉ khi đang xem lời. Lời có mốc thời gian sẽ chạy theo nhạc.",
                       "Lyrics come from lrclib.net (free and open source). zMac only sends the title, artist, album and length, and only while lyrics are showing. Time-synced lyrics follow the music."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NotchHUD: Equatable {
    var symbol: String
    var text: String
    var color: Color
    /// 0...1: vẽ thêm thanh mức (âm lượng, độ sáng).
    var level: Double?
    /// Chữ dài hơn số % (vd "Chỉnh trên TV"): cánh rộng như HUD có thanh mức.
    var wide = false

    var usesWideWings: Bool { level != nil || wide }
}

/// Thẻ nhắc thả xuống dưới notch.
struct NotchAlert: Equatable {
    var symbol: String
    var tint: Color
    var title: String
    /// Phần nổi bật cạnh tiêu đề ("10%").
    var value: String
    var detail: String
}

/// Cảnh báo pin yếu (hàm thuần, có test).
enum LowBattery {
    /// Mốc báo: mốc người dùng chọn, rồi 10% và 5%.
    static func thresholds(_ level: Int) -> [Int] {
        Set([level, 10, 5].filter { $0 > 0 && $0 <= max(level, 5) }).sorted(by: >)
    }

    /// Mốc vừa tụt qua (pin giảm từ trên mốc xuống bằng / dưới mốc). nil = không báo.
    static func crossed(from old: Int?, to new: Int, thresholds: [Int]) -> Int? {
        guard let old, new < old else { return nil }
        return thresholds.filter { new <= $0 && old > $0 }.min()
    }

    @MainActor static func alert(percent: Int, lowPower: Bool) -> NotchAlert {
        NotchAlert(symbol: percent <= 10 ? "battery.0percent" : "battery.25percent", tint: Color(hex: 0xFF5F57),
                   title: L("Pin yếu", "Low battery"), value: "\(percent)%",
                   detail: lowPower ? L("Đã bật Chế độ nguồn điện thấp. Cắm sạc sớm nhé.", "Low Power Mode is on. Plug in soon.")
                                    : L("Bật Chế độ nguồn điện thấp hoặc cắm sạc.", "Turn on Low Power Mode or plug in."))
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

/// Gốc toạ độ ở góc trên: canvas SwiftUI luôn bám mép trên cửa sổ.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// NSHostingView kèm một tracking area riêng để biết chuột vào / ra notch.
final class NotchHostingView: NSHostingView<NotchRootView> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMouseDown: (() -> Void)?
    private var area: NSTrackingArea?

    // Báo cú bấm rồi vẫn chuyển cho SwiftUI, để nút trong notch đang mở vẫn bấm được.
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

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
        // inVisibleRect: canvas rộng hơn cửa sổ, chỉ theo dõi phần thấy được.
        var opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if let w = window, w.frame.contains(NSEvent.mouseLocation) { opts.insert(.assumeInside) }
        let a = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
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

#if DEBUG
extension NotchModule {
    /// Chỉ cho `--render-ui`: dựng trạng thái notch với một bài mẫu, không mở panel thật.
    func preview(open: Bool, track: NowPlayingTrack?, hud: NotchHUD?, alert: NotchAlert? = nil,
                 notch: CGSize = CGSize(width: 185, height: 32)) {
        notchWidth = notch.width
        notchHeight = notch.height
        self.track = track
        self.hud = hud
        self.alert = alert
        self.open = open
        contentOpen = open
        shapeSize = open ? expandedSize : collapsedSize
        shapeOffset = open ? 0 : collapsedOffset
    }
}
#endif
