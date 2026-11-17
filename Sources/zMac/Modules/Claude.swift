import AppKit
import Darwin
import Observation
import SwiftUI

// Duyệt quyền của Claude Code ngay trên notch.
// - zmac-claude-hook (hook PermissionRequest) gửi yêu cầu qua Unix socket trong Application Support.
// - Module nghe socket bằng DispatchSource (theo sự kiện, không poll). Mỗi yêu cầu giữ kết nối tới khi người dùng bấm.
// - Hook đóng kết nối (người dùng trả lời trong terminal, Claude Code huỷ) thì thẻ tự biến mất.
// - Chỉ sửa ~/.claude/settings.json khi người dùng bấm Kết nối; Gỡ chỉ bỏ đúng mục của zMac.

/// Một yêu cầu cấp quyền đang chờ.
struct ClaudeRequest: Identifiable, Equatable {
    let id = UUID()
    let fd: Int32
    let tool: String
    let summary: String
    let project: String
    /// Quy tắc "Luôn cho phép" Claude Code gợi ý. nil = không có gợi ý nên không hiện nút đó.
    let alwaysLabel: String?
    let suggestions: Data?

    enum Decision { case allow, allowAlways, deny, pass }

    struct Parsed: Equatable {
        var tool: String
        var summary: String
        var project: String
        var alwaysLabel: String?
        var suggestions: Data?
    }

