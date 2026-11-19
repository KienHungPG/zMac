import AppKit
import Observation
import QuartzCore
import SwiftUI

// Trình phát nhạc trên màn hình khoá (thuộc module Notch, dùng chung bài đang phát và lời).
// - Theo sự kiện: com.apple.screenIsLocked / screenIsUnlocked (distributed notification), màn hình ngủ / thức.
//   Không nghe gì khi tuỳ chọn đang Tắt.
// - Cửa sổ chỉ tồn tại khi đang khoá, có bài cần hiện và màn hình đang sáng. Mở khoá, màn hình ngủ hay hết bài
//   thì đóng cửa sổ, huỷ view, gỡ Space.
// - Cửa sổ thường không nằm trên màn hình khoá được: tạo một Space riêng bằng SkyLight, đặt mức tuyệt đối 400 (trên
//   lớp khoá) rồi chuyển cửa sổ vào đó (cách của SkyLightWindow, MIT). Thiếu API thì tuỳ chọn bị khoá lại.
// - Thanh tiến độ chạy bằng CABasicAnimation (WindowServer tự vẽ), lời đổi dòng bằng TimelineView(.explicit).

enum LockScreenStyle: String, CaseIterable, Identifiable {
    case off, compact, full

    var id: String { rawValue }

    var name: String {
        switch self {
        case .off: L("Tắt", "Off")
        case .compact: L("Gọn", "Compact")
        case .full: L("Trình phát đầy đủ", "Full player")
        }
    }

    var detail: String {
        switch self {
        case .off: L("Không hiện gì", "Shows nothing")
        case .compact: L("Widget nhỏ dưới đồng hồ", "A small widget under the clock")
        case .full: L("Ảnh bìa lớn và lời", "Big artwork and lyrics")
        }
    }
}

enum LockScreenWhen: String, CaseIterable, Identifiable {
    case playing, paused

    var id: String { rawValue }

    var name: String {
        switch self {
        case .playing: L("Chỉ khi đang phát nhạc", "Only while music plays")
        case .paused: L("Cả khi đang tạm dừng", "Also when paused")
        }
    }
}

/// Hàm thuần (có test): có hiện không, đặt ở đâu.
enum LockScreenLayout {
    static func shows(style: LockScreenStyle, when: LockScreenWhen, track: NowPlayingTrack?) -> Bool {
        shows(style: style, when: when, hasTrack: !(track?.title.isEmpty ?? true), playing: track?.isPlaying == true)
    }

    static func shows(style: LockScreenStyle, when: LockScreenWhen, hasTrack: Bool, playing: Bool) -> Bool {
        guard style != .off, hasTrack else { return false }
        return playing || when == .paused
    }

    /// Căn giữa màn hình chính, mép trên cách đỉnh màn hình 27% chiều cao (tối thiểu 230 pt): ngay dưới đồng hồ.
    static func frame(size: CGSize, screen: CGRect) -> CGRect {
        let top = screen.maxY - max(screen.height * 0.27, 230)
        return CGRect(x: (screen.midX - size.width / 2).rounded(), y: (top - size.height).rounded(),
                      width: size.width, height: size.height)
    }
}

// MARK: - Space trên màn hình khoá (SkyLight)

/// Một Space riêng nằm trên lớp khoá. Tạo khi cần hiện, huỷ ngay khi mở khoá.
@MainActor
final class LockScreenSpace {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetLevelFn = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias DestroyFn = @convention(c) (Int32, UInt64) -> Void

