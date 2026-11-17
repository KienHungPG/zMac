import AppKit
import Foundation

// Nhạc đang phát cho notch, hoàn toàn theo sự kiện:
// - Apple Music và Spotify phát distributed notification mỗi khi đổi bài / phát / dừng.
// - MediaRemote (API riêng) chỉ thử thêm để lấy ảnh bìa; từ macOS 15.4 app ngoài Apple thường không đọc được.
// - Điều khiển bằng phím media giả lập: hệ thống tự gửi tới trình phát đang "Now Playing".

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
    /// Chỉ có khi MediaRemote trả về.
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
    private var mediaRemoteObserver: NSObjectProtocol?
    private var running = false

    static let sources: [(notification: String, bundleID: String)] = [
        ("com.apple.Music.playerInfo", "com.apple.Music"),
        ("com.spotify.client.PlaybackStateChanged", "com.spotify.client"),
    ]

    func start() {
        guard !running else { return }
        running = true
        let center = DistributedNotificationCenter.default()
        for s in Self.sources {
            // deliverImmediately: app nền (accessory) vẫn nhận ngay, không bị gom lại.
            center.addObserver(self, selector: #selector(received(_:)), name: Notification.Name(s.notification),
                               object: nil, suspensionBehavior: .deliverImmediately)
        }
        guard MediaRemote.getInfo != nil else { return }
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

    func stop() {
        guard running else { return }
        running = false
        DistributedNotificationCenter.default().removeObserver(self)
        if let mediaRemoteObserver {
            NotificationCenter.default.removeObserver(mediaRemoteObserver)
            MediaRemote.unregister?()
        }
        mediaRemoteObserver = nil
        track = nil
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
        let state = info["Player State"] as? String ?? ""
        let title = info["Name"] as? String ?? ""
        if state == "Stopped" || title.isEmpty {
            if track?.bundleID == bundle { set(nil) }
            return
        }
        let playing = state == "Playing"
        // Trình phát khác đang phát mà trình này chỉ báo tạm dừng: giữ bài đang phát.
        if let t = track, t.bundleID != bundle, t.isPlaying, !playing { return }

        var duration: Double?
        if let ms = info["Total Time"] as? NSNumber { duration = ms.doubleValue / 1000 }   // Music: ms
        if let ms = info["Duration"] as? NSNumber { duration = ms.doubleValue / 1000 }     // Spotify: ms
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue               // Spotify: giây
        let sameSong = track?.bundleID == bundle && track?.title == title
        set(NowPlayingTrack(bundleID: bundle, title: title,
                            artist: info["Artist"] as? String ?? "",
                            album: info["Album"] as? String ?? "",
                            isPlaying: playing,
                            duration: (duration ?? 0) > 0 ? duration : nil,
                            position: position,
                            updatedAt: Date(),
                            artwork: sameSong ? track?.artwork : nil))
        if !sameSong { fetchMediaRemote() }
    }

    private func set(_ t: NowPlayingTrack?) {
        guard t != track else { return }
        track = t
        onChange?(t)
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
