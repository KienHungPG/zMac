import AppKit
import CoreBluetooth
import GameController
import IOBluetooth
import IOKit
import Observation
import SwiftUI

// Pin thiết bị không dây trên notch: HUD khi vừa kết nối, chip pin khi mở notch, báo khi sắp hết pin.
// Nguồn (đều theo sự kiện, không poll):
// - IOKit: phụ kiện Apple và thiết bị Bluetooth báo pin chuẩn (thuộc tính BatteryPercent). Không cần quyền.
// - IOBluetooth: AirPods / Beats / tai nghe (pin trái, phải, hộp). Thuộc tính riêng của Apple, đọc bằng KVC có kiểm
//   tra trước; cần quyền Bluetooth (chỉ hỏi khi người dùng bấm Cho phép).
// - GameController: tay cầm PS / Xbox.
// - HID++: Logitech sau đầu thu Unifying / Bolt / Lightspeed (LogitechHIDPP.swift).
// Đọc lại khi thiết bị kết nối / ngắt, khi mở notch, khi máy thức dậy. Logitech tự báo khi pin đổi.

struct DeviceBattery: Identifiable, Equatable {
    enum Kind: String { case mouse, keyboard, trackpad, headphones, controller, other }

    struct Level: Equatable {
        /// nil = pin đơn; AirPods: Trái / Phải / Hộp.
        var label: String?
        var percent: Int
        var isCase = false
    }

    var id: String
    var name: String
    var kind: Kind
    var symbol: String
    var levels: [Level]
    var charging = false
    /// % là ước lượng (Logitech chỉ báo mức hoặc điện áp).
    var approximate = false
    /// Địa chỉ Bluetooth (aa-bb-cc-dd-ee-ff) để gộp cùng một thiết bị thấy từ hai nguồn.
    var address: String? = nil

    /// Mức dùng để báo pin yếu và hiện HUD: thấp nhất trong các mức, không tính hộp sạc AirPods.
    var level: Int? { levels.filter { !$0.isCase }.map(\.percent).min() ?? levels.map(\.percent).min() }

    /// "Trái 80% · Phải 75% · Hộp 60%", hoặc "45%".
    var detail: String {
        let text = levels.map { l in (l.label.map { $0 + " " } ?? "") + "\(l.percent)%" }.joined(separator: " · ")
        return (approximate ? "~" : "") + text + (charging ? L(" · đang sạc", " · charging") : "")
    }

    /// AirPods / tai nghe Bluetooth: các mức có giá trị (1…100). Có trái / phải thì bỏ mức đơn.
    static func bluetoothLevels(left: Int?, right: Int?, case box: Int?, single: Int?) -> [Level] {
        func ok(_ v: Int?) -> Int? { v.flatMap { (1...100).contains($0) ? $0 : nil } }
        var out: [Level] = []
        if let l = ok(left) { out.append(Level(label: L("Trái", "L"), percent: l)) }
        if let r = ok(right) { out.append(Level(label: L("Phải", "R"), percent: r)) }
        if out.isEmpty, let s = ok(single) { out.append(Level(percent: s)) }
        if let c = ok(box) { out.append(Level(label: L("Hộp", "Case"), percent: c, isCase: true)) }
        return out
    }

    /// Gộp các nguồn: cùng địa chỉ hoặc cùng tên thì giữ nguồn đứng trước (IOKit, tay cầm, Logitech rồi mới Bluetooth).
    static func merge(_ sources: [[DeviceBattery]]) -> [DeviceBattery] {
        var out: [DeviceBattery] = []
        var addresses = Set<String>()
        var names = Set<String>()
        for d in sources.joined() {
            let name = d.name.lowercased()
            if let a = d.address, addresses.contains(a) { continue }
            if names.contains(name) || out.contains(where: { $0.id == d.id }) { continue }
            out.append(d)
            if let a = d.address { addresses.insert(a) }
            names.insert(name)
        }
        return out.sorted { ($0.level ?? 101, $0.name) < ($1.level ?? 101, $1.name) }
    }

