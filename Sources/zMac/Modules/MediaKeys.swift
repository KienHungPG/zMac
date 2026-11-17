import AppKit
import CoreAudio

// Phím âm lượng / độ sáng: zMac tự chỉnh rồi hiện mức trên hai cánh notch, thay cho HUD của macOS.
// Ngoại lệ duy nhất của quy tắc "không CGEventTap": tap chỉ đăng ký NX_SYSDEFINED (phím media, độ sáng),
// nên phím chữ và chuột không bao giờ đi qua zMac. Cần quyền Trợ năng (tap được phép chặn sự kiện).
// Phím có ⌘ / ⌃ / ⌥, hay màn hình zMac không biết cách chỉnh, thì trả nguyên cho macOS.

// MARK: - Hàm thuần (có test)

enum MediaKeyEvent {
    enum Key: Equatable { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    struct Decoded: Equatable {
        var code: Int
        var key: Key?
        var down: Bool
        var isRepeat: Bool
    }

    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS.
    static let auxSubtype = 8

    /// NX_KEYTYPE_* trong IOKit/hidsystem/ev_keymap.h.
    static func key(_ code: Int) -> Key? {
        switch code {
        case 0: .volumeUp
        case 1: .volumeDown
        case 2: .brightnessUp
        case 3: .brightnessDown
        case 7: .mute
        default: nil
        }
    }

    /// data1 của sự kiện phím media: 16 bit cao là mã phím, byte 0xA = nhấn / 0xB = nhả, bit thấp = giữ phím (lặp).
    static func decode(data1: Int) -> Decoded {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        return Decoded(code: code, key: key(code), down: (flags & 0xFF00) >> 8 == 0xA, isRepeat: flags & 0x1 == 1)
    }

    /// Bước theo lưới như macOS: 16 nấc, ⇧⌥ thì 64 nấc. Giá trị lệch lưới thì làm tròn về nấc gần nhất trước.
    static func step(_ value: Double, up: Bool, steps: Double) -> Double {
        let k = (min(max(value, 0), 1) * steps).rounded()
        let n = min(max(up ? k + 1 : k - 1, 0), steps)
        return n / steps
    }

