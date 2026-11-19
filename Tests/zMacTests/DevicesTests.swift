import Testing
@testable import zMac

// Pin thiết bị không dây: gói HID++ của Logitech, mức pin AirPods, gộp nguồn, khi nào báo.
// Không import Foundation (xem NowPlayingAdapterTests).

@Test func buildsHIDPPRequests() {
    let r = HIDPP.getFeature(device: 2, .unifiedBattery)
    #expect(r.count == 20)
    #expect(Array(r.prefix(6)) == [0x11, 0x02, 0x00, 0x0B, 0x10, 0x04])   // root, hàm 0, swID 0xB, feature 0x1004
    #expect(r.dropFirst(6).allSatisfy { $0 == 0 })
    let ping = HIDPP.ping(device: 1)
    #expect(Array(ping.prefix(7)) == [0x11, 0x01, 0x00, 0x1B, 0, 0, 0x5A])
}

@Test func parsesHIDPPMessages() {
    let pad13 = [UInt8](repeating: 0, count: 13)
    // Trả lời getFeature: feature index 6.
    #expect(HIDPP.parse([0x11, 0x02, 0x00, 0x0B, 0x06, 0x00, 0x01] + pad13)
            == .response(device: 2, feature: 0, function: 0, params: [0x06, 0x00, 0x01] + pad13))
    // Lỗi HID++ 1.0 cho ping (thiết bị không có ở chỗ 3).
    #expect(HIDPP.parse([0x10, 0x03, 0x8F, 0x00, 0x1B, 0x09, 0x00]) == .error(device: 3, feature: 0, function: 1, code: 9))
    // Lỗi HID++ 2.0.
    #expect(HIDPP.parse([0x11, 0x01, 0xFF, 0x05, 0x2B, 0x02] + [UInt8](repeating: 0, count: 14))
            == .error(device: 1, feature: 5, function: 2, code: 2))
    // Đầu thu báo thiết bị 1 kết nối, thiết bị 2 mất kết nối (bit 6).
    #expect(HIDPP.parse([0x10, 0x01, 0x41, 0x04, 0x01, 0x6D, 0x40]) == .connection(device: 1, connected: true))
    #expect(HIDPP.parse([0x10, 0x02, 0x41, 0x04, 0x41, 0x6D, 0x40]) == .connection(device: 2, connected: false))
    // Sự kiện pin (swID 0).
    #expect(HIDPP.parse([0x11, 0x01, 0x06, 0x00, 55, 0x04, 0x00] + pad13)
            == .event(device: 1, feature: 6, function: 0, params: [55, 0x04, 0x00] + pad13))
    // Trả lời cho phần mềm khác (swID 0x3): bỏ qua. Gói lạ: bỏ qua.
    #expect(HIDPP.parse([0x11, 0x01, 0x06, 0x13, 55, 0, 0] + pad13) == nil)
    #expect(HIDPP.parse([0x01, 0x02]) == nil)
}

@Test func readsLogitechBatteryFeatures() {
    // 0x1004: 55%, đang sạc.
    #expect(HIDPP.unifiedBattery([55, 0x04, 0x01, 0x01]) == .init(percent: 55, charging: true, approximate: false))
    // 0x1004 chỉ báo mức "yếu": ước lượng 20%.
    #expect(HIDPP.unifiedBattery([0, 0x02, 0x00, 0x00]) == .init(percent: 20, charging: false, approximate: true))
    #expect(HIDPP.unifiedBattery([0, 0x00, 0x03, 0x00]) == .init(percent: 100, charging: false, approximate: false))
    #expect(HIDPP.unifiedBattery([0, 0, 0, 0]) == nil)
    // 0x1000: 30%, đang xả; trạng thái lỗi thì bỏ.
    #expect(HIDPP.batteryStatus([30, 20, 0]) == .init(percent: 30, charging: false, approximate: false))
    #expect(HIDPP.batteryStatus([30, 20, 6]) == nil)
    // 0x1001: 3,85 V (0x0F0A = 3850 mV), đang sạc.
    #expect(HIDPP.batteryVoltage([0x0F, 0x0A, 0x80]) == .init(percent: 52, charging: true, approximate: true))
    #expect(HIDPP.percent(millivolts: 4300) == 100)
    #expect(HIDPP.percent(millivolts: 3725) == 24)
    #expect(HIDPP.percent(millivolts: 3400) == 0)
    #expect(HIDPP.readFunction(.unifiedBattery) == 1)
    #expect(HIDPP.readFunction(.batteryStatus) == 0)
}

