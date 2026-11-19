import Foundation
import IOKit.hid

// Pin chuột / bàn phím Logitech sau đầu thu Unifying, Bolt, Lightspeed (giao thức HID++ công khai của Logitech, mã tự
// viết). Chỉ hỏi, không ghi gì vào đầu thu (không đổi cờ thông báo, không ảnh hưởng Logi Options+ hay phím Fn).
// Theo sự kiện: hỏi khi đầu thu cắm vào và khi mở notch (tối đa mỗi phút một lần); thiết bị tự gửi sự kiện pin khi đổi.

enum HIDPP {
    static let vendor = 0x046D
    /// Giao diện HID++ của đầu thu: usage page riêng của Logitech.
    static let usagePage = 0xFF00
    static let shortID: UInt8 = 0x10
    static let longID: UInt8 = 0x11
    static let longLength = 20
    /// Mã phần mềm của zMac trong mỗi yêu cầu (4 bit thấp): trả lời cho app khác (Options+) có mã khác, bỏ qua.
    static let swID: UInt8 = 0x0B

    enum Feature: UInt16 {
        case root = 0x0000
        case deviceName = 0x0005
        case batteryStatus = 0x1000
        case batteryVoltage = 0x1001
        case unifiedBattery = 0x1004
    }

    /// Yêu cầu HID++ 2.0 dạng long: [0x11, thiết bị, feature index, hàm << 4 | swID, tham số…], đủ 20 byte.
    static func request(device: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = []) -> [UInt8] {
        var r: [UInt8] = [longID, device, feature, (function << 4) | swID] + params.prefix(longLength - 4)
        r += [UInt8](repeating: 0, count: longLength - r.count)
        return r
    }

    /// Hỏi feature index của một feature (root, hàm 0).
    static func getFeature(device: UInt8, _ f: Feature) -> [UInt8] {
        request(device: device, feature: 0, function: 0, params: [UInt8(f.rawValue >> 8), UInt8(f.rawValue & 0xFF)])
    }

    /// Ping (root, hàm 1): thiết bị đang kết nối thì trả lời phiên bản giao thức.
    static func ping(device: UInt8) -> [UInt8] { request(device: device, feature: 0, function: 1, params: [0, 0, 0x5A]) }

    enum Message: Equatable {
        /// Trả lời yêu cầu của zMac (đúng swID).
        case response(device: UInt8, feature: UInt8, function: UInt8, params: [UInt8])
        /// Lỗi cho yêu cầu của zMac (HID++ 1.0: 0x8F, HID++ 2.0: 0xFF), hoặc thiết bị không có ở chỗ đó.
        case error(device: UInt8, feature: UInt8, function: UInt8, code: UInt8)
        /// Đầu thu báo thiết bị kết nối / mất kết nối (0x41), nếu app khác đã bật thông báo này.
        case connection(device: UInt8, connected: Bool)
        /// Thiết bị tự gửi (swID 0), ví dụ pin đổi.
        case event(device: UInt8, feature: UInt8, function: UInt8, params: [UInt8])
    }