    /// Đọc một dòng JSON hook gửi (đúng stdin của Claude Code).
    static func parse(_ line: [UInt8]) -> Parsed? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let tool = obj["tool_name"] as? String, !tool.isEmpty else { return nil }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let cwd = obj["cwd"] as? String ?? ""
        let sugg = obj["permission_suggestions"] as? [[String: Any]] ?? []
        return Parsed(tool: displayName(tool), summary: summary(tool: tool, input: input),
                      project: cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent,
                      alwaysLabel: alwaysLabel(sugg),
                      suggestions: sugg.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: sugg))
    }

    /// mcp__github__create_issue -> "github · create_issue".
    static func displayName(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return tool }
        return parts[1] + " · " + parts[2...].joined(separator: "__")
    }

    /// Dòng chính của thẻ: lệnh Bash, đường dẫn file, URL…
    static func summary(tool: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let text: String
        switch tool {
        case "Bash": text = s("command") ?? ""
        case "Edit", "MultiEdit", "Write", "Read": text = tildify(s("file_path") ?? "")
        case "NotebookEdit": text = tildify(s("notebook_path") ?? "")
        case "WebFetch": text = s("url") ?? ""
        case "WebSearch": text = s("query") ?? ""
        case "Glob", "Grep": text = s("pattern") ?? ""
        case "Task", "Agent": text = s("description") ?? s("prompt") ?? ""
        default: text = input.keys.sorted().lazy.compactMap { s($0) }.first ?? ""
        }
        return String(text.prefix(600))
    }

    static func alwaysLabel(_ suggestions: [[String: Any]]) -> String? {
        guard !suggestions.isEmpty else { return nil }
        for s in suggestions {
            if let rules = s["rules"] as? [[String: Any]], !rules.isEmpty {
                return rules.compactMap { r -> String? in
                    guard let t = r["toolName"] as? String else { return nil }
                    if let c = r["ruleContent"] as? String, !c.isEmpty { return "\(t)(\(c))" }
                    return t
                }.joined(separator: ", ")
            }
            if let mode = s["mode"] as? String { return "mode: \(mode)" }
            if let dirs = s["directories"] as? [String], !dirs.isEmpty { return dirs.map(tildify).joined(separator: ", ") }
        }
        return ""
    }

    static func tildify(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Dòng trả lời gửi về hook. "none" = không quyết định, Claude Code hỏi trong terminal.
    static func reply(_ d: Decision, suggestions: Data?) -> [UInt8] {
        var obj: [String: Any]
        switch d {
        case .allow: obj = ["behavior": "allow"]
        case .allowAlways:
            obj = ["behavior": "allow"]
            if let suggestions, let arr = try? JSONSerialization.jsonObject(with: suggestions) as? [Any] {
                obj["updatedPermissions"] = arr
            }
        case .deny: obj = ["behavior": "deny", "message": "The user denied this in zMac."]
        case .pass: obj = ["behavior": "none"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"behavior":"none"}"#.utf8)
        return Array(data) + [0x0A]
    }
}

// MARK: - Mức dùng (Claude Code tự lưu trong ~/.claude.json)

/// Hạn mức 5 giờ / 7 ngày của gói Pro / Max. Claude Code tự lấy số này và lưu ở `cachedUsageUtilization`
/// trong ~/.claude.json, nên zMac chỉ đọc file: không mạng, không Keychain, chạy cả với bản VS Code lẫn terminal.
struct ClaudeUsage: Codable, Equatable {
    struct Window: Codable, Equatable {
        var percent: Double
        /// Giây kể từ 1970.
        var resetsAt: Double?
    }

    var fiveHour: Window?
    var sevenDay: Window?
    /// Lúc Claude Code lấy số liệu (giây kể từ 1970).
    var fetchedAt: Double?

    var hasLimits: Bool { fiveHour != nil || sevenDay != nil }

    static func fromClaudeConfig(_ bytes: [UInt8]) -> ClaudeUsage? { fromClaudeConfig(data: Data(bytes)) }

    static func fromClaudeConfig(data: Data) -> ClaudeUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = obj["cachedUsageUtilization"] as? [String: Any],
              let util = cache["utilization"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = util[key] as? [String: Any], let p = number(w["utilization"]) else { return nil }
            return Window(percent: min(max(p, 0), 100), resetsAt: time(w["resets_at"]))
        }
        let u = ClaudeUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"),
                            fetchedAt: number(cache["fetchedAtMs"]).map { $0 / 1000 })
        return u.hasLimits ? u : nil
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        return (v as? String).flatMap(Double.init)
    }

    /// resets_at dạng "2026-11-17T09:20:00.486592+00:00" (phần lẻ 6 chữ số) hoặc số giây.
    static func time(_ v: Any?) -> Double? {
        if let n = number(v) { return n }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return f.date(from: trimmed)?.timeIntervalSince1970
    }

    /// Hạn mức đã tới giờ đặt lại thì về 0. Trả về nhãn các hạn mức vừa đặt lại (đang dùng > 0).
    func resetting(now: Double) -> (usage: ClaudeUsage, labels: [String]) {
        var u = self
        var labels: [String] = []
        func reset(_ w: inout Window?, _ label: String) {
            guard let r = w?.resetsAt, r <= now else { return }
            if (w?.percent ?? 0) > 0 { labels.append(label) }
            w?.percent = 0
            w?.resetsAt = nil
        }
        reset(&u.fiveHour, "5h")
        reset(&u.sevenDay, "7d")
        return (u, labels)
    }

    /// Lần đặt lại sắp tới (chỉ tính hạn mức đang dùng > 0).
    func nextReset(after now: Double) -> Double? {
        [fiveHour, sevenDay].compactMap { w -> Double? in
            guard let w, w.percent > 0, let r = w.resetsAt, r > now else { return nil }
            return r
        }.min()
    }
}

// MARK: - Ghi / gỡ hook trong ~/.claude/settings.json (hàm thuần, có test)

enum ClaudeHookInstaller {
    static let marker = "zmac-claude-hook"
    static let event = "PermissionRequest"
    /// Giây. Hook tự thoát sau 520 s, trước khi Claude Code cắt.
    static let timeout = 540

    enum State: Equatable { case notInstalled, installed, outdated }

    /// Lệnh shell gọi hook. Đường dẫn có ký tự lạ thì đặt trong nháy đơn.
    static func command(for path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
        return safe ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func permissionCommands(_ settings: [String: Any]) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        return groups
            .flatMap { ($0 as? [String: Any])?["hooks"] as? [Any] ?? [] }
            .compactMap { ($0 as? [String: Any])?["command"] as? String }
    }

    static func ourCommands(_ settings: [String: Any]) -> [String] {
        permissionCommands(settings).filter { $0.contains(marker) }
    }

    /// Hook duyệt quyền của app khác (vd Roost): cùng hiện yêu cầu với zMac.
    static func otherPermissionHooks(_ settings: [String: Any]) -> [String] {
        permissionCommands(settings).filter { !$0.contains(marker) }
    }

