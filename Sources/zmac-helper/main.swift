import CryptoKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Security
import ZMacShared

// zmac-helper: daemon root (launchd) giữ ngưỡng sạc kiểu AlDente.
// - Không timer: chỉ thức dậy khi pin cập nhật (IOKit interest), cắm/rút sạc (IOPS), ngủ/thức (IOPM).
// - Nhận SIGTERM (gỡ cài đặt, tắt máy) thì trả SMC về mặc định: cho sạc, bật adapter.
//
// Dòng lệnh:
//   zmac-helper daemon         chạy dưới launchd
//   zmac-helper smc KEY...     đọc key SMC (debug, không cần root)
//   zmac-helper restore        trả SMC về mặc định (cần root)

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    FileHandle.standardError.write(("zmac-helper: " + s + "\n").data(using: .utf8)!)
}

// MARK: - Điều khiển sạc

final class PowerController {
    private let smc: SMC
    let chargingKey: String?
    let adapterKey: String?
    private(set) var policy: BatteryPolicy
    private(set) var inhibited = false
    private(set) var adapterOff = false
    private(set) var reason = "off"
    private var sleeping = false
    private var heatLatched = false

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        // Firmware mới (macOS 15+ trên Apple Silicon) dùng CHTE; M1 đời đầu dùng CH0B/CH0C.
        if smc.exists("CHTE") { chargingKey = "CHTE" }
        else if smc.exists("CH0B") { chargingKey = "CH0B" }
        else { chargingKey = nil }
        if smc.exists("CHIE") { adapterKey = "CHIE" }
        else if smc.exists("CH0I") { adapterKey = "CH0I" }
        else { adapterKey = nil }
        policy = Self.loadPolicy()
        inhibited = readInhibited()
        adapterOff = readAdapterOff()
    }

    // MARK: Trạng thái SMC

    private func readInhibited() -> Bool {
        guard let key = chargingKey, let v = smc.read(key), let b = v.first else { return false }
        return key == "CHTE" ? v.contains { $0 != 0 } : b == 0x02
    }

    private func readAdapterOff() -> Bool {
        guard let key = adapterKey, let b = smc.read(key)?.first else { return false }
        return key == "CHIE" ? b == 0x08 : b == 0x01
    }

    private func value(for key: String, first: UInt8) -> [UInt8] {
        // Giữ đúng kích thước key (CHTE là 4 byte, các key khác 1 byte).
        let size = smc.read(key)?.count ?? 1
        var bytes = [UInt8](repeating: 0, count: max(size, 1))
        bytes[0] = first
        return bytes
    }

    private func setInhibit(_ on: Bool) {
        guard let key = chargingKey, on != inhibited else { return }
        var ok = smc.write(key, value(for: key, first: on ? (key == "CHTE" ? 0x01 : 0x02) : 0x00))
        if key == "CH0B", smc.exists("CH0C") { ok = smc.write("CH0C", [on ? 0x02 : 0x00]) && ok }
        if ok { inhibited = on } else { log("ghi \(key) thất bại") }
    }

    private func setAdapterOff(_ off: Bool) {
        guard let key = adapterKey, off != adapterOff else { return }
        let ok = smc.write(key, value(for: key, first: off ? (key == "CHIE" ? 0x08 : 0x01) : 0x00))
        if ok { adapterOff = off } else { log("ghi \(key) thất bại") }
    }

    // MARK: Quyết định

    func evaluate() {
        guard chargingKey != nil else { reason = "unsupported"; return }
        guard let b = BatteryReader.snapshot() else { return }
        let d = ChargeLogic.decide(policy: policy, battery: b, currentlyInhibited: inhibited, heatLatched: heatLatched,
                                   sleeping: sleeping, canDisableAdapter: adapterKey != nil)
        heatLatched = d.heatLatched
        if d.finishTopUp { policy.topUp = false; savePolicy() }
        setAdapterOff(d.adapterOff)
        setInhibit(d.inhibit)
        reason = d.reason
    }

    func update(_ newPolicy: BatteryPolicy) {
        policy = newPolicy.clamped()
        savePolicy()
        evaluate()
    }

    func willSleep() { sleeping = true; evaluate() }
    func didWake() { sleeping = false; evaluate() }

    /// Trả máy về hành vi gốc của Apple.
    func restoreDefaults() {
        setAdapterOff(false)
        setInhibit(false)
        // Ghi thẳng phòng khi trạng thái nhớ trong RAM lệch với SMC.
        if let key = chargingKey { smc.write(key, value(for: key, first: 0)) }
        if chargingKey == "CH0B", smc.exists("CH0C") { smc.write("CH0C", [0]) }
        if let key = adapterKey { smc.write(key, value(for: key, first: 0)) }
    }

    var status: HelperStatus {
        HelperStatus(version: HelperConstants.version, chargingKey: chargingKey, adapterKey: adapterKey,
                     chargingInhibited: inhibited, adapterDisabled: adapterOff, reason: reason, policy: policy)
    }

    // MARK: Lưu chính sách (root-only)

    private static func loadPolicy() -> BatteryPolicy {
        guard let data = FileManager.default.contents(atPath: HelperConstants.policyFile),
              let p = try? JSONDecoder().decode(BatteryPolicy.self, from: data) else { return BatteryPolicy() }
        return p.clamped()
    }

    private func savePolicy() {
        let url = URL(fileURLWithPath: HelperConstants.policyFile)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(policy) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - XPC

final class HelperService: NSObject, ZMacHelperXPC {
    let controller: PowerController
    init(_ c: PowerController) { controller = c }

    func status(reply: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            self.controller.evaluate()
            reply(try? JSONEncoder().encode(self.controller.status))
        }
    }

    func setPolicy(_ json: Data, reply: @escaping (Data?, String?) -> Void) {
        guard let p = try? JSONDecoder().decode(BatteryPolicy.self, from: json) else {
            reply(nil, "invalid policy"); return
        }
        DispatchQueue.main.async {
            self.controller.update(p)
            reply(try? JSONEncoder().encode(self.controller.status), nil)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: HelperService
    let requirement: String
    init(_ s: HelperService) {
        service = s
        // Chỉ nhận app zMac ký cùng chứng chỉ với helper. Helper ký ad-hoc thì chỉ kiểm bundle id.
        if let hash = Self.ownLeafCertHash() {
            requirement = "identifier \"\(HelperConstants.appBundleID)\" and certificate leaf = H\"\(hash)\""
        } else {
            requirement = "identifier \"\(HelperConstants.appBundleID)\""
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.setCodeSigningRequirement(requirement)
        c.exportedInterface = NSXPCInterface(with: ZMacHelperXPC.self)
        c.exportedObject = service
        c.resume()
        return true
    }

    static func ownLeafCertHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return nil }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - Sự kiện IOKit

var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var batteryInterest: io_object_t = 0

// iokit_common_msg(x) là macro C, Swift không nhập được: ghi thẳng giá trị.
let kIOMessageCanSystemSleep: UInt32 = 0xE000_0270
let kIOMessageSystemWillSleep: UInt32 = 0xE000_0280
let kIOMessageSystemHasPoweredOn: UInt32 = 0xE000_0300

func registerEvents(_ controller: PowerController) {
    let ctx = Unmanaged.passUnretained(controller).toOpaque()

    // Cắm / rút sạc, % thay đổi.
    if let src = IOPSNotificationCreateRunLoopSource({ ctx in
        guard let ctx else { return }
        Unmanaged<PowerController>.fromOpaque(ctx).takeUnretainedValue().evaluate()
    }, ctx)?.takeRetainedValue() {
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    // Pin tự cập nhật (nhiệt độ, %): interest notification trên AppleSmartBattery.
    let port = IONotificationPortCreate(kIOMainPortDefault)
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
    let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    if battery != 0 {
        IOServiceAddInterestNotification(port, battery, kIOGeneralInterest, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<PowerController>.fromOpaque(ctx).takeUnretainedValue().evaluate()
        }, ctx, &batteryInterest)
        IOObjectRelease(battery)
    }

    // Ngủ / thức.
    var powerPort: IONotificationPortRef?
    rootPort = IORegisterForSystemPower(ctx, &powerPort, { ctx, _, message, arg in
        guard let ctx else { return }
        let c = Unmanaged<PowerController>.fromOpaque(ctx).takeUnretainedValue()
        switch message {
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: arg))
        case kIOMessageSystemWillSleep:
            c.willSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: arg))
        case kIOMessageSystemHasPoweredOn:
            c.didWake()
        default: break
        }
    }, &notifier)
    if let powerPort {
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(powerPort).takeUnretainedValue(), .defaultMode)
    }
}