    static func parse(_ r: [UInt8]) -> Message? {
        guard r.count >= 7, r[0] == shortID || r[0] == longID else { return nil }
        let device = r[1], sub = r[2], fs = r[3]
        if (r[0] == shortID && sub == 0x8F) || (r[0] == longID && sub == 0xFF) {
            guard r[4] & 0x0F == swID else { return nil }
            return .error(device: device, feature: fs, function: r[4] >> 4, code: r[5])
        }
        if r[0] == shortID && sub == 0x41 {
            return .connection(device: device, connected: r[4] & 0x40 == 0)
        }
        let params = Array(r[4...])
        switch fs & 0x0F {
        case swID: return .response(device: device, feature: sub, function: fs >> 4, params: params)
        case 0: return .event(device: device, feature: sub, function: fs >> 4, params: params)
        default: return nil   // trả lời cho phần mềm khác
        }
    }

    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        /// Thiết bị chỉ báo mức (đầy / tốt / yếu / rất yếu) hoặc điện áp: % là ước lượng.
        var approximate: Bool
    }

    /// 0x1004 Unified Battery (hàm GetStatus và sự kiện): [%, cờ mức, trạng thái sạc, nguồn ngoài].
    static func unifiedBattery(_ p: [UInt8]) -> Battery? {
        guard p.count >= 3 else { return nil }
        let charging = p[2] == 1 || p[2] == 2
        if p[0] > 0 { return Battery(percent: min(Int(p[0]), 100), charging: charging, approximate: false) }
        if p[2] == 3 { return Battery(percent: 100, charging: false, approximate: false) }   // sạc xong
        // Không báo %: đoán từ cờ mức (bit 3 đầy, 2 tốt, 1 yếu, 0 rất yếu).
        let level = p[1]
        let guess: Int? = level & 0x08 != 0 ? 100 : level & 0x04 != 0 ? 60 : level & 0x02 != 0 ? 20 : level & 0x01 != 0 ? 5 : nil
        return guess.map { Battery(percent: $0, charging: charging, approximate: true) }
    }

    /// 0x1000 Battery Status: [%, mức kế tiếp, trạng thái (0 xả, 1 sạc, 2 gần đầy, 3 đầy, 4 sạc chậm, 5+ lỗi)].
    static func batteryStatus(_ p: [UInt8]) -> Battery? {
        guard p.count >= 3, p[2] <= 4 else { return nil }
        let charging = p[2] == 1 || p[2] == 2 || p[2] == 4
        if p[0] == 0 { return p[2] == 3 ? Battery(percent: 100, charging: false, approximate: false) : nil }
        return Battery(percent: min(Int(p[0]), 100), charging: charging, approximate: false)
    }

    /// 0x1001 Battery Voltage: [mV cao, mV thấp, cờ (bit 7 đang sạc)].
    static func batteryVoltage(_ p: [UInt8]) -> Battery? {
        guard p.count >= 3 else { return nil }
        let mV = Int(p[0]) << 8 | Int(p[1])
        guard mV > 0 else { return nil }
        return Battery(percent: percent(millivolts: mV), charging: p[2] & 0x80 != 0, approximate: true)
    }

    /// Ước lượng % từ điện áp pin Li-ion một cell (đường xả gần đúng, nội suy tuyến tính).
    static func percent(millivolts mV: Int) -> Int {
        let curve: [(mV: Int, pct: Int)] = [(4200, 100), (4100, 90), (4000, 78), (3900, 62), (3850, 52), (3800, 42),
                                             (3750, 30), (3700, 18), (3650, 9), (3600, 4), (3500, 0)]
        if mV >= curve[0].mV { return 100 }
        for (hi, lo) in zip(curve, curve.dropFirst()) where mV >= lo.mV {
            let t = Double(mV - lo.mV) / Double(hi.mV - lo.mV)
            return lo.pct + Int((Double(hi.pct - lo.pct) * t).rounded())
        }
        return 0
    }

    static func battery(feature: Feature, _ params: [UInt8]) -> Battery? {
        switch feature {
        case .unifiedBattery: unifiedBattery(params)
        case .batteryStatus: batteryStatus(params)
        case .batteryVoltage: batteryVoltage(params)
        default: nil
        }
    }

    /// Hàm đọc pin của từng feature (0x1004: GetStatus là hàm 1; hai feature kia hàm 0).
    static func readFunction(_ f: Feature) -> UInt8 { f == .unifiedBattery ? 1 : 0 }

    /// Loại thiết bị theo feature 0x0005 (hàm GetDeviceType).
    static func kind(_ type: UInt8) -> DeviceBattery.Kind {
        switch type {
        case 0, 2: .keyboard
        case 3, 5: .mouse
        case 4: .trackpad
        case 8: .headphones
        case 11, 12: .controller
        default: .other
        }
    }
}

// MARK: - Đầu thu

/// Theo dõi đầu thu Logitech cắm vào / rút ra (IOHIDManager, theo sự kiện) và gom pin của các thiết bị sau chúng.
@MainActor
final class LogitechMonitor {
    var onChange: (() -> Void)?
    private var manager: IOHIDManager?
    private var receivers: [ObjectIdentifier: LogitechReceiver] = [:]

