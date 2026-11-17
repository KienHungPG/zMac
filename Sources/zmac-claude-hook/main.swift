import Darwin
import Foundation

// zmac-claude-hook: hook PermissionRequest của Claude Code.
// Chuyển yêu cầu cấp quyền tới zMac qua Unix socket rồi chờ người dùng bấm trên notch.
// zMac không chạy, không trả lời, hay có lỗi gì: thoát 0 và không in gì, Claude Code hỏi trong terminal như cũ.
// Không bao giờ in quyết định nếu người dùng chưa bấm Cho phép / Từ chối.

// ZMAC_CLAUDE_SOCKET chỉ để thử hook với một socket giả.
let socketPath = ProcessInfo.processInfo.environment["ZMAC_CLAUDE_SOCKET"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/zMac/claude.sock")
/// Thấp hơn timeout 540 s ghi trong settings.json, để luôn tự thoát trước khi Claude Code cắt.
let waitSeconds = 520

func quietExit() -> Never { exit(0) }

/// Kết nối socket. Không có zMac lắng nghe thì thất bại ngay (ENOENT / ECONNREFUSED), không phải chờ.
func connectToZMac() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: pathBytes)
        buf[pathBytes.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { close(fd); return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// Gửi một dòng JSON (bỏ xuống dòng bên trong).
func sendLine(_ fd: Int32, _ data: Data) -> Bool {
    var message = Data(data.filter { $0 != 0x0A && $0 != 0x0D })
    message.append(0x0A)
    return message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == message.count
}

let args = CommandLine.arguments
let input = FileHandle.standardInput.readDataToEndOfFile()

// Bản thử nghiệm từng ghi "zmac-claude-hook --statusline" vào statusLine. Gặp thì thoát êm (Cập nhật kết nối sẽ gỡ).
if args.count > 1, args[1] == "--statusline" { quietExit() }

// MARK: PermissionRequest

guard !input.isEmpty, (try? JSONSerialization.jsonObject(with: input)) is [String: Any],
      let fd = connectToZMac() else { quietExit() }
var tv = timeval(tv_sec: waitSeconds, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
guard sendLine(fd, input) else { quietExit() }

// Đọc một dòng trả lời. Hết giờ hoặc zMac đóng kết nối: không quyết định.
var reply = Data()
var buf = [UInt8](repeating: 0, count: 4096)
while !reply.contains(0x0A) {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    reply.append(contentsOf: buf[0..<n])
}
close(fd)

guard let line = reply.split(separator: 0x0A).first,
      let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
      let behavior = obj["behavior"] as? String, behavior == "allow" || behavior == "deny" else { quietExit() }

var decision: [String: Any] = ["behavior": behavior]
if behavior == "deny" {
    decision["message"] = (obj["message"] as? String) ?? "The user denied this in zMac."
}
if behavior == "allow", let updated = obj["updatedPermissions"] as? [Any], !updated.isEmpty {
    decision["updatedPermissions"] = updated
}
// AskUserQuestion / ExitPlanMode: "allow" phải kèm input đầy đủ (câu hỏi + answers, hoặc kế hoạch).
if behavior == "allow", let input = obj["updatedInput"] as? [String: Any] {
    decision["updatedInput"] = input
}
let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
guard let data = try? JSONSerialization.data(withJSONObject: output) else { quietExit() }
FileHandle.standardOutput.write(data)
exit(0)