    /// Địa chỉ Bluetooth chuẩn hoá: chữ thường, cách nhau bằng "-".
    static func normalize(address: String?) -> String? {
        guard let a = address?.lowercased().replacingOccurrences(of: ":", with: "-"), !a.isEmpty else { return nil }
        return a
    }

    static func kind(name: String) -> Kind {
        let n = name.lowercased()
        if n.contains("trackpad") { return .trackpad }
        if n.contains("mouse") || n.contains("chuột") { return .mouse }
        if n.contains("keyboard") || n.contains("bàn phím") || n.contains("keys") { return .keyboard }
        if n.contains("airpods") || n.contains("beats") || n.contains("buds") || n.contains("headphone") { return .headphones }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return .controller }
        return .other
    }

    /// SF Symbol theo tên (AirPods có icon riêng) rồi theo loại; symbol không có trên máy thì lùi về icon chung.
    static func symbol(kind: Kind, name: String) -> String {
        let n = name.lowercased()
        var candidates: [String] = []
        if n.contains("airpods max") { candidates.append("airpodsmax") }
        if n.contains("airpods pro") { candidates.append("airpodspro") }
        if n.contains("airpods") { candidates.append("airpods") }
        if n.contains("beats") { candidates.append("beats.headphones") }
        if n.contains("magic mouse") { candidates.append("magicmouse") }
        switch kind {
        case .mouse: candidates.append("computermouse")
        case .keyboard: candidates.append("keyboard")
        case .trackpad: candidates.append("hand.point.up.left")
        case .headphones: candidates.append("headphones")
        case .controller: candidates.append("gamecontroller")
        case .other: break
        }
        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "battery.75percent"
    }
}

/// Quyết định báo (hàm thuần, có test).
enum DeviceAlerts {
    /// Mốc pin yếu vừa chạm. Lần đầu thấy thiết bị (vừa kết nối) mà đã dưới mốc thì báo luôn. Đang sạc thì không.
    static func lowCrossing(old: Int?, new: Int, charging: Bool, threshold: Int) -> Int? {
        guard !charging else { return nil }
        let marks = LowBattery.thresholds(threshold)
        guard let old else { return marks.filter { new <= $0 }.min() }
        return LowBattery.crossed(from: old, to: new, thresholds: marks)
    }

    /// HUD khi kết nối: chỉ khi thiết bị vắng ít nhất 10 phút (chuột Logitech ngủ / thức không làm notch nháy), và
    /// không phải lần quét đầu lúc mở app.
    static func shouldAnnounce(awayFor: Double?, settled: Bool) -> Bool {
        settled && (awayFor ?? .infinity) >= 600
    }
}

// MARK: - Nguồn: IOKit (phụ kiện Apple, Bluetooth chuẩn)

enum HIDBatteryReader {
    static func matching() -> CFDictionary { [kIOPropertyExistsMatchKey: "BatteryPercent"] as CFDictionary }

    static func read() -> [DeviceBattery] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching(), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [DeviceBattery] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            func prop(_ k: String) -> Any? {
                IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let pct = (prop("BatteryPercent") as? NSNumber)?.intValue, (1...100).contains(pct) else { continue }
            let name = prop("Product") as? String ?? "Bluetooth"
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &entry)
            let kind = DeviceBattery.kind(name: name)
            out.append(DeviceBattery(id: "hid:\(entry)", name: name, kind: kind, symbol: DeviceBattery.symbol(kind: kind, name: name),
                                     levels: [.init(percent: pct)],
                                     address: DeviceBattery.normalize(address: prop("DeviceAddress") as? String)))
        }
        return out
    }
}

// MARK: - Nguồn: IOBluetooth (AirPods, Beats, tai nghe)

