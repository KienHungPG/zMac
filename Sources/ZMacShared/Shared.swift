import Foundation
import IOKit
import IOKit.ps

// MARK: - Hằng số dùng chung app <-> helper

public enum HelperConstants {
    public static let appBundleID = "com.zmac.app"
    public static let machService = "com.zmac.helper"
    public static let label = "com.zmac.helper"
    /// Tăng khi giao thức / logic helper đổi để app đề nghị cài lại.
    public static let version = "1"
    public static let installedBinary = "/Library/PrivilegedHelperTools/com.zmac.helper"
    public static let launchdPlist = "/Library/LaunchDaemons/com.zmac.helper.plist"
    public static let policyFile = "/Library/Application Support/zMac/battery-policy.json"
}

// MARK: - Chính sách sạc (app gửi, helper lưu và thực thi)

public struct BatteryPolicy: Codable, Equatable, Sendable {
    /// Bật giới hạn sạc.
    public var enabled = false
    /// Ngưỡng dừng sạc (%).
    public var limit = 80
    /// Sailing: chỉ sạc lại khi pin tụt xuống dưới limit - sailingDelta (tránh sạc nhấp nhả, hại pin).
    public var sailingDelta = 5
    /// Tạm ngừng sạc khi pin nóng hơn maxTemperature (°C).
    public var heatProtection = false
    public var maxTemperature = 35.0
    /// Pin đang cao hơn ngưỡng thì ngắt nguồn adapter để xả về ngưỡng (máy chạy bằng pin dù đang cắm sạc).
    public var dischargeToLimit = false
    /// Sạc đầy 100% một lần (vd. trước chuyến đi), tự tắt khi đầy.
    public var topUp = false
    /// Ngừng sạc khi máy ngủ (máy ngủ thì helper không xử lý được ngưỡng).
    public var inhibitDuringSleep = true

    public init() {}

    public func clamped() -> BatteryPolicy {
        var p = self
        p.limit = min(max(p.limit, 20), 100)
        p.sailingDelta = min(max(p.sailingDelta, 1), 20)
        p.maxTemperature = min(max(p.maxTemperature, 25), 50)
        return p
    }
}

public struct HelperStatus: Codable, Sendable {
    public var version: String
    /// Key SMC đang dùng để chặn sạc: "CHTE" (firmware mới), "CH0B" (M1 cũ), nil = máy không hỗ trợ.
    public var chargingKey: String?
    /// Key SMC ngắt adapter: "CHIE" hoặc "CH0I".
    public var adapterKey: String?
    public var chargingInhibited: Bool
    public var adapterDisabled: Bool
    /// Lý do trạng thái hiện tại: off, charging, limit, sailing, heat, sleep, topup, discharge, unsupported.
    public var reason: String
    public var policy: BatteryPolicy

    public init(version: String, chargingKey: String?, adapterKey: String?, chargingInhibited: Bool,
                adapterDisabled: Bool, reason: String, policy: BatteryPolicy) {
        self.version = version
        self.chargingKey = chargingKey
        self.adapterKey = adapterKey
        self.chargingInhibited = chargingInhibited
        self.adapterDisabled = adapterDisabled
        self.reason = reason
        self.policy = policy
    }
}

// MARK: - Quyết định chặn sạc (hàm thuần, helper gọi, có test)

public struct ChargeDecision: Equatable, Sendable {
    public var inhibit = false
    public var adapterOff = false
    public var reason = "charging"
    public var heatLatched = false
    /// Top-up đã đầy: helper tắt cờ topUp và lưu lại.
    public var finishTopUp = false
}

