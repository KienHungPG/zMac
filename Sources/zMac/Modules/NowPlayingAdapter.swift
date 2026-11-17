import AppKit
import Foundation

// "Đang phát" qua mediaremote-adapter (Vendor/MediaRemoteAdapter, BSD 3-Clause).
// Từ macOS 15.4 chỉ tiến trình của Apple đọc được MediaRemote. Adapter chạy /usr/bin/perl (của Apple),
// cho nó nạp framework đi kèm app rồi đẩy JSON ra stdout mỗi khi bài hay trạng thái đổi.
// Theo sự kiện: đọc stdout bằng readabilityHandler, không hỏi định kỳ.
// Chỉ chạy khi module Notch bật (NowPlayingMonitor.start/stop). Khoảng 7 MB, 0% CPU khi rảnh.

@MainActor
final class NowPlayingAdapter {
    struct Paths { let script: String; let framework: String }
    static let perl = "/usr/bin/perl"

    /// Trong app: Contents/Resources và Contents/Frameworks. Chạy từ .build (dev): Vendor/ và .build/ của repo.
    static var paths: Paths? {
        let fm = FileManager.default
        if let script = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"),
           let fw = Bundle.main.privateFrameworksPath.map({ $0 + "/MediaRemoteAdapter.framework" }),
           fm.fileExists(atPath: fw) {
            return Paths(script: script, framework: fw)
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<5 {
            guard let d = dir else { break }
            let script = d.appendingPathComponent("Vendor/MediaRemoteAdapter/bin/mediaremote-adapter.pl").path
            let fw = d.appendingPathComponent(".build/MediaRemoteAdapter.framework").path
            if fm.fileExists(atPath: script), fm.fileExists(atPath: fw) { return Paths(script: script, framework: fw) }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// Mã lệnh của `send` (MRCommand).
    enum Command: Int { case togglePlayPause = 2, next = 4, previous = 5 }

    var onUpdate: ((NowPlayingTrack?) -> Void)?
    /// Adapter thoát ngoài ý muốn (Apple chặn, perl lỗi…): bên gọi lùi về cách cũ.
    var onExit: (() -> Void)?
    /// Đã nhận được ít nhất một dòng hợp lệ: adapter dùng được.
    private(set) var live = false
    private(set) var lastExitStatus: Int32?
    private(set) var artworkBytes = 0

    private var process: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var artworkString: String?
    private var artwork: NSImage?
    private var commands = Set<Process>()

    func start() -> Bool {
        guard process == nil, let p = Self.paths, FileManager.default.isExecutableFile(atPath: Self.perl) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.perl)
        // Diff: ảnh bìa chỉ gửi lại khi đổi bài. Debounce gom các thay đổi dồn dập khi chuyển bài.
        proc.arguments = [p.script, p.framework, "stream", "--micros", "--debounce=80"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            // EOF: gỡ handler, nếu không nó được gọi liên tục với dữ liệu rỗng.
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status: status) } }
        }
        do {
            try proc.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return false
        }
        process = proc
        return true
    }

    func stop() {
        guard let proc = process else { return }
        process = nil
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
        reset()
    }

    /// Gửi lệnh thẳng tới trình phát đang "Now Playing" (kể cả trình duyệt). Tiến trình ngắn, tự thoát.
    func send(_ command: Command) -> Bool {
        guard live, let p = Self.paths else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.perl)
        proc.arguments = [p.script, p.framework, "send", String(command.rawValue)]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.commands.remove(p) } }
        }
        guard (try? proc.run()) != nil else { return false }
        commands.insert(proc)
        return true
    }

    private func reset() {
        buffer.removeAll()
        state.removeAll()
        artworkString = nil
        artwork = nil
        artworkBytes = 0
        live = false
    }

    private func exited(status: Int32) {
        lastExitStatus = status
        // process == nil: đã stop() chủ động, không phải lỗi.
        guard let proc = process else { return }
        process = nil
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        reset()
        onExit?()
    }

    private func receive(_ data: Data) {
        guard process != nil else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard Self.apply(line: line, to: &state) else { continue }
            live = true
            // Chỉ giải mã ảnh bìa khi nó đổi; cùng một NSImage thì NowPlayingTrack so sánh bằng nhau, view không vẽ lại.
            let art = state["artworkData"] as? String
            if art != artworkString {
                artworkString = art
                let bytes = art.flatMap { Data(base64Encoded: $0) }
                artworkBytes = bytes?.count ?? 0
                artwork = bytes.flatMap { NSImage(data: $0) }
            }
            onUpdate?(Self.track(from: state, artwork: artwork))
        }
    }

    // MARK: Hàm thuần (có test)

    /// Gộp một dòng JSON của `stream` vào trạng thái. diff=false thay toàn bộ; diff=true chỉ đè khoá có mặt,
    /// khoá mang giá trị null thì xoá. Trả về false nếu dòng không hợp lệ.
    nonisolated static func apply(line: Data, to state: inout [String: Any]) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "data",
              let payload = obj["payload"] as? [String: Any] else { return false }
        if obj["diff"] as? Bool != true { state = [:] }
        for (key, value) in payload {
            if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
        }
        return true
    }

    /// Trạng thái gộp → bài đang phát. Không có tiêu đề nghĩa là không có gì đang phát.
    nonisolated static func track(from s: [String: Any], artwork: NSImage?) -> NowPlayingTrack? {
        guard let title = s["title"] as? String, !title.isEmpty else { return nil }
        func seconds(_ key: String) -> Double? { (s[key] as? NSNumber).map { $0.doubleValue / 1_000_000 } }
        // Trang web phát nhạc: lấy app cha (trình duyệt) để hiện đúng icon.
        let bundle = s["parentApplicationBundleIdentifier"] as? String ?? s["bundleIdentifier"] as? String ?? ""
        let duration = seconds("durationMicros")
        return NowPlayingTrack(bundleID: bundle, title: title,
                               artist: s["artist"] as? String ?? "",
                               album: s["album"] as? String ?? "",
                               isPlaying: s["playing"] as? Bool ?? false,
                               duration: (duration ?? 0) > 0 ? duration : nil,
                               position: seconds("elapsedTimeMicros"),
                               updatedAt: seconds("timestampEpochMicros").map { Date(timeIntervalSince1970: $0) } ?? Date(),
                               artwork: artwork)
    }

    // MARK: Chẩn đoán (zMac --diagnose)

    /// Chạy stream thật vài giây và in kết quả. Không in tên bài, chỉ in trình phát và cỡ ảnh bìa.
    static func diagnose() {
        print("  đang phát (adapter):")
        guard paths != nil else { print("    không có framework (chưa chạy build.sh?), notch dùng Music/Spotify"); return }
        let adapter = NowPlayingAdapter()
        var got = false
        var track: NowPlayingTrack?
        adapter.onUpdate = { t in got = true; track = t }
        let t0 = Date()
        guard adapter.start() else { print("    không chạy được \(perl)"); return }
        // Chỉ dùng khi chẩn đoán từ dòng lệnh. Dòng đầu của stream luôn rỗng, dữ liệu thật tới ngay sau:
        // chờ tới khi có bài, tối đa 3 giây.
        while track == nil, adapter.process != nil, Date().timeIntervalSince(t0) < 3 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let bytes = adapter.artworkBytes
        adapter.stop()
        if !got {
            print("    không đọc được (thoát: \(adapter.lastExitStatus.map(String.init) ?? "chưa"), \(ms) ms), notch dùng Music/Spotify")
        } else if let t = track {
            print("    đọc được: \(t.bundleID), \(t.isPlaying ? "đang phát" : "tạm dừng"), ảnh bìa \(bytes) byte (\(ms) ms)")
        } else {
            print("    đọc được, không có gì đang phát (\(ms) ms)")
        }
    }
}