/// Nhận thông báo kết nối / ngắt của IOBluetooth (cần NSObject cho selector). Chỉ chạy khi đã có quyền Bluetooth.
@MainActor
final class BluetoothBatteryWatcher: NSObject {
    var onChange: (() -> Void)?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]

    func start() {
        guard connectNote == nil else { return }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        for d in Self.connected() { watchDisconnect(d) }
    }

    func stop() {
        connectNote?.unregister()
        connectNote = nil
        for n in disconnectNotes.values { n.unregister() }
        disconnectNotes = [:]
    }

    @objc nonisolated private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        MainActor.assumeIsolated {
            watchDisconnect(device)
            onChange?()
        }
    }

    @objc nonisolated private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        MainActor.assumeIsolated {
            if let a = device.addressString { disconnectNotes.removeValue(forKey: a)?.unregister() }
            onChange?()
        }
    }

    private func watchDisconnect(_ d: IOBluetoothDevice) {
        guard let a = d.addressString, disconnectNotes[a] == nil,
              let n = d.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) else { return }
        disconnectNotes[a] = n
    }

    static func connected() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
    }

    static func read() -> [DeviceBattery] {
        connected().compactMap { d in
            // Thuộc tính riêng của Apple: kiểm tra có trước khi đọc, không có thì bỏ qua (đường lùi).
            func pct(_ key: String) -> Int? {
                guard d.responds(to: NSSelectorFromString(key)) else { return nil }
                return (d.value(forKey: key) as? NSNumber)?.intValue
            }
            let levels = DeviceBattery.bluetoothLevels(left: pct("batteryPercentLeft"), right: pct("batteryPercentRight"),
                                                       case: pct("batteryPercentCase"), single: pct("batteryPercentSingle"))
            guard !levels.isEmpty else { return nil }
            let name = d.name ?? d.addressString ?? "Bluetooth"
            var kind = DeviceBattery.kind(name: name)
            if kind == .other, d.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) { kind = .headphones }
            let address = DeviceBattery.normalize(address: d.addressString)
            return DeviceBattery(id: "bt:\(address ?? name)", name: name, kind: kind, symbol: DeviceBattery.symbol(kind: kind, name: name),
                                 levels: levels, address: address)
        }
    }
}

/// Hỏi quyền Bluetooth (CoreBluetooth hiện hộp hỏi của macOS), báo kết quả rồi bỏ CBCentralManager.
@MainActor
final class BluetoothPermission: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var done: ((Bool) -> Void)?

    func request(_ done: @escaping (Bool) -> Void) {
        self.done = done
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard CBManager.authorization != .notDetermined else { return }
            done?(CBManager.authorization == .allowedAlways)
            done = nil
            manager = nil
        }
    }
}

// MARK: - Nguồn: tay cầm

enum ControllerBatteryReader {
    static func read() -> [DeviceBattery] {
        GCController.controllers().compactMap { c in
            guard let b = c.battery, b.batteryState != .unknown else { return nil }
            let pct = Int((b.batteryLevel * 100).rounded())
            guard (1...100).contains(pct) else { return nil }
            let name = c.vendorName ?? c.productCategory
            return DeviceBattery(id: "gc:\(c.productCategory):\(name)", name: name, kind: .controller,
                                 symbol: DeviceBattery.symbol(kind: .controller, name: name),
                                 levels: [.init(percent: pct)], charging: b.batteryState == .charging)
        }
    }
}

// MARK: - Module

@MainActor @Observable
final class DevicesModule: ZModule {
    static let id = "devices"
    static var name: String { L("Pin thiết bị", "Device Battery") }
    static let replaces = "AirBuddy"
    static let symbol = "headphones"
    static var summary: String {
        L("Pin chuột, bàn phím, AirPods, tay cầm và thiết bị Logitech trên notch: hiện khi vừa kết nối, báo khi sắp hết pin.",
          "Battery for your mouse, keyboard, AirPods, controllers and Logitech gear on the notch: shown when they connect, with a warning when they run low.")
    }

