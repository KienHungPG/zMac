import Testing
@testable import zMac

// Phím âm lượng / độ sáng và cảnh báo pin yếu. Không import Foundation (xem NowPlayingAdapterTests).

@Test func decodesMediaKeyData() {
    // NX_KEYTYPE_SOUND_UP nhấn: mã 0 ở 16 bit cao, 0x0A00 ở 16 bit thấp.
    #expect(MediaKeyEvent.decode(data1: 0x0000_0A00) == .init(code: 0, key: .volumeUp, down: true, isRepeat: false))
    // SOUND_DOWN nhả.
    #expect(MediaKeyEvent.decode(data1: 0x0001_0B00) == .init(code: 1, key: .volumeDown, down: false, isRepeat: false))
    // BRIGHTNESS_UP giữ phím (lặp).
    #expect(MediaKeyEvent.decode(data1: 0x0002_0A01) == .init(code: 2, key: .brightnessUp, down: true, isRepeat: true))
    #expect(MediaKeyEvent.decode(data1: 0x0003_0A00).key == .brightnessDown)
    #expect(MediaKeyEvent.decode(data1: 0x0007_0A00).key == .mute)
    // PLAY (16) và đèn bàn phím (21) để macOS xử lý.
    #expect(MediaKeyEvent.decode(data1: 0x0010_0A00).key == nil)
    #expect(MediaKeyEvent.decode(data1: 0x0015_0A00).key == nil)
}

@Test func stepsOnTheSystemGrid() {
    #expect(MediaKeyEvent.step(0.5, up: true, steps: 16) == 0.5625)
    #expect(MediaKeyEvent.step(0.5, up: false, steps: 16) == 0.4375)
    // Lệch lưới: làm tròn về nấc gần nhất rồi mới bước.
    #expect(MediaKeyEvent.step(0.53, up: true, steps: 16) == 0.5625)
    // Không vượt 0...1.
    #expect(MediaKeyEvent.step(1, up: true, steps: 16) == 1)
    #expect(MediaKeyEvent.step(0, up: false, steps: 16) == 0)
    #expect(MediaKeyEvent.step(0.02, up: false, steps: 16) == 0)
    // ⇧⌥: 64 nấc.
    #expect(MediaKeyEvent.step(0.5, up: true, steps: 64) == 0.515625)
}

@Test func volumeSymbols() {
    #expect(MediaKeyEvent.volumeSymbol(0.8, muted: true) == "speaker.slash.fill")
    #expect(MediaKeyEvent.volumeSymbol(0, muted: false) == "speaker.fill")
    #expect(MediaKeyEvent.volumeSymbol(0.2, muted: false) == "speaker.wave.1.fill")
    #expect(MediaKeyEvent.volumeSymbol(0.5, muted: false) == "speaker.wave.2.fill")
    #expect(MediaKeyEvent.volumeSymbol(1, muted: false) == "speaker.wave.3.fill")
}

@Test func lowBatteryThresholds() {
    #expect(LowBattery.thresholds(20) == [20, 10, 5])
    #expect(LowBattery.thresholds(10) == [10, 5])
    #expect(LowBattery.thresholds(30) == [30, 10, 5])
}

@Test func lowBatteryWarnsOnceWhenCrossing() {
    let t = LowBattery.thresholds(20)
    #expect(LowBattery.crossed(from: 21, to: 20, thresholds: t) == 20)
    #expect(LowBattery.crossed(from: 20, to: 19, thresholds: t) == nil)
    #expect(LowBattery.crossed(from: 11, to: 10, thresholds: t) == 10)
    #expect(LowBattery.crossed(from: 6, to: 5, thresholds: t) == 5)
    // Tụt nhiều nấc một lúc (máy ngủ dậy): báo mốc thấp nhất.
    #expect(LowBattery.crossed(from: 25, to: 9, thresholds: t) == 10)
    // Pin tăng, hoặc chưa biết số cũ (vừa mở app): không báo.
    #expect(LowBattery.crossed(from: 9, to: 12, thresholds: t) == nil)
    #expect(LowBattery.crossed(from: nil, to: 8, thresholds: t) == nil)
}

@Test func findsMeetingLinks() {
    let meet = MeetingLink.find(in: [nil, "Phòng họp tầng 3", "Tham gia: https://meet.google.com/abc-defg-hij?authuser=0 nhé"])
    #expect(meet == .init(url: "https://meet.google.com/abc-defg-hij", service: "Meet"))
    let zoom = MeetingLink.find(in: ["https://us02web.zoom.us/j/81234567890?pwd=AbC.1"])
    #expect(zoom?.service == "Zoom")
    #expect(zoom?.url == "https://us02web.zoom.us/j/81234567890?pwd=AbC.1")
    let teams = MeetingLink.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d>"])
    #expect(teams?.service == "Teams")
    #expect(MeetingLink.find(in: ["https://example.com/meet", "", nil]) == nil)
}
