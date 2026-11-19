import AppKit
import Foundation

// Nhạc đang phát cho notch, hoàn toàn theo sự kiện:
// - Chính: mediaremote-adapter (NowPlayingAdapter.swift) đọc mọi trình phát, kể cả trình duyệt, có ảnh bìa.
// - Đường lùi khi adapter không chạy được: Apple Music và Spotify phát distributed notification mỗi khi
//   đổi bài / phát / dừng; MediaRemote gọi thẳng chỉ còn đọc được trước macOS 15.4.
// - macOS chỉ cho biết MỘT trình phát (cái gần nhất giành quyền): video Brave đã tạm dừng vẫn giữ chỗ trong khi Spotify
//   phát tiếp. Vì vậy luôn nghe thêm Music / Spotify và ưu tiên trình đang phát thật (`pick`). Hai app này chỉ báo khi
//   đổi trạng thái, nên lúc trình macOS chọn không phát mà chưa biết gì về Music / Spotify đang mở thì hỏi nó một lần
//   bằng AppleScript (`PlayerScript.query`). Ảnh bìa Spotify trong trường hợp này chỉ có qua mạng (i.scdn.co), là tuỳ
//   chọn tắt sẵn (`fetchesSpotifyArtwork`).
// - Điều khiển: gửi lệnh qua adapter; đang hiện Music / Spotify mà macOS chọn app khác thì gửi AppleScript tới đúng app;
//   không có adapter thì giả lập phím media.

struct NowPlayingTrack: Equatable {
    var bundleID: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    /// Giây. Music và Spotify đều gửi độ dài bài.
    var duration: Double?
    /// Giây, tại thời điểm `updatedAt`. Chỉ Spotify gửi kèm.
    var position: Double?
    var updatedAt: Date
    /// Có khi adapter (hoặc MediaRemote trước macOS 15.4) trả về.
    var artwork: NSImage?

    func elapsed(at date: Date) -> Double? {
        guard let position else { return nil }
        let p = isPlaying ? position + date.timeIntervalSince(updatedAt) : position
        return min(max(p, 0), duration ?? p)
    }
}

@MainActor
final class NowPlayingMonitor: NSObject {
    var onChange: ((NowPlayingTrack?) -> Void)?
    private(set) var track: NowPlayingTrack?
    /// Bài macOS báo qua adapter (trình phát macOS đang chọn).
    private var adapterTrack: NowPlayingTrack?
    /// Bài Music / Spotify tự báo qua distributed notification, theo bundle id.
    private var appTracks: [String: NowPlayingTrack] = [:]
    /// Music / Spotify đã hỏi trạng thái từ lúc nó mở (xoá khi app thoát): sau đó notification giữ trạng thái mới.
    private var queried: Set<String> = []
    /// Tải ảnh bìa Spotify từ i.scdn.co khi nó không đến qua adapter. Tắt sẵn vì phải gọi mạng.
    var fetchesSpotifyArtwork = false {
        didSet { if fetchesSpotifyArtwork { fetchArtworkIfNeeded() } }
    }
    /// Bài Spotify đã xin ảnh (mỗi bài một lần, lỗi cũng không thử lại).
    private var artworkRequested: String?
    private var terminateObserver: NSObjectProtocol?
    private var mediaRemoteObserver: NSObjectProtocol?
    private var running = false
    private let adapter = NowPlayingAdapter()

    static let sources: [(notification: String, bundleID: String)] = [
        ("com.apple.Music.playerInfo", "com.apple.Music"),
        ("com.spotify.client.PlaybackStateChanged", "com.spotify.client"),
    ]