    enum BluetoothAccess { case notAsked, granted, denied }

    private(set) var devices: [DeviceBattery] = []
    private(set) var bluetoothAccess: BluetoothAccess = .notAsked

    var showOnConnect = Pref.bool("devices.showOnConnect", true) {
        didSet { Pref.set("devices.showOnConnect", showOnConnect) }
    }
    var lowAlert = Pref.bool("devices.lowAlert", true) {
        didSet { Pref.set("devices.lowAlert", lowAlert) }
    }
    var lowLevel = Pref.int("devices.lowLevel", 20) {
        didSet { Pref.set("devices.lowLevel", lowLevel) }
    }
    var showInNotch = Pref.bool("devices.showInNotch", true) {
        didSet { Pref.set("devices.showInNotch", showInNotch) }
    }

    @ObservationIgnored private var hidPort: IONotificationPortRef?
    @ObservationIgnored private var hidIterators: [io_iterator_t] = []
    @ObservationIgnored private let bluetooth = BluetoothBatteryWatcher()
    @ObservationIgnored private let logitech = LogitechMonitor()
    @ObservationIgnored private var permission: BluetoothPermission?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var delayed: [DispatchWorkItem] = []
    @ObservationIgnored private var settledAt = Date.distantFuture
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    @ObservationIgnored private var lastLevel: [String: Int] = [:]
    @ObservationIgnored private var running = false
    #if DEBUG
    @ObservationIgnored fileprivate var previewing = false
    #endif

    init() {}