    var devices: [DeviceBattery] { receivers.values.flatMap(\.devices) }

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: HIDPP.vendor, kIOHIDPrimaryUsagePageKey: HIDPP.usagePage] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<LogitechMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.added(device) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<LogitechMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.removed(device) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    func stop() {
        for r in receivers.values { r.stop() }
        receivers = [:]
        if let m = manager {
            IOHIDManagerRegisterDeviceMatchingCallback(m, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(m, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    /// Mở notch, máy thức dậy: hỏi lại thiết bị chưa thấy và pin đã cũ (mỗi đầu thu tối đa mỗi phút một lần).
    func refresh() {
        for r in receivers.values { r.refresh() }
    }

    private func added(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard receivers[key] == nil else { return }
        let r = LogitechReceiver(device: device)
        r.onChange = { [weak self] in self?.onChange?() }
        receivers[key] = r
        r.start()
    }

    private func removed(_ device: IOHIDDevice) {
        guard let r = receivers.removeValue(forKey: ObjectIdentifier(device)) else { return }
        r.stop()
        onChange?()
    }
}

/// Một đầu thu (hoặc thiết bị Logitech cắm dây có HID++): hàng đợi yêu cầu, mỗi lúc một yêu cầu, hết giờ thì bỏ qua.
@MainActor
final class LogitechReceiver {
    var onChange: (() -> Void)?
    let device: IOHIDDevice
    private let location: Int
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var running = false

    private struct Pending {
        let bytes: [UInt8]
        let done: ([UInt8]?) -> Void
        var device: UInt8 { bytes[1] }
        var feature: UInt8 { bytes[2] }
        var function: UInt8 { bytes[3] >> 4 }
    }
    private var queue: [Pending] = []
    private var inflight: Pending?
    private var timeout: DispatchWorkItem?

    private struct Paired {
        var name: String?
        var kind: DeviceBattery.Kind = .other
        var batteryFeature: (index: UInt8, feature: HIDPP.Feature)?
        var battery: HIDPP.Battery?
        var querying = false
    }
    private var paired: [UInt8: Paired] = [:]
    private var lastScan: Date?

    /// Chỗ thiết bị sau đầu thu (1…6) và 0xFF (thiết bị nối thẳng).
    private static let slots: [UInt8] = [1, 2, 3, 4, 5, 6, 0xFF]

    init(device: IOHIDDevice) {
        self.device = device
        location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue ?? 0
    }

    var devices: [DeviceBattery] {
        paired.compactMap { idx, p in
            guard let b = p.battery else { return nil }
            let name = p.name ?? "Logitech"
            return DeviceBattery(id: "logi:\(location):\(idx)", name: name, kind: p.kind,
                                 symbol: DeviceBattery.symbol(kind: p.kind, name: name),
                                 levels: [.init(percent: b.percent)], charging: b.charging, approximate: b.approximate)
        }
    }

    func start() {
        running = true
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { ctx, _, _, _, _, report, length in
            guard let ctx, length > 0 else { return }
            let me = Unmanaged<LogitechReceiver>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated { me.received(bytes) }
        }, Unmanaged.passUnretained(self).toOpaque())
        scan()
    }

    func stop() {
        guard running else { return }
        running = false
        timeout?.cancel()
        timeout = nil
        queue = []
        inflight = nil
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        buffer.deallocate()
    }

    func refresh() {
        guard running, lastScan.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        scan()
    }

    /// Ping mọi chỗ: thiết bị trả lời thì hỏi tên, loại, pin. Thiết bị đã biết thì chỉ đọc lại pin.
    private func scan() {
        lastScan = Date()
        for idx in Self.slots {
            if let bf = paired[idx]?.batteryFeature {
                readBattery(idx, bf)
                continue
            }
            send(HIDPP.ping(device: idx)) { [weak self] params in
                guard params != nil else { return }
                self?.query(idx)
            }
        }
    }

    private func query(_ idx: UInt8) {
        guard paired[idx]?.querying != true else { return }
        paired[idx, default: Paired()].querying = true
        feature(idx, .deviceName) { [weak self] nameIndex in
            guard let self else { return }
            self.readName(idx, nameIndex) {
                self.findBattery(idx, [.unifiedBattery, .batteryStatus, .batteryVoltage]) {
                    self.paired[idx]?.querying = false
                    self.onChange?()
                }
            }
        }
    }

    private func feature(_ idx: UInt8, _ f: HIDPP.Feature, done: @escaping (UInt8?) -> Void) {
        send(HIDPP.getFeature(device: idx, f)) { params in
            guard let i = params?.first, i != 0 else { return done(nil) }
            done(i)
        }
    }

    /// 0x0005: loại (hàm 2), độ dài tên (hàm 0), rồi từng đoạn tên (hàm 1, tham số là vị trí ký tự).
    private func readName(_ idx: UInt8, _ fi: UInt8?, done: @escaping () -> Void) {
        guard let fi else { return done() }
        send(HIDPP.request(device: idx, feature: fi, function: 2)) { [weak self] p in
            guard let self else { return }
            if let t = p?.first { self.paired[idx]?.kind = HIDPP.kind(t) }
            self.send(HIDPP.request(device: idx, feature: fi, function: 0)) { [weak self] p in
                guard let self, let count = p?.first, count > 0 else { return done() }
                self.readNameChunk(idx, fi, count: Int(count), sofar: [], done: done)
            }
        }
    }

    private func readNameChunk(_ idx: UInt8, _ fi: UInt8, count: Int, sofar: [UInt8], done: @escaping () -> Void) {
        send(HIDPP.request(device: idx, feature: fi, function: 1, params: [UInt8(min(sofar.count, 255))])) { [weak self] p in
            guard let self else { return }
            let chunk = (p ?? []).prefix(count - sofar.count).filter { $0 != 0 }
            let all = sofar + chunk
            if chunk.isEmpty || all.count >= count {
                let name = String(decoding: all, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { self.paired[idx]?.name = name }
                return done()
            }
            self.readNameChunk(idx, fi, count: count, sofar: all, done: done)
        }
    }

    private func findBattery(_ idx: UInt8, _ candidates: [HIDPP.Feature], done: @escaping () -> Void) {
        guard let f = candidates.first else { return done() }
        feature(idx, f) { [weak self] fi in
            guard let self else { return }
            guard let fi else { return self.findBattery(idx, Array(candidates.dropFirst()), done: done) }
            self.paired[idx]?.batteryFeature = (fi, f)
            self.readBattery(idx, (fi, f), done: done)
        }
    }

    private func readBattery(_ idx: UInt8, _ bf: (index: UInt8, feature: HIDPP.Feature), done: (() -> Void)? = nil) {
        send(HIDPP.request(device: idx, feature: bf.index, function: HIDPP.readFunction(bf.feature))) { [weak self] p in
            if let self, let p, let b = HIDPP.battery(feature: bf.feature, p), b != self.paired[idx]?.battery {
                self.paired[idx]?.battery = b
                if done == nil { self.onChange?() }
            }
            done?()
        }
    }

    // MARK: Gửi / nhận

    private func send(_ bytes: [UInt8], done: @escaping ([UInt8]?) -> Void) {
        guard running else { return }
        queue.append(Pending(bytes: bytes, done: done))
        next()
    }

    private func next() {
        guard running, inflight == nil, !queue.isEmpty else { return }
        let p = queue.removeFirst()
        inflight = p
        let r = p.bytes.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(p.bytes[0]), buf.baseAddress!, buf.count)
        }
        guard r == kIOReturnSuccess else { return finish(nil) }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish(nil) } }
        timeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func finish(_ params: [UInt8]?) {
        timeout?.cancel()
        timeout = nil
        guard let p = inflight else { return }
        inflight = nil
        p.done(params)
        next()
    }

    private func received(_ bytes: [UInt8]) {
        guard running, let msg = HIDPP.parse(bytes) else { return }
        switch msg {
        case let .response(dev, feat, fn, params):
            if let p = inflight, p.device == dev, p.feature == feat, p.function == fn { finish(params) }
        case let .error(dev, feat, fn, _):
            if let p = inflight, p.device == dev, p.feature == feat, p.function == fn { finish(nil) }
        case let .connection(dev, connected):
            if connected {
                if let bf = paired[dev]?.batteryFeature { readBattery(dev, bf) } else { query(dev) }
            } else if paired[dev]?.battery != nil {
                paired[dev]?.battery = nil
                onChange?()
            }
        case let .event(dev, feat, _, params):
            guard let bf = paired[dev]?.batteryFeature, bf.index == feat, let b = HIDPP.battery(feature: bf.feature, params),
                  b != paired[dev]?.battery else { return }
            paired[dev]?.battery = b
            onChange?()
        }
    }
}