    func start() {
        guard !running else { return }
        running = true
        // Đường lùi luôn đăng ký (rẻ: chỉ thức khi Music / Spotify đổi trạng thái); bỏ qua khi adapter đang chạy.
        let center = DistributedNotificationCenter.default()
        for s in Self.sources {
            // deliverImmediately: app nền (accessory) vẫn nhận ngay, không bị gom lại.
            center.addObserver(self, selector: #selector(received(_:)), name: Notification.Name(s.notification),
                               object: nil, suspensionBehavior: .deliverImmediately)
        }
        // Music / Spotify thoát mà không kịp báo dừng: bỏ bài của nó, không thì notch giữ mãi bài "đang phát".
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            let bundle = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundle else { return }
                self.queried.remove(bundle)
                guard self.appTracks.removeValue(forKey: bundle) != nil else { return }
                if self.adapter.live { self.refresh() } else if self.track?.bundleID == bundle { self.set(nil) }
            }
        }
        adapter.onUpdate = { [weak self] t in
            guard let self else { return }
            self.adapterTrack = t
            if t?.isPlaying != true { self.queryUnknownApps() }
            self.refresh()
        }
        adapter.onExit = { [weak self] in self?.adapterFailed() }
        if adapter.start() { return }
        queryUnknownApps()
        startMediaRemote()
    }

    private func startMediaRemote() {
        guard running, mediaRemoteObserver == nil, MediaRemote.getInfo != nil else { return }
        // macOS 15.4+ chặn app ngoài Apple đọc MediaRemote: đăng ký nhận thông báo chỉ tốn lần đánh thức.
        // Khi đó chỉ thử đọc một lần mỗi khi đổi bài (lấy ảnh bìa nếu may mắn).
        if MediaRemote.readable, let register = MediaRemote.register {
            register(DispatchQueue.main)
            mediaRemoteObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fetchMediaRemote() }
            }
        }
        fetchMediaRemote()
    }

    /// Adapter thoát ngoài ý muốn (Apple chặn cách này, perl lỗi…): notch vẫn chạy bằng Music / Spotify.
    private func adapterFailed() {
        guard running else { return }
        adapterTrack = nil
        set(nil)
        startMediaRemote()
    }

    enum Control { case playPause, next, previous }

    /// Gửi qua adapter để tới đúng trình phát (kể cả trình duyệt); không có adapter thì giả lập phím media.
    func send(_ control: Control) {
        if let bundle = scriptTarget {
            PlayerScript.send(control, to: bundle)
            return
        }
        switch control {
        case .playPause: if !adapter.send(.togglePlayPause) { MediaKeys.send(MediaKeys.play) }
        case .next: if !adapter.send(.next) { MediaKeys.send(MediaKeys.next) }
        case .previous: if !adapter.send(.previous) { MediaKeys.send(MediaKeys.previous) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        adapter.stop()
        adapter.onUpdate = nil
        adapter.onExit = nil
        DistributedNotificationCenter.default().removeObserver(self)
        if let terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver) }
        terminateObserver = nil
        if let mediaRemoteObserver {
            NotificationCenter.default.removeObserver(mediaRemoteObserver)
            MediaRemote.unregister?()
        }
        mediaRemoteObserver = nil
        track = nil
        adapterTrack = nil
        appTracks = [:]
        queried = []
        artworkRequested = nil
    }

    /// Music / Spotify đang mở mà chưa biết trạng thái (phát từ trước khi zMac chạy): hỏi một lần.
    /// Lần đầu macOS hỏi quyền "zMac muốn điều khiển …"; từ chối thì chỉ còn chờ notification.
    private func queryUnknownApps() {
        let unknown = PlayerScript.bundles.subtracting(queried).filter { appTracks[$0] == nil }
        guard !unknown.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, unknown.contains(bundle) else { continue }
            queried.insert(bundle)
            PlayerScript.query(bundle) { [weak self] t in
                // Notification tới trước thì nó mới hơn.
                guard let self, self.running, self.appTracks[bundle] == nil, let t else { return }
                self.ingest(bundle, t)
            }
        }
    }

    /// Bài đang hiện là của Music / Spotify nhưng macOS đang chọn app khác: lệnh qua adapter (hay phím media) sẽ tới
    /// nhầm app đó, phải gửi AppleScript thẳng tới Music / Spotify.
    private var scriptTarget: String? {
        guard adapter.live, let t = track, t.bundleID != adapterTrack?.bundleID, appTracks[t.bundleID] != nil else { return nil }
        return t.bundleID
    }

    /// Tua được khi adapter chạy, hoặc khi đang hiện Spotify (nó báo vị trí, AppleScript tua được).
    var canSeek: Bool {
        guard track?.duration != nil, track?.position != nil else { return false }
        return scriptTarget != nil || adapter.canControl
    }

    /// Tua tới `seconds`: đổi vị trí ngay trên thanh, sự kiện thật từ trình phát sẽ ghi đè sau.
    func seek(to seconds: Double) {
        if let bundle = scriptTarget {
            PlayerScript.seek(seconds, in: bundle)
        } else if !adapter.seek(seconds) {
            return
        }
        guard var t = track else { return }
        t.position = seconds
        t.updatedAt = Date()
        set(t)
    }

    /// Bấm phát / dừng: đổi icon ngay, sự kiện thật từ trình phát sẽ ghi đè sau.
    func togglePlayingOptimistic() {
        guard var t = track else { return }
        if let e = t.elapsed(at: Date()) { t.position = e }
        t.isPlaying.toggle()
        t.updatedAt = Date()
        set(t)
    }

    // Distributed notification luôn tới trên main run loop.
    @objc nonisolated private func received(_ n: Notification) {
        let name = n.name.rawValue
        let info = n.userInfo ?? [:]
        MainActor.assumeIsolated { self.handle(name: name, info: info) }
    }

    private func handle(name: String, info: [AnyHashable: Any]) {
        guard let bundle = Self.sources.first(where: { $0.notification == name })?.bundleID else { return }
        ingest(bundle, Self.appTrack(info, bundle: bundle))
    }

    /// Trạng thái mới của Music / Spotify (notification hoặc AppleScript).
    private func ingest(_ bundle: String, _ new: NowPlayingTrack?) {
        var new = new
        // Cùng bài (chỉ đổi phát / dừng): giữ ảnh bìa đã tải.
        if let old = appTracks[bundle], old.title == new?.title, new?.artwork == nil { new?.artwork = old.artwork }
        appTracks[bundle] = new
        // Adapter chạy: gộp với bài macOS đang chọn.
        if adapter.live { refresh(); return }

        guard var new else {
            if track?.bundleID == bundle { set(nil) }
            return
        }
        // Trình phát khác đang phát mà trình này chỉ báo tạm dừng: giữ bài đang phát.
        if let t = track, t.bundleID != bundle, t.isPlaying, !new.isPlaying { return }
        let sameSong = track?.bundleID == bundle && track?.title == new.title
        if new.artwork == nil, sameSong { new.artwork = track?.artwork }
        set(new)
        if !sameSong { fetchMediaRemote() }
    }

    /// Distributed notification của Music / Spotify → bài. nil khi đã dừng hẳn.
    nonisolated static func appTrack(_ info: [AnyHashable: Any], bundle: String) -> NowPlayingTrack? {
        let state = info["Player State"] as? String ?? ""
        let title = info["Name"] as? String ?? ""
        guard state != "Stopped", !title.isEmpty else { return nil }
        var duration: Double?
        if let ms = info["Total Time"] as? NSNumber { duration = ms.doubleValue / 1000 }   // Music: ms
        if let ms = info["Duration"] as? NSNumber { duration = ms.doubleValue / 1000 }     // Spotify: ms
        return NowPlayingTrack(bundleID: bundle, title: title,
                               artist: info["Artist"] as? String ?? "",
                               album: info["Album"] as? String ?? "",
                               isPlaying: state == "Playing",
                               duration: (duration ?? 0) > 0 ? duration : nil,
                               position: (info["Playback Position"] as? NSNumber)?.doubleValue,   // Spotify: giây
                               updatedAt: Date(),
                               artwork: nil)
    }

    private func refresh() {
        set(Self.pick(adapter: adapterTrack, apps: Array(appTracks.values), current: track))
    }

    /// Chọn bài để hiện: trình đang phát thật thắng trình macOS chọn nhưng đã tạm dừng.
    nonisolated static func pick(adapter: NowPlayingTrack?, apps: [NowPlayingTrack],
                                 current: NowPlayingTrack?) -> NowPlayingTrack? {
        if let adapter, adapter.isPlaying { return adapter }
        if var app = apps.filter(\.isPlaying).max(by: { $0.updatedAt < $1.updatedAt }) {
            // Cùng bài với macOS (adapter chưa kịp báo phát): mượn ảnh bìa của adapter.
            if let adapter, adapter.bundleID == app.bundleID, adapter.title == app.title { app.artwork = adapter.artwork }
            return app
        }
        // Không gì đang phát: vừa tạm dừng Spotify thì giữ Spotify, không nhảy về video cũ macOS còn giữ.
        if let current, current.bundleID != adapter?.bundleID,
           let app = apps.first(where: { $0.bundleID == current.bundleID && $0.title == current.title }) {
            return app
        }
        return adapter ?? apps.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private func set(_ t: NowPlayingTrack?) {
        guard t != track else { return }
        track = t
        onChange?(t)
        fetchArtworkIfNeeded()
    }

    /// Đang hiện Spotify không có ảnh (macOS giữ app khác nên adapter không có ảnh của nó): hỏi Spotify địa chỉ ảnh
    /// rồi tải từ i.scdn.co. Chỉ khi bật tuỳ chọn.
    private func fetchArtworkIfNeeded() {
        let spotify = "com.spotify.client"
        guard running, fetchesSpotifyArtwork, let t = track, t.bundleID == spotify, t.artwork == nil,
              adapterTrack?.bundleID != spotify, appTracks[spotify]?.title == t.title, artworkRequested != t.title
        else { return }
        let title = t.title
        artworkRequested = title
        PlayerScript.artworkURL(spotify) { [weak self] url in
            guard let self, self.running, self.fetchesSpotifyArtwork, let url, self.appTracks[spotify]?.title == title
            else { return }
            SpotifyArtwork.load(url) { [weak self] image in
                guard let self, let image, var a = self.appTracks[spotify], a.title == title else { return }
                a.artwork = image
                self.appTracks[spotify] = a
                if self.adapter.live {
                    self.refresh()
                } else if var shown = self.track, shown.bundleID == spotify, shown.title == title {
                    shown.artwork = image
                    self.set(shown)
                }
            }
        }
    }

    // MARK: MediaRemote (tuỳ chọn)

    private func fetchMediaRemote() {
        guard running, let get = MediaRemote.getInfo else { return }
        get(DispatchQueue.main) { [weak self] dict in
            guard let d = dict as? [String: Any], !d.isEmpty else { return }
            MainActor.assumeIsolated { self?.merge(d) }
        }
    }

    private func merge(_ d: [String: Any]) {
        let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        guard !title.isEmpty else { return }
        let art = (d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).flatMap { NSImage(data: $0) }
        if var t = track, t.title == title {
            if let art { t.artwork = art; set(t) }
            return
        }
        // Chỉ dùng MediaRemote khi không có bài nào từ Music / Spotify đang phát.
        guard track?.isPlaying != true else { return }
        let rate = (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        set(NowPlayingTrack(bundleID: "", title: title,
                            artist: d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
                            album: d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
                            isPlaying: rate > 0,
                            duration: (d["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue,
                            position: (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue,
                            updatedAt: d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date(),
                            artwork: art))
    }
}

/// Điều khiển Music / Spotify bằng AppleScript khi macOS đang chọn app khác. Lần đầu macOS hỏi quyền
/// "zMac muốn điều khiển Spotify" (NSAppleEventsUsageDescription). Chạy osascript riêng, không chặn giao diện.
enum PlayerScript {
    static let bundles: Set<String> = ["com.spotify.client", "com.apple.Music"]

    static func send(_ control: NowPlayingMonitor.Control, to bundle: String) {
        switch control {
        case .playPause: run("playpause", in: bundle)
        case .next: run("next track", in: bundle)
        case .previous: run("previous track", in: bundle)
        }
    }

    static func seek(_ seconds: Double, in bundle: String) {
        run("set player position to \(Int(max(seconds, 0)))", in: bundle)
    }

    /// Hỏi trạng thái hiện tại (chạy osascript riêng, gọi `done` trên main). Số trả về là số nguyên mili giây để không
    /// phụ thuộc dấu thập phân của ngôn ngữ máy; các trường cách nhau bằng ký tự 0x1F.
    @MainActor
    static func query(_ bundle: String, done: @escaping @MainActor @Sendable (NowPlayingTrack?) -> Void) {
        guard bundles.contains(bundle) else { return }
        let scale = bundle == "com.spotify.client" ? 1 : 1000   // duration: Spotify mili giây, Music giây
        let script = """
        tell application id "\(bundle)"
            set s to player state as text
            if s is "stopped" then return s
            set t to current track
            set d to character id 31
            return s & d & (name of t) & d & (artist of t) & d & (album of t) & d & (round ((duration of t) * \(scale))) & d & (round ((player position) * 1000))
        end tell
        """
        output(script) { done(parseState($0, bundle: bundle)) }
    }

    /// Địa chỉ ảnh bìa bài đang phát (chỉ Spotify có), đã kiểm là ảnh của Spotify qua https.
    @MainActor
    static func artworkURL(_ bundle: String, done: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard bundle == "com.spotify.client" else { return done(nil) }
        output("tell application id \"\(bundle)\" to artwork url of current track") { text in
            done(URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(SpotifyArtwork.allowed))
        }
    }

    /// Chạy osascript, trả stdout trên main ("" khi lỗi hay bị từ chối quyền).
    @MainActor
    private static func output(_ script: String, done: @escaping @MainActor @Sendable (String) -> Void) {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let reader = out.fileHandleForReading
        p.terminationHandler = { p in
            let ok = p.terminationStatus == 0
            let text = ok ? String(decoding: reader.readDataToEndOfFile(), as: UTF8.self) : ""
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
        do { try p.run() } catch { done("") }
    }

    /// Kết quả `query` → bài. nil khi dừng hẳn, lỗi hay bị từ chối quyền.
    nonisolated static func parseState(_ text: String, bundle: String) -> NowPlayingTrack? {
        let f = text.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1F}")
        guard f.count == 6, f[0] == "playing" || f[0] == "paused", !f[1].isEmpty else { return nil }
        let duration = Double(f[4].trimmingCharacters(in: .whitespaces)).map { $0 / 1000 }
        return NowPlayingTrack(bundleID: bundle, title: f[1], artist: f[2], album: f[3], isPlaying: f[0] == "playing",
                               duration: (duration ?? 0) > 0 ? duration : nil,
                               position: Double(f[5].trimmingCharacters(in: .whitespaces)).map { $0 / 1000 },
                               updatedAt: Date(), artwork: nil)
    }

    private static func run(_ command: String, in bundle: String) {
        guard bundles.contains(bundle) else { return }
        // "is running": không tự mở lại app nếu nó vừa thoát.
        let script = "if application id \"\(bundle)\" is running then tell application id \"\(bundle)\" to \(command)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// Ảnh bìa Spotify từ máy chủ ảnh của nó (tuỳ chọn, tắt sẵn). Phiên ephemeral: không cache, không cookie.
enum SpotifyArtwork {
    /// Chỉ nhận ảnh của Spotify qua https (i.scdn.co, mosaic.scdn.co…).
    nonisolated static func allowed(_ url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "scdn.co" || host.hasSuffix(".scdn.co") else { return nil }
        return url
    }

    @MainActor
    static func load(_ url: URL, done: @escaping @MainActor @Sendable (NSImage?) -> Void) {
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            // Ảnh bìa vài trăm KB là cùng; lớn hơn 4 MB thì bỏ.
            let bytes = ok && (data?.count ?? 0) < 4_000_000 ? data : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { done(bytes.flatMap { NSImage(data: $0) }) } }
        }.resume()
        session.finishTasksAndInvalidate()
    }
}

enum MediaRemote {
    static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    // Block được MediaRemote giữ lại và gọi sau: phải @escaping, nếu không Swift abort khi chạy.
    typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    typealias UnregisterFn = @convention(c) () -> Void
    static let getInfo = handle == nil ? nil : PrivateAPI.sym(handle, "MRMediaRemoteGetNowPlayingInfo", GetInfoFn.self)
    static let register = handle == nil ? nil : PrivateAPI.sym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications", RegisterFn.self)
    static let unregister = handle == nil ? nil : PrivateAPI.sym(handle, "MRMediaRemoteUnregisterForNowPlayingNotifications", UnregisterFn.self)
    /// Trước macOS 15.4 app thường còn đọc được thông tin bài đang phát.
    static let readable = !ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0))
}

/// Phím media giả lập (NX_KEYTYPE_*), hệ thống chuyển tới trình phát đang hoạt động.
enum MediaKeys {
    static let play: Int32 = 16
    static let next: Int32 = 17
    static let previous: Int32 = 18

    static func send(_ key: Int32) {
        for down in [true, false] {
            let state: Int32 = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: Int((key << 16) | (state << 8)), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
