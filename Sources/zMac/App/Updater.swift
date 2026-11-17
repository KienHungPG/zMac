import AppKit
import CryptoKit
import Observation
import SwiftUI

// Tự cập nhật từ GitHub Releases. Tắt sẵn.
// - Bật thì chỉ kiểm tra lúc mở app và khi máy thức dậy, tối đa một lần mỗi ngày (theo sự kiện, không timer).
//   Nút "Kiểm tra ngay" thì kiểm tra lúc bấm.
// - Mỗi bản phát hành có zMac-x.y.z.zip và zMac-x.y.z.zip.sig (chữ ký Ed25519 trên nguyên file zip).
//   Khoá công khai gắn vào Info.plist lúc build (Resources/update-public-key.txt). Sai chữ ký thì không cài.
// - Cài: giải nén, kiểm bundle id và phiên bản, rồi một script nhỏ chờ zMac thoát, thay app (giữ bản cũ để
//   trả lại nếu hỏng) và mở bản mới.

// MARK: - Hàm thuần (có test)

enum UpdateVersion {
    /// "v0.1.10" -> [0, 1, 10]. Phần không phải số (vd "-beta") bị bỏ.
    static func parts(_ v: String) -> [Int] {
        let core = v.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        return core.split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateRelease: Equatable {
    var version: String
    var notes: String
    var zipURL: String
    var sigURL: String
    var size: Int

    /// JSON của GET /repos/{repo}/releases/latest. Cần một file .zip có "zMac" trong tên và file .sig đi kèm.
    static func parse(_ json: [UInt8]) -> UpdateRelease? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        func url(_ a: [String: Any]) -> String? { a["browser_download_url"] as? String }
        guard let zip = assets.first(where: { a in
                  let n = a["name"] as? String ?? ""
                  return n.hasSuffix(".zip") && n.lowercased().contains("zmac")
              }),
              let zipName = zip["name"] as? String,
              let sig = assets.first(where: { $0["name"] as? String == zipName + ".sig" }),
              let zipURL = url(zip), let sigURL = url(sig),
              zipURL.hasPrefix("https://"), sigURL.hasPrefix("https://") else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return UpdateRelease(version: version, notes: obj["body"] as? String ?? "", zipURL: zipURL, sigURL: sigURL,
                             size: (zip["size"] as? NSNumber)?.intValue ?? 0)
    }
}

enum UpdateSignature {
    /// Chữ ký Ed25519 (base64) trên nguyên nội dung file, khoá công khai 32 byte (base64).
    static func verify(_ file: Data, signature: String, publicKey: String) -> Bool {
        guard let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: file)
    }

    static func verify(bytes: [UInt8], signature: String, publicKey: String) -> Bool {
        verify(Data(bytes), signature: signature, publicKey: publicKey)
    }

    #if DEBUG
    /// Chỉ cho test: (khoá bí mật, khoá công khai) base64.
    static func makeKeyPair() -> (privateKey: String, publicKey: String) {
        let k = Curve25519.Signing.PrivateKey()
        return (k.rawRepresentation.base64EncodedString(), k.publicKey.rawRepresentation.base64EncodedString())
    }

    static func sign(bytes: [UInt8], privateKey: String) -> String? {
        guard let raw = Data(base64Encoded: privateKey),
              let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
              let sig = try? k.signature(for: Data(bytes)) else { return nil }
        return sig.base64EncodedString()
    }
    #endif
}

enum UpdateInstaller {
    /// Chạy bằng `/bin/sh -c script sh PID APP NEW BACKUP` (đường dẫn đi qua tham số, không ghép chuỗi).
    /// Chờ zMac cũ thoát (tối đa 20 s), đổi app, hỏng thì trả bản cũ, rồi mở.
    static let script = """
    pid="$1"; app="$2"; new="$3"; backup="$4"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i+1)); [ "$i" -gt 100 ] && exit 1
      sleep 0.2
    done
    rm -rf "$backup"
    if mv "$app" "$backup"; then
      if mv "$new" "$app"; then rm -rf "$backup"; else mv "$backup" "$app"; fi
    fi
    sleep 0.5
    open "$app"
    """
}

// MARK: - Bộ cập nhật

