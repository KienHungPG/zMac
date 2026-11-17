import CoreGraphics
import Foundation
import IOKit

// DDC/CI qua IOAVService (Apple Silicon). Mọi I/O I2C chạy trên một queue nền nối tiếp:
// bus I2C chậm (~50 ms mỗi lần đọc), không bao giờ gọi trên main.

/// Bọc CFTypeRef của IOAVService để chuyển qua lại giữa các queue.
final class AVService: @unchecked Sendable {
    let ref: CFTypeRef
    let vendor: Int?
    let product: Int?
    let serial: Int?
    let name: String?

    init(ref: CFTypeRef, attributes: [String: Any]?) {
        self.ref = ref
        let pa = attributes?["ProductAttributes"] as? [String: Any]
        vendor = (pa?["LegacyManufacturerID"] as? NSNumber)?.intValue
        product = (pa?["ProductID"] as? NSNumber)?.intValue
        serial = (pa?["SerialNumber"] as? NSNumber)?.intValue
        name = pa?["ProductName"] as? String
    }
}

/// Màn hình cần ghép với dịch vụ DDC.
struct DDCTarget: Sendable {
    let id: CGDirectDisplayID
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
}

enum DDC {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let create = PrivateAPI.sym(nil, "IOAVServiceCreateWithService", CreateFn.self)
    private static let writeI2C = PrivateAPI.sym(nil, "IOAVServiceWriteI2C", I2CFn.self)
    private static let readI2C = PrivateAPI.sym(nil, "IOAVServiceReadI2C", I2CFn.self)

    static var available: Bool { create != nil && writeI2C != nil && readI2C != nil }

