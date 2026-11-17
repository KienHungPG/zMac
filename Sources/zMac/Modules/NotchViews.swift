import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZMacShared

// Giao diện notch. Lúc thu gọn chỉ còn hình đen (và cánh hai bên nếu có HUD / nhạc);
// cây view lúc mở nằm trong nhánh `if contentOpen` nên bị gỡ hẳn khi thu lại.

/// Mép trên phẳng với hai "tai" cong vào, đáy bo tròn như notch thật.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = min(top, r.width / 4), b = min(bottom, r.height / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    let model: NotchModule

    var body: some View {
        let size = model.shapeSize
        let open = model.contentOpen
        let shape = NotchShape(top: open ? 12 : 6, bottom: open ? 24 : 10)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                .frame(width: size.width, height: size.height)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .offset(x: model.shapeOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(get: { model.dropTargeted },
                                                         set: { model.setDropTargeted($0) })) { providers in
            model.handleDrop(providers)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        if model.contentOpen {
            // Nội dung đặt ở kích thước cuối, hình animate thì chỉ cắt bớt: không layout lại chữ mỗi khung hình.
            NotchExpandedView(model: model)
                .frame(width: model.expandedSize.width, height: model.expandedSize.height)
                .transition(.opacity)
        } else if let hud = model.hud {
            NotchWings(model: model) {
                Image(systemName: hud.symbol)
                    .font(.system(size: model.notchHeight * 0.42, weight: .semibold))
                    .foregroundStyle(hud.color)
            } right: {
                Text(hud.text)
                    .font(.system(size: model.notchHeight * 0.36, weight: .bold).monospacedDigit())
                    .foregroundStyle(hud.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .transition(.opacity)
        } else if model.wingsBothSides && (model.showsPet || model.showsLiveActivity) {
            // Hai bên, cân giữa: trái là nhạc (ảnh bìa, thêm sóng nhạc nếu bên phải có thú cưng), phải là thú cưng.
            let e = model.collapsedExtents
            let h = model.notchHeight
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    if model.showsLiveActivity, let track = model.track {
                        NotchArtwork(track: track, size: h * 0.62, corner: 6)
                        if model.showsPet { NotchWaveform(track: track, height: h * 0.8) }
                    }
                }
                .padding(.leading, model.showsPet ? 12 : 0)
                .frame(width: e.left, height: h)
                Color.clear.frame(width: model.notchWidth)
                Group {
                    if model.showsPet, let pet = model.pet {
                        // Chừa góc bo của notch bên phải.
                        PetWingView(pet: pet, height: h, musicPlaying: model.track?.isPlaying == true).padding(.trailing, 8)
                    } else if let track = model.track {
                        NotchWaveform(track: track, height: h)
                    }
                }
                .frame(width: e.right, height: h)
            }
            .transition(.opacity)
        } else if model.showsPet, let pet = model.pet {
            HStack(spacing: 0) {
                // Chừa góc bo của notch bên trái.
                PetWingView(pet: pet, height: model.notchHeight)
                    .padding(.leading, 8)
                    .frame(width: model.petWingWidth, height: model.notchHeight)
                Color.clear.frame(width: model.notchWidth)
            }
            .transition(.opacity)
        } else if model.showsLiveActivity, let track = model.track {
            NotchWings(model: model) {
                NotchArtwork(track: track, size: model.notchHeight * 0.62, corner: 6)
            } right: {
                NotchWaveform(track: track, height: model.notchHeight)
            }
            .transition(.opacity)
        }
    }
}

/// Sóng nhạc theo màu ảnh bìa, chỉ chuyển động khi đang phát.
/// Không dùng symbolEffect của SF Symbol: nó bắt zMac vẽ lại mỗi khung hình (đo được ~9% CPU suốt lúc nghe nhạc).
/// Bốn thanh co giãn bằng CABasicAnimation, WindowServer tự chạy, zMac không làm gì (0% CPU).
struct NotchWaveform: View {
    let track: NowPlayingTrack
    let height: CGFloat

