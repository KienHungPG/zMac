import Testing
@testable import zMac

// Duyệt quyền Claude Code: đọc yêu cầu hook gửi, câu trả lời gửi về, ghi / gỡ hook trong settings.json.
// Không import Foundation (xem NowPlayingAdapterTests).

private func parse(_ json: String) -> ClaudeRequest.Parsed? { ClaudeRequest.parse(Array(json.utf8)) }

private let bashRequest = """
{"session_id":"abc","cwd":"/work/zMac","permission_mode":"default","hook_event_name":"PermissionRequest",\
"tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Xoá build"},\
"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],\
"behavior":"allow","destination":"localSettings"}]}
"""

@Test func parsesBashRequest() throws {
    let p = try #require(parse(bashRequest))
    #expect(p.tool == "Bash")
    #expect(p.summary == "rm -rf build")
    #expect(p.project == "zMac")
    #expect(p.alwaysLabel == "Bash(rm -rf build)")
    #expect(p.suggestions != nil)
}

@Test func parsesFileAndMcpTools() throws {
    let edit = try #require(parse(#"{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts","old_string":"a"}}"#))
    #expect(edit.summary == "/etc/hosts")
    #expect(edit.alwaysLabel == nil)
    #expect(edit.project == "")
    let mcp = try #require(parse(#"{"tool_name":"mcp__github__create_issue","tool_input":{"title":"Lỗi"}}"#))
    #expect(mcp.tool == "github · create_issue")
    #expect(mcp.summary == "Lỗi")
}

@Test func rejectsGarbage() {
    #expect(parse("not json") == nil)
    #expect(parse(#"{"tool_input":{}}"#) == nil)
    #expect(parse("[1,2]") == nil)
}

@Test func modeSuggestionLabel() {
    #expect(ClaudeRequest.alwaysLabel([["type": "setMode", "mode": "acceptEdits", "destination": "session"]]) == "mode: acceptEdits")
    #expect(ClaudeRequest.alwaysLabel([["type": "somethingNew"]]) == "")
    #expect(ClaudeRequest.alwaysLabel([]) == nil)
}

@Test func replyLines() throws {
    func text(_ d: ClaudeRequest.Decision, _ sugg: ClaudeRequest.Parsed? = nil) -> String {
        String(decoding: ClaudeRequest.reply(d, suggestions: sugg?.suggestions), as: UTF8.self)
    }
    #expect(text(.allow) == "{\"behavior\":\"allow\"}\n")
    #expect(text(.pass) == "{\"behavior\":\"none\"}\n")
    #expect(text(.deny).contains("\"behavior\":\"deny\""))
    #expect(text(.deny).contains("\"message\""))
    let p = try #require(parse(bashRequest))
    let always = text(.allowAlways, p)
    #expect(always.contains("\"updatedPermissions\""))
    #expect(always.contains("addRules"))
    #expect(always.hasSuffix("}\n"))
}

// MARK: - Câu hỏi (AskUserQuestion) và kế hoạch (ExitPlanMode)

private let questionRequest = """
{"cwd":"/work/site","tool_name":"AskUserQuestion","tool_input":{"questions":[\
{"question":"Which framework?","header":"Framework","multiSelect":false,"options":[\
{"label":"React","description":"Hooks"},{"label":"Vue","description":"SFC"}]},\
{"question":"Which parts?","header":"Parts","multiSelect":true,"options":[\
{"label":"Intro","description":""},{"label":"Body"},{"label":"Outro"}]}]}}
"""

@Test func parsesQuestions() throws {
    let p = try #require(parse(questionRequest))
    #expect(p.questions.count == 2)
    #expect(p.questions[0].question == "Which framework?")
    #expect(p.questions[0].header == "Framework")
    #expect(p.questions[0].options.map(\.label) == ["React", "Vue"])
    #expect(p.questions[0].options[0].detail == "Hooks")
    #expect(!p.questions[0].multiSelect)
    #expect(p.questions[1].multiSelect)
    #expect(p.summary == "Which framework?")
    #expect(p.input != nil)
    #expect(!p.isPlan)
    // Yêu cầu quyền thường không giữ tool_input.
    #expect(try #require(parse(bashRequest)).input == nil)
}