    private static let sky = PrivateAPI.skyLight
    private static let mainConnection = PrivateAPI.sym(sky, "SLSMainConnectionID", MainConnectionFn.self)
    private static let create = PrivateAPI.sym(sky, "SLSSpaceCreate", CreateFn.self)
    private static let setLevel = PrivateAPI.sym(sky, "SLSSpaceSetAbsoluteLevel", SetLevelFn.self)
    private static let showSpaces = PrivateAPI.sym(sky, "SLSShowSpaces", SpacesFn.self)
    private static let hideSpaces = PrivateAPI.sym(sky, "SLSHideSpaces", SpacesFn.self)
    private static let addWindows = PrivateAPI.sym(sky, "SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindowsFn.self)
    private static let destroySpace = PrivateAPI.sym(sky, "SLSSpaceDestroy", DestroyFn.self)

    /// Mức tuyệt đối của Space: 400 nằm trên màn hình khoá (300) và hộp mật khẩu (200).
    private static let level: Int32 = 400

    /// Đủ API để hiện trên màn hình khoá và gỡ đi sau đó.
    static var available: Bool {
        mainConnection != nil && create != nil && setLevel != nil && showSpaces != nil && hideSpaces != nil
            && addWindows != nil && destroySpace != nil
    }

    private var cid: Int32 = 0
    private var space: UInt64 = 0

    /// Đưa cửa sổ (đã có windowNumber) vào Space trên màn hình khoá.
    func attach(_ window: NSWindow) -> Bool {
        guard Self.available, let mainConnection = Self.mainConnection, let create = Self.create,
              let setLevel = Self.setLevel, let showSpaces = Self.showSpaces, let addWindows = Self.addWindows,
              window.windowNumber > 0 else { return false }
        if space == 0 {
            cid = mainConnection()
            space = create(cid, 1, 0)
            guard space != 0 else { return false }
            setLevel(cid, space, Self.level)
            showSpaces(cid, [NSNumber(value: space)] as CFArray)
        }
        addWindows(cid, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        return true
    }

    /// Ẩn rồi huỷ Space (gọi sau khi đã đóng cửa sổ).
    func detach() {
        guard space != 0 else { return }
        Self.hideSpaces?(cid, [NSNumber(value: space)] as CFArray)
        Self.destroySpace?(cid, space)
        space = 0
    }
}

// MARK: - Cửa sổ

@MainActor
final class LockScreenPlayer {
    private weak var model: NotchModule?
    private var distributed: [NSObjectProtocol] = []
    private var workspace: [NSObjectProtocol] = []
    private var locked = false
    private var screenAsleep = false
    private var panel: NSPanel?
    private let space = LockScreenSpace()

    init(model: NotchModule) { self.model = model }

    func start() {
        guard distributed.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributed.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.locked = value
                    self?.update()
                }
            })
        }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            workspace.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenAsleep = value
                    self?.update()
                }
            })
        }
    }

    func stop() {
        distributed.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        workspace.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributed = []
        workspace = []
        locked = false
        close()
    }

    /// Gọi khi khoá / mở khoá, đổi bài, đổi tuỳ chọn.
    func update() {
        guard let model else { return }
        let want = locked && !screenAsleep
            && LockScreenLayout.shows(style: model.lockScreenStyle, when: model.lockScreenWhen, track: model.track)
        if want { show(model) } else { close() }
    }

    private func show(_ model: NotchModule) {
        if let panel {
            place(panel)
            return
        }
        guard LockScreenSpace.available else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: Int(Int32.max) - 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.canBecomeVisibleWithoutLogin = true
        // Không bao giờ thành key window: phím gõ vẫn vào ô mật khẩu.
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: LockScreenWidgetView(model: model))
        place(p)
        guard space.attach(p) else {
            p.contentView = nil
            p.close()
            space.detach()
            log.error("màn hình khoá: không đưa được cửa sổ lên màn hình khoá")
            return
        }
        p.orderFrontRegardless()
        panel = p
        log.notice("màn hình khoá: hiện trình phát")
    }

    private func place(_ p: NSPanel) {
        guard let host = p.contentView, let screen = NSScreen.screens.first else { return }
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let frame = LockScreenLayout.frame(size: size, screen: screen.frame)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }

    private func close() {
        guard let p = panel else { return }
        p.orderOut(nil)
        p.contentView = nil
        p.close()
        panel = nil
        space.detach()
        log.notice("màn hình khoá: đóng trình phát")
    }
}

// MARK: - View

struct LockScreenWidgetView: View {
    let model: NotchModule