public enum ChargeLogic {
    public static func decide(policy p: BatteryPolicy, battery b: BatterySnapshot, currentlyInhibited: Bool,
                              heatLatched: Bool, sleeping: Bool, canDisableAdapter: Bool) -> ChargeDecision {
        var d = ChargeDecision()
        d.heatLatched = heatLatched
        guard p.enabled else { d.reason = "off"; d.heatLatched = false; return d }
        if p.topUp {
            if b.percent < 100 && !b.fullyCharged { d.reason = "topup"; return d }
            d.finishTopUp = true
        }
        let lower = p.limit - p.sailingDelta
        if p.limit >= 100 {
            d.inhibit = false
        } else if b.percent >= p.limit {
            d.inhibit = true; d.reason = "limit"
        } else if b.percent <= lower {
            d.inhibit = false
        } else {
            // Vùng sailing: giữ nguyên trạng thái để không sạc nhấp nhả.
            d.inhibit = currentlyInhibited
            d.reason = currentlyInhibited ? "sailing" : "charging"
        }
        // Nhiệt: trễ 2°C để không bật tắt liên tục quanh ngưỡng.
        if p.heatProtection {
            if b.temperature >= p.maxTemperature { d.heatLatched = true }
            else if b.temperature < p.maxTemperature - 2 { d.heatLatched = false }
            if d.heatLatched { d.inhibit = true; d.reason = "heat" }
        } else {
            d.heatLatched = false
        }
        if p.dischargeToLimit, canDisableAdapter, b.externalConnected, b.percent > p.limit {
            d.adapterOff = true; d.inhibit = true; d.reason = "discharge"
        }
        // Máy ngủ thì helper không theo dõi được: đã gần ngưỡng thì ngừng sạc để khỏi sạc vượt;
        // pin còn thấp thì vẫn cho sạc (sạc quá ngưỡng một chút còn hơn sáng ra pin không lên).
        if sleeping {
            d.adapterOff = false
            if p.inhibitDuringSleep && b.percent >= lower { d.inhibit = true; d.reason = "sleep" }
            else if d.reason == "discharge" { d.reason = "limit" }   // không xả khi ngủ, vẫn chặn sạc vì đang trên ngưỡng
        }
        return d
    }
}

/// Giao thức XPC. Dữ liệu trao đổi dạng JSON để hai bên đổi field dễ (không phải NSSecureCoding).
@objc public protocol ZMacHelperXPC {
    func status(reply: @escaping (Data?) -> Void)
    func setPolicy(_ json: Data, reply: @escaping (Data?, String?) -> Void)
}

// MARK: - Đọc pin từ IORegistry (không cần quyền)

public struct BatterySnapshot: Equatable, Sendable {
    public init(percent: Int, isCharging: Bool, externalConnected: Bool, fullyCharged: Bool, temperature: Double,
                cycleCount: Int, designCapacity: Int, maxCapacity: Int, adapterWatts: Int, timeRemaining: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.temperature = temperature
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.adapterWatts = adapterWatts
        self.timeRemaining = timeRemaining
    }

    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    public var temperature: Double          // °C
    public var cycleCount: Int
    public var designCapacity: Int          // mAh
    public var maxCapacity: Int             // mAh (dung lượng thực còn lại khi đầy)
    public var adapterWatts: Int
    public var timeRemaining: Int?          // phút, nil = đang tính

    public var health: Double {
        designCapacity > 0 ? min(Double(maxCapacity) / Double(designCapacity), 1.0) : 0
    }
}

public enum BatteryReader {
    /// Máy có pin trong (MacBook) hay không (Mac mini / Studio / iMac).
    public static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { src in
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else { return false }
            return d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    public static func snapshot() -> BatterySnapshot? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        func bool(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }

        // Apple Silicon: CurrentCapacity là % hiển thị, AppleRaw* là mAh.
        var percent = int("CurrentCapacity")
        let maxCap = int("MaxCapacity")
        if maxCap > 100 { percent = maxCap > 0 ? percent * 100 / maxCap : 0 }
        let rawMax = int("AppleRawMaxCapacity")
        let nominal = int("NominalChargeCapacity")
        let adapter = d["AdapterDetails"] as? [String: Any]
        let time = int("TimeRemaining")

        return BatterySnapshot(
            percent: min(max(percent, 0), 100),
            isCharging: bool("IsCharging"),
            externalConnected: bool("ExternalConnected"),
            fullyCharged: bool("FullyCharged"),
            temperature: Double(int("Temperature")) / 100.0,
            cycleCount: int("CycleCount"),
            designCapacity: int("DesignCapacity"),
            maxCapacity: nominal > 0 ? nominal : rawMax,
            adapterWatts: (adapter?["Watts"] as? NSNumber)?.intValue ?? 0,
            timeRemaining: (time > 0 && time < 65535) ? time : nil
        )
    }
}