@Test func answersJoinMultiSelect() throws {
    let p = try #require(parse(questionRequest))
    let a = ClaudeRequest.answers(p.questions, picks: [0: [1], 1: [2, 0]])
    #expect(a == ["Which framework?": "Vue", "Which parts?": "Intro, Outro"])
    #expect(ClaudeRequest.answers(p.questions, picks: [1: []]).isEmpty)
    let reply = String(decoding: ClaudeRequest.reply(.answer(["Which framework?": "Vue"]), suggestions: nil, input: p.input),
                       as: UTF8.self)
    #expect(reply.contains("\"behavior\":\"allow\""))
    #expect(reply.contains("\"updatedInput\""))
    #expect(reply.contains("\"answers\":{\"Which framework?\":\"Vue\"}"))
    #expect(reply.contains("\"questions\""))
}

@Test func planApprovalSendsInputBack() throws {
    let p = try #require(parse(##"{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Plan\n- Step one","planFilePath":"/tmp/p.md"}}"##))
    #expect(p.isPlan)
    #expect(p.summary.hasPrefix("# Plan"))
    let allow = String(decoding: ClaudeRequest.reply(.allow, suggestions: nil, input: p.input, plan: true), as: UTF8.self)
    #expect(allow.contains("\"updatedInput\""))
    #expect(allow.contains("planFilePath"))
    let deny = String(decoding: ClaudeRequest.reply(.deny, suggestions: nil, input: p.input, plan: true), as: UTF8.self)
    #expect(deny.contains("keep planning"))
    #expect(!deny.contains("updatedInput"))
    #expect(ClaudeRequestCard.plainPlan("## Kế hoạch\n- **Bước** một\n\n* hai") == "Kế hoạch\n• Bước một\n• hai")
}

// MARK: - settings.json

private let cmd = "/Applications/zMac.app/Contents/MacOS/zmac-claude-hook"

