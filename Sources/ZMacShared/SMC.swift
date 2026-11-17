import CSMC
import Foundation
import IOKit

/// Kết nối AppleSMC. Một kết nối mở suốt vòng đời (mở/đóng mỗi lần tốn hơn một IPC).
public final class SMC {
    private var conn: io_connect_t = 0

    public init?() {
        guard zsmc_open(&conn) == KERN_SUCCESS else { return nil }
    }

    deinit { zsmc_close(conn) }

    public func exists(_ key: String) -> Bool {
        var info = zsmc_key_info()
        return key.withCString { zsmc_get_info(conn, $0, &info) } == KERN_SUCCESS
    }

    public func read(_ key: String) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var type: UInt32 = 0
        let kr = key.withCString { k in buf.withUnsafeMutableBufferPointer { zsmc_read(conn, k, $0.baseAddress, &size, &type) } }
        return kr == KERN_SUCCESS ? Array(buf.prefix(Int(size))) : nil
    }

    @discardableResult
    public func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        let kr = key.withCString { k in bytes.withUnsafeBufferPointer { zsmc_write(conn, k, $0.baseAddress, UInt32(bytes.count)) } }
        return kr == KERN_SUCCESS
    }

    /// Kiểu dữ liệu dạng chuỗi ("ui8 ", "hex_", "flt "…), để debug.
    public func type(_ key: String) -> String? {
        var info = zsmc_key_info()
        guard key.withCString({ zsmc_get_info(conn, $0, &info) }) == KERN_SUCCESS else { return nil }
        let t = info.dataType
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((t >> $0) & 0xff))) }
        return String(chars)
    }
}