@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing
        case available(UpdateRelease)
        case failed(String)
    }

    static let repo = "KienHungPG/zMac"
    static let bundleID = "com.zmac.app"

    private(set) var state: State = .idle
    private(set) var lastCheck: Date? = {
        let t = Pref.double("update.lastCheck", 0)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    var autoCheck = Pref.bool("update.auto", false) {
        didSet {
            Pref.set("update.auto", autoCheck)
            if autoCheck { start() } else { stopObserving() }
        }
    }

    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Khoá công khai gắn lúc build. Không có thì bản này không tự cập nhật được.
    static var publicKey: String? {
        (Bundle.main.infoDictionary?["ZMUpdatePublicKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var available: UpdateRelease? {
        if case .available(let r) = state { return r }
        return nil
    }

    var busy: Bool { state == .checking || state == .downloading || state == .installing }

    /// Gọi lúc mở app. Chỉ làm gì khi người dùng đã bật.
    func start() {
        guard autoCheck, Self.publicKey != nil else { return }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkIfDue() }
            }
        }
        checkIfDue()
    }

    private func stopObserving() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func checkIfDue() {
        guard autoCheck, lastCheck.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
        Task { await check() }
    }

    func check() async {
        guard !busy else { return }
        guard Self.publicKey != nil else {
            state = .failed(L("Bản build này không có khoá cập nhật.", "This build has no update key."))
            return
        }
        state = .checking
        do {
            guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("zMac/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastCheck = Date()
            Pref.set("update.lastCheck", lastCheck?.timeIntervalSince1970)
            if status == 404 { state = .upToDate; return }   // chưa có bản phát hành nào
            guard status == 200 else { throw URLError(.badServerResponse) }
            guard let r = UpdateRelease.parse(Array(data)) else {
                state = .failed(L("Bản phát hành mới nhất thiếu file .zip hoặc chữ ký.",
                                  "The latest release is missing its .zip or signature."))
                return
            }
            state = UpdateVersion.isNewer(r.version, than: Self.currentVersion) ? .available(r) : .upToDate
            log.info("cập nhật: mới nhất \(r.version, privacy: .public)")
        } catch {
            state = .failed(L("Không kiểm tra được (mất mạng?).", "Couldn't check (offline?)."))
        }
    }

    func install() async {
        guard case .available(let r) = state, let key = Self.publicKey else { return }
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            state = .failed(L("Không có quyền ghi vào \(parent). Hãy tải bản mới từ trang web.",
                              "No permission to write to \(parent). Download the new version from the website."))
            return
        }
        state = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("zmac-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = try await download(r.zipURL, to: work.appendingPathComponent("update.zip"))
            let sigFile = try await download(r.sigURL, to: work.appendingPathComponent("update.sig"))
            let sig = try String(contentsOf: sigFile, encoding: .utf8)
            guard UpdateSignature.verify(try Data(contentsOf: zip), signature: sig, publicKey: key) else {
                state = .failed(L("Chữ ký không khớp, đã huỷ cập nhật.", "Signature mismatch, update cancelled."))
                log.error("cập nhật: sai chữ ký")
                return
            }
            state = .installing
            let out = work.appendingPathComponent("app")
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  let info = Bundle(url: newApp)?.infoDictionary,
                  info["CFBundleIdentifier"] as? String == Self.bundleID,
                  info["CFBundleShortVersionString"] as? String == r.version else {
                state = .failed(L("Gói tải về không đúng là zMac \(r.version).", "The download isn't zMac \(r.version)."))
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", UpdateInstaller.script, "sh", String(getpid()), appPath, newApp.path, appPath + ".zmac-old"]
            try p.run()
            log.info("cập nhật: cài \(r.version, privacy: .public), mở lại")
            NSApp.terminate(nil)
        } catch {
            state = .failed(L("Tải hoặc giải nén thất bại.", "Download or unpacking failed."))
        }
    }

    private func download(_ url: String, to dest: URL) async throws -> URL {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 60)
        req.setValue("zMac/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
}

// MARK: - Giao diện

/// Mục Cập nhật trong trang Chung.
struct UpdateSection: View {
    var updater = Updater.shared

    var body: some View {
        Section(L("Cập nhật", "Updates")) {
            LabeledContent(L("Phiên bản", "Version"), value: Updater.currentVersion)
            if Updater.publicKey == nil {
                Text(L("Bản build này không có khoá cập nhật (Resources/update-public-key.txt) nên không tự cập nhật được.",
                       "This build has no update key (Resources/update-public-key.txt), so it can't update itself."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(L("Tự kiểm tra bản mới (tối đa mỗi ngày một lần)", "Check for new versions automatically (at most once a day)"),
                       isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                HStack {
                    status
                    Spacer()
                    if let r = updater.available {
                        Button(L("Cài \(r.version) và mở lại", "Install \(r.version) and relaunch")) {
                            Task { await updater.install() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(L("Kiểm tra ngay", "Check now")) { Task { await updater.check() } }
                            .disabled(updater.busy)
                    }
                }
                if let r = updater.available, !r.notes.isEmpty {
                    Text(r.notes).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                }
                Text(L("Kiểm tra hỏi api.github.com; bản mới tải từ github.com và chỉ được cài khi chữ ký Ed25519 khớp khoá gắn trong app.",
                       "Checks ask api.github.com; updates download from github.com and only install if their Ed25519 signature matches the key built into the app."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle:
            if let t = updater.lastCheck {
                Text(L("Kiểm tra lần cuối ", "Last checked ") + t.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text(L("Đang dùng bản mới nhất", "You're up to date")).foregroundStyle(ZTheme.green.light)
        case .available(let r): Text(L("Có bản \(r.version)", "Version \(r.version) is out")).foregroundStyle(ZTheme.orange.light)
        case .downloading: Text(L("Đang tải và kiểm chữ ký…", "Downloading and verifying…"))
        case .installing: Text(L("Đang cài…", "Installing…"))
        case .failed(let m): Text(m).foregroundStyle(Color(hex: 0xFF8A80))
        }
    }
}

/// Dải báo bản mới trong bảng menu bar.
struct UpdateBanner: View {
    var updater = Updater.shared

    var body: some View {
        if let r = updater.available {
            HStack(spacing: 10) {
                ZTile(symbol: "arrow.down", hue: ZTheme.blue, size: 24)
                Text(L("Có zMac \(r.version)", "zMac \(r.version) is out")).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button(L("Cài", "Install")) { Task { await updater.install() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(10)
            .zCard()
        }
    }
}