// MARK: - main

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "smc":
    guard let smc = SMC() else { print("không mở được AppleSMC"); exit(1) }
    for key in args.dropFirst(2) {
        if let v = smc.read(key) {
            print("\(key) [\(smc.type(key) ?? "?")] " + v.map { String(format: "%02x", $0) }.joined(separator: " "))
        } else {
            print("\(key) không có")
        }
    }

case "restore":
    guard let c = PowerController() else { exit(1) }
    c.restoreDefaults()
    print("restored")

case "daemon":
    guard let controller = PowerController() else { log("không mở được AppleSMC"); exit(1) }
    controller.evaluate()
    registerEvents(controller)

    let service = HelperService(controller)
    let delegate = ListenerDelegate(service)
    let listener = NSXPCListener(machServiceName: HelperConstants.machService)
    listener.delegate = delegate
    listener.resume()

    // launchd gửi SIGTERM khi gỡ / tắt máy: trả SMC về mặc định trước khi thoát.
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler {
        controller.restoreDefaults()
        exit(0)
    }
    term.resume()
    log("chạy, key sạc \(controller.chargingKey ?? "không có"), key adapter \(controller.adapterKey ?? "không có")")
    withExtendedLifetime((listener, delegate, term)) { CFRunLoopRun() }

default:
    print("dùng: zmac-helper daemon | smc KEY... | restore")
    exit(2)
}