    var body: some View {
        Group {
            if let t = model.track {
                if model.lockScreenStyle == .full {
                    LockScreenPlayerView(model: model, track: t)
                } else {
                    LockScreenCompactView(model: model, track: t)
                }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// Gọn: ảnh bìa nhỏ, tên bài, ca sĩ, sóng nhạc và nút phát.
struct LockScreenCompactView: View {
    let model: NotchModule
    let track: NowPlayingTrack

    var body: some View {
        let tint = ArtworkColor.of(track.artwork)
        HStack(spacing: 11) {
            NotchArtwork(track: track, size: 42, corner: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(NotchNowPlayingView.subtitle(track))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)
            PlayingBars(color: NSColor(tint), playing: track.isPlaying)
                .frame(width: 13, height: 12)
                .opacity(track.isPlaying ? 1 : 0.5)
            NotchControl(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 13) { model.playPause() }
        }
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 9)
        .lockScreenGlass(radius: 18, artwork: nil)
    }
}

/// Đầy đủ: ảnh bìa lớn, tiến độ, nút điều khiển, và lời (nếu đã bật lời bài hát).
struct LockScreenPlayerView: View {
    let model: NotchModule
    let track: NowPlayingTrack

    var body: some View {
        let tint = ArtworkColor.of(track.artwork)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                NotchArtwork(track: track, size: 108, corner: 16)
                    .shadow(color: tint.opacity(track.artwork == nil ? 0 : 0.5), radius: 18, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.system(size: 17, weight: .bold)).lineLimit(2)
                    Text(NotchNowPlayingView.subtitle(track))
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    Spacer(minLength: 6)
                    LockProgressBar(track: track, tint: tint).frame(height: 4)
                    HStack(spacing: 22) {
                        NotchControl(symbol: "backward.fill", size: 15) { model.previousTrack() }
                        Button { model.playPause() } label: {
                            Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(.white))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        NotchControl(symbol: "forward.fill", size: 15) { model.nextTrack() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 108)
            }
            if model.lyricsEnabled { lyrics }
        }
        .padding(16)
        .frame(width: 420)
        .lockScreenGlass(radius: 24, artwork: track.artwork)
    }

    /// Chiều cao cố định để cửa sổ không đổi cỡ khi lời tải xong.
    private var lyrics: some View {
        Group {
            switch model.lyrics.state {
            case .found(.synced(let lines)): SyncedLyricsView(lines: lines, track: track)
            case .found(.plain(let text)):
                Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(4)
            case .found(.instrumental): message("♪ " + L("Bài không lời", "Instrumental"))
            case .idle, .loading: message(L("Đang tìm lời…", "Finding lyrics…"))
            case .notFound: message(L("Không tìm thấy lời cho bài này", "No lyrics found for this track"))
            case .failed: message(L("Không tải được lời (mất mạng?)", "Couldn't load lyrics (offline?)"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 84, alignment: .top)
        .task(id: LyricsStore.key(track)) { await model.lyrics.load(for: track) }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
    }
}

private extension View {
    /// Kính mờ của macOS, phủ tối; có ảnh bìa thì trải màu ảnh (làm mờ) ra nền.
    func lockScreenGlass(radius: CGFloat, artwork: NSImage?) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            ZStack {
                VisualEffectBlur(material: .hudWindow)
                // Ảnh nằm trong overlay của một khung đúng bằng thẻ: ảnh .fill không làm nền to ra, cắt gọn theo thẻ.
                Color.clear.overlay {
                    if let artwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                            .blur(radius: 40).saturation(1.3).opacity(0.45)
                    }
                }
                Color.black.opacity(0.28)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

/// Thanh tiến độ bằng Core Animation: đặt mức hiện tại rồi để WindowServer kéo dần tới cuối bài.
/// Không TimelineView, không vẽ lại mỗi giây (màn hình khoá có thể hiện hàng giờ).
struct LockProgressBar: NSViewRepresentable {
    let track: NowPlayingTrack
    let tint: Color

    func makeNSView(context: Context) -> LockProgressView { LockProgressView() }
    func updateNSView(_ v: LockProgressView, context: Context) { v.set(track, color: NSColor(tint)) }
}

final class LockProgressView: NSView {
    private let fill = CALayer()
    private var track: NowPlayingTrack?
    private var color = NSColor.white

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        fill.anchorPoint = .zero
        fill.position = .zero
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { nil }

    func set(_ t: NowPlayingTrack, color c: NSColor) {
        track = t
        color = c
        restart()
    }

    override func layout() {
        super.layout()
        restart()
    }

    private func restart() {
        fill.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color.cgColor
        let w = bounds.width, h = bounds.height
        guard let t = track, let d = t.duration, d > 0, let e = t.elapsed(at: Date()), w > 0 else {
            fill.bounds = .zero
            CATransaction.commit()
            return
        }
        let frac = min(max(e / d, 0), 1)
        fill.bounds = CGRect(x: 0, y: 0, width: w * frac, height: h)
        CATransaction.commit()
        guard t.isPlaying, frac < 1 else { return }
        let a = CABasicAnimation(keyPath: "bounds.size.width")
        a.fromValue = w * frac
        a.toValue = w
        a.duration = d - e
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        fill.add(a, forKey: "progress")
    }
}

// MARK: - Cài đặt

extension NotchModule {
    var lockScreenSettings: some View {
        Section(L("Trên màn hình khoá", "On the lock screen")) {
            ZChoiceTiles(options: LockScreenStyle.allCases,
                         selection: Binding(get: { self.lockScreenStyle }, set: { self.lockScreenStyle = $0 }),
                         hue: ZTheme.hue(Self.id), title: { $0.name }, detail: { $0.detail }) { LockScreenSketch(style: $0) }
                .disabled(!LockScreenSpace.available)
            Picker(L("Hiện khi", "Show"), selection: Binding(get: { self.lockScreenWhen }, set: { self.lockScreenWhen = $0 })) {
                ForEach(LockScreenWhen.allCases) { Text($0.name).tag($0) }
            }
            .disabled(lockScreenStyle == .off)
            if !LockScreenSpace.available {
                Text(L("macOS này không cho zMac hiện trên màn hình khoá (thiếu API SkyLight).",
                       "This macOS doesn't let zMac show on the lock screen (SkyLight API missing)."))
                    .font(.caption).foregroundStyle(ZTheme.orange.light)
            }
            Text(L("Ai nhìn màn hình khoá cũng thấy tên bài, ca sĩ, ảnh bìa (và lời nếu đã bật). Màn hình tắt hay mở khoá thì trình phát đóng lại, không tốn gì.",
                   "Anyone looking at the lock screen sees the title, artist and artwork (and lyrics if they're on). When the screen turns off or you unlock, the player closes and costs nothing."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Hình minh hoạ: nền màn hình khoá, đồng hồ, widget, ảnh đại diện.
private struct LockScreenSketch: View {
    let style: LockScreenStyle

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x5B7FDB), Color(hex: 0x9A78D2), Color(hex: 0xE09AA6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                Text("9:41").font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                switch style {
                case .off: EmptyView()
                case .compact:
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(ZTheme.orange.gradient).frame(width: 15, height: 15)
                        VStack(alignment: .leading, spacing: 3) {
                            Capsule().fill(.white.opacity(0.9)).frame(width: 34, height: 3)
                            Capsule().fill(.white.opacity(0.5)).frame(width: 24, height: 3)
                        }
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.32)))
                case .full:
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(ZTheme.orange.gradient).frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(.white.opacity(0.6)).frame(width: 44, height: 3)
                            Capsule().fill(.white.opacity(0.95)).frame(width: 60, height: 3.5)
                            Capsule().fill(.white.opacity(0.6)).frame(width: 38, height: 3)
                        }
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.26)))
                }
                Spacer(minLength: 0)
                Circle().fill(.white.opacity(0.8)).frame(width: 9, height: 9)
            }
            .padding(.top, 10).padding(.bottom, 12)
        }
    }
}