    /// statusLine do một bản zMac thử nghiệm ghi (bản VS Code không chạy statusLine nên đã bỏ). Gặp thì dọn.
    private static func hasLegacyStatusLine(_ settings: [String: Any]) -> Bool {
        ((settings["statusLine"] as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    static func state(_ settings: [String: Any], path: String) -> State {
        let perm = ourCommands(settings)
        let legacy = hasLegacyStatusLine(settings)
        if perm.isEmpty && !legacy { return .notInstalled }
        return perm == [command(for: path)] && !legacy ? .installed : .outdated
    }

    private static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    /// Bỏ mọi thứ zMac đã ghi, giữ nguyên phần còn lại. Nhóm / khoá chỉ bị xoá khi zMac làm nó rỗng.
    static func uninstall(_ settings: [String: Any]) -> [String: Any] {
        var s = settings
        if hasLegacyStatusLine(s) { s.removeValue(forKey: "statusLine") }
        guard var hooks = s["hooks"] as? [String: Any], let groups = hooks[event] as? [Any] else { return s }
        var kept: [Any] = []
        var changed = false
        for g in groups {
            guard var group = g as? [String: Any], let list = group["hooks"] as? [Any] else { kept.append(g); continue }
            let rest = list.filter { !isOurs($0) }
            if rest.count == list.count { kept.append(g); continue }
            changed = true
            if rest.isEmpty { continue }
            group["hooks"] = rest
            kept.append(group)
        }
        guard changed else { return s }
        if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        if hooks.isEmpty { s.removeValue(forKey: "hooks") } else { s["hooks"] = hooks }
        return s
    }

    /// Thêm đúng một hook của zMac (thay bản cũ nếu có). nil = file có cấu trúc lạ, không dám sửa.
    static func install(_ settings: [String: Any], path: String) -> [String: Any]? {
        if let h = settings["hooks"], !(h is [String: Any]) { return nil }
        if let e = (settings["hooks"] as? [String: Any])?[event], !(e is [Any]) { return nil }
        var s = uninstall(settings)
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        var groups = hooks[event] as? [Any] ?? []
        let hook: [String: Any] = ["type": "command", "command": command(for: path), "timeout": timeout]
        groups.append(["matcher": "*", "hooks": [hook]] as [String: Any])
        hooks[event] = groups
        s["hooks"] = hooks
        return s
    }
}

// MARK: - Module

@MainActor @Observable
final class ClaudeModule: ZModule {
    static let id = "claude"
    static var name: String { "Claude Code" }
    static let replaces = "Roost"
    static let symbol = "sparkle"
    static var summary: String {
        L("Claude Code xin quyền chạy lệnh, sửa file thì notch mở ra để bạn Cho phép hoặc Từ chối. Notch còn hiện hạn mức 5 giờ và 7 ngày đã dùng.",
          "When Claude Code asks to run a command or edit a file, the notch opens so you can allow or deny it. The notch also shows how much of your 5-hour and 7-day limits you've used.")
    }
    static var defaultEnabled: Bool { false }

    private(set) var pending: [ClaudeRequest] = []
    private(set) var hookState: ClaudeHookInstaller.State?
    private(set) var message: String?
    private(set) var otherHooks: [String] = []
    private(set) var usage: ClaudeUsage? = Pref.codable("claude.usage", nil as ClaudeUsage?)

    var showUsage = Pref.bool("claude.showUsage", true) {
        didSet { Pref.set("claude.showUsage", showUsage) }
    }
    var resetAlert = Pref.bool("claude.resetAlert", true) {
        didSet { Pref.set("claude.resetAlert", resetAlert) }
    }

    @ObservationIgnored private var resetWork: DispatchWorkItem?
    @ObservationIgnored private var configSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var configWork: DispatchWorkItem?

    @ObservationIgnored private var listenSource: DispatchSourceRead?
    @ObservationIgnored private var listenFD: Int32 = -1
    @ObservationIgnored private var clients: [Int32: Client] = [:]
    #if DEBUG
    /// Chỉ cho `--claude-selftest`: không cần notch, tự trả lời (nil = để chờ).
    @ObservationIgnored fileprivate var selfTestAnswer: ((ClaudeRequest) -> ClaudeRequest.Decision?)?
    #endif

    private final class Client {
        let source: DispatchSourceRead
        var buffer: [UInt8] = []
        var hasRequest = false
        init(source: DispatchSourceRead) { self.source = source }
    }

    /// ZMAC_CLAUDE_SOCKET chỉ để thử (giống hook). Mở app từ Finder thì không có biến này.
    static var socketPath: String {
        ProcessInfo.processInfo.environment["ZMAC_CLAUDE_SOCKET"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/zMac/claude.sock")
    }

    init() {}

    func start() {
        refreshHookState()
        watchConfig()
        readConfig()
        startServer()
    }

    func stop() {
        resetWork?.cancel()
        resetWork = nil
        configWork?.cancel()
        configWork = nil
        configSource?.cancel()   // cancel handler đóng fd
        configSource = nil
        passAll()
        for c in clients.values { c.source.cancel() }
        clients.removeAll()
        listenSource?.cancel()   // cancel handler đóng fd
        listenSource = nil
        listenFD = -1
        unlink(Self.socketPath)
    }

    // MARK: Socket

    fileprivate func startServer() {
        let path = Self.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            log.error("claude: không mở được socket (errno \(errno))")
            close(fd)
            unlink(path)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptClients() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        listenFD = fd
        listenSource = src
    }

    private func acceptClients() {
        while true {
            let c = accept(listenFD, nil, nil)
            guard c >= 0 else { return }
            // Chỉ nhận tiến trình cùng user. Quá nhiều kết nối thì đóng: hook coi như không quyết định.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == getuid(), clients.count < 16 else { close(c); continue }
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readClient(c) } }
            src.setCancelHandler { close(c) }
            clients[c] = Client(source: src)
            src.resume()
        }
    }

    private func readClient(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var buf = [UInt8](repeating: 0, count: 16_384)
        let n = read(fd, &buf, buf.count)
        if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            drop(fd)   // hook thoát: người dùng đã trả lời trong terminal hoặc Claude Code huỷ
            return
        }
        guard n > 0, !client.hasRequest else { return }
        client.buffer.append(contentsOf: buf[0..<n])
        if client.buffer.count > 1 << 20 { drop(fd); return }
        guard let nl = client.buffer.firstIndex(of: 0x0A) else { return }
        let line = Array(client.buffer[..<nl])
        client.buffer = []
        client.hasRequest = true
        #if DEBUG
        let headless = selfTestAnswer != nil
        #else
        let headless = false
        #endif
        // Không có notch để hiện (Notch tắt, không có màn hình): trả lời ngay để terminal hỏi như thường.
        guard let p = ClaudeRequest.parse(line),
              headless || ModuleManager.shared.module(NotchModule.self)?.canShowClaude == true else {
            finish(fd, .pass, suggestions: nil)
            return
        }
        let request = ClaudeRequest(fd: fd, tool: p.tool, summary: p.summary, project: p.project,
                                    alwaysLabel: p.alwaysLabel, suggestions: p.suggestions)
        pending.append(request)
        log.info("claude: yêu cầu \(p.tool, privacy: .public)")
        notifyNotch()
        #if DEBUG
        if headless {
            print("  nhận \(p.tool): \(p.summary), đang chờ \(pending.count)")
            if let d = selfTestAnswer?(request) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    MainActor.assumeIsolated { self?.respond(request, d) }
                }
            }
        }
        #endif
    }

    private func finish(_ fd: Int32, _ d: ClaudeRequest.Decision, suggestions: Data?) {
        let bytes = ClaudeRequest.reply(d, suggestions: suggestions)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        drop(fd)
    }

    private func drop(_ fd: Int32) {
        clients.removeValue(forKey: fd)?.source.cancel()
        let before = pending.count
        pending.removeAll { $0.fd == fd }
        if pending.count != before { notifyNotch() }
        #if DEBUG
        if selfTestAnswer != nil { print("  đóng kết nối, đang chờ \(pending.count)") }
        #endif
    }

    private func notifyNotch() {
        ModuleManager.shared.module(NotchModule.self)?.setClaudeAttention(!pending.isEmpty)
    }

    // MARK: Mức dùng

    /// ZMAC_CLAUDE_CONFIG chỉ để thử (giống ZMAC_CLAUDE_SOCKET).
    static var claudeConfigPath: String {
        ProcessInfo.processInfo.environment["ZMAC_CLAUDE_CONFIG"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
    }

    /// Theo dõi ~/.claude.json bằng kqueue (DispatchSource), không poll. Claude Code ghi file này thường xuyên,
    /// nên gom các lần ghi sát nhau lại rồi mới đọc. File bị thay (ghi nguyên tử) thì mở lại.
    fileprivate func watchConfig() {
        configSource?.cancel()
        configSource = nil
        let fd = open(Self.claudeConfigPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let events = self.configSource?.data else { return }
                self.scheduleConfigRead(replaced: !events.isDisjoint(with: [.delete, .rename]))
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configSource = src
    }

    private func scheduleConfigRead(replaced: Bool) {
        #if DEBUG
        if isSelfTest { print("  ~/.claude.json đổi\(replaced ? " (file mới)" : "")") }
        #endif
        if replaced {
            configSource?.cancel()
            configSource = nil
        }
        configWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.configSource == nil { self.watchConfig() }
                self.readConfig()
            }
        }
        configWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    fileprivate func readConfig() {
        guard let data = FileManager.default.contents(atPath: Self.claudeConfigPath),
              let fresh = ClaudeUsage.fromClaudeConfig(data: data) else { return }
        // Hạn mức đã qua giờ đặt lại mà Claude Code chưa lấy số mới: coi là 0, không báo lại.
        let (u, _) = fresh.resetting(now: Date().timeIntervalSince1970)
        guard u != usage else { return }
        usage = u
        saveUsage()
        #if DEBUG
        if isSelfTest { print("  mức dùng: 5h \(u.fiveHour?.percent ?? -1)% 7d \(u.sevenDay?.percent ?? -1)%") }
        #endif
        scheduleReset()
    }

    /// `--claude-selftest` không được ghi vào defaults.
    private var isSelfTest: Bool {
        #if DEBUG
        selfTestAnswer != nil
        #else
        false
        #endif
    }

    private func saveUsage() {
        if !isSelfTest { Pref.setCodable("claude.usage", usage) }
    }

    /// Hẹn đúng một lần cho lần đặt lại kế tiếp (không lặp). Tới giờ: về 0 và báo trên notch.
    private func scheduleReset() {
        resetWork?.cancel()
        resetWork = nil
        let now = Date().timeIntervalSince1970
        guard let at = usage?.nextReset(after: now) else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.limitReset() } }
        resetWork = w
        // wallDeadline: vẫn đúng giờ sau khi máy ngủ dậy.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(at - now, 1), execute: w)
    }

    private func limitReset() {
        guard let current = usage else { return }
        let (next, labels) = current.resetting(now: Date().timeIntervalSince1970)
        usage = next
        saveUsage()
        if resetAlert, let label = labels.first {
            ModuleManager.shared.module(NotchModule.self)?.showHUD(
                NotchHUD(symbol: "sparkle", text: "\(label) 0%", color: ZTheme.orange.light), seconds: 4)
        }
        scheduleReset()
    }

    // MARK: Trả lời (thẻ trên notch gọi)

    func respond(_ request: ClaudeRequest, _ d: ClaudeRequest.Decision) {
        guard pending.contains(where: { $0.id == request.id }) else { return }
        finish(request.fd, d, suggestions: request.suggestions)
    }

    /// Notch biến mất hoặc module tắt: trả mọi yêu cầu về terminal.
    func passAll() {
        for r in pending { finish(r.fd, .pass, suggestions: nil) }
    }

    // MARK: settings.json

    /// Đi theo symlink (dotfiles): ghi nguyên tử vào đường dẫn symlink sẽ biến nó thành file thường.
    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
    }

    /// Hook nằm cạnh file chạy của app (Contents/MacOS khi đóng gói, .build/debug khi chạy thử).
    static var hookPath: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let p = dir.appendingPathComponent(ClaudeHookInstaller.marker).path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    private enum SettingsError: Error { case unreadable, unexpected }

    private func readSettings() throws -> [String: Any] {
        let url = Self.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SettingsError.unreadable }
        return obj
    }

    /// Sao lưu bản hiện tại thành settings.json.zmac-backup rồi ghi đè nguyên tử, giữ quyền file cũ.
    private func writeSettings(_ obj: [String: Any]) throws {
        let fm = FileManager.default
        let url = Self.settingsURL
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var perms: Any?
        if fm.fileExists(atPath: url.path) {
            perms = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]
            let backup = url.appendingPathExtension("zmac-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    func refreshHookState() {
        guard let path = Self.hookPath, let settings = try? readSettings() else { hookState = nil; return }
        hookState = ClaudeHookInstaller.state(settings, path: path)
        otherHooks = ClaudeHookInstaller.otherPermissionHooks(settings).map { cmd in
            let first = cmd.split(separator: " ").first.map(String.init) ?? cmd
            return (first as NSString).lastPathComponent
        }
    }

    func connect() {
        message = nil
        guard let path = Self.hookPath else {
            message = L("Không tìm thấy zmac-claude-hook cạnh app. Hãy build lại bằng ./build.sh.",
                        "Can't find zmac-claude-hook next to the app. Rebuild with ./build.sh.")
            return
        }
        do {
            guard let next = ClaudeHookInstaller.install(try readSettings(), path: path) else {
                throw SettingsError.unexpected
            }
            try writeSettings(next)
            message = L("Đã kết nối. Phiên Claude Code đang mở cần mở lại để nhận hook.",
                        "Connected. Restart any open Claude Code session to pick up the hook.")
        } catch {
            message = L("Không sửa được ~/.claude/settings.json (file không phải JSON hợp lệ?). File chưa bị đổi.",
                        "Couldn't update ~/.claude/settings.json (not valid JSON?). The file was left unchanged.")
        }
        refreshHookState()
    }

    func disconnect() {
        message = nil
        do {
            let current = try readSettings()
            let next = ClaudeHookInstaller.uninstall(current)
            if ClaudeHookInstaller.state(current, path: Self.hookPath ?? "") != .notInstalled { try writeSettings(next) }
            message = L("Đã gỡ hook của zMac khỏi settings.json.", "Removed zMac's hook from settings.json.")
        } catch {
            message = L("Không sửa được ~/.claude/settings.json. File chưa bị đổi.",
                        "Couldn't update ~/.claude/settings.json. The file was left unchanged.")
        }
        refreshHookState()
    }

    /// `zMac --diagnose`: hạn mức đọc được từ ~/.claude.json (chỉ đọc).
    static func diagnose() {
        guard let data = FileManager.default.contents(atPath: claudeConfigPath) else {
            print("  Claude Code: không có ~/.claude.json")
            return
        }
        guard let u = ClaudeUsage.fromClaudeConfig(data: data) else {
            print("  Claude Code: ~/.claude.json chưa có hạn mức")
            return
        }
        let age = u.fetchedAt.map { Int((Date().timeIntervalSince1970 - $0) / 60) }
        print("  Claude Code: 5h \(u.fiveHour.map(describe) ?? "-"); 7d \(u.sevenDay.map(describe) ?? "-"); "
              + "lấy cách đây \(age.map(String.init) ?? "?") phút")
    }

    // MARK: Cài đặt

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm")
        return f.string(from: date)
    }

    static func describe(_ w: ClaudeUsage.Window) -> String {
        var text = "\(Int(w.percent.rounded()))%"
        if let r = w.resetsAt { text += L(", đặt lại ", ", resets ") + clock(Date(timeIntervalSince1970: r)) }
        return text
    }

    func settingsView() -> AnyView {
        moduleForm {
            Section {
                LabeledContent(L("Trạng thái", "Status")) {
                    switch hookState {
                    case .installed: Text(L("Đã kết nối", "Connected")).foregroundStyle(ZTheme.green.light)
                    case .outdated: Text(L("Cần cập nhật kết nối", "Connection needs an update")).foregroundStyle(ZTheme.orange.light)
                    case .notInstalled: Text(L("Chưa kết nối", "Not connected"))
                    case nil:
                        Text(Self.hookPath == nil ? L("Thiếu zmac-claude-hook cạnh app", "zmac-claude-hook is missing next to the app")
                                                  : L("Không đọc được settings.json", "Can't read settings.json"))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    switch hookState {
                    case .installed:
                        Button(L("Gỡ kết nối", "Disconnect")) { self.disconnect() }
                    case .outdated:
                        Button(L("Cập nhật kết nối", "Update connection")) { self.connect() }
                        Button(L("Gỡ kết nối", "Disconnect")) { self.disconnect() }
                    default:
                        Button(L("Kết nối Claude Code", "Connect Claude Code")) { self.connect() }
                    }
                    Spacer()
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Kết nối thêm một hook PermissionRequest vào ~/.claude/settings.json (bản cũ được sao lưu thành settings.json.zmac-backup). Gỡ kết nối chỉ bỏ đúng hook đó. Khi zMac không chạy, hook tự bỏ qua và Claude Code hỏi trong terminal như thường.",
                       "Connecting adds one PermissionRequest hook to ~/.claude/settings.json (the old file is backed up as settings.json.zmac-backup). Disconnecting removes only that hook. When zMac isn't running the hook steps aside and Claude Code asks in the terminal as usual."))
                    .font(.caption).foregroundStyle(.secondary)
                if !otherHooks.isEmpty {
                    Label(L("Hook duyệt quyền khác cũng đang bật: \(otherHooks.joined(separator: ", ")). Mỗi yêu cầu sẽ hiện ở cả hai app; gỡ hook kia nếu không còn dùng app đó.",
                            "Another approval hook is also set up: \(otherHooks.joined(separator: ", ")). Every request will show in both apps; remove that hook if you no longer use the other app."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(ZTheme.orange.light)
                }
            }
            Section(L("Mức dùng", "Usage")) {
                if let u = usage, u.hasLimits {
                    if let w = u.fiveHour { LabeledContent(L("5 giờ", "5 hours"), value: Self.describe(w)) }
                    if let w = u.sevenDay { LabeledContent(L("7 ngày", "7 days"), value: Self.describe(w)) }
                    if let at = u.fetchedAt {
                        LabeledContent(L("Claude Code cập nhật", "Updated by Claude Code"),
                                       value: Self.clock(Date(timeIntervalSince1970: at)))
                    }
                } else {
                    Text(L("Chưa có số liệu. Claude Code lưu hạn mức sau khi đăng nhập bằng gói Pro hoặc Max.",
                           "No data yet. Claude Code saves your limits once you sign in with a Pro or Max plan."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle(L("Hiện trên notch", "Show on the notch"),
                       isOn: Binding(get: { self.showUsage }, set: { self.showUsage = $0 }))
                Toggle(L("Báo trên notch khi hạn mức đặt lại", "Tell me on the notch when a limit resets"),
                       isOn: Binding(get: { self.resetAlert }, set: { self.resetAlert = $0 }))
                Text(L("zMac đọc số Claude Code tự lưu trong ~/.claude.json (chạy cả với bản VS Code), không cần mạng hay Keychain. Claude Code làm mới số này theo nhịp riêng nên có thể chậm vài chục phút; dòng \"Claude Code cập nhật\" cho biết số mới đến đâu.",
                       "zMac reads the numbers Claude Code saves in ~/.claude.json (works with the VS Code extension too), with no network or Keychain access. Claude Code refreshes them on its own schedule, so they can lag by tens of minutes; \"Updated by Claude Code\" tells you how fresh they are."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if ModuleManager.shared.module(NotchModule.self)?.canShowClaude != true {
                Section {
                    Label(L("Cần bật Notch (máy không có notch thì bật cả notch giả) để hiện yêu cầu. Lúc này Claude Code vẫn hỏi trong terminal.",
                            "Turn on Notch (and the virtual notch on Macs without one) to see requests. Until then Claude Code keeps asking in the terminal."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ZTheme.orange.light)
                }
            }
            Section(L("Cách dùng", "How it works")) {
                Text(L("Claude xin quyền thì notch mở ra với lệnh hoặc file nó muốn đụng tới. Trả lời trong terminal cũng được, thẻ trên notch tự biến mất. Luôn cho phép thêm quy tắc Claude Code gợi ý, giống chọn \"Yes, and don't ask again\".",
                       "When Claude asks for permission the notch opens with the command or file it wants to touch. You can still answer in the terminal and the card goes away. Always allow adds the rule Claude Code suggests, like picking \"Yes, and don't ask again\"."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Thẻ trên notch

struct ClaudeRequestCard: View {
    let module: ClaudeModule
    let request: ClaudeRequest
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZTile(symbol: "sparkle", hue: ZTheme.orange, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Claude muốn dùng ", "Claude wants to use ") + request.tool)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !request.project.isEmpty {
                        Text(request.project)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if count > 1 {
                    Text(L("còn \(count - 1)", "+\(count - 1) more"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
            }
            Text(request.summary.isEmpty ? request.tool : request.summary)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
                .help(request.summary)
            HStack(spacing: 6) {
                Button(L("Hỏi trong terminal", "Ask in terminal")) { module.respond(request, .pass) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                pill(L("Từ chối", "Deny"), fill: Color(hex: 0xFF695D).opacity(0.22), text: Color(hex: 0xFF8A80)) {
                    module.respond(request, .deny)
                }
                if let rule = request.alwaysLabel {
                    pill(L("Luôn cho phép", "Always allow"), fill: .white.opacity(0.14), text: .white) {
                        module.respond(request, .allowAlways)
                    }
                    .help(rule.isEmpty ? L("Không hỏi lại lệnh này", "Don't ask again for this") : rule)
                }
                pill(L("Cho phép", "Allow"), fill: .white, text: .black) {
                    module.respond(request, .allow)
                }
            }
        }
    }

    private func pill(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(fill))
                .foregroundStyle(text)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mức dùng trên hàng trên của notch

struct ClaudeUsageBadge: View {
    let usage: ClaudeUsage

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ZTheme.orange.light)
            if let w = usage.fiveHour { item("5h", w) }
            if usage.fiveHour != nil, usage.sevenDay != nil {
                Capsule().fill(.white.opacity(0.18)).frame(width: 1, height: 10)
            }
            if let w = usage.sevenDay { item("7d", w) }
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.08)))
        .fixedSize()
    }

    private func item(_ label: String, _ w: ClaudeUsage.Window) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.white.opacity(0.5))
            Text("\(Int(w.percent.rounded()))%").foregroundStyle(Self.color(w.percent))
        }
        .help(ClaudeModule.describe(w))
    }

    /// Dưới 50% trắng, tới 80% cam, trên nữa đỏ.
    static func color(_ percent: Double) -> Color {
        switch percent {
        case ..<50: .white.opacity(0.85)
        case ..<80: ZTheme.orange.light
        default: Color(hex: 0xFF8A80)
        }
    }
}

#if DEBUG
extension ClaudeModule {
    /// Chỉ cho `--render-ui`: hai yêu cầu mẫu, không mở socket.
    func previewRequests() {
        pending = [
            ClaudeRequest(fd: -1, tool: "Bash", summary: "swift build -c release && ./scripts/test.sh",
                          project: "zMac", alwaysLabel: "Bash(swift build:*)", suggestions: nil),
            ClaudeRequest(fd: -1, tool: "Edit", summary: "~/zMac/Sources/zMac/Modules/Notch.swift",
                          project: "zMac", alwaysLabel: nil, suggestions: nil),
        ]
    }

    func clearPreview() { pending = [] }

    func previewUsage() {
        let now = Date().timeIntervalSince1970
        usage = ClaudeUsage(fiveHour: .init(percent: 81, resetsAt: now + 5400),
                            sevenDay: .init(percent: 60, resetsAt: now + 3 * 86400), fetchedAt: now - 600)
    }

    /// `zMac --claude-selftest GIÂY`: chỉ chạy server socket (đặt ZMAC_CLAUDE_SOCKET), không notch, không module khác.
    /// Tự trả lời: Bash cho phép, Edit từ chối, Write luôn cho phép, công cụ khác để chờ tới khi hook đóng kết nối.
    static func selfTest(seconds: Double) {
        let m = ClaudeModule()
        m.selfTestAnswer = { r in
            switch r.tool {
            case "Bash": .allow
            case "Edit": .deny
            case "Write": .allowAlways
            default: nil
            }
        }
        m.startServer()
        m.watchConfig()
        m.readConfig()
        print("claude selftest: nghe \(socketPath)")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print("claude selftest: hết giờ, còn \(m.pending.count) yêu cầu")
        m.stop()
    }
}
#endif