    func start() {
        running = true
        // Lần quét đầu lúc mở app không hiện HUD.
        settledAt = Date().addingTimeInterval(5)
        startHID()
        bluetoothAccess = Self.currentBluetoothAccess()
        bluetooth.onChange = { [weak self] in self?.bluetoothChanged() }
        if bluetoothAccess == .granted { bluetooth.start() }
        logitech.onChange = { [weak self] in self?.refresh() }
        logitech.start()
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logitech.refresh()
                self?.refresh()
            }
        })
        refresh()
    }

    func stop() {
        running = false
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers = []
        for w in delayed { w.cancel() }
        delayed = []
        stopHID()
        bluetooth.stop()
        bluetooth.onChange = nil
        logitech.stop()
        logitech.onChange = nil
        permission = nil
        devices = []
        announced = []
        lastSeen = [:]
        lastLevel = [:]
    }

    // MARK: Đọc

    /// Đọc lại mọi nguồn (rẻ: vài thuộc tính IOKit / IOBluetooth). Gọi theo sự kiện và khi mở notch.
    func refresh() {
        #if DEBUG
        if previewing { return }
        #endif
        guard running else { return }
        let bt = bluetoothAccess == .granted ? BluetoothBatteryWatcher.read() : []
        process(DeviceBattery.merge([HIDBatteryReader.read(), ControllerBatteryReader.read(), logitech.devices, bt]))
    }

    /// Mở notch: đọc lại, và hỏi lại Logitech nếu đã lâu.
    func notchOpened() {
        logitech.refresh()
        refresh()
    }

    /// AirPods báo pin vài giây sau khi kết nối: đọc ngay, rồi đọc lại hai lần (hẹn một lần mỗi mốc, không lặp).
    private func bluetoothChanged() {
        refresh()
        for w in delayed { w.cancel() }
        delayed = [3.0, 10.0].map { delay in
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            return w
        }
    }

    private func process(_ next: [DeviceBattery]) {
        let now = Date()
        let ids = Set(next.map(\.id))
        for d in devices where !ids.contains(d.id) {
            lastSeen[d.id] = now
            announced.remove(d.id)
        }
        if next != devices { devices = next }
        let notch = ModuleManager.shared.module(NotchModule.self)
        var hudShown = false
        for d in next {
            guard let level = d.level else { continue }
            if !announced.contains(d.id) {
                announced.insert(d.id)
                let away = lastSeen[d.id].map { now.timeIntervalSince($0) }
                if showOnConnect, !hudShown, DeviceAlerts.shouldAnnounce(awayFor: away, settled: now >= settledAt) {
                    notch?.showHUD(NotchHUD(symbol: d.symbol, text: "\(level)%", color: .white, level: Double(level) / 100),
                                   seconds: 3)
                    hudShown = true
                }
            }
            if lowAlert, let mark = DeviceAlerts.lowCrossing(old: lastLevel[d.id], new: level, charging: d.charging, threshold: lowLevel) {
                notch?.showAlert(NotchAlert(symbol: d.symbol, tint: Color(hex: 0xFF5F57), title: d.name, value: "\(level)%",
                                            detail: mark <= 10 ? L("Sắp hết pin, sạc ngay nhé.", "Almost out of battery, charge it now.")
                                                               : L("Pin yếu, nhớ sạc sớm.", "Battery is low, charge it soon.")))
            }
            lastLevel[d.id] = level
        }
    }

    // MARK: IOKit: thiết bị có BatteryPercent xuất hiện / biến mất

    private func startHID() {
        guard hidPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        hidPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { ctx, it in
            while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }   // phải rút hết để nhận lần sau
            guard let ctx else { return }
            let me = Unmanaged<DevicesModule>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.refresh() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, HIDBatteryReader.matching(), callback, ctx, &it) == KERN_SUCCESS
            else { continue }
            while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
            hidIterators.append(it)
        }
    }

    private func stopHID() {
        for it in hidIterators { IOObjectRelease(it) }
        hidIterators = []
        if let hidPort { IONotificationPortDestroy(hidPort) }
        hidPort = nil
    }

    // MARK: Quyền Bluetooth

    private static func currentBluetoothAccess() -> BluetoothAccess {
        switch CBManager.authorization {
        case .allowedAlways: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestBluetooth() {
        if bluetoothAccess == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let p = BluetoothPermission()
        permission = p
        p.request { [weak self] granted in
            guard let self else { return }
            self.permission = nil
            self.bluetoothAccess = granted ? .granted : .denied
            if granted, self.running {
                self.bluetooth.start()
                self.refresh()
            }
        }
    }

    // MARK: Cài đặt

    func settingsView() -> AnyView {
        moduleForm {
            Section(L("Đang kết nối", "Connected")) {
                if devices.isEmpty {
                    Text(L("Chưa thấy thiết bị nào báo pin. Kết nối chuột, bàn phím, AirPods hay tay cầm, hoặc cắm đầu thu Logitech, rồi mở notch.",
                           "No device is reporting its battery yet. Connect a mouse, keyboard, AirPods or a controller, or plug in a Logitech receiver, then open the notch."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(devices) { d in
                    LabeledContent {
                        Text(d.detail).monospacedDigit()
                            .foregroundStyle((d.level ?? 100) <= self.lowLevel && !d.charging ? Color(hex: 0xFF5F57) : .secondary)
                    } label: {
                        Label(d.name, systemImage: d.symbol)
                    }
                }
            }
            Section(L("AirPods và tai nghe Bluetooth", "AirPods and Bluetooth headphones")) {
                LabeledContent(L("Quyền Bluetooth", "Bluetooth access")) {
                    switch bluetoothAccess {
                    case .granted: Text(L("Đã cho phép", "Allowed")).foregroundStyle(.green)
                    case .denied: Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { self.requestBluetooth() }
                    case .notAsked: Button(L("Cho phép", "Allow")) { self.requestBluetooth() }
                    }
                }
                Text(L("Cần để đọc pin tai trái, tai phải và hộp sạc AirPods, Beats và các tai nghe Bluetooth khác. zMac chỉ đọc pin của thiết bị đã ghép đôi, không quét hay kết nối gì.",
                       "Needed to read the left, right and case battery of AirPods, Beats and other Bluetooth headphones. zMac only reads the battery of devices you've already paired; it doesn't scan or connect to anything."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Báo trên notch", "On the notch")) {
                Toggle(L("Hiện pin khi thiết bị vừa kết nối", "Show the battery when a device connects"),
                       isOn: Binding(get: { self.showOnConnect }, set: { self.showOnConnect = $0 }))
                Toggle(L("Hiện pin thiết bị khi mở notch", "Show device batteries when the notch opens"),
                       isOn: Binding(get: { self.showInNotch }, set: { self.showInNotch = $0 }))
                Toggle(L("Báo khi sắp hết pin", "Warn when the battery runs low"),
                       isOn: Binding(get: { self.lowAlert }, set: { self.lowAlert = $0 }))
                Picker(L("Báo lần đầu ở", "First warning at"), selection: Binding(get: { self.lowLevel }, set: { self.lowLevel = $0 })) {
                    ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!lowAlert)
                Text(L("Sau đó báo thêm ở 10% và 5%. Pin được đọc lại khi thiết bị kết nối, khi mở notch và khi máy thức dậy; thiết bị Logitech tự báo khi pin đổi. Không đọc định kỳ.",
                       "Then again at 10% and 5%. Batteries are re-read when a device connects, when the notch opens and when the Mac wakes; Logitech devices report changes themselves. Nothing runs on a timer."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Logitech", "Logitech")) {
                Text(L("Chuột, bàn phím Logitech qua đầu thu Unifying, Bolt hay Lightspeed được đọc thẳng, không cần Logi Options+. zMac chỉ hỏi pin, không đổi cài đặt nào của đầu thu hay thiết bị.",
                       "Logitech mice and keyboards on a Unifying, Bolt or Lightspeed receiver are read directly, no Logi Options+ needed. zMac only asks for the battery and never changes any receiver or device setting."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Chip pin trên hàng trên của notch

struct DeviceBatteryChips: View {
    let devices: [DeviceBattery]
    let lowLevel: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(devices.prefix(3)) { d in
                HStack(spacing: 3) {
                    Image(systemName: d.symbol).font(.system(size: 10, weight: .semibold))
                    Text("\(d.level ?? 0)%").monospacedDigit()
                    if d.charging { Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)) }
                }
                .foregroundStyle(color(d))
                .help("\(d.name): \(d.detail)")
            }
            if devices.count > 3 {
                Text("+\(devices.count - 3)")
                    .foregroundStyle(.white.opacity(0.5))
                    .help(devices.dropFirst(3).map { "\($0.name): \($0.detail)" }.joined(separator: "\n"))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
    }

    private func color(_ d: DeviceBattery) -> Color {
        if d.charging { return .green }
        return (d.level ?? 100) <= lowLevel ? Color(hex: 0xFF5F57) : .white.opacity(0.85)
    }
}

#if DEBUG
extension DevicesModule {
    func previewSample() {
        previewing = true
        bluetoothAccess = .granted
        devices = DeviceBattery.merge([[
            DeviceBattery(id: "a", name: "AirPods Pro của Hùng", kind: .headphones,
                          symbol: DeviceBattery.symbol(kind: .headphones, name: "AirPods Pro"),
                          levels: DeviceBattery.bluetoothLevels(left: 80, right: 75, case: 60, single: nil)),
            DeviceBattery(id: "m", name: "MX Master 3S", kind: .mouse, symbol: DeviceBattery.symbol(kind: .mouse, name: ""),
                          levels: [.init(percent: 15)]),
            DeviceBattery(id: "k", name: "Magic Keyboard", kind: .keyboard, symbol: DeviceBattery.symbol(kind: .keyboard, name: ""),
                          levels: [.init(percent: 64)], charging: true),
        ]])
    }
}
#endif
