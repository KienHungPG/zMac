import Foundation
import Observation
import SwiftUI

// Lời bài hát từ lrclib.net (miễn phí, không cần khoá). Tắt sẵn; bật rồi cũng chỉ gọi mạng khi người dùng mở tab Lời.
// Mỗi bài tối đa 3 yêu cầu, chỉ gửi tên bài, ca sĩ, album, độ dài. Kết quả giữ trong bộ nhớ, không ghi đĩa.
// Lời có mốc thời gian thì đổi dòng bằng TimelineView(.explicit) đúng lúc dòng kế tiếp bắt đầu, không timer lặp.

struct LyricLine: Equatable {
    var time: Double
    var text: String
}

enum Lyrics: Equatable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
}

// MARK: - Hàm thuần (có test)

enum LRC {
    /// "[01:23.45] lời" (một dòng có thể có nhiều mốc). Bỏ thẻ [ar:], [ti:]…, áp dụng [offset:±ms].
    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset = 0.0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = time(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append(LyricLine(time: t, text: words)) }
        }
        // offset dương = lời hiện sớm hơn.
        return lines.map { LyricLine(time: max($0.time - offset, 0), text: $0.text) }.sorted { $0.time < $1.time }
    }

    /// "mm:ss", "mm:ss.xx", "mm:ss:xx".
    private static func time(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let m = Double(parts[0]), m >= 0 else { return nil }
        let sec = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let s = Double(sec), s >= 0, s < 60 else { return nil }
        return m * 60 + s
    }

    /// Dòng đang hát: dòng cuối cùng đã bắt đầu. nil = chưa tới dòng đầu.
    static func index(_ lines: [LyricLine], at position: Double) -> Int? {
        var lo = 0, hi = lines.count - 1
        var found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position + 0.15 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// Bỏ phần thêm của tên video: "(Official MV)", "[Lyrics]", "| Kênh XYZ", "(feat. A)".
    static func cleanTitle(_ title: String) -> String {
        var t = title
        for sep in [" | ", " ｜ ", " || "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        let noise = ["official", "video", "mv", "m/v", "lyric", "audio", "visualizer", "hd", "4k", "remaster",
                     "feat", "ft.", "karaoke"]
        for (open, close) in [("(", ")"), ("[", "]"), ("【", "】")] {
            var from = t.startIndex
            while let o = t.range(of: open, range: from..<t.endIndex),
                  let c = t.range(of: close, range: o.upperBound..<t.endIndex) {
                let inside = t[o.upperBound..<c.lowerBound].lowercased()
                if noise.contains(where: { inside.contains($0) }) {
                    t.removeSubrange(o.lowerBound..<c.upperBound)
                    from = t.startIndex
                } else {
                    from = c.upperBound
                }
            }
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Một bản ghi của lrclib.
struct LrclibRecord: Equatable {
    var duration: Double?
    var instrumental: Bool
    var plain: String?
    var synced: String?

    init(duration: Double?, instrumental: Bool, plain: String?, synced: String?) {
        self.duration = duration
        self.instrumental = instrumental
        self.plain = plain
        self.synced = synced
    }

    init?(_ obj: Any) {
        guard let d = obj as? [String: Any] else { return nil }
        func text(_ k: String) -> String? {
            (d[k] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        self.init(duration: (d["duration"] as? NSNumber)?.doubleValue, instrumental: d["instrumental"] as? Bool ?? false,
                  plain: text("plainLyrics"), synced: text("syncedLyrics"))
    }

    var lyrics: Lyrics? {
        if let synced {
            let lines = LRC.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain { return .plain(plain) }
        return instrumental ? .instrumental : nil
    }

    /// Bản hợp nhất: độ dài lệch tối đa 3 giây (nếu biết độ dài), ưu tiên bản có mốc thời gian.
    static func best(_ records: [LrclibRecord], duration: Double?) -> LrclibRecord? {
        var pool = records.filter { $0.lyrics != nil }
        if let d = duration {
            pool = pool.filter { r in r.duration.map { abs($0 - d) <= 3 } ?? false }
        }
        return pool.first { $0.synced != nil } ?? pool.first
    }
}

// MARK: - Tải lời

@MainActor @Observable
final class LyricsStore {
    enum State: Equatable { case idle, loading, found(Lyrics), notFound, failed }

    private(set) var state: State = .idle
    @ObservationIgnored private var key: String?
    /// Lời đã tải (nil = bài không có lời). Giữ tối đa 30 bài.
    @ObservationIgnored private var cache: [String: Lyrics?] = [:]
    @ObservationIgnored private var order: [String] = []

    struct Query: Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: Double?
    }

    static func key(_ t: NowPlayingTrack) -> String {
        "\(t.title)\u{1}\(t.artist)\u{1}\(Int((t.duration ?? 0).rounded()))"
    }

    func load(for t: NowPlayingTrack) async {
        let k = Self.key(t)
        if k == key, state != .failed { return }
        key = k
        if let cached = cache[k] {
            state = cached.map { .found($0) } ?? .notFound
            return
        }
        state = .loading
        do {
            let result = try await Self.fetch(Query(title: t.title, artist: t.artist, album: t.album, duration: t.duration))
            guard key == k else { return }
            cache[k] = .some(result)
            order.append(k)
            if order.count > 30 { cache.removeValue(forKey: order.removeFirst()) }
            state = result.map { .found($0) } ?? .notFound
        } catch {
            guard key == k else { return }
            // Bị huỷ (đóng tab giữa chừng): lần mở sau thử lại.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                key = nil
                state = .idle
            } else {
                state = .failed
            }
        }
    }

    #if DEBUG
    /// Chỉ cho `--render-ui`.
    func previewSet(_ s: State, for t: NowPlayingTrack) {
        state = s
        key = Self.key(t)   // trùng khoá: load(for:) không gọi mạng
    }
    #endif

    func clear() {
        cache.removeAll()
        order.removeAll()
        key = nil
        state = .idle
    }

    private nonisolated static let userAgent: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "zMac/\(v) (https://zmac-website.vercel.app)"
    }()

    /// /api/get khớp chính xác, rồi /api/search theo tên + ca sĩ, cuối cùng tìm tự do.
    nonisolated static func fetch(_ q: Query) async throws -> Lyrics? {
        let title = LRC.cleanTitle(q.title)
        guard !title.isEmpty else { return nil }
        let duration = q.duration.flatMap { $0 > 0 ? $0 : nil }
        if let d = duration, !q.artist.isEmpty, !q.album.isEmpty,
           let obj = try await request("/api/get", ["track_name": title, "artist_name": q.artist,
                                                    "album_name": q.album, "duration": String(Int(d.rounded()))]),
           let lyrics = LrclibRecord(obj)?.lyrics {
            return lyrics
        }
        var params = ["track_name": title]
        if !q.artist.isEmpty { params["artist_name"] = q.artist }
        if let list = try await request("/api/search", params) as? [Any],
           let r = LrclibRecord.best(list.compactMap(LrclibRecord.init), duration: duration) {
            return r.lyrics
        }
        let free = q.artist.isEmpty ? title : "\(q.artist) \(title)"
        if let list = try await request("/api/search", ["q": free]) as? [Any],
           let r = LrclibRecord.best(list.compactMap(LrclibRecord.init), duration: duration) {
            return r.lyrics
        }
        return nil
    }

    private nonisolated static func request(_ path: String, _ params: [String: String]) async throws -> Any? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "lrclib.net"
        c.path = path
        c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Phiên ephemeral: không ghi cache / cookie ra đĩa.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - Giao diện (tab Lời trên notch)

struct NotchLyricsView: View {
    let model: NotchModule

    var body: some View {
        if let t = model.track {
            HStack(spacing: 18) {
                NotchArtwork(track: t, size: 64, corner: 12)
                content(t)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .task(id: LyricsStore.key(t)) { await model.lyrics.load(for: t) }
        } else {
            Text(L("Chưa có nhạc đang phát", "Nothing playing"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func content(_ t: NowPlayingTrack) -> some View {
        switch model.lyrics.state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Đang tìm lời…", "Finding lyrics…")).foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 12))
        case .found(.synced(let lines)):
            SyncedLyricsView(lines: lines, track: t)
        case .found(.plain(let text)):
            ScrollView {
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        case .found(.instrumental):
            message("♪ " + L("Bài không lời", "Instrumental"))
        case .notFound:
            message(L("Không tìm thấy lời cho bài này", "No lyrics found for this track"))
        case .failed:
            message(L("Không tải được lời (mất mạng?)", "Couldn't load lyrics (offline?)"))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
    }
}

/// Bốn dòng quanh dòng đang hát. TimelineView chỉ cập nhật đúng lúc một dòng mới bắt đầu.
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let track: NowPlayingTrack

    var body: some View {
        let now = Date()
        if track.isPlaying, let pos = track.elapsed(at: now) {
            let dates = lines.filter { $0.time > pos + 0.15 }.map { now.addingTimeInterval($0.time - pos - 0.15) }
            TimelineView(.explicit(dates)) { ctx in
                window(LRC.index(lines, at: track.elapsed(at: ctx.date) ?? pos))
            }
        } else {
            window(track.elapsed(at: now).flatMap { LRC.index(lines, at: $0) })
        }
    }

    private func window(_ current: Int?) -> some View {
        let cur = current ?? -1
        let first = max(cur - 1, 0)
        let last = min(max(cur, 0) + 2, lines.count - 1)
        return VStack(alignment: .leading, spacing: 5) {
            if first <= last {
                ForEach(first...last, id: \.self) { i in
                    Text(lines[i].text.isEmpty ? "♪" : lines[i].text)
                        .font(.system(size: i == cur ? 16 : 12.5, weight: i == cur ? .bold : .medium))
                        .foregroundStyle(.white.opacity(i == cur ? 1 : (i < cur ? 0.3 : 0.45)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.35), value: cur)
    }
}
