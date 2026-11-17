import Foundation
import Observation
import SwiftUI

// Lời bài hát từ lrclib.net (miễn phí, không cần khoá). Tắt sẵn; bật rồi cũng chỉ gọi mạng khi người dùng bấm nút Lời
// trong trình phát ở notch. Mỗi bài tối đa 5 yêu cầu (dừng ngay khi thấy), chỉ gửi tên bài, ca sĩ, album, độ dài.
// Kết quả giữ trong bộ nhớ, không ghi đĩa.
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
        // "Tên bài ft. Ca sĩ khác" (không ngoặc): bỏ từ "ft." / "feat." trở đi.
        for marker in [" ft. ", " feat. ", " ft ", " feat ", " featuring "] {
            if let r = t.range(of: marker, options: .caseInsensitive) {
                t = String(t[..<r.lowerBound])
                break
            }
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Tên kênh YouTube thay cho ca sĩ: "Sơn Tùng M-TP Official", "Đen - Topic", "AdeleVEVO".
    static func cleanArtist(_ artist: String) -> String {
        var a = artist.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for suffix in [" - Topic", " Official Channel", " Official", "VEVO"] {
            if a.count > suffix.count, a.lowercased().hasSuffix(suffix.lowercased()) {
                a = String(a.dropLast(suffix.count))
            }
        }
        return a.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Tên video dạng "Ca sĩ - Tên bài": tách ra để tìm theo đúng ca sĩ.
    static func splitTitle(_ title: String) -> (artist: String, title: String)? {
        for sep in [" - ", " – ", " — "] {
            guard let r = title.range(of: sep) else { continue }
            let a = title[..<r.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let t = title[r.upperBound...].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !a.isEmpty && !t.isEmpty { return (a, t) }
        }
        return nil
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

    /// Lần lượt: /api/get khớp chính xác; tìm theo tên + ca sĩ; tên video "Ca sĩ - Tên bài" tách ra; tìm tự do
    /// "ca sĩ tên bài"; cuối cùng chỉ tên bài (cần độ dài để lọc bài trùng tên). Dừng ngay khi có lời chạy theo nhạc;
    /// chỉ thấy lời không mốc thời gian thì giữ lại và tìm tiếp (lrclib hay có nhiều bản cho cùng một bài).
    nonisolated static func fetch(_ q: Query) async throws -> Lyrics? {
        let title = LRC.cleanTitle(q.title)
        guard !title.isEmpty else { return nil }
        let artist = LRC.cleanArtist(q.artist)
        let duration = q.duration.flatMap { $0 > 0 ? $0 : nil }
        var fallback: Lyrics?
        /// true = đã có lời chạy theo nhạc, dừng.
        func take(_ l: Lyrics?) -> Bool {
            guard let l else { return false }
            if case .synced = l { return true }
            if fallback == nil { fallback = l }
            return false
        }
        if let d = duration, !artist.isEmpty, !q.album.isEmpty {
            let obj = try await request("/api/get", ["track_name": title, "artist_name": artist,
                                                     "album_name": q.album, "duration": String(Int(d.rounded()))])
            let l = obj.flatMap(LrclibRecord.init)?.lyrics
            if take(l) { return l }
        }
        func search(_ params: [String: String]) async throws -> Lyrics? {
            guard let list = try await request("/api/search", params) as? [Any] else { return nil }
            return LrclibRecord.best(list.compactMap(LrclibRecord.init), duration: duration)?.lyrics
        }
        var stages: [[String: String]] = []
        stages.append(artist.isEmpty ? ["track_name": title] : ["track_name": title, "artist_name": artist])
        if let split = LRC.splitTitle(title) { stages.append(["track_name": split.title, "artist_name": split.artist]) }
        stages.append(["q": artist.isEmpty ? title : "\(artist) \(title)"])
        if !artist.isEmpty, duration != nil { stages.append(["q": title]) }
        for params in stages {
            let l = try await search(params)
            if take(l) { return l }
        }
        return fallback
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

// MARK: - Giao diện (lời thay chỗ trình phát trên notch)

/// Nút Lời trong trình phát: bật thì lời thay chỗ ảnh bìa và nút điều khiển.
/// Lúc chưa xem lời thì có chữ "Lời" cho dễ thấy; đang xem lời thì chỉ còn icon trên nền trắng.
struct LyricsToggle: View {
    let model: NotchModule

    var body: some View {
        let on = model.showLyrics
        Button { withAnimation(.easeInOut(duration: 0.2)) { model.showLyrics.toggle() } } label: {
            HStack(spacing: 4) {
                Image(systemName: "quote.bubble.fill").font(.system(size: 11, weight: .bold))
                if !on { Text(L("Lời", "Lyrics")).font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, on ? 0 : 9)
            .frame(minWidth: 26, minHeight: 26)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.13)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? L("Ẩn lời bài hát", "Hide lyrics") : L("Lời bài hát", "Lyrics"))
    }
}

struct NotchLyricsView: View {
    let model: NotchModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { model.openPlayer() } label: { NotchArtwork(track: model.track, size: 36, corner: 8) }
                    .buttonStyle(.plain)
                    .help(L("Mở trình phát", "Open player"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.track?.title ?? L("Chưa có nhạc đang phát", "Nothing playing"))
                        .font(.system(size: 13, weight: .bold)).lineLimit(1)
                    if let t = model.track {
                        Text(t.artist.isEmpty ? t.album : t.artist)
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if model.track != nil {
                    NotchControl(symbol: model.track?.isPlaying == true ? "pause.fill" : "play.fill", size: 12) {
                        model.playPause()
                    }
                }
                LyricsToggle(model: model)
            }
            Group {
                if !model.lyricsEnabled {
                    consent
                } else if let t = model.track {
                    content(t).task(id: LyricsStore.key(t)) { await model.lyrics.load(for: t) }
                } else {
                    message(L("Phát một bài để xem lời", "Play a song to see its lyrics"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Lời bài hát cần mạng: hỏi một lần, bấm là bật.
    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Lời lấy từ lrclib.net (miễn phí, mã nguồn mở). zMac chỉ gửi tên bài, ca sĩ, album và độ dài.",
                   "Lyrics come from lrclib.net (free and open source). zMac only sends the title, artist, album and length."))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Button { model.lyricsEnabled = true } label: {
                Text(L("Bật lời bài hát", "Turn on lyrics"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
        return VStack(alignment: .leading, spacing: 4) {
            if first <= last {
                ForEach(first...last, id: \.self) { i in
                    Text(lines[i].text.isEmpty ? "♪" : lines[i].text)
                        .font(.system(size: i == cur ? 15 : 12.5, weight: i == cur ? .bold : .medium))
                        .foregroundStyle(.white.opacity(i == cur ? 1 : (i < cur ? 0.3 : 0.45)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.35), value: cur)
    }
}
