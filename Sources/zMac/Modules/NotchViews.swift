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
        } else if let percent = model.hudPercent {
            NotchWings(notchWidth: model.notchWidth, wing: model.wingWidth, height: model.notchHeight) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: model.notchHeight * 0.42, weight: .semibold))
                    .foregroundStyle(.green)
            } right: {
                Text("\(percent)%")
                    .font(.system(size: model.notchHeight * 0.36, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
            .transition(.opacity)
        } else if model.showsLiveActivity, let track = model.track {
            NotchWings(notchWidth: model.notchWidth, wing: model.wingWidth, height: model.notchHeight) {
                NotchArtwork(track: track, size: model.notchHeight * 0.58, corner: 5)
            } right: {
                Image(systemName: "waveform")
                    .font(.system(size: model.notchHeight * 0.4, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.opacity)
        }
    }
}

/// Hai "cánh" hai bên camera lúc thu gọn.
struct NotchWings<Left: View, Right: View>: View {
    let notchWidth: CGFloat
    let wing: CGFloat
    let height: CGFloat
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: wing, height: height)
            Spacer(minLength: notchWidth)
            right.frame(width: wing, height: height)
        }
        .frame(width: notchWidth + 2 * wing, height: height)
    }
}

// MARK: - Lúc mở

struct NotchExpandedView: View {
    let model: NotchModule

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabs
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 22)
                Color.clear.frame(width: model.notchWidth)
                status
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 22)
            }
            .frame(height: model.notchHeight)

            Group {
                switch model.tab {
                case .nowPlaying: NotchNowPlayingView(model: model)
                case .shelf: NotchShelfView(model: model)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.nowPlaying, symbol: "music.note", title: L("Nhạc", "Music"))
            tabButton(.shelf, symbol: "tray", title: L("Kệ", "Shelf") + (model.shelf.isEmpty ? "" : " \(model.shelf.count)"))
        }
    }

    private func tabButton(_ tab: NotchModule.Tab, symbol: String, title: String) -> some View {
        let selected = model.tab == tab
        return Button { model.tab = tab } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 10) {
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
                HStack(spacing: 4) {
                    Image(systemName: Self.batterySymbol(b))
                    Text("\(b.percent)%").monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(b.externalConnected ? Color.green : Color.white.opacity(0.85))
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

struct NotchNowPlayingView: View {
    let model: NotchModule

    var body: some View {
        HStack(spacing: 16) {
            Button { model.openPlayer() } label: {
                NotchArtwork(track: model.track, size: 84, corner: 14)
            }
            .buttonStyle(.plain)
            .help(L("Mở trình phát", "Open player"))

            VStack(alignment: .leading, spacing: 3) {
                if let t = model.track {
                    Text(t.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(t.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if !t.album.isEmpty {
                        Text(t.album).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                } else {
                    Text(L("Chưa có nhạc đang phát", "Nothing playing")).font(.system(size: 14, weight: .semibold))
                    Text(L("Tên bài hiện với Apple Music và Spotify. Nút điều khiển dùng được với mọi trình phát.",
                           "Track names show for Apple Music and Spotify. Controls work with any player."))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    NotchControl(symbol: "backward.fill", size: 15) { model.previousTrack() }
                    NotchControl(symbol: model.track?.isPlaying == true ? "pause.fill" : "play.fill", size: 20) { model.playPause() }
                    NotchControl(symbol: "forward.fill", size: 15) { model.nextTrack() }
                    Spacer()
                }
                if let t = model.track { NotchProgress(track: t) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.85))
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