    var body: some View {
        PlayingBars(color: NSColor(ArtworkColor.of(track.artwork)), playing: track.isPlaying)
            .frame(width: height * 0.42, height: height * 0.42)
    }
}

struct PlayingBars: NSViewRepresentable {
    let color: NSColor
    let playing: Bool

    func makeNSView(context: Context) -> PlayingBarsView { PlayingBarsView() }
    func updateNSView(_ view: PlayingBarsView, context: Context) { view.configure(color: color, playing: playing) }
}

final class PlayingBarsView: NSView {
    private let bars: [CALayer] = (0..<4).map { _ in CALayer() }
    private var playing: Bool?
    /// Chiều cao khi dừng, và nhịp co giãn (giây) của từng thanh.
    private static let rest: [CGFloat] = [0.45, 0.8, 0.6, 0.35]
    private static let periods: [Double] = [0.47, 0.61, 0.39, 0.54]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            bar.actions = ["transform": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let n = CGFloat(bars.count)
        let w = max(1.5, (bounds.width / (n * 1.7)).rounded(.down))
        let gap = (bounds.width - n * w) / (n - 1)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
            bar.cornerRadius = w / 2
        }
    }

    func configure(color: NSColor, playing: Bool) {
        for bar in bars { bar.backgroundColor = color.cgColor }
        guard playing != self.playing else { return }
        self.playing = playing
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            bar.transform = CATransform3DMakeScale(1, Self.rest[i], 1)
            guard playing else { continue }
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 0.25
            a.toValue = 1.0
            a.duration = Self.periods[i]
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.timeOffset = Double(i) * 0.13
            a.isRemovedOnCompletion = false
            bar.add(a, forKey: "bounce")
        }
    }
}

/// "Cánh" lúc thu gọn: hai bên notch, hoặc (chỉ bên trái) cả hai thứ nằm bên trái camera.
struct NotchWings<Left: View, Right: View>: View {
    let model: NotchModule
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        let e = model.collapsedExtents
        let h = model.notchHeight
        HStack(spacing: 0) {
            if model.wingsBothSides {
                left.frame(width: e.left, height: h)
                Color.clear.frame(width: model.notchWidth)
                right.frame(width: e.right, height: h)
            } else {
                HStack(spacing: 8) { left; right }
                    .frame(width: e.left, height: h)
                Color.clear.frame(width: model.notchWidth)
            }
        }
        .frame(width: model.notchWidth + e.left + e.right, height: h)
    }
}

// MARK: - Lúc mở

