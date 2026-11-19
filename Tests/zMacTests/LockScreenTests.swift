import CoreGraphics
import Testing
@testable import zMac

// Trình phát trên màn hình khoá: khi nào hiện, đặt ở đâu.

@Test func lockScreenShowsOnlyWhatTheUserChose() {
    // Tắt: không bao giờ hiện.
    #expect(!LockScreenLayout.shows(style: .off, when: .paused, hasTrack: true, playing: true))
    // Không có bài (hoặc bài không tên, ví dụ app chỉ phát âm thanh): không hiện.
    #expect(!LockScreenLayout.shows(style: .compact, when: .paused, hasTrack: false, playing: true))
    // "Chỉ khi đang phát nhạc".
    #expect(LockScreenLayout.shows(style: .compact, when: .playing, hasTrack: true, playing: true))
    #expect(!LockScreenLayout.shows(style: .full, when: .playing, hasTrack: true, playing: false))
    // "Cả khi đang tạm dừng".
    #expect(LockScreenLayout.shows(style: .full, when: .paused, hasTrack: true, playing: false))
}

@Test func lockScreenWidgetSitsCenteredUnderTheClock() {
    // MacBook Air 13" (1470 × 956 pt).
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let f = LockScreenLayout.frame(size: CGSize(width: 320, height: 60), screen: screen)
    #expect(f.midX == screen.midX)
    #expect(screen.maxY - f.maxY == 258)   // 27% chiều cao
    // Màn thấp: tối thiểu 230 pt từ đỉnh, để không đè lên đồng hồ.
    let small = CGRect(x: 0, y: 0, width: 1024, height: 640)
    #expect(small.maxY - LockScreenLayout.frame(size: CGSize(width: 320, height: 60), screen: small).maxY == 230)
    // Màn chính không ở gốc toạ độ (màn ngoài bên trái): vẫn căn theo màn đó.
    let shifted = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    #expect(LockScreenLayout.frame(size: CGSize(width: 420, height: 240), screen: shifted).midX == shifted.midX)
}
