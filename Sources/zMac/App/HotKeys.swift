import AppKit
import Carbon.HIToolbox
import SwiftUI

// Phím tắt toàn cục bằng Carbon RegisterEventHotKey thay vì CGEventTap:
// - Hệ thống chỉ báo cho app khi đúng tổ hợp được nhấn, mọi phím khác không đi qua zMac.
// - Không nằm trên đường xử lý bàn phím nên app có bận thì gõ phím vẫn không trễ.

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var mods: UInt32   // cmdKey | optionKey | controlKey | shiftKey

    static let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey), shift = UInt32(shiftKey)

    init(_ keyCode: Int, _ mods: UInt32) {
        self.keyCode = UInt32(keyCode)
        self.mods = mods
    }

    var display: String {
        var s = ""
        if mods & Self.ctrl != 0 { s += "⌃" }
        if mods & Self.opt != 0 { s += "⌥" }
        if mods & Self.shift != 0 { s += "⇧" }
        if mods & Self.cmd != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Modifier tương ứng dạng NSEvent (dùng để phát hiện nhả phím giữ, vd ⌥ của ⌥Tab).
    var eventModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & Self.ctrl != 0 { f.insert(.control) }
        if mods & Self.opt != 0 { f.insert(.option) }
        if mods & Self.shift != 0 { f.insert(.shift) }
        if mods & Self.cmd != 0 { f.insert(.command) }
        return f
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= ctrl }
        if f.contains(.option) { m |= opt }
        if f.contains(.shift) { m |= shift }
        if f.contains(.command) { m |= cmd }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1...kVK_F20:
            let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            if let i = fkeys.firstIndex(of: Int(code)) { return "F\(i + 1)" }
            return "F?"
        default: return translate(code)
        }
    }

    /// Tên phím theo bố cục bàn phím hiện tại.
    private static func translate(_ code: UInt32) -> String {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let st = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard st == noErr, len > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        var combo: KeyCombo
        var handler: () -> Void
        var ref: EventHotKeyRef?
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private var suspended = false

    /// Trả về id để gỡ sau. Tổ hợp đã bị app khác giữ thì vẫn trả id nhưng `isActive` = false.
    @discardableResult
    func register(_ combo: KeyCombo, _ handler: @escaping () -> Void) -> UInt32 {
        installIfNeeded()
        let id = nextID
        nextID += 1
        entries[id] = Entry(combo: combo, handler: handler, ref: suspended ? nil : carbonRegister(combo, id))
        return id
    }

    func unregister(_ id: UInt32?) {
        guard let id, let e = entries.removeValue(forKey: id) else { return }
        if let ref = e.ref { UnregisterEventHotKey(ref) }
    }

    func unregister(_ ids: [UInt32]) { ids.forEach { unregister($0) } }

    func isActive(_ id: UInt32) -> Bool { entries[id]?.ref != nil }

    /// Tạm gỡ tất cả (khi đang ghi phím tắt mới trong Cài đặt).
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for (id, e) in entries {
            if let ref = e.ref { UnregisterEventHotKey(ref) }
            entries[id]?.ref = nil
        }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for (id, e) in entries { entries[id]?.ref = carbonRegister(e.combo, id) }
    }

    private func carbonRegister(_ combo: KeyCombo, _ id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x7A4D_6163), id: id)   // 'zMac'
        let st = RegisterEventHotKey(combo.keyCode, combo.mods, hk, GetApplicationEventTarget(), 0, &ref)
        if st != noErr { log.error("hotkey \(combo.display, privacy: .public) lỗi \(st)") }
        return st == noErr ? ref : nil
    }

    fileprivate func fire(_ id: UInt32) { entries[id]?.handler() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Lưu phím tắt

enum Shortcuts {
    /// nil = người dùng tắt phím tắt này.
    static func combo(_ id: String, _ def: KeyCombo?) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: "hotkey.\(id)") else { return def }
        return (try? JSONDecoder().decode(KeyCombo?.self, from: data)) ?? def
    }

    static func set(_ id: String, _ combo: KeyCombo?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(combo), forKey: "hotkey.\(id)")
    }
}

/// Ô ghi phím tắt trong Cài đặt.
struct ShortcutField: View {
    let id: String
    let defaultCombo: KeyCombo?
    var onChange: () -> Void = {}
    @State private var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    init(id: String, defaultCombo: KeyCombo?, onChange: @escaping () -> Void = {}) {
        self.id = id
        self.defaultCombo = defaultCombo
        self.onChange = onChange
        _combo = State(initialValue: Shortcuts.combo(id, defaultCombo))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? L("Nhấn tổ hợp…", "Press keys…") : (combo?.display ?? L("Không", "None")))
                    .font(.system(.body, design: .rounded))
                    .frame(minWidth: 84)
            }
            if combo != nil && !recording {
                Button { save(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Tắt phím tắt", "Disable shortcut"))
            }
            if combo != defaultCombo && !recording {
                Button { save(defaultCombo) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Về mặc định", "Reset to default"))
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = KeyCombo.carbonMods(e.modifierFlags)
            if Int(e.keyCode) == kVK_Escape && mods == 0 { stop(); return nil }
            let isF = (kVK_F1...kVK_F20).contains(Int(e.keyCode))
            guard mods != 0 || isF else { NSSound.beep(); return nil }
            save(KeyCombo(Int(e.keyCode), mods))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKeyCenter.shared.resume() }
        recording = false
    }

    private func save(_ c: KeyCombo?) {
        combo = c
        Shortcuts.set(id, c)
        onChange()
    }
}