private func groups(_ s: [String: Any]) -> [[String: Any]] {
    ((s["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
}

@Test func installIntoEmptySettings() throws {
    let s = try #require(ClaudeHookInstaller.install([:], path: cmd))
    let g = groups(s)
    #expect(g.count == 1)
    #expect(g[0]["matcher"] as? String == "*")
    let hook = try #require((g[0]["hooks"] as? [Any])?.first as? [String: Any])
    #expect(hook["type"] as? String == "command")
    #expect(hook["command"] as? String == cmd)
    #expect(hook["timeout"] as? Int == 540)
    #expect(ClaudeHookInstaller.state(s, path: cmd) == .installed)
    #expect(ClaudeHookInstaller.state(s, path: "/other/zmac-claude-hook") == .outdated)
}

@Test func installKeepsOtherSettingsAndIsIdempotent() throws {
    let theirs: [String: Any] = ["type": "command", "command": "~/bin/notify.sh"]
    let original: [String: Any] = [
        "model": "opus",
        "permissions": ["allow": ["Bash(ls:*)"]],
        "hooks": [
            "PermissionRequest": [["matcher": "Bash", "hooks": [theirs]]],
            "Stop": [["hooks": [["type": "command", "command": "say xong"]]]],
        ],
    ]
    let once = try #require(ClaudeHookInstaller.install(original, path: cmd))
    let twice = try #require(ClaudeHookInstaller.install(once, path: cmd))
    #expect(once["model"] as? String == "opus")
    #expect((once["hooks"] as? [String: Any])?["Stop"] != nil)
    #expect(groups(twice).count == 2)
    #expect(ClaudeHookInstaller.ourCommands(twice) == [cmd])
    // Gỡ: còn đúng hook của người dùng.
    let removed = ClaudeHookInstaller.uninstall(twice)
    #expect(groups(removed).count == 1)
    #expect(groups(removed)[0]["matcher"] as? String == "Bash")
    #expect((removed["hooks"] as? [String: Any])?["Stop"] != nil)
    #expect(ClaudeHookInstaller.state(removed, path: cmd) == .notInstalled)
}

private func eventGroups(_ s: [String: Any], _ e: String) -> [[String: Any]] {
    ((s["hooks"] as? [String: Any])?[e] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
}

private func eventCommands(_ s: [String: Any], _ e: String) -> [String] {
    eventGroups(s, e).flatMap { ($0["hooks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String } }
}

/// PostToolUse và Stop: để gỡ thẻ khi người dùng đã trả lời trong terminal / VS Code.
@Test func installsWatchHooks() throws {
    let s = try #require(ClaudeHookInstaller.install([:], path: cmd))
    let post = eventGroups(s, "PostToolUse")
    #expect(post.count == 1)
    #expect(post[0]["matcher"] as? String == "*")
    #expect(((post[0]["hooks"] as? [Any])?.first as? [String: Any])?["timeout"] as? Int == 5)
    let stop = eventGroups(s, "Stop")
    #expect(stop.count == 1)
    #expect(stop[0]["matcher"] == nil)
    #expect(eventCommands(s, "Stop") == [cmd])
    // Bản kết nối cũ chỉ có PermissionRequest: cần cập nhật.
    var old = s
    var hooks = try #require(old["hooks"] as? [String: Any])
    hooks.removeValue(forKey: "PostToolUse")
    hooks.removeValue(forKey: "Stop")
    old["hooks"] = hooks
    #expect(ClaudeHookInstaller.state(old, path: cmd) == .outdated)
    #expect(ClaudeHookInstaller.state(try #require(ClaudeHookInstaller.install(old, path: cmd)), path: cmd) == .installed)
    // Gỡ: hook Stop của người dùng còn nguyên, của zMac thì mất.
    let mine: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say xong"]]]]]]
    let both = try #require(ClaudeHookInstaller.install(mine, path: cmd))
    #expect(eventCommands(both, "Stop").sorted() == [cmd, "say xong"].sorted())
    let removed = ClaudeHookInstaller.uninstall(both)
    #expect(eventCommands(removed, "Stop") == ["say xong"])
    #expect(eventGroups(removed, "PostToolUse").isEmpty)
    #expect(ClaudeHookInstaller.state(removed, path: cmd) == .notInstalled)
}

@Test func eventsResolveCardsAnsweredElsewhere() throws {
    let q = try #require(parse(#"{"session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","options":[{"label":"A"}]}]}}"#))
    let card = ClaudeRequest(fd: -1, tool: q.tool, summary: q.summary, project: "", alwaysLabel: nil, suggestions: nil,
                             questions: q.questions, input: q.input, session: q.session)
    #expect(card.session == "s1")
    // Trả lời trong VS Code: công cụ chạy xong, PostToolUse mang đúng câu hỏi (thêm answers).
    let done = try #require(ClaudeEvent.parse(Array(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","options":[{"label":"A"}]}],"answers":{"Which?":"A"}}}"#.utf8)))
    #expect(done.resolves(card))
    // Công cụ khác, hay phiên khác: không đụng.
    let other = try #require(ClaudeEvent.parse(Array(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)))
    #expect(!other.resolves(card))
    let elsewhere = try #require(ClaudeEvent.parse(Array(#"{"hook_event_name":"Stop","session_id":"s2"}"#.utf8)))
    #expect(!elsewhere.resolves(card))
    // Hết lượt (từ chối trong VS Code thường kết thúc lượt): gỡ mọi thẻ của phiên.
    #expect(try #require(ClaudeEvent.parse(Array(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8))).resolves(card))
    // Yêu cầu cấp quyền không phải sự kiện.
    #expect(ClaudeEvent.parse(Array(bashRequest.utf8)) == nil)
    #expect(ClaudeEvent.parse(Array(#"{"tool_name":"Bash"}"#.utf8)) == nil)
}

@Test func uninstallDropsOnlyWhatItEmptied() throws {
    let s = try #require(ClaudeHookInstaller.install(["model": "opus"], path: cmd))
    let removed = ClaudeHookInstaller.uninstall(s)
    #expect(removed["hooks"] == nil)
    #expect(removed["model"] as? String == "opus")
    // Không có hook của zMac: không đụng gì, kể cả "hooks": {} rỗng của người dùng.
    let untouched = ClaudeHookInstaller.uninstall(["hooks": [String: Any]()])
    #expect(untouched["hooks"] != nil)
}

@Test func installRefusesOddStructure() {
    #expect(ClaudeHookInstaller.install(["hooks": "x"], path: cmd) == nil)
    #expect(ClaudeHookInstaller.install(["hooks": ["PermissionRequest": "x"]], path: cmd) == nil)
}

@Test func commandQuoting() {
    #expect(ClaudeHookInstaller.command(for: cmd) == cmd)
    #expect(ClaudeHookInstaller.command(for: "/Users/a b/zMac.app/zmac-claude-hook") == "'/Users/a b/zMac.app/zmac-claude-hook'")
    #expect(ClaudeHookInstaller.command(for: "/x/it's/zmac-claude-hook") == #"'/x/it'\''s/zmac-claude-hook'"#)
}

@Test func otherApprovalHooksAreReported() throws {
    let other: [String: Any] = ["type": "command", "command": "/Applications/Other.app/Contents/MacOS/approve-hook", "timeout": 110]
    let s = try #require(ClaudeHookInstaller.install(["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [other]]]]], path: cmd))
    #expect(ClaudeHookInstaller.otherPermissionHooks(s) == ["/Applications/Other.app/Contents/MacOS/approve-hook"])
    #expect(ClaudeHookInstaller.ourCommands(s) == [cmd])
}

@Test func legacyStatusLineIsCleanedUp() throws {
    // Bản thử nghiệm từng ghi statusLine: coi là cần cập nhật, cập nhật thì gỡ, statusLine của người dùng thì giữ.
    let hook: [String: Any] = ["type": "command", "command": cmd, "timeout": 540]
    let old: [String: Any] = [
        "hooks": ["PermissionRequest": [["matcher": "*", "hooks": [hook]]]],
        "statusLine": ["type": "command", "command": cmd + " --statusline"],
    ]
    #expect(ClaudeHookInstaller.state(old, path: cmd) == .outdated)
    let fixed = try #require(ClaudeHookInstaller.install(old, path: cmd))
    #expect(fixed["statusLine"] == nil)
    #expect(ClaudeHookInstaller.state(fixed, path: cmd) == .installed)
    let mine: [String: Any] = ["statusLine": ["type": "command", "command": "~/.claude/statusline.sh"]]
    let kept = try #require(ClaudeHookInstaller.install(mine, path: cmd))
    #expect((kept["statusLine"] as? [String: Any])?["command"] as? String == "~/.claude/statusline.sh")
}

// MARK: - Mức dùng (~/.claude.json)

/// `account`: tài khoản đang đăng nhập (nil = đã đăng xuất). `owner`: tài khoản của số liệu (nil = bản cũ không ghi).
private func claudeConfig(account: String? = "u", owner: String? = "u") -> String {
    let login = account.map { #""oauthAccount":{"accountUuid":"\#($0)","displayName":"x"},"# } ?? ""
    let ownerField = owner.map { #""accountUuid":"\#($0)","# } ?? ""
    return #"{"numStartups":3,"projects":{"/w":{"x":1}},"# + login
        + #""cachedUsageUtilization":{"fetchedAtMs":1794892565618,"# + ownerField
        + #""utilization":{"five_hour":{"utilization":26,"resets_at":"2026-11-17T09:20:00.486592+00:00","limit_dollars":null},"#
        + #""seven_day":{"utilization":33,"resets_at":"2026-11-22T10:00:00+00:00"},"seven_day_opus":null}}}"#
}

@Test func readsUsageFromClaudeConfig() throws {
    guard case .usage(let u) = ClaudeUsage.read(Array(claudeConfig().utf8)) else {
        Issue.record("không đọc được hạn mức")
        return
    }
    #expect(u.fiveHour?.percent == 26)
    #expect(abs((u.fiveHour?.resetsAt ?? 0) - 1794907200.486592) < 0.01)
    #expect(u.sevenDay?.percent == 33)
    #expect(u.sevenDay?.resetsAt == 1795341600)
    #expect(abs((u.fetchedAt ?? 0) - 1794892565.618) < 0.001)
}

@Test func noUsageWithoutCache() {
    #expect(ClaudeUsage.read(Array(#"{"numStartups":3}"#.utf8)) == .noLimits)
    #expect(ClaudeUsage.read(Array(#"{"cachedUsageUtilization":{"utilization":{"five_hour":null}}}"#.utf8)) == .noLimits)
    #expect(ClaudeUsage.read(Array("not json".utf8)) == .unreadable)
    #expect(ClaudeUsage.read(Array(#"{"cachedUsageUtilization":{"utilization":"#.utf8)) == .unreadable)
}

/// Vừa đổi tài khoản: số trong file vẫn của tài khoản cũ cho tới khi Claude Code lấy số mới.
@Test func usageOfAnotherAccountIsHidden() {
    #expect(ClaudeUsage.read(Array(claudeConfig(account: "v").utf8)) == .noLimits)
    #expect(ClaudeUsage.read(Array(claudeConfig(account: nil).utf8)) == .noLimits)
    // Bản Claude Code cũ không ghi chủ của số liệu: vẫn đọc.
    guard case .usage = ClaudeUsage.read(Array(claudeConfig(owner: nil).utf8)) else {
        Issue.record("cache không có accountUuid phải đọc được")
        return
    }
}

@Test func limitsResetOnTime() throws {
    let u = ClaudeUsage(fiveHour: .init(percent: 81, resetsAt: 1000), sevenDay: .init(percent: 60, resetsAt: 5000), fetchedAt: 400)
    #expect(u.nextReset(after: 500) == 1000)
    let (before, none) = u.resetting(now: 999)
    #expect(none.isEmpty)
    #expect(before == u)
    let (after, labels) = u.resetting(now: 1000)
    #expect(labels == ["5h"])
    #expect(after.fiveHour == .init(percent: 0, resetsAt: nil))
    #expect(after.sevenDay == u.sevenDay)
    #expect(after.nextReset(after: 1000) == 5000)
}
