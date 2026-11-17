#if DEBUG
import AppKit
import SwiftUI

/// Chỉ có trong bản debug: `zMac --render-ui THƯ_MỤC` vẽ các màn hình chính ra PNG mà không mở cửa sổ nào,
/// để xem giao diện khi sửa mà không phải chạy app. Module được tạo nhưng không start().
@MainActor
enum UIPreview {
    /// Đang vẽ xem trước: Pref.set bỏ qua, không ghi defaults.
    nonisolated(unsafe) static var active = false

    static func run(to dir: String) {
        active = true
        // --vi / --en: chụp giao diện theo ngôn ngữ đó (mặc định theo máy).
        if CommandLine.arguments.contains("--vi") { LangState.shared.previewSet(vietnamese: true) }
        if CommandLine.arguments.contains("--en") { LangState.shared.previewSet(vietnamese: false) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let manager = ModuleManager.shared
        manager.attachForPreview()
        manager.module(ClaudeModule.self)?.previewUsage()
        manager.module(CalendarModule.self)?.previewSample()

        for sel in ["general", "performance"] + manager.types.map({ $0.id }) {
            save("settings-\(sel)", SettingsRoot(selection: sel), CGSize(width: 860, height: 620), to: out)
        }
        save("popover", QuickPanel(), nil, to: out)

        // Đổi ngôn ngữ phải vẽ lại ngay trên chính cửa sổ đang mở.
        let lang = LangState.shared.isVietnamese
        let host = NSHostingView(rootView: AnyView(SettingsRoot(selection: "general").environment(\.colorScheme, .dark)))
        snapshot(host, CGSize(width: 860, height: 300), to: out.appendingPathComponent("lang-before.png"))
        LangState.shared.previewSet(vietnamese: !lang)
        snapshot(host, CGSize(width: 860, height: 300), to: out.appendingPathComponent("lang-after.png"))
        LangState.shared.previewSet(vietnamese: lang)

        if let notch = manager.module(NotchModule.self) {
            let size = CGSize(width: notch.expandedSize.width + 160, height: notch.expandedSize.height + 40)
            notch.preview(open: true, track: sampleTrack, hud: nil)
            save("notch-open", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)

            // Ảnh đầu README: notch đang mở và HUD ⌥⇥ trên cùng một nền.
            let hud = SwitcherState()
            hud.items = sampleWindows
            hud.selected = 1
            save("readme-hero", ZStack(alignment: .top) {
                ZBackdrop()
                VStack(spacing: 70) {
                    NotchRootView(model: notch).frame(height: notch.expandedSize.height)
                    SwitcherView(state: hud, cardWidth: { 112 }, onSelect: { _ in })
                }
            }, CGSize(width: 1180, height: 410), to: out)
            if let claude = manager.module(ClaudeModule.self) {
                claude.previewRequests()
                save("notch-claude", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
                // Câu hỏi / kế hoạch làm notch cao thêm: dựng lại hình và khung ảnh theo kích thước mới.
                claude.previewQuestion()
                notch.preview(open: true, track: sampleTrack, hud: nil)
                let tall = CGSize(width: notch.expandedSize.width + 160, height: notch.expandedSize.height + 40)
                save("notch-claude-question", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, tall, to: out)
                claude.previewPlan()
                notch.preview(open: true, track: sampleTrack, hud: nil)
                save("notch-claude-plan", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, tall, to: out)
                claude.clearPreview()
            }
            notch.showLyrics = true
            notch.lyricsEnabled = false
            save("notch-lyrics-off", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.lyricsEnabled = true
            notch.lyrics.previewSet(.found(.synced(sampleLyrics)), for: sampleTrack)
            save("notch-lyrics", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.showLyrics = false
            notch.tab = .pet
            save("notch-pet", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.tab = .nowPlaying
            notch.preview(open: false, track: nil, hud: nil)
            save("notch-pet-wing", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.preview(open: false, track: sampleTrack, hud: nil)
            save("notch-live-pet", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.preview(open: false, track: sampleTrack, hud: nil)
            save("notch-live", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.preview(open: false, track: sampleTrack, hud: NotchHUD(symbol: "bolt.fill", text: "82%", color: ZTheme.green.light))
            save("notch-charging", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.preview(open: false, track: sampleTrack,
                          hud: NotchHUD(symbol: "speaker.wave.2.fill", text: "63%", color: .white, level: 0.625))
            save("notch-volume", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.preview(open: false, track: sampleTrack,
                          hud: NotchHUD(symbol: "tv", text: "Chỉnh trên TV", color: .white.opacity(0.85), wide: true))
            // Đúng notch MacBook Air M4 (209 × 38): số "100%" không được bị cắt.
            notch.preview(open: false, track: nil, hud: NotchHUD(symbol: "speaker.wave.3.fill", text: "100%", color: .white, level: 1),
                          notch: CGSize(width: 209, height: 38))
            save("notch-volume-100", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.wingsBothSides = false
            notch.preview(open: false, track: nil, hud: NotchHUD(symbol: "speaker.wave.3.fill", text: "100%", color: .white, level: 1),
                          notch: CGSize(width: 209, height: 38))
            save("notch-volume-100-left", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.wingsBothSides = true
            notch.preview(open: false, track: sampleTrack,
                          hud: NotchHUD(symbol: "tv", text: "Chỉnh trên TV", color: .white.opacity(0.85), wide: true))
            save("notch-volume-fixed", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.preview(open: false, track: nil, hud: NotchHUD(symbol: "sun.max.fill", text: "81%", color: .white, level: 0.8125))
            save("notch-brightness", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.wingsBothSides = false
            notch.preview(open: false, track: nil, hud: NotchHUD(symbol: "sun.max.fill", text: "81%", color: .white, level: 0.8125))
            save("notch-brightness-left", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.wingsBothSides = true
            notch.preview(open: false, track: nil, hud: nil, alert: LowBattery.alert(percent: 10, lowPower: false))
            save("notch-lowbattery", ZStack(alignment: .top) { ZBackdrop(); NotchRootView(model: notch) }, size, to: out)
            notch.preview(open: false, track: nil, hud: nil)
        }

        // Bảng các loài thú cưng và tư thế.
        let poses: [PetPose] = [.idle, .blink, .step(0), .step(1), .sleep]
        save("pets", VStack(alignment: .leading, spacing: 18) {
            ForEach(PetKind.allCases) { k in
                HStack(spacing: 22) {
                    Text(k.name).frame(width: 60, alignment: .leading)
                    ForEach(0..<poses.count, id: \.self) { i in PixelPet(kind: k, pose: poses[i], frame: i, pixel: 6) }
                }
            }
        }.padding(24).background(Color.black), nil, to: out)

        // Các khung Core Animation của từng vòng lặp (ảnh CGImage vẽ sẵn).
        save("pet-loops", VStack(alignment: .leading, spacing: 10) {
            ForEach([PetLoop.idle, .dance, .happy], id: \.stepDuration) { loop in
                HStack(spacing: 6) {
                    ForEach(Array(loop.steps.enumerated()), id: \.offset) { _, st in
                        if let img = PetArt.cat.image(st.pose, frame: st.frame, lift: st.lift, cell: 6) {
                            Image(decorative: img, scale: 2).overlay(Rectangle().stroke(.white.opacity(0.15)))
                        }
                    }
                }
            }
        }.padding(20).background(Color.black), nil, to: out)

        let state = SwitcherState()
        state.items = sampleWindows
        state.selected = 1
        save("switcher", SwitcherView(state: state, cardWidth: { 112 }, onSelect: { _ in }), nil, to: out)

        if let clip = manager.module(ClipboardModule.self) {
            clip.previewItems()
            save("clipboard", ClipboardView(model: clip).frame(width: 420, height: 440), nil, to: out)
        }
    }

    /// Một ô 40×40 ở góc dưới trái màn hình chỉ chạy đúng một hoạt hình, để đo CPU từ bên ngoài.
    static func benchAnimation(_ kind: String, seconds: Double) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let track = NowPlayingTrack(bundleID: "", title: "t", artist: "a", album: "", isPlaying: true,
                                    duration: 200, position: 10, updatedAt: Date(), artwork: nil)
        let view: AnyView = switch kind {
        case "waveform": AnyView(NotchWaveform(track: track, height: 32))
        case "pet": AnyView(PetLoopView(kind: .cat, loop: .idle, pixel: 2).frame(width: 28, height: 30))
        default: AnyView(Color.clear)
        }
        let w = NSPanel(contentRect: NSRect(x: 4, y: 4, width: 40, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.level = .statusBar
        w.contentView = NSHostingView(rootView: view.frame(width: 40, height: 40).background(Color.black))
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static let sampleLyrics: [LyricLine] = [
        .init(time: 50, text: "Đèn đường vàng như tơ trên phố vắng"),
        .init(time: 58, text: "Gió đưa câu hát qua những mái hiên"),
        .init(time: 66, text: "Mình đi qua nhau như hai bến cảng"),
        .init(time: 76, text: "Sóng vẫn hát về một nơi bình yên"),
        .init(time: 84, text: "Và ta lại về bên bến cũ"),
    ]

    private static func snapshot(_ host: NSView, _ size: CGSize, to file: URL) {
        host.frame = NSRect(origin: .zero, size: size)
        if host.window == nil {
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    private static func save(_ name: String, _ view: some View, _ size: CGSize?, to out: URL) {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        let s = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: s)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(ZTheme.navyBottom)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        print("  \(name).png")
    }

    private static var sampleArtwork: NSImage {
        NSImage(size: NSSize(width: 160, height: 160), flipped: false) { r in
            NSGradient(colors: [NSColor(ZTheme.orange.light), NSColor(ZTheme.purple.dark), NSColor(ZTheme.navyTop)])?
                .draw(in: r, angle: -45)
            return true
        }
    }

    private static var sampleTrack: NowPlayingTrack {
        NowPlayingTrack(bundleID: "com.apple.Music", title: "Quiet Harbor", artist: "Lumen Drift", album: "Night Ferries",
                        isPlaying: true, duration: 205, position: 72, updatedAt: Date(), artwork: sampleArtwork)
    }

    private static var sampleWindows: [SwitcherItem] {
        let apps = [("/Applications/Safari.app", "Safari", "zmac.vercel.app"),
                    ("/System/Applications/Notes.app", "Notes", "Việc tuần này"),
                    ("/System/Applications/Utilities/Terminal.app", "Terminal", "~/zMac — zsh"),
                    ("/System/Applications/Music.app", "Music", "Quiet Harbor"),
                    ("/System/Library/CoreServices/Finder.app", "Finder", "Downloads")]
        return apps.enumerated().map { i, a in
            SwitcherItem(id: CGWindowID(i + 1), pid: 1, element: AXUIElementCreateApplication(1), title: a.2,
                         appName: a.1, icon: NSWorkspace.shared.icon(forFile: a.0), isMinimized: i == 4, isHidden: false)
        }
    }
}
#endif
