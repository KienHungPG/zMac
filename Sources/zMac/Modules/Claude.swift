import AppKit
import Darwin
import Observation
import SwiftUI

// Duyệt quyền của Claude Code ngay trên notch.
// - zmac-claude-hook (hook PermissionRequest) gửi yêu cầu qua Unix socket trong Application Support.
// - Module nghe socket bằng DispatchSource (theo sự kiện, không poll). Mỗi yêu cầu giữ kết nối tới khi người dùng bấm.
// - Hook đóng kết nối (người dùng trả lời trong terminal, Claude Code huỷ) thì thẻ tự biến mất.
// - Chỉ sửa ~/.claude/settings.json khi người dùng bấm Kết nối; Gỡ chỉ bỏ đúng mục của zMac. Đã kết nối (chưa Gỡ) thì
//   bản cài trong Applications tự nối lại khi hook bị cũ, đổi đường dẫn hay bị xoá (tắt được; theo dõi file bằng kqueue).

/// Một câu hỏi của công cụ AskUserQuestion (Claude hỏi lại người dùng, kèm 2 đến 4 lựa chọn).
struct ClaudeQuestion: Equatable {
    struct Option: Equatable {
        var label: String
        var detail: String
    }

    var question: String
    var header: String
    var options: [Option]
    var multiSelect: Bool
}

/// Sự kiện Claude Code báo qua hook (PostToolUse, Stop). Claude Code không dừng hook PermissionRequest khi người dùng
/// trả lời ngay trong terminal hay VS Code, nên zMac dựa vào các sự kiện này để gỡ thẻ đã lỗi thời.
struct ClaudeEvent: Equatable {
    var name: String
    var session: String
    /// PostToolUse: công cụ vừa chạy, tên và dòng tóm tắt tính giống hệt thẻ.
    var tool: String?
    var summary: String?