@Test func airPodsLevelsSkipUnknownAndCase() {
    let pods = DeviceBattery.bluetoothLevels(left: 80, right: 75, case: 60, single: 70)
    #expect(pods.map(\.percent) == [80, 75, 60])   // có trái / phải thì bỏ mức đơn
    #expect(pods.last?.isCase == true)
    // Hộp sạc không tính vào mức báo.
    let d = DeviceBattery(id: "a", name: "AirPods", kind: .headphones, symbol: "airpods", levels: pods)
    #expect(d.level == 75)
    // 0 = chưa biết.
    #expect(DeviceBattery.bluetoothLevels(left: 0, right: nil, case: 0, single: 45).map(\.percent) == [45])
    #expect(DeviceBattery.bluetoothLevels(left: 0, right: 0, case: 0, single: 0).isEmpty)
}

@Test func mergesTheSameDeviceFromTwoSources() {
    func dev(_ id: String, _ name: String, _ pct: Int, address: String? = nil) -> DeviceBattery {
        DeviceBattery(id: id, name: name, kind: .other, symbol: "x", levels: [.init(percent: pct)], address: address)
    }
    let hid = dev("hid:1", "Magic Mouse", 40, address: "aa-bb")
    let bt = dev("bt:aa-bb", "Chuột của Hùng", 41, address: "aa-bb")       // cùng địa chỉ: bỏ
    let pad = dev("gc:1", "DualSense Wireless Controller", 90)
    let padBT = dev("bt:cc", "DualSense Wireless Controller", 88, address: "cc")   // cùng tên: bỏ
    let pods = dev("bt:dd", "AirPods", 10, address: "dd")
    let all = DeviceBattery.merge([[hid], [pad], [], [bt, padBT, pods]])
    #expect(all.map(\.id) == ["bt:dd", "hid:1", "gc:1"])   // pin thấp nhất lên trước
    #expect(DeviceBattery.normalize(address: "AA:BB:CC") == "aa-bb-cc")
}

@Test func warnsOnceWhenADeviceRunsLow() {
    // Vừa kết nối đã ở 15%: báo mốc 20.
    #expect(DeviceAlerts.lowCrossing(old: nil, new: 15, charging: false, threshold: 20) == 20)
    #expect(DeviceAlerts.lowCrossing(old: nil, new: 50, charging: false, threshold: 20) == nil)
    // Tụt qua 10%.
    #expect(DeviceAlerts.lowCrossing(old: 12, new: 9, charging: false, threshold: 20) == 10)
    // Vẫn ở mức cũ, hoặc đang sạc: không báo lại.
    #expect(DeviceAlerts.lowCrossing(old: 15, new: 15, charging: false, threshold: 20) == nil)
    #expect(DeviceAlerts.lowCrossing(old: nil, new: 5, charging: true, threshold: 20) == nil)
}

@Test func announcesOnlyRealReconnects() {
    #expect(DeviceAlerts.shouldAnnounce(awayFor: nil, settled: true))
    #expect(DeviceAlerts.shouldAnnounce(awayFor: 900, settled: true))
    #expect(!DeviceAlerts.shouldAnnounce(awayFor: 60, settled: true))   // chuột ngủ một lát rồi thức
    #expect(!DeviceAlerts.shouldAnnounce(awayFor: nil, settled: false))  // lần quét đầu lúc mở app
}
