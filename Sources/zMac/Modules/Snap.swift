import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import SwiftUI

// Chia cửa sổ kiểu Rectangle, qua Accessibility API.
// Phím tắt: Carbon hotkey (không event tap). Kéo ra mép: global monitor chỉ nhận sự kiện chuột trái
// (down / dragged / up), mỗi lần kéo chỉ hỏi AX một lần, chuột đứng yên thì không tốn gì.

enum SnapAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, almostMaximize, center, restore, larger, smaller
    case nextDisplay, previousDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return L("Nửa trái", "Left half")
        case .rightHalf: return L("Nửa phải", "Right half")
        case .topHalf: return L("Nửa trên", "Top half")
        case .bottomHalf: return L("Nửa dưới", "Bottom half")
        case .topLeft: return L("Góc trên trái", "Top left")
        case .topRight: return L("Góc trên phải", "Top right")
        case .bottomLeft: return L("Góc dưới trái", "Bottom left")
        case .bottomRight: return L("Góc dưới phải", "Bottom right")
        case .firstThird: return L("Một phần ba đầu", "First third")
        case .centerThird: return L("Một phần ba giữa", "Center third")
        case .lastThird: return L("Một phần ba cuối", "Last third")
        case .firstTwoThirds: return L("Hai phần ba đầu", "First two thirds")
        case .lastTwoThirds: return L("Hai phần ba cuối", "Last two thirds")
        case .maximize: return L("Phóng to", "Maximize")
        case .almostMaximize: return L("Gần đầy màn hình", "Almost maximize")
        case .center: return L("Căn giữa", "Center")
        case .restore: return L("Khôi phục", "Restore")
        case .larger: return L("To hơn", "Larger")
        case .smaller: return L("Nhỏ hơn", "Smaller")
        case .nextDisplay: return L("Sang màn hình sau", "Next display")
        case .previousDisplay: return L("Sang màn hình trước", "Previous display")
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .firstThird, .firstTwoThirds: return "rectangle.leadingthird.inset.filled"
        case .centerThird: return "rectangle.center.inset.filled"
        case .lastThird, .lastTwoThirds: return "rectangle.trailingthird.inset.filled"
        case .maximize: return "rectangle.inset.filled"
        case .almostMaximize: return "rectangle.center.inset.filled"
        case .center: return "rectangle.center.inset.filled"
        case .restore: return "arrow.uturn.backward"
        case .larger: return "plus.rectangle"
        case .smaller: return "minus.rectangle"
        case .nextDisplay: return "arrow.right.to.line"
        case .previousDisplay: return "arrow.left.to.line"
        }
    }

    /// Mặc định giống Rectangle: ⌃⌥ + phím.
    var defaultCombo: KeyCombo? {
        let m = KeyCombo.ctrl | KeyCombo.opt
        switch self {
        case .leftHalf: return KeyCombo(kVK_LeftArrow, m)
        case .rightHalf: return KeyCombo(kVK_RightArrow, m)
        case .topHalf: return KeyCombo(kVK_UpArrow, m)
        case .bottomHalf: return KeyCombo(kVK_DownArrow, m)
        case .topLeft: return KeyCombo(kVK_ANSI_U, m)
        case .topRight: return KeyCombo(kVK_ANSI_I, m)
        case .bottomLeft: return KeyCombo(kVK_ANSI_J, m)
        case .bottomRight: return KeyCombo(kVK_ANSI_K, m)
        case .firstThird: return KeyCombo(kVK_ANSI_D, m)
        case .centerThird: return KeyCombo(kVK_ANSI_F, m)
        case .lastThird: return KeyCombo(kVK_ANSI_G, m)
        case .firstTwoThirds: return KeyCombo(kVK_ANSI_E, m)
        case .lastTwoThirds: return KeyCombo(kVK_ANSI_T, m)
        case .maximize: return KeyCombo(kVK_Return, m)
        case .almostMaximize: return nil
        case .center: return KeyCombo(kVK_ANSI_C, m)
        case .restore: return KeyCombo(kVK_Delete, m)
        case .larger: return KeyCombo(kVK_ANSI_Equal, m)
        case .smaller: return KeyCombo(kVK_ANSI_Minus, m)
        case .nextDisplay: return KeyCombo(kVK_RightArrow, m | KeyCombo.cmd)
        case .previousDisplay: return KeyCombo(kVK_LeftArrow, m | KeyCombo.cmd)
        }
    }

    static let groups: [(String, [SnapAction])] = [
        (L("Nửa", "Halves"), [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        (L("Góc", "Quarters"), [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        (L("Phần ba", "Thirds"), [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds]),
        (L("Kích thước", "Size"), [.maximize, .almostMaximize, .center, .larger, .smaller, .restore]),
        (L("Màn hình", "Displays"), [.nextDisplay, .previousDisplay]),
    ]
}

/// Tính khung đích (toạ độ Cocoa) trong vùng `v` (visibleFrame). Hàm thuần, không đụng AX.
enum SnapGeometry {
    static func rect(_ a: SnapAction, in v: CGRect, current c: CGRect, gap g: CGFloat, step: Int = 0) -> CGRect? {
        let r = v.insetBy(dx: g, dy: g)
        let portrait = r.height > r.width
        let halfW = (r.width - g) / 2, halfH = (r.height - g) / 2
        // Bấm lặp lại nửa trái/phải: 1/2 -> 2/3 -> 1/3.
        let fractions: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]
        let f = fractions[step % fractions.count]

        func thirds(_ i: Int, span: Int) -> CGRect {
            if portrait {
                let t = (r.height - 2 * g) / 3
                let h = t * CGFloat(span) + g * CGFloat(span - 1)
                return CGRect(x: r.minX, y: r.maxY - CGFloat(i) * (t + g) - h, width: r.width, height: h)
            }
            let t = (r.width - 2 * g) / 3
            let w = t * CGFloat(span) + g * CGFloat(span - 1)
            return CGRect(x: r.minX + CGFloat(i) * (t + g), y: r.minY, width: w, height: r.height)
        }

        switch a {
        case .leftHalf:
            let w = step == 0 ? halfW : (r.width - g) * f
            return CGRect(x: r.minX, y: r.minY, width: w, height: r.height)
        case .rightHalf:
            let w = step == 0 ? halfW : (r.width - g) * f
            return CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height)
        case .topHalf:
            let h = step == 0 ? halfH : (r.height - g) * f
            return CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
        case .bottomHalf:
            let h = step == 0 ? halfH : (r.height - g) * f
            return CGRect(x: r.minX, y: r.minY, width: r.width, height: h)
        case .topLeft: return CGRect(x: r.minX, y: r.maxY - halfH, width: halfW, height: halfH)
        case .topRight: return CGRect(x: r.maxX - halfW, y: r.maxY - halfH, width: halfW, height: halfH)
        case .bottomLeft: return CGRect(x: r.minX, y: r.minY, width: halfW, height: halfH)
        case .bottomRight: return CGRect(x: r.maxX - halfW, y: r.minY, width: halfW, height: halfH)
        case .firstThird: return thirds(0, span: 1)
        case .centerThird: return thirds(1, span: 1)
        case .lastThird: return thirds(2, span: 1)
        case .firstTwoThirds: return thirds(0, span: 2)
        case .lastTwoThirds: return thirds(1, span: 2)
        case .maximize: return r
        case .almostMaximize: return r.insetBy(dx: r.width * 0.05, dy: r.height * 0.05)
        case .center:
            let w = min(c.width, r.width), h = min(c.height, r.height)
            return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        case .larger, .smaller:
            let d: CGFloat = a == .larger ? 30 : -30
            var n = c.insetBy(dx: -d, dy: -d)
            n.size.width = min(max(n.width, 200), r.width)
            n.size.height = min(max(n.height, 150), r.height)
            n.origin.x = min(max(n.minX, r.minX), r.maxX - n.width)
            n.origin.y = min(max(n.minY, r.minY), r.maxY - n.height)
            return n
        case .restore, .nextDisplay, .previousDisplay:
            return nil
        }
    }

    /// Giữ vị trí và tỉ lệ tương đối khi chuyển cửa sổ sang màn hình khác.
    static func move(_ c: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        let sx = b.width / a.width, sy = b.height / a.height
        var n = CGRect(x: b.minX + (c.minX - a.minX) * sx, y: b.minY + (c.minY - a.minY) * sy,
                       width: c.width * sx, height: c.height * sy)
        n.size.width = min(n.width, b.width)
        n.size.height = min(n.height, b.height)
        n.origin.x = min(max(n.minX, b.minX), b.maxX - n.width)
        n.origin.y = min(max(n.minY, b.minY), b.maxY - n.height)
        return n
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}

@MainActor @Observable
final class SnapModule: ZModule {
    static let id = "snap"
    static var name: String { L("Chia cửa sổ", "Window Snapping") }
    static let replaces = "Rectangle"
    static let symbol = "rectangle.split.2x1"
    static var summary: String {
        L("Xếp cửa sổ nửa, phần tư, phần ba màn hình bằng phím tắt hoặc kéo ra mép màn hình.",
          "Snap windows to halves, quarters and thirds with shortcuts or by dragging to screen edges.")
    }

    var gap = Pref.double("snap.gap", 0) { didSet { Pref.set("snap.gap", gap) } }
    var dragToSnap = Pref.bool("snap.drag", true) {
        didSet { Pref.set("snap.drag", dragToSnap); dragToSnap ? startDrag() : stopDrag() }
    }

    @ObservationIgnored private var hotkeys: [UInt32] = []
    @ObservationIgnored private var restoreFrames: [CGWindowID: CGRect] = [:]
    @ObservationIgnored private var last: (action: SnapAction, window: CGWindowID, rect: CGRect, step: Int)?

    // Kéo ra mép
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var downLocation = CGPoint.zero
    @ObservationIgnored private var probed = false
    @ObservationIgnored private var probe: (win: AXUIElement, pid: pid_t, start: CGRect)?
    @ObservationIgnored private var zone: SnapAction?
    @ObservationIgnored private var preview: NSPanel?

    init() {}

    func start() {
        registerHotkeys()
        if dragToSnap { startDrag() }
    }

    func stop() {
        HotKeyCenter.shared.unregister(hotkeys)
        hotkeys = []
        stopDrag()
    }

    private func registerHotkeys() {
        HotKeyCenter.shared.unregister(hotkeys)
        hotkeys = SnapAction.allCases.compactMap { a in
            guard let c = Shortcuts.combo("snap.\(a.rawValue)", a.defaultCombo) else { return nil }
            return HotKeyCenter.shared.register(c) { [weak self] in self?.perform(a) }
        }
    }

    // MARK: Thực hiện

    func perform(_ a: SnapAction) {
        guard AXIsProcessTrusted() else { Permissions.shared.requestAccessibility(); return }
        guard let (win, pid) = AX.focusedWindow() else { return }
        perform(a, window: win, pid: pid)
    }

    private func perform(_ a: SnapAction, window win: AXUIElement, pid: pid_t) {
        guard let axFrame = AX.frame(win), let screen = Coords.screen(containing: axFrame) else { return }
        let wid = PrivateAPI.windowID(of: win) ?? 0
        let current = Coords.flip(axFrame)

        var target: CGRect?
        switch a {
        case .restore:
            guard let saved = restoreFrames.removeValue(forKey: wid) else { return }
            setFrame(win, pid: pid, cocoa: Coords.flip(saved))
            last = nil
            return
        case .nextDisplay, .previousDisplay:
            let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
            guard screens.count > 1, let i = screens.firstIndex(of: screen) else { return }
            let next = screens[(i + (a == .nextDisplay ? 1 : screens.count - 1)) % screens.count]
            target = SnapGeometry.move(current, from: screen.visibleFrame, to: next.visibleFrame)
        default:
            var step = 0
            if let l = last, l.action == a, l.window == wid, SnapGeometry.close(l.rect, current),
               [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains(a) {
                step = l.step + 1
            }
            target = SnapGeometry.rect(a, in: screen.visibleFrame, current: current, gap: CGFloat(gap), step: step)
            if let t = target { last = (a, wid, t, step) }
        }
        guard let t = target else { return }
        if restoreFrames[wid] == nil { restoreFrames[wid] = axFrame }
        setFrame(win, pid: pid, cocoa: t)
    }

    private func setFrame(_ win: AXUIElement, pid: pid_t, cocoa: CGRect) {
        let r = Coords.flip(cocoa)
        // Tắt AXEnhancedUserInterface tạm thời: một số app (Chrome, Electron) bật nó và animate rất chậm.
        let app = AXUIElementCreateApplication(pid)
        let enhanced = AX.attr(app, "AXEnhancedUserInterface", Bool.self) ?? false
        if enhanced { AX.setBool(app, "AXEnhancedUserInterface", false) }
        // Size -> vị trí -> size: tránh bị kẹp kích thước khi chuyển giữa các màn hình khác cỡ.
        AX.setSize(win, r.size)
        AX.setPoint(win, r.origin)
        AX.setSize(win, r.size)
        if enhanced { AX.setBool(app, "AXEnhancedUserInterface", true) }
    }

    // MARK: Kéo ra mép màn hình

    private func startDrag() {
        guard monitors.isEmpty else { return }
        func add(_ mask: NSEvent.EventTypeMask, _ f: @escaping @MainActor (SnapModule) -> Void) {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { if let self { f(self) } }
            }) { monitors.append(m) }
        }
        add(.leftMouseDown) { $0.mouseDown() }
        add(.leftMouseDragged) { $0.mouseDragged() }
        add(.leftMouseUp) { $0.mouseUp() }
    }

    private func stopDrag() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        preview?.orderOut(nil)
        preview = nil
    }

    private func mouseDown() {
        downLocation = NSEvent.mouseLocation
        probed = false
        probe = nil
        zone = nil
    }

    private func mouseDragged() {
        if !probed {
            probed = true
            probe = windowUnder(downLocation)
        }
        guard let probe else { return }
        let z = zone(at: NSEvent.mouseLocation)
        guard z != zone else { return }
        zone = z
        guard let z, moved(probe), let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
              let rect = SnapGeometry.rect(z, in: screen.visibleFrame, current: .zero, gap: CGFloat(gap)) else {
            preview?.orderOut(nil)
            return
        }
        showPreview(rect)
    }

    private func mouseUp() {
        defer {
            preview?.orderOut(nil)
            zone = nil
            probe = nil
        }
        guard let z = zone, let p = probe, moved(p) else { return }
        perform(z, window: p.win, pid: p.pid)
    }

    private func moved(_ p: (win: AXUIElement, pid: pid_t, start: CGRect)) -> Bool {
        guard let now = AX.frame(p.win) else { return false }
        return abs(now.minX - p.start.minX) > 8 || abs(now.minY - p.start.minY) > 8
    }

    private func windowUnder(_ cocoaPoint: CGPoint) -> (win: AXUIElement, pid: pid_t, start: CGRect)? {
        guard AXIsProcessTrusted() else { return nil }
        let p = CGPoint(x: cocoaPoint.x, y: Coords.primaryHeight - cocoaPoint.y)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success,
              let el else { return nil }
        let win: AXUIElement
        if AX.attr(el, kAXRoleAttribute, String.self) == kAXWindowRole { win = el }
        else if let w = AX.element(el, kAXWindowAttribute) { win = w }
        else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        guard pid != getpid(), let f = AX.frame(win) else { return nil }
        return (win, pid, f)
    }

    private func zone(at p: CGPoint) -> SnapAction? {
        guard let f = NSScreen.screens.first(where: { $0.frame.contains(p) })?.frame else { return nil }
        let m: CGFloat = 4, corner: CGFloat = 60
        let left = p.x <= f.minX + m, right = p.x >= f.maxX - m - 1
        let top = p.y >= f.maxY - m - 1, bottom = p.y <= f.minY + m
        let nearTop = p.y >= f.maxY - corner, nearBottom = p.y <= f.minY + corner
        let nearLeft = p.x <= f.minX + corner, nearRight = p.x >= f.maxX - corner
        if left { return nearTop ? .topLeft : nearBottom ? .bottomLeft : .leftHalf }
        if right { return nearTop ? .topRight : nearBottom ? .bottomRight : .rightHalf }
        if top { return nearLeft ? .topLeft : nearRight ? .topRight : .maximize }
        if bottom { return nearLeft ? .bottomLeft : nearRight ? .bottomRight : nil }
        return nil
    }

    private func showPreview(_ rect: CGRect) {
        let p: NSPanel
        if let existing = preview {
            p = existing
        } else {
            p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 12
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
            v.layer?.borderWidth = 2
            p.contentView = v
            preview = p
        }
        let wasVisible = p.isVisible
        if !wasVisible { p.setFrame(rect.insetBy(dx: 2, dy: 2), display: false) }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = wasVisible ? 0.12 : 0
            p.animator().setFrame(rect.insetBy(dx: 2, dy: 2), display: true)
        }
    }

    // MARK: Giao diện

    func settingsView() -> AnyView {
        moduleForm {
            if !Permissions.shared.accessibility {
                Section {
                    PermissionRow(title: L("Cần quyền Trợ năng", "Accessibility needed"),
                                  detail: L("Để di chuyển và đổi cỡ cửa sổ của app khác.", "To move and resize other apps' windows."),
                                  granted: false) { Permissions.shared.requestAccessibility() }
                }
            }
            Section(L("Chung", "General")) {
                Toggle(L("Kéo cửa sổ ra mép màn hình để xếp", "Drag windows to screen edges to snap"),
                       isOn: Binding(get: { self.dragToSnap }, set: { self.dragToSnap = $0 }))
                HStack {
                    Text(L("Khoảng cách giữa các cửa sổ", "Gap between windows"))
                    Slider(value: Binding(get: { self.gap }, set: { self.gap = $0.rounded() }), in: 0...24)
                    Text("\(Int(gap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text(L("Bấm lặp lại nửa trái / phải / trên / dưới để đổi giữa 1/2, 2/3, 1/3.",
                       "Press a half shortcut again to cycle through 1/2, 2/3 and 1/3."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(SnapAction.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { a in
                        HStack {
                            Label(a.title, systemImage: a.symbol)
                            Spacer()
                            ShortcutField(id: "snap.\(a.rawValue)", defaultCombo: a.defaultCombo) { [weak self] in
                                self?.registerHotkeys()
                            }
                        }
                    }
                }
            }
        }
    }
}