    /// Icon loa theo mức, như HUD macOS.
    static func volumeSymbol(_ level: Double, muted: Bool) -> String {
        if muted { return "speaker.slash.fill" }
        switch level {
        case ..<0.001: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

// MARK: - Event tap

private let mediaKeyCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(info).takeUnretainedValue()
    return MainActor.assumeIsolated { tap.handle(type, event) }
}

@MainActor
final class MediaKeyTap {
    /// Trả về true nếu zMac đã xử lý (nuốt phím, macOS không thấy).
    var onPress: ((MediaKeyEvent.Key, _ fine: Bool) -> Bool)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Phím đã nuốt lúc nhấn: nuốt luôn lúc nhả cho cân.
    private var swallowed: Set<Int> = []

    var isRunning: Bool { port != nil }

    /// Không có quyền Trợ năng thì tạo tap thất bại, trả false.
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask = CGEventMask(1) << 14   // NX_SYSDEFINED, không gì khác
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: mediaKeyCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let s = CFMachPortCreateRunLoopSource(nil, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        port = p
        source = s
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        port = nil
        source = nil
        swallowed.removeAll()
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
              Int(ns.subtype.rawValue) == MediaKeyEvent.auxSubtype else { return pass }
        let d = MediaKeyEvent.decode(data1: ns.data1)
        guard let key = d.key else { return pass }
        if !d.down {
            return swallowed.remove(d.code) != nil ? nil : pass
        }
        // ⌥ (không ⇧): macOS mở Cài đặt Âm thanh / Màn hình. ⌘, ⌃: để nguyên cho app khác.
        let f = event.flags
        if f.contains(.maskCommand) || f.contains(.maskControl) { return pass }
        if f.contains(.maskAlternate) && !f.contains(.maskShift) { return pass }
        let fine = f.contains(.maskAlternate) && f.contains(.maskShift)
        guard onPress?(key, fine) == true else { return pass }
        swallowed.insert(d.code)
        return nil
    }
}

// MARK: - Chỉnh âm lượng / độ sáng

@MainActor
enum MediaKeyActions {
    /// Chỉnh loa mặc định. nil = không có loa (để macOS xử lý).
    static func volume(_ key: MediaKeyEvent.Key, fine: Bool) -> NotchHUD? {
        let dev = ZAudioHAL.defaultDevice(output: true)
        guard dev != 0 else { return nil }
        let muted = ZAudioHAL.isMuted(dev, output: true)
        let current = Double(ZAudioHAL.volume(dev, output: true) ?? 0)
        if key == .mute {
            guard ZAudioHAL.hasMute(dev, output: true) else { return fixedVolume(dev) }
            ZAudioHAL.setMuted(dev, output: true, !muted)
            return hud(current, muted: !muted)
        }
        // Loa không có âm lượng phần cứng (TV qua HDMI): báo trên notch như macOS, chỉnh bằng điều khiển của loa.
        guard ZAudioHAL.canSetVolume(dev, output: true) else { return fixedVolume(dev) }
        let next = MediaKeyEvent.step(current, up: key == .volumeUp, steps: fine ? 64 : 16)
        ZAudioHAL.setVolume(dev, output: true, Float(next))
        // Như macOS: bấm tăng / giảm thì bỏ tắt tiếng.
        if muted { ZAudioHAL.setMuted(dev, output: true, false) }
        return hud(next, muted: false)
    }

    /// TV / loa HDMI: không có âm lượng phần cứng, chỉnh bằng điều khiển của chính nó.
    private static func fixedVolume(_ dev: AudioDeviceID) -> NotchHUD {
        let name = ZAudioHAL.string(dev, kAudioObjectPropertyName) ?? ""
        let tv = name.range(of: "TV", options: .caseInsensitive) != nil
        return NotchHUD(symbol: tv ? "tv" : "hifispeaker.fill",
                        text: tv ? L("Chỉnh trên TV", "Use TV remote") : L("Âm lượng cố định", "Fixed volume"),
                        color: .white.opacity(0.85), wide: true)
    }

    private static func hud(_ level: Double, muted: Bool) -> NotchHUD {
        NotchHUD(symbol: MediaKeyEvent.volumeSymbol(level, muted: muted), text: "\(Int((level * 100).rounded()))%",
                 color: .white, level: muted ? 0 : level)
    }

    /// Chỉnh màn hình đang có con trỏ chuột: màn tích hợp qua DisplayServices, màn ngoài qua module Màn hình
    /// (DDC, hoặc làm tối bằng phần mềm như LG TV). nil = không chỉnh được màn này.
    static func brightness(_ key: MediaKeyEvent.Key, fine: Bool) -> NotchHUD? {
        let id = displayUnderMouse()
        let up = key == .brightnessUp
        let steps: Double = fine ? 64 : 16
        var next: Double?
        if let display = ModuleManager.shared.module(DisplayModule.self),
           let d = display.displays.first(where: { $0.id == id }),
           [.native, .ddc, .software].contains(d.method) {
            let current = d.method == .native ? (DisplayModule.nativeBrightness(id) ?? d.brightness) : d.brightness
            let n = MediaKeyEvent.step(current, up: up, steps: steps)
            display.setBrightness(id, n)
            next = n
        } else if CGDisplayIsBuiltin(id) != 0, let current = DisplayModule.nativeBrightness(id),
                  let set = PrivateAPI.setBrightness {
            let n = MediaKeyEvent.step(current, up: up, steps: steps)
            if set(id, Float(n)) == 0 { next = n }
        }
        guard let next else { return nil }
        return NotchHUD(symbol: next < 0.5 ? "sun.min.fill" : "sun.max.fill", text: "\(Int((next * 100).rounded()))%",
                        color: .white, level: next)
    }

    private static func displayUnderMouse() -> CGDirectDisplayID {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        return screen?.displayID ?? CGMainDisplayID()
    }
}