struct NotchExpandedView: View {
    let model: NotchModule

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                header
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 22)
                Color.clear.frame(width: model.notchWidth)
                status
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 22)
            }
            .frame(height: model.notchHeight)

            Group {
                if let claude, let request = claude.pending.first {
                    ClaudeRequestCard(module: claude, request: request, count: claude.pending.count)
                        .id(request.id)
                        .transition(.opacity)
                } else {
                    switch model.tab {
                    case .nowPlaying: NotchNowPlayingView(model: model)
                    case .lyrics: NotchLyricsView(model: model)
                    case .shelf: NotchShelfView(model: model)
                    case .pet:
                        if let pet = ModuleManager.shared.module(PetModule.self) {
                            PetTabView(pet: pet, musicPlaying: model.track?.isPlaying == true)
                        } else {
                            NotchNowPlayingView(model: model)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
    }

    /// Có yêu cầu Claude đang chờ thì thẻ duyệt thay cho tab nhạc / kệ.
    private var claude: ClaudeModule? {
        guard let c = ModuleManager.shared.module(ClaudeModule.self), !c.pending.isEmpty else { return nil }
        return c
    }

    @ViewBuilder private var header: some View {
        if claude != nil {
            Label("Claude Code", systemImage: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ZTheme.orange.light)
                .padding(.horizontal, 8)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.nowPlaying, symbol: "music.note", title: L("Nhạc", "Music"))
            if model.lyricsEnabled {
                tabButton(.lyrics, symbol: "quote.bubble", title: L("Lời", "Lyrics"))
            }
            tabButton(.shelf, symbol: "tray", title: L("Kệ", "Shelf") + (model.shelf.isEmpty ? "" : " \(model.shelf.count)"))
            if hasPetTab {
                tabButton(.pet, symbol: "pawprint.fill", title: ModuleManager.shared.module(PetModule.self)?.displayName ?? L("Thú cưng", "Pet"))
            }
        }
    }

    private var hasPetTab: Bool { ModuleManager.shared.module(PetModule.self) != nil }

    /// Ba tab trở lên thì tab không chọn chỉ còn icon, để hàng trên không chật.
    private func tabButton(_ tab: NotchModule.Tab, symbol: String, title: String) -> some View {
        let selected = model.tab == tab
        let compact = (model.lyricsEnabled || hasPetTab) && !selected
        return Button { withAnimation(.easeInOut(duration: 0.2)) { model.tab = tab } } label: {
            Label(title, systemImage: symbol)
                .labelStyle(TabLabelStyle(iconOnly: compact))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 10) {
            if model.showsClaudeUsage, let usage = ModuleManager.shared.module(ClaudeModule.self)?.usage {
                ClaudeUsageBadge(usage: usage)
            }
            if let keepAwake = ModuleManager.shared.module(KeepAwakeModule.self) {
                Button {
                    keepAwake.isActive ? keepAwake.deactivate() : keepAwake.activate(minutes: nil)
                } label: {
                    Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(keepAwake.isActive ? Color.orange : Color.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(keepAwake.isActive ? L("Đang giữ máy thức, bấm để tắt", "Keeping awake, click to stop")
                                         : L("Giữ máy thức", "Keep awake"))
            }
            if let b = model.battery {
                // Có hạn mức Claude thì chỉ còn icon pin (thanh menu đã có số %), để hàng trên không chật.
                HStack(spacing: 4) {
                    Image(systemName: Self.batterySymbol(b))
                    if !model.showsClaudeUsage { Text("\(b.percent)%").monospacedDigit() }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(b.externalConnected ? Color.green : Color.white.opacity(0.85))
                .help("\(b.percent)%")
            }
        }
    }

    static func batterySymbol(_ b: BatterySnapshot) -> String {
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct TabLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if !iconOnly { configuration.title }
        }
    }
}

struct NotchNowPlayingView: View {
    let model: NotchModule

    var body: some View {
        let tint = ArtworkColor.of(model.track?.artwork)
        HStack(spacing: 18) {
            Button { model.openPlayer() } label: {
                NotchArtwork(track: model.track, size: 92, corner: 16)
                    .shadow(color: tint.opacity(model.track?.artwork == nil ? 0 : 0.55), radius: 18)
            }
            .buttonStyle(.plain)
            .help(L("Mở trình phát", "Open player"))

            VStack(alignment: .leading, spacing: 2) {
                if let t = model.track {
                    Text(t.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(t.artist.isEmpty ? t.album : t.artist)
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                } else {
                    Text(L("Chưa có nhạc đang phát", "Nothing playing")).font(.system(size: 15, weight: .bold))
                    Text(L("Phát nhạc ở bất kỳ app nào, kể cả trình duyệt, bài sẽ hiện ở đây.",
                           "Play something in any app, browsers included, and it shows up here."))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                HStack(spacing: 14) {
                    NotchControl(symbol: "backward.fill", size: 15) { model.previousTrack() }
                    Button { model.playPause() } label: {
                        Image(systemName: model.track?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.white))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    NotchControl(symbol: "forward.fill", size: 15) { model.nextTrack() }
                    Spacer()
                }
                if let t = model.track { NotchProgress(track: t, tint: tint).padding(.top, 6) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .leading) {
            // Quầng sáng theo màu ảnh bìa.
            if model.track?.artwork != nil {
                RadialGradient(colors: [tint.opacity(0.32), .clear], center: .center, startRadius: 0, endRadius: 170)
                    .frame(width: 340, height: 260)
                    .offset(x: -110)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Màu chủ đạo của ảnh bìa (vẽ xuống 1×1 pixel), làm sáng lên để nổi trên nền đen. Chỉ tính lại khi đổi ảnh.
enum ArtworkColor {
    @MainActor private static var last: (image: NSImage, color: Color)?

    @MainActor static func of(_ image: NSImage?) -> Color {
        guard let image else { return ZTheme.green.light }
        if let last, last.image === image { return last.color }
        var color = ZTheme.green.light
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 4, bitsPerPixel: 32),
           let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
            NSGraphicsContext.restoreGraphicsState()
            if let c = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) {
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                color = Color(hue: Double(h), saturation: Double(min(max(s, 0.45), 0.85)), brightness: Double(max(b, 0.85)))
            }
        }
        last = (image, color)
        return color
    }
}

struct NotchArtwork: View {
    let track: NowPlayingTrack?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let art = track?.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else if let icon = NotchIcons.icon(for: track?.bundleID) {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(size * 0.1)
                    .background(Color.white.opacity(0.07))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Icon app theo bundle id, nhớ tạm trong lúc module chạy.
enum NotchIcons {
    @MainActor static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for bundleID: String?) -> NSImage? {
        guard let id = bundleID, !id.isEmpty else { return nil }
        if let c = cache[id] { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = img
        return img
    }
}

struct NotchControl: View {
    let symbol: String
    var size: CGFloat = 16
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 18, height: size + 14)
                .background(Circle().fill(.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Thanh tiến độ. TimelineView chỉ chạy khi notch đang mở và đang phát (bị huỷ cùng cây view khi thu gọn).
struct NotchProgress: View {
    let track: NowPlayingTrack
    var tint: Color = .white

    var body: some View {
        if let d = track.duration, d > 0, track.position != nil {
            if track.isPlaying {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in bar(track.elapsed(at: ctx.date) ?? 0, d) }
            } else {
                bar(track.elapsed(at: Date()) ?? 0, d)
            }
        } else if let d = track.duration, d > 0 {
            Text(Self.format(d)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
        }
    }

    private func bar(_ elapsed: Double, _ duration: Double) -> some View {
        HStack(spacing: 8) {
            Text(Self.format(elapsed))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.9), .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * min(max(elapsed / duration, 0), 1))
                }
            }
            .frame(height: 4)
            Text(Self.format(duration))
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
    }

    static func format(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Kệ file

struct NotchShelfView: View {
    let model: NotchModule

    var body: some View {
        if model.shelf.isEmpty {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.white.opacity(model.dropTargeted ? 0.8 : 0.3))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                        Text(L("Kéo file vào đây để để tạm", "Drop files here to park them"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
        } else {
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.shelf, id: \.self) { url in NotchShelfTile(url: url, model: model) }
                    }
                    .padding(.vertical, 2)
                }
                .overlay {
                    if model.dropTargeted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
                    }
                }
                HStack(spacing: 14) {
                    Text("\(model.shelf.count) file").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button { model.airDropShelf() } label: {
                        Label("AirDrop", systemImage: "airplayaudio").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    Button { model.clearShelf() } label: {
                        Label(L("Xoá hết", "Clear"), systemImage: "trash").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

struct NotchShelfTile: View {
    let url: URL
    let model: NotchModule
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 42, height: 42)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { model.removeFromShelf(url) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(L("Bỏ khỏi kệ", "Remove from shelf"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button(L("Mở", "Open")) { NSWorkspace.shared.open(url) }
            Button(L("Hiện trong Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button(L("Bỏ khỏi kệ", "Remove from shelf")) { model.removeFromShelf(url) }
        }
        .help(url.path)
    }
}