    /// Duyệt cây IOService theo thứ tự: nhớ DisplayAttributes của framebuffer gần nhất,
    /// ghép với DCPAVServiceProxy (Location = External) đứng sau nó.
    static func externalServices() -> [AVService] {
        guard let create else { return [] }
        var iter: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iter) }

        var result: [AVService] = []
        var lastAttributes: [String: Any]?
        var nameBuf = [CChar](repeating: 0, count: 128)
        while true {
            let entry = IOIteratorNext(iter)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard IOObjectGetClass(entry, &nameBuf) == KERN_SUCCESS else { continue }
            let cls = String(cString: nameBuf)
            if cls == "AppleCLCD2" || cls == "IOMobileFramebufferShim" {
                lastAttributes = property(entry, "DisplayAttributes") as? [String: Any]
            } else if cls == "DCPAVServiceProxy" {
                guard property(entry, "Location") as? String == "External",
                      let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                result.append(AVService(ref: svc, attributes: lastAttributes))
            }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Ghép theo vendor / product (/ serial). Chỉ một màn ngoài và một dịch vụ thì ghép thẳng.
    static func pair(_ targets: [DDCTarget], _ services: [AVService]) -> [CGDirectDisplayID: AVService] {
        var out: [CGDirectDisplayID: AVService] = [:]
        var left = services
        for t in targets {
            if let i = left.firstIndex(where: { s in
                s.vendor == Int(t.vendor) && s.product == Int(t.model)
                    && (s.serial == nil || s.serial == 0 || t.serial == 0 || s.serial == Int(t.serial))
            }) {
                out[t.id] = left.remove(at: i)
            }
        }
        if out.isEmpty, targets.count == 1, services.count == 1 { out[targets[0].id] = services[0] }
        return out
    }

    private static func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Set VCP: [0x84, 0x03, vcp, hi, lo, chk]. Gửi 2 lần cho màn hình khó tính.
    @discardableResult
    static func write(_ svc: AVService, vcp: UInt8, value: UInt16) -> Bool {
        guard let writeI2C else { return false }
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xff), 0]
        packet[5] = checksum(0x6E ^ 0x51, packet[0..<5])
        var ok = false
        for _ in 0..<2 {
            usleep(10_000)
            if writeI2C(svc.ref, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
        }
        return ok
    }

    /// Get VCP: gửi [0x82, 0x01, vcp, chk], đợi ~50 ms rồi đọc 11 byte.
    /// Trả lời: [0x6E, 0x88, 0x02, kết quả, vcp, loại, maxHi, maxLo, curHi, curLo, chk].
    static func read(_ svc: AVService, vcp: UInt8, attempts: Int = 4) -> (current: UInt16, max: UInt16)? {
        guard let writeI2C, let readI2C else { return nil }
        var packet: [UInt8] = [0x82, 0x01, vcp, 0]
        packet[3] = checksum(0x6E, packet[0..<3])
        for _ in 0..<attempts {
            for _ in 0..<2 {
                usleep(10_000)
                _ = writeI2C(svc.ref, 0x37, 0x51, &packet, UInt32(packet.count))
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            if readI2C(svc.ref, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               checksum(0x50, reply[0..<10]) == reply[10],
               reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp {
                let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
                let cur = UInt16(reply[8]) << 8 | UInt16(reply[9])
                if max > 0 { return (cur, max) }
            }
            usleep(20_000)
        }
        return nil
    }
}

/// Giữ dịch vụ DDC đã ghép và gom giá trị khi kéo thanh trượt: chỉ gửi giá trị mới nhất.
final class DDCController: @unchecked Sendable {
    struct Detected: Sendable {
        let current: UInt16
        let max: UInt16
    }

    private let queue = DispatchQueue(label: "com.zmac.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var services: [CGDirectDisplayID: AVService] = [:]
    private var maxValues: [CGDirectDisplayID: UInt16] = [:]
    private var pending: [CGDirectDisplayID: UInt16] = [:]
    private var draining: Set<CGDirectDisplayID> = []
    private var generation = 0

    /// Ghép lại dịch vụ và đọc độ sáng (VCP 0x10) trên queue nền.
    /// Kết quả: id -> giá trị đọc được, nil = màn không trả lời DDC.
    func detect(_ targets: [DDCTarget], completion: @escaping @Sendable ([CGDirectDisplayID: Detected?]) -> Void) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        queue.async { [self] in
            let results = detectNow(targets)
            lock.lock()
            let current = gen == generation
            lock.unlock()
            if current { completion(results) }
        }
    }

    /// Bản đồng bộ cho `zMac --diagnose`.
    func detectNow(_ targets: [DDCTarget]) -> [CGDirectDisplayID: Detected?] {
        let paired = targets.isEmpty || !DDC.available ? [:] : DDC.pair(targets, DDC.externalServices())
        var results: [CGDirectDisplayID: Detected?] = [:]
        var found: [CGDirectDisplayID: AVService] = [:]
        var maxes: [CGDirectDisplayID: UInt16] = [:]
        for t in targets {
            guard let svc = paired[t.id], let v = DDC.read(svc, vcp: 0x10) else {
                results[t.id] = .some(nil)
                continue
            }
            found[t.id] = svc
            maxes[t.id] = v.max
            results[t.id] = Detected(current: v.current, max: v.max)
        }
        lock.lock()
        services = found
        maxValues = maxes
        lock.unlock()
        return results
    }

    /// value: 0...1. Gọi dồn dập được, chỉ giá trị cuối được gửi.
    func set(_ id: CGDirectDisplayID, _ value: Double) {
        lock.lock()
        guard services[id] != nil else { lock.unlock(); return }
        let maxV = Double(maxValues[id] ?? 100)
        pending[id] = UInt16((min(max(value, 0), 1) * maxV).rounded())
        let start = !draining.contains(id)
        if start { draining.insert(id) }
        lock.unlock()
        if start { queue.async { [self] in drain(id) } }
    }

    private func drain(_ id: CGDirectDisplayID) {
        while true {
            lock.lock()
            guard let v = pending.removeValue(forKey: id), let svc = services[id] else {
                draining.remove(id)
                lock.unlock()
                return
            }
            lock.unlock()
            DDC.write(svc, vcp: 0x10, value: v)
        }
    }

    func reset() {
        lock.lock()
        generation += 1
        services = [:]
        maxValues = [:]
        pending = [:]
        lock.unlock()
    }
}