    /// nil = không phải sự kiện (là yêu cầu cấp quyền, hoặc dòng hỏng).
    static func parse(_ line: [UInt8]) -> ClaudeEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let name = obj["hook_event_name"] as? String, name != ClaudeHookInstaller.event else { return nil }
        var ev = ClaudeEvent(name: name, session: obj["session_id"] as? String ?? "")
        if name == "PostToolUse", let tool = obj["tool_name"] as? String {
            ev.tool = ClaudeRequest.displayName(tool)
            ev.summary = ClaudeRequest.summary(tool: tool, input: obj["tool_input"] as? [String: Any] ?? [:])
        }
        return ev
    }

    /// Thẻ này đã được trả lời ở chỗ khác. Công cụ chạy xong: đúng công cụ và nội dung đó. Hết lượt: mọi thẻ của phiên.
    func resolves(_ r: ClaudeRequest) -> Bool {
        guard !session.isEmpty, r.session == session else { return false }
        if name == "PostToolUse" { return r.tool == tool && r.summary == summary }
        return ["Stop", "UserPromptSubmit", "SessionEnd"].contains(name)
    }
}

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
    /// AskUserQuestion: các câu hỏi (rỗng = yêu cầu quyền thường).
    var questions: [ClaudeQuestion] = []
    /// ExitPlanMode: Claude xin bắt đầu làm theo kế hoạch (`summary` là kế hoạch).
    var isPlan = false
    /// tool_input gốc. AskUserQuestion và ExitPlanMode phải gửi lại nó trong updatedInput, "allow" suông không đủ.
    var input: Data?
    /// Phiên Claude Code (session_id): để nhận ra yêu cầu đã được trả lời ở chỗ khác.
    var session = ""

    enum Decision: Equatable {
        case allow, allowAlways, deny, pass
        /// Trả lời AskUserQuestion: câu hỏi -> nhãn đã chọn (chọn nhiều thì nối bằng ", ").
        case answer([String: String])
    }

    struct Parsed: Equatable {
        var tool: String
        var summary: String
        var project: String
        var alwaysLabel: String?
        var suggestions: Data?
        var questions: [ClaudeQuestion] = []
        var isPlan = false
        var input: Data?
        var session = ""
    }

    /// Đọc một dòng JSON hook gửi (đúng stdin của Claude Code).
    static func parse(_ line: [UInt8]) -> Parsed? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let tool = obj["tool_name"] as? String, !tool.isEmpty else { return nil }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let cwd = obj["cwd"] as? String ?? ""
        let sugg = obj["permission_suggestions"] as? [[String: Any]] ?? []
        let questions = tool == "AskUserQuestion" ? Self.questions(input) : []
        let isPlan = tool == "ExitPlanMode"
        return Parsed(tool: displayName(tool), summary: summary(tool: tool, input: input),
                      project: cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent,
                      alwaysLabel: alwaysLabel(sugg),
                      suggestions: sugg.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: sugg),
                      questions: questions, isPlan: isPlan,
                      input: !questions.isEmpty || isPlan ? try? JSONSerialization.data(withJSONObject: input) : nil,
                      session: obj["session_id"] as? String ?? "")
    }

    static func questions(_ input: [String: Any]) -> [ClaudeQuestion] {
        guard let list = input["questions"] as? [[String: Any]] else { return [] }
        return list.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty,
                  let opts = q["options"] as? [[String: Any]] else { return nil }
            let options = opts.compactMap { o -> ClaudeQuestion.Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return .init(label: label, detail: o["description"] as? String ?? "")
            }
            guard !options.isEmpty else { return nil }
            return ClaudeQuestion(question: text, header: q["header"] as? String ?? "", options: options,
                                  multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// Lựa chọn (chỉ số theo từng câu) -> `answers` cho updatedInput. Câu chưa chọn thì bỏ qua.
    static func answers(_ questions: [ClaudeQuestion], picks: [Int: Set<Int>]) -> [String: String] {
        var out: [String: String] = [:]
        for (i, q) in questions.enumerated() {
            let labels = (picks[i] ?? []).sorted().compactMap { q.options.indices.contains($0) ? q.options[$0].label : nil }
            if !labels.isEmpty { out[q.question] = labels.joined(separator: ", ") }
        }
        return out
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
        case "ExitPlanMode": return String((s("plan") ?? "").prefix(4000))
        case "AskUserQuestion":
            text = ((input["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? ""
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
    /// `input` (AskUserQuestion, ExitPlanMode) được gửi lại nguyên vẹn trong updatedInput, kèm `answers` nếu có.
    static func reply(_ d: Decision, suggestions: Data?, input: Data? = nil, plan: Bool = false) -> [UInt8] {
        let original = input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var obj: [String: Any]
        switch d {
        case .allow:
            obj = ["behavior": "allow"]
            if let original { obj["updatedInput"] = original }
        case .allowAlways:
            obj = ["behavior": "allow"]
            if let original { obj["updatedInput"] = original }
            if let suggestions, let arr = try? JSONSerialization.jsonObject(with: suggestions) as? [Any] {
                obj["updatedPermissions"] = arr
            }
        case .answer(let answers):
            var updated = original ?? [:]
            updated["answers"] = answers
            obj = ["behavior": "allow", "updatedInput": updated]
        case .deny:
            obj = ["behavior": "deny",
                   "message": plan ? "The user wants to keep planning (said in zMac). Ask what to change."
                                   : "The user denied this in zMac."]
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
    /// Lúc lấy số liệu (giây kể từ 1970): Claude Code ghi vào ~/.claude.json, hoặc zMac tự hỏi Anthropic.
    var fetchedAt: Double?
    /// Tài khoản Claude của số liệu (accountUuid), để không lẫn số khi đổi tài khoản.
    var account: String? = nil
    /// zMac tự hỏi Anthropic (tuỳ chọn) thay vì đọc số Claude Code lưu.
    var live: Bool? = nil

    /// Số đã cũ hơn 30 phút: notch hiện mờ đi.
    static let staleAfter: Double = 30 * 60

    var hasLimits: Bool { fiveHour != nil || sevenDay != nil }

    /// Kết quả đọc ~/.claude.json.
    enum Reading: Equatable {
        /// Không đọc được (đang ghi dở, hỏng): giữ số đang hiện.
        case unreadable
        /// Tài khoản đang đăng nhập không có số: chưa lấy, gói không có hạn mức, đã đăng xuất,
        /// hoặc vừa đổi tài khoản mà số trong file vẫn của tài khoản cũ. Ẩn đi.
        case noLimits
        case usage(ClaudeUsage)
    }

    static func read(_ bytes: [UInt8]) -> Reading { read(data: Data(bytes)) }

    static func read(data: Data) -> Reading { readWithAccount(data: data).reading }

    /// Như `read`, kèm tài khoản đang đăng nhập (oauthAccount.accountUuid) để biết số zMac tự lấy còn đúng người không.
    static func readWithAccount(data: Data) -> (reading: Reading, account: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (.unreadable, nil) }
        let current = (obj["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
        guard let cache = obj["cachedUsageUtilization"] as? [String: Any],
              let util = cache["utilization"] as? [String: Any] else { return (.noLimits, current) }
        // Claude Code chỉ lấy số mới sau một lúc, nên ngay sau khi đổi tài khoản file vẫn giữ số của tài khoản cũ.
        let owner = cache["accountUuid"] as? String
        if let owner, owner != current { return (.noLimits, current) }
        guard let u = parse(util, fetchedAt: number(cache["fetchedAtMs"]).map { $0 / 1000 }, account: owner ?? current)
        else { return (.noLimits, current) }
        return (.usage(u), current)
    }

    /// Phần "utilization" (Claude Code lưu nguyên câu trả lời của api/oauth/usage): five_hour, seven_day.
    static func parse(_ util: [String: Any], fetchedAt: Double?, account: String?, live: Bool? = nil) -> ClaudeUsage? {
        func window(_ key: String) -> Window? {
            guard let w = util[key] as? [String: Any], let p = number(w["utilization"]) else { return nil }
            return Window(percent: min(max(p, 0), 100), resetsAt: time(w["resets_at"]))
        }
        let u = ClaudeUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), fetchedAt: fetchedAt,
                            account: account, live: live)
        return u.hasLimits ? u : nil
    }

    /// Câu trả lời của api.anthropic.com/api/oauth/usage (zMac tự hỏi).
    static func fromResponse(_ bytes: [UInt8], fetchedAt: Double, account: String?) -> ClaudeUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return nil }
        return parse(obj, fetchedAt: fetchedAt, account: account, live: true)
    }

    func isStale(now: Double) -> Bool { fetchedAt.map { now - $0 >= Self.staleAfter } ?? false }

    /// Gộp số mới (từ file hoặc tự hỏi) với số đang hiện: cùng tài khoản thì giữ số lấy sau cùng.
    static func newer(_ current: ClaudeUsage?, _ fresh: ClaudeUsage) -> ClaudeUsage {
        guard let current, current.account == fresh.account,
              let a = current.fetchedAt, let b = fresh.fetchedAt, b < a else { return fresh }
        return current
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

// MARK: - Hạn mức lấy thẳng từ Anthropic (tuỳ chọn, tắt sẵn)

/// Đọc token đăng nhập Claude Code trong Keychain ("Claude Code-credentials", macOS hỏi quyền lần đầu) rồi hỏi
/// api.anthropic.com/api/oauth/usage, chỗ Claude Code lấy số cho /usage. Không bao giờ làm mới token: làm vậy đổi
/// refresh token và Claude Code bị đăng xuất. Token hết hạn thì chờ Claude Code tự làm mới. Không ghi token ra log.
enum ClaudeLiveUsage {
    enum Failure: Error, Equatable { case noLogin, denied, expired, rejected, network }

    static let service = "Claude Code-credentials"
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// {"claudeAiOauth": {"accessToken": "...", "expiresAt": mili giây}} → token còn hạn.
    static func accessToken(fromCredentials bytes: [UInt8], now: Double) -> Result<String, Failure> {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .failure(.noLogin) }
        if let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue, exp / 1000 <= now + 30 { return .failure(.expired) }
        return .success(token)
    }

    /// Chạy trên luồng nền: SecItemCopyMatching chờ tới khi người dùng trả lời hộp hỏi quyền Keychain.
    nonisolated private static func token(now: Double) -> Result<String, Failure> {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess: break
        case errSecItemNotFound: return .failure(.noLogin)
        default: return .failure(.denied)
        }
        guard let data = out as? Data else { return .failure(.noLogin) }
        return accessToken(fromCredentials: Array(data), now: now)
    }

    /// Kết quả (câu trả lời JSON, dạng byte) gọi trên main.
    static func fetch(done: @escaping @MainActor @Sendable (Result<[UInt8], Failure>) -> Void) {
        func finish(_ r: Result<[UInt8], Failure>) {
            DispatchQueue.main.async { MainActor.assumeIsolated { done(r) } }
        }
        DispatchQueue.global(qos: .utility).async {
            let token: String
            switch Self.token(now: Date().timeIntervalSince1970) {
            case .failure(let f): return finish(.failure(f))
            case .success(let t): token = t
            }
            var req = URLRequest(url: endpoint, timeoutInterval: 10)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            // Phiên ephemeral: không ghi cache / cookie ra đĩa.
            let session = URLSession(configuration: .ephemeral)
            session.dataTask(with: req) { data, response, _ in
                switch (response as? HTTPURLResponse)?.statusCode {
                case 200?: finish(data.map { .success(Array($0)) } ?? .failure(.network))
                case 401?, 403?: finish(.failure(.rejected))
                default: finish(.failure(.network))
                }
            }.resume()
            session.finishTasksAndInvalidate()
        }
    }
}

// MARK: - Ghi / gỡ hook trong ~/.claude/settings.json (hàm thuần, có test)

enum ClaudeHookInstaller {
    static let marker = "zmac-claude-hook"
    static let event = "PermissionRequest"
    /// Sự kiện chỉ để biết yêu cầu đã được trả lời ở chỗ khác (terminal, VS Code), để gỡ thẻ trên notch.
    static let watchEvents = ["PostToolUse", "Stop"]
    /// Giây. Hook tự thoát sau 520 s, trước khi Claude Code cắt.
    static let timeout = 540
    /// Hook báo sự kiện chỉ gửi một dòng rồi thoát.
    static let watchTimeout = 5

    enum State: Equatable { case notInstalled, installed, outdated }

    /// Tự nối lại khi người dùng đã bấm Kết nối (chưa Gỡ) mà hook của zMac bị cũ, đổi đường dẫn hay bị xoá mất.
    static func needsRepair(_ state: State, wanted: Bool) -> Bool { wanted && state != .installed }

    /// Bản trước chưa lưu ý muốn kết nối: settings.json đang có hook của zMac thì coi như đã bấm Kết nối.
    static func inferWanted(_ state: State) -> Bool { state != .notInstalled }

    /// Chỉ bản cài (/Applications, ~/Applications) mới tự sửa settings.json; bản chạy thử (.build, build/) thì không,
    /// kẻo hai bản giành nhau đường dẫn hook.
    static func autoRepairAllowed(hookPath: String) -> Bool { hookPath.contains("/Applications/") }

    /// Lệnh shell gọi hook. Đường dẫn có ký tự lạ thì đặt trong nháy đơn.
    static func command(for path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
        return safe ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        return groups
            .flatMap { ($0 as? [String: Any])?["hooks"] as? [Any] ?? [] }
            .compactMap { ($0 as? [String: Any])?["command"] as? String }
    }

    static func ourCommands(_ settings: [String: Any]) -> [String] {
        commands(settings, event).filter { $0.contains(marker) }
    }

    /// Hook duyệt quyền của app khác: cùng hiện yêu cầu với zMac.
    static func otherPermissionHooks(_ settings: [String: Any]) -> [String] {
        commands(settings, event).filter { !$0.contains(marker) }
    }

    /// statusLine do một bản zMac thử nghiệm ghi (bản VS Code không chạy statusLine nên đã bỏ). Gặp thì dọn.
    private static func hasLegacyStatusLine(_ settings: [String: Any]) -> Bool {
        ((settings["statusLine"] as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    static func state(_ settings: [String: Any], path: String) -> State {
        let perm = ourCommands(settings)
        let watched = watchEvents.map { e in commands(settings, e).filter { $0.contains(marker) } }
        let legacy = hasLegacyStatusLine(settings)
        if perm.isEmpty && watched.allSatisfy(\.isEmpty) && !legacy { return .notInstalled }
        let cmd = [command(for: path)]
        return perm == cmd && watched.allSatisfy { $0 == cmd } && !legacy ? .installed : .outdated
    }

    private static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    /// Bỏ mọi thứ zMac đã ghi (ở mọi sự kiện), giữ nguyên phần còn lại. Nhóm / khoá chỉ bị xoá khi zMac làm nó rỗng.
    static func uninstall(_ settings: [String: Any]) -> [String: Any] {
        var s = settings
        if hasLegacyStatusLine(s) { s.removeValue(forKey: "statusLine") }
        guard var hooks = s["hooks"] as? [String: Any] else { return s }
        var changed = false
        for (name, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            var touched = false
            for g in groups {
                guard var group = g as? [String: Any], let list = group["hooks"] as? [Any] else { kept.append(g); continue }
                let rest = list.filter { !isOurs($0) }
                if rest.count == list.count { kept.append(g); continue }
                touched = true
                if rest.isEmpty { continue }
                group["hooks"] = rest
                kept.append(group)
            }
            guard touched else { continue }
            changed = true
            if kept.isEmpty { hooks.removeValue(forKey: name) } else { hooks[name] = kept }
        }
        guard changed else { return s }
        if hooks.isEmpty { s.removeValue(forKey: "hooks") } else { s["hooks"] = hooks }
        return s
    }

    /// Thêm hook của zMac (thay bản cũ nếu có). nil = file có cấu trúc lạ, không dám sửa.
    static func install(_ settings: [String: Any], path: String) -> [String: Any]? {
        if let h = settings["hooks"], !(h is [String: Any]) { return nil }
        for e in [event] + watchEvents {
            if let v = (settings["hooks"] as? [String: Any])?[e], !(v is [Any]) { return nil }
        }
        var s = uninstall(settings)
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        let cmd = command(for: path)
        func add(_ e: String, _ group: [String: Any]) {
            var groups = hooks[e] as? [Any] ?? []
            groups.append(group)
            hooks[e] = groups
        }
        add(event, ["matcher": "*", "hooks": [["type": "command", "command": cmd, "timeout": timeout] as [String: Any]]])
        for e in watchEvents {
            var group: [String: Any] = ["hooks": [["type": "command", "command": cmd, "timeout": watchTimeout] as [String: Any]]]
            if e == "PostToolUse" { group["matcher"] = "*" }
            add(e, group)
        }
        s["hooks"] = hooks
        return s
    }
}

// MARK: - Module

@MainActor @Observable
final class ClaudeModule: ZModule {
    static let id = "claude"
    static var name: String { "Claude Code" }
    static let replaces = ""
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
    /// Tự hỏi hạn mức từ Anthropic (Keychain + mạng). Tắt sẵn.
    var liveUsage = Pref.bool("claude.liveUsage", false) {
        didSet {
            Pref.set("claude.liveUsage", liveUsage)
            liveUsageError = nil
            liveBlocked = false
            if liveUsage { fetchUsage(force: true) }
        }
    }
    /// Lần tự hỏi gần nhất bị lỗi (hiện trong Cài đặt).
    private(set) var liveUsageError: String?
    /// Số đang hiện đã cũ hơn 30 phút.
    private(set) var usageStale = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var lastFetch: Date?
    /// Bị từ chối Keychain / chưa đăng nhập: thôi hỏi tới khi bật lại công tắc, không hiện hộp hỏi quyền mãi.
    @ObservationIgnored private var liveBlocked = false
    /// Tài khoản đang đăng nhập Claude Code (đọc từ ~/.claude.json).
    @ObservationIgnored private var currentAccount: String?
    @ObservationIgnored private var staleWork: DispatchWorkItem?

    /// Hook bị cũ / đổi đường dẫn / bị xoá thì tự thêm lại (chỉ khi đã bấm Kết nối).
    var autoReconnect = Pref.bool("claude.autoReconnect", true) {
        didSet {
            Pref.set("claude.autoReconnect", autoReconnect)
            if autoReconnect { repairIfNeeded() }
        }
    }

    /// Người dùng muốn kết nối: bật khi bấm Kết nối, tắt khi Gỡ. nil = chưa biết (cài từ bản chưa lưu mục này).
    @ObservationIgnored private var wantsConnection = UserDefaults.standard.object(forKey: "claude.connected") as? Bool
    /// Số lần tự nối lại trong lần chạy này: công cụ khác cứ xoá hook thì thôi, không giành nhau mãi.
    @ObservationIgnored private var repairs = 0
    @ObservationIgnored private var settingsSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var settingsWork: DispatchWorkItem?

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
        active = true
        refreshHookState()
        repairIfNeeded()
        watchSettings()
        watchConfig()
        readConfig()
        startServer()
        updateStale()
        fetchUsage(force: true)
    }

    func stop() {
        active = false
        staleWork?.cancel()
        staleWork = nil
        resetWork?.cancel()
        resetWork = nil
        configWork?.cancel()
        configWork = nil
        configSource?.cancel()   // cancel handler đóng fd
        configSource = nil
        settingsWork?.cancel()
        settingsWork = nil
        settingsSource?.cancel()   // cancel handler đóng fd
        settingsSource = nil
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
        // Sự kiện (không phải yêu cầu): gỡ các thẻ đã được trả lời ở chỗ khác, đóng kết nối, không trả lời gì.
        if let ev = ClaudeEvent.parse(line) {
            drop(fd)
            for r in pending where ev.resolves(r) {
                log.info("claude: \(ev.name, privacy: .public) gỡ thẻ \(r.tool, privacy: .public)")
                finish(r.fd, .pass, suggestions: nil)
            }
            // Claude vừa dùng thêm: hỏi lại hạn mức (nếu bật, tối đa 2 phút một lần).
            fetchUsage()
            return
        }
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
                                    alwaysLabel: p.alwaysLabel, suggestions: p.suggestions,
                                    questions: p.questions, isPlan: p.isPlan, input: p.input, session: p.session)
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

    private func finish(_ fd: Int32, _ d: ClaudeRequest.Decision, suggestions: Data?, input: Data? = nil, plan: Bool = false) {
        let bytes = ClaudeRequest.reply(d, suggestions: suggestions, input: input, plan: plan)
        // Câu trả lời có thể dài (kế hoạch gửi lại): ghi chặn cho hết, hook đang chờ đọc ngay.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
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
        let notch = ModuleManager.shared.module(NotchModule.self)
        notch?.setClaudeAttention(!pending.isEmpty)
        // Thẻ câu hỏi / kế hoạch cần notch cao hơn thẻ duyệt thường.
        notch?.refreshExpanded()
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
        // Không có file (chưa cài / đã gỡ Claude Code) thì cũng không còn số nào đúng.
        let (reading, account) = FileManager.default.contents(atPath: Self.claudeConfigPath)
            .map { ClaudeUsage.readWithAccount(data: $0) } ?? (.noLimits, nil)
        if case .unreadable = reading { return }
        let switched = currentAccount != nil && account != currentAccount
        currentAccount = account
        if switched { fetchUsage(force: true) }
        apply(reading: reading)
    }

    /// Gộp số đọc từ file với số đang hiện (có thể do zMac tự hỏi Anthropic).
    private func apply(reading: ClaudeUsage.Reading) {
        let next: ClaudeUsage?
        switch reading {
        case .unreadable: return
        case .noLimits:
            // File vẫn là số của tài khoản cũ nhưng zMac đã tự lấy số cho đúng tài khoản đang đăng nhập: giữ.
            if let u = usage, u.live == true, u.account != nil, u.account == currentAccount { return }
            next = nil
        // Hạn mức đã qua giờ đặt lại mà chưa có số mới: coi là 0, không báo lại.
        case .usage(let fresh):
            next = ClaudeUsage.newer(usage, fresh).resetting(now: Date().timeIntervalSince1970).usage
        }
        setUsage(next)
    }

    private func setUsage(_ next: ClaudeUsage?) {
        updateStale(next)
        guard next != usage else { return }
        usage = next
        saveUsage()
        #if DEBUG
        if isSelfTest { print("  mức dùng: 5h \(next?.fiveHour?.percent ?? -1)% 7d \(next?.sevenDay?.percent ?? -1)%") }
        #endif
        scheduleReset()
    }

    /// Tự hỏi hạn mức nếu bật. Chỉ gọi theo sự kiện (mở app, mở notch, Claude vừa xong một lượt), tối đa 2 phút một lần.
    func fetchUsage(force: Bool = false) {
        guard active, liveUsage, !liveBlocked, !fetching, !isSelfTest else { return }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 120 { return }
        fetching = true
        lastFetch = Date()
        let account = currentAccount
        ClaudeLiveUsage.fetch { [weak self] result in
            guard let self else { return }
            self.fetching = false
            guard self.active, self.liveUsage else { return }
            switch result {
            case .success(let bytes):
                guard let fresh = ClaudeUsage.fromResponse(bytes, fetchedAt: Date().timeIntervalSince1970, account: account)
                else { self.liveUsageError = L("Anthropic trả về dữ liệu lạ.", "Anthropic sent back unexpected data."); return }
                // Đổi tài khoản trong lúc đang hỏi: bỏ kết quả.
                guard account == self.currentAccount else { return }
                self.liveUsageError = nil
                self.setUsage(ClaudeUsage.newer(self.usage, fresh).resetting(now: Date().timeIntervalSince1970).usage)
            case .failure(let f):
                if f == .noLogin || f == .denied { self.liveBlocked = true }
                self.liveUsageError = Self.describe(f)
            }
        }
    }

    private static func describe(_ f: ClaudeLiveUsage.Failure) -> String {
        switch f {
        case .noLogin: L("Không thấy đăng nhập Claude Code trong Keychain. Đăng nhập Claude Code rồi bật lại mục này.",
                         "No Claude Code sign-in found in the Keychain. Sign in to Claude Code, then turn this back on.")
        case .denied: L("macOS không cho đọc Keychain (bạn đã từ chối?). Tắt rồi bật lại mục này để được hỏi lại.",
                        "macOS didn't allow reading the Keychain (denied?). Turn this off and on to be asked again.")
        case .expired: L("Đăng nhập của Claude Code đã hết hạn. Mở Claude Code là nó tự làm mới; zMac không tự làm mới.",
                         "Claude Code's sign-in has expired. Open Claude Code and it renews itself; zMac never renews it.")
        case .rejected: L("Anthropic từ chối token (có thể vừa hết hạn). Mở Claude Code để nó làm mới.",
                          "Anthropic rejected the token (it may have just expired). Open Claude Code to renew it.")
        case .network: L("Không hỏi được Anthropic (mạng?). Lần sau sẽ thử lại.",
                         "Couldn't reach Anthropic (network?). It will try again next time.")
        }
    }

    /// Số cũ hơn 30 phút thì notch hiện mờ. Hẹn đúng một lần tại mốc 30 phút (không lặp).
    private func updateStale(_ u: ClaudeUsage? = nil) {
        staleWork?.cancel()
        staleWork = nil
        let current = u ?? usage
        let now = Date().timeIntervalSince1970
        let stale = current?.isStale(now: now) ?? false
        if usageStale != stale { usageStale = stale }
        guard !stale, let at = current?.fetchedAt else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.updateStale() } }
        staleWork = w
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(at + ClaudeUsage.staleAfter - now, 1), execute: w)
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
        finish(request.fd, d, suggestions: request.suggestions, input: request.input, plan: request.isPlan)
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
        setWanted(true)
        install(auto: false)
    }

    private func setWanted(_ wanted: Bool) {
        wantsConnection = wanted
        Pref.set("claude.connected", wanted)
    }

    /// Đã kết nối mà hook bị cũ / đổi đường dẫn / bị xoá: thêm lại. Gọi lúc chạy và khi settings.json đổi.
    private func repairIfNeeded() {
        guard autoReconnect, let path = Self.hookPath, ClaudeHookInstaller.autoRepairAllowed(hookPath: path),
              let state = hookState else { return }
        if wantsConnection == nil { setWanted(ClaudeHookInstaller.inferWanted(state)) }
        guard ClaudeHookInstaller.needsRepair(state, wanted: wantsConnection == true), repairs < 3 else { return }
        repairs += 1
        install(auto: true)
    }

    private func install(auto: Bool) {
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
            message = auto
                ? L("Đã tự kết nối lại (hook của zMac bị cũ hoặc bị xoá). Phiên Claude Code đang mở cần mở lại để nhận hook.",
                    "Reconnected automatically (zMac's hook was out of date or removed). Restart any open Claude Code session to pick up the hook.")
                : L("Đã kết nối. Phiên Claude Code đang mở cần mở lại để nhận hook.",
                    "Connected. Restart any open Claude Code session to pick up the hook.")
        } catch {
            message = L("Không sửa được ~/.claude/settings.json (file không phải JSON hợp lệ?). File chưa bị đổi.",
                        "Couldn't update ~/.claude/settings.json (not valid JSON?). The file was left unchanged.")
        }
        refreshHookState()
    }

    func disconnect() {
        setWanted(false)
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

    /// Theo dõi settings.json bằng kqueue như ~/.claude.json: đổi thì đọc lại trạng thái và tự nối lại nếu cần.
    /// Lần ghi của chính zMac cũng tới đây, nhưng lúc đó trạng thái đã đúng nên không ghi thêm.
    private func watchSettings() {
        settingsSource?.cancel()
        settingsSource = nil
        let fd = open(Self.settingsURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let events = self.settingsSource?.data else { return }
                if !events.isDisjoint(with: [.delete, .rename]) {
                    self.settingsSource?.cancel()
                    self.settingsSource = nil
                }
                self.settingsWork?.cancel()
                let w = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.settingsSource == nil { self.watchSettings() }
                        self.refreshHookState()
                        self.repairIfNeeded()
                    }
                }
                self.settingsWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        settingsSource = src
    }

    /// `zMac --diagnose`: hạn mức đọc được từ ~/.claude.json (chỉ đọc).
    static func diagnose() {
        guard let data = FileManager.default.contents(atPath: claudeConfigPath) else {
            print("  Claude Code: không có ~/.claude.json")
            return
        }
        let u: ClaudeUsage
        switch ClaudeUsage.read(data: data) {
        case .unreadable:
            print("  Claude Code: ~/.claude.json không đọc được")
            return
        case .noLimits:
            print("  Claude Code: chưa có hạn mức cho tài khoản đang đăng nhập")
            return
        case .usage(let v): u = v
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
                Toggle(L("Tự kết nối lại", "Reconnect automatically"),
                       isOn: Binding(get: { self.autoReconnect }, set: { self.autoReconnect = $0 }))
                Text(L("Đã kết nối mà hook của zMac trong settings.json bị cũ (sau khi cập nhật zMac), đổi chỗ cài (ví dụ chuyển sang bản Homebrew) hay bị công cụ khác xoá thì zMac tự thêm lại. Bấm Gỡ kết nối thì zMac thôi.",
                       "Once connected, if zMac's hook in settings.json goes out of date (after a zMac update), moves (say, switching to the Homebrew build) or gets removed by another tool, zMac adds it back. Disconnect and it stops."))
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
                        LabeledContent(u.live == true ? L("zMac hỏi Anthropic lúc", "Fetched from Anthropic")
                                                      : L("Claude Code cập nhật", "Updated by Claude Code"),
                                       value: Self.clock(Date(timeIntervalSince1970: at))
                                           + (usageStale ? L(" (đã cũ)", " (stale)") : ""))
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
                Text(L("Mặc định zMac đọc số Claude Code tự lưu trong ~/.claude.json (chạy cả với bản VS Code), không cần mạng hay Keychain. Claude Code chỉ làm mới số này khi bạn xem mức dùng, nên số có thể cũ; cũ hơn 30 phút thì notch hiện mờ.",
                       "By default zMac reads the numbers Claude Code saves in ~/.claude.json (works with the VS Code extension too), with no network or Keychain access. Claude Code only refreshes them when you check your usage, so they can be old; past 30 minutes the notch dims them."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Lấy hạn mức trực tiếp từ Anthropic", "Fetch limits straight from Anthropic"),
                       isOn: Binding(get: { self.liveUsage }, set: { self.liveUsage = $0 }))
                Text(L("zMac đọc token đăng nhập của Claude Code trong Keychain (macOS hỏi quyền lần đầu, chọn Luôn cho phép) và chỉ gửi nó tới api.anthropic.com để hỏi hạn mức: khi mở app, mở notch và khi Claude làm xong một lượt, tối đa 2 phút một lần. zMac không bao giờ tự làm mới token.",
                       "zMac reads Claude Code's sign-in token from the Keychain (macOS asks the first time; pick Always Allow) and only sends it to api.anthropic.com to ask for your limits: at launch, when you open the notch and when Claude finishes a turn, at most once every 2 minutes. zMac never renews the token."))
                    .font(.caption).foregroundStyle(.secondary)
                if liveUsage, let liveUsageError {
                    Label(liveUsageError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(ZTheme.orange.light)
                }
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
        if request.questions.isEmpty {
            permission
        } else {
            ClaudeQuestionCard(module: module, request: request, count: count)
        }
    }

    private var title: String {
        request.isPlan ? L("Claude muốn bắt đầu làm theo kế hoạch", "Claude is ready to start on its plan")
                       : L("Claude muốn dùng ", "Claude wants to use ") + request.tool
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZTile(symbol: request.isPlan ? "list.bullet.clipboard" : "sparkle", hue: ZTheme.orange, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
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
            Group {
                if request.isPlan {
                    // Kế hoạch là Markdown nhiều dòng: cuộn được, chữ thường thay vì chữ máy.
                    // Ngắn thì vừa khít, dài thì cuộn trong khung tối đa 100 điểm.
                    let plan = Text(Self.plainPlan(request.summary))
                        .font(.system(size: 11))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .vertical) {
                        plan.fixedSize(horizontal: false, vertical: true)
                        ScrollView { plan }.scrollIndicators(.never)
                    }
                    .frame(maxHeight: 100)
                } else {
                    Text(request.summary.isEmpty ? request.tool : request.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
            .help(request.isPlan ? "" : request.summary)
            HStack(spacing: 6) {
                Button(request.isPlan ? L("Xem trong Claude Code", "Review in Claude Code") : L("Hỏi trong Claude Code", "Ask in Claude Code")) {
                    module.respond(request, .pass)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                Spacer()
                claudePill(request.isPlan ? L("Lên kế hoạch tiếp", "Keep planning") : L("Từ chối", "Deny"),
                           fill: Color(hex: 0xFF695D).opacity(0.22), text: Color(hex: 0xFF8A80)) {
                    module.respond(request, .deny)
                }
                if let rule = request.alwaysLabel {
                    let acceptEdits = request.isPlan && rule.contains("acceptEdits")
                    claudePill(acceptEdits ? L("Đồng ý, tự sửa file", "Yes, auto-accept edits") : L("Luôn cho phép", "Always allow"),
                               fill: .white.opacity(0.14), text: .white) {
                        module.respond(request, .allowAlways)
                    }
                    .help(rule.isEmpty ? L("Không hỏi lại lệnh này", "Don't ask again for this") : rule)
                }
                claudePill(request.isPlan ? L("Đồng ý", "Approve") : L("Cho phép", "Allow"), fill: .white, text: .black) {
                    module.respond(request, .allow)
                }
            }
        }
    }

    /// Bỏ ký hiệu Markdown đầu dòng (#, -, *) cho gọn trong thẻ.
    static func plainPlan(_ md: String) -> String {
        md.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
            var t = line.trimmingCharacters(in: .whitespaces)
            while t.hasPrefix("#") { t.removeFirst() }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { t = "• " + t.dropFirst(2) }
            return t.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
    }
}

func claudePill(_ title: String, fill: Color, text: Color, disabled: Bool = false, action: @escaping () -> Void) -> some View {
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
    .disabled(disabled)
    .opacity(disabled ? 0.4 : 1)
}

/// Claude hỏi lại (AskUserQuestion): mỗi lần một câu, bấm lựa chọn để trả lời.
/// Chọn một: bấm là sang câu sau (câu cuối thì gửi luôn). Chọn nhiều: đánh dấu rồi bấm Tiếp / Gửi.
/// Muốn gõ câu trả lời khác thì "Trả lời trong terminal" (panel notch không nhận bàn phím).
struct ClaudeQuestionCard: View {
    let module: ClaudeModule
    let request: ClaudeRequest
    let count: Int
    @State private var page = 0
    @State private var picks: [Int: Set<Int>] = [:]

    var body: some View {
        let qs = request.questions
        let i = min(page, qs.count - 1)
        let q = qs[i]
        let last = i == qs.count - 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ZTile(symbol: "questionmark.bubble", hue: ZTheme.orange, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.question)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([q.header, request.project].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if qs.count > 1 { chip("\(i + 1)/\(qs.count)") }
                if count > 1 { chip(L("còn \(count - 1)", "+\(count - 1) more")) }
            }
            // Ô vừa chữ, hết chỗ thì xuống hàng: không cắt nhãn thành "…" khi còn chỗ trống.
            FlowLayout(spacing: 6) {
                ForEach(q.options.indices, id: \.self) { k in option(q, page: i, index: k) }
            }
            HStack(spacing: 6) {
                Button(L("Trả lời trong Claude Code", "Answer in Claude Code")) { module.respond(request, .pass) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if q.multiSelect {
                    Text(L("Chọn được nhiều", "Pick any")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
                if i > 0 {
                    claudePill(L("Trước", "Back"), fill: .white.opacity(0.14), text: .white) { page = i - 1 }
                }
                if q.multiSelect || (picks[i]?.isEmpty == false && !last) || qs.count > 1 {
                    claudePill(last ? L("Gửi", "Send") : L("Tiếp", "Next"), fill: .white, text: .black,
                               disabled: picks[i]?.isEmpty ?? true) { advance(from: i) }
                }
            }
        }
    }

    private func option(_ q: ClaudeQuestion, page i: Int, index k: Int) -> some View {
        let on = picks[i]?.contains(k) == true
        let o = q.options[k]
        return Button {
            if q.multiSelect {
                var set = picks[i] ?? []
                if on { set.remove(k) } else { set.insert(k) }
                picks[i] = set
            } else {
                picks[i] = [k]
                advance(from: i)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if q.multiSelect {
                        Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 10.5))
                    }
                    Text(o.label).font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
                }
                if !o.detail.isEmpty {
                    Text(o.detail).font(.system(size: 10)).opacity(0.62).lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Color.white : Color.white.opacity(0.1)))
            .foregroundStyle(on ? Color.black : Color.white)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(o.detail.isEmpty ? o.label : o.detail)
    }

    private func advance(from i: Int) {
        if i < request.questions.count - 1 {
            page = i + 1
        } else {
            module.respond(request, .answer(ClaudeRequest.answers(request.questions, picks: picks)))
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.12)))
    }
}

/// Xếp các ô theo hàng, hết chỗ thì xuống hàng. Ô rộng vừa chữ (tối đa `maxItemWidth`, chữ dài thì xuống dòng),
/// các ô trong cùng một hàng cao bằng nhau.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var maxItemWidth: CGFloat = 300

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let rows = arrange(width, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y),
                                           proposal: ProposedViewSize(width: item.size.width, height: row.height))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        let cap = min(maxItemWidth, max(maxWidth, 1))
        for i in subviews.indices {
            let ideal = subviews[i].sizeThatFits(.unspecified)
            let w = min(ideal.width, cap)
            let size = w < ideal.width ? CGSize(width: w, height: subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
                                       : ideal
            if !row.items.isEmpty && row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((i, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Mức dùng trên hàng trên của notch

struct ClaudeUsageBadge: View {
    let usage: ClaudeUsage
    /// Số cũ hơn 30 phút: mờ đi, rê chuột thấy giờ lấy số.
    var stale = false

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
        .opacity(stale ? 0.45 : 1)
        .help(stale ? staleHelp : "")
        .fixedSize()
    }

    private var staleHelp: String {
        let at = usage.fetchedAt.map { ClaudeModule.clock(Date(timeIntervalSince1970: $0)) } ?? "?"
        return L("Số từ \(at), đã cũ. Xem mức dùng trong Claude Code hoặc bật \"Lấy hạn mức trực tiếp từ Anthropic\" để có số mới.",
                 "Numbers from \(at), out of date. Check usage in Claude Code, or turn on \"Fetch limits straight from Anthropic\".")
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

    /// Thẻ câu hỏi (AskUserQuestion) và thẻ kế hoạch (ExitPlanMode).
    func previewQuestion() {
        // Câu dài, nhãn dài như một câu hỏi thật của Claude Code: kiểm tra chữ xuống dòng, không bị cắt.
        let q = ClaudeQuestion(
            question: "Bản 0.2.0, mục Phiên bản trên web và cask Homebrew đã sẵn sàng ở máy. Lệnh `brew install --cask kienhungpg/tap/zmac` chỉ chạy được khi có GitHub Release v0.2.0 (kèm zMac.dmg) và repo công khai KienHungPG/homebrew-tap. Mình phát hành thế nào?",
            header: "Phát hành", options: [
                .init(label: "Phát hành tất cả (Recommended)",
                      detail: "Commit theo từng nhóm rồi push zMac, tạo GitHub Release v0.2.0 kèm zMac.dmg, tạo repo homebrew-tap."),
                .init(label: "Chỉ commit và push zMac",
                      detail: "Trang web lên bản mới nhưng lệnh brew sẽ báo lỗi cho tới khi có release và repo tap."),
                .init(label: "Chưa đẩy gì", detail: "Giữ mọi thay đổi ở máy để bạn xem trước."),
            ], multiSelect: false)
        let parts = ClaudeQuestion(question: "Thêm những phần nào?", header: "Phần", options: [
            .init(label: "Demo", detail: ""), .init(label: "Bảng giá", detail: ""), .init(label: "FAQ", detail: ""),
        ], multiSelect: true)
        pending = [ClaudeRequest(fd: -1, tool: "AskUserQuestion", summary: q.question, project: "zmac-website",
                                 alwaysLabel: nil, suggestions: nil, questions: [q, parts])]
    }

    func previewPlan() {
        pending = [ClaudeRequest(fd: -1, tool: "ExitPlanMode",
                                 summary: "## Kế hoạch\n- **Thêm** thẻ câu hỏi lên notch\n- Gửi answers qua updatedInput\n- Viết test cho hook",
                                 project: "zMac", alwaysLabel: "mode: acceptEdits", suggestions: nil, isPlan: true)]
    }

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
            // Câu hỏi: chọn lựa chọn cuối của mỗi câu. Kế hoạch: đồng ý.
            case "AskUserQuestion":
                .answer(ClaudeRequest.answers(r.questions, picks: Dictionary(uniqueKeysWithValues:
                    r.questions.enumerated().map { ($0.offset, [$0.element.options.count - 1]) })))
            case "ExitPlanMode": .allow
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
