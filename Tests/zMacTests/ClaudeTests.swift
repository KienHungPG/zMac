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
    let roost: [String: Any] = ["type": "command", "command": "/Applications/Roost.app/Contents/MacOS/roost-hook", "timeout": 110]
    let s = try #require(ClaudeHookInstaller.install(["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [roost]]]]], path: cmd))
    #expect(ClaudeHookInstaller.otherPermissionHooks(s) == ["/Applications/Roost.app/Contents/MacOS/roost-hook"])
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

private let claudeConfig = """
{"numStartups":3,"projects":{"/w":{"x":1}},"cachedUsageUtilization":{"fetchedAtMs":1794892565618,"accountUuid":"u",\
"utilization":{"five_hour":{"utilization":26,"resets_at":"2026-11-17T09:20:00.486592+00:00","limit_dollars":null},\
"seven_day":{"utilization":33,"resets_at":"2026-11-22T10:00:00+00:00"},"seven_day_opus":null}}}
"""

@Test func readsUsageFromClaudeConfig() throws {
    let u = try #require(ClaudeUsage.fromClaudeConfig(Array(claudeConfig.utf8)))
    #expect(u.fiveHour?.percent == 26)
    #expect(abs((u.fiveHour?.resetsAt ?? 0) - 1794907200.486592) < 0.01)
    #expect(u.sevenDay?.percent == 33)
    #expect(u.sevenDay?.resetsAt == 1795341600)
    #expect(abs((u.fetchedAt ?? 0) - 1794892565.618) < 0.001)
}

@Test func noUsageWithoutCache() {
    #expect(ClaudeUsage.fromClaudeConfig(Array(#"{"numStartups":3}"#.utf8)) == nil)
    #expect(ClaudeUsage.fromClaudeConfig(Array(#"{"cachedUsageUtilization":{"utilization":{"five_hour":null}}}"#.utf8)) == nil)
    #expect(ClaudeUsage.fromClaudeConfig(Array("not json".utf8)) == nil)
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
