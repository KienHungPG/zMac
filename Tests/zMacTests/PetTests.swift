import Testing
@testable import zMac

// Thú cưng: chỉ số giảm theo giờ thật, cho ăn / chơi, lên cấp, và lưới hình vẽ không sai sót.
// Không import Foundation (xem NowPlayingAdapterTests).

@Test func statsDecayOverTime() {
    let s = PetStats.newborn(0)
    #expect(s.food(at: 0) == 80)
    #expect(s.food(at: 3600) == 76)          // 4 / giờ
    #expect(s.joy(at: 7200) == 74)           // 3 / giờ
    #expect(s.food(at: 3600 * 100) == 0)     // không âm
    #expect(s.food(at: -50) == 80)           // đồng hồ lùi: không tăng
    #expect(s.days(at: 86_400 * 3 + 5) == 3)
}

@Test func feedingStopsWhenFull() {
    var s = PetStats.newborn(0)
    let first = s.feed(0)                    // 80 -> 100 (tối đa 100)
    #expect(first)
    #expect(s.food(at: 0) == 100)
    let full = s.feed(10)                    // no quá thì không ăn, không thêm xp
    #expect(!full)
    #expect(s.xp == 10)
    let later = s.feed(3600 * 5)             // 100 - 20 = 80 < 90 thì ăn được
    #expect(later)
}

@Test func caringLevelsUp() {
    var s = PetStats.newborn(0)
    #expect(s.level == 1)
    for i in 0..<13 { s.play(Double(i)) }    // 13 x 8 = 104 xp
    #expect(s.level == 2)
    #expect(s.joy(at: 12) == 100)             // đúng lúc vừa chơi xong
    s.pat(14)
    #expect(s.xp == 109)
    #expect(s.levelProgress == 0.09)
}

@Test func spritesAreWellFormed() {
    for kind in PetKind.allCases {
        let art = kind.art
        for pose in [PetPose.idle, .blink, .sleep, .happy, .step(0), .step(1)] {
            for frame in 0..<2 {
                let grid = art.pixels(pose, frame: frame)
                #expect(grid.count == art.height, "\(kind) \(pose)")
                for row in grid {
                    #expect(row.count == PetArt.width, "\(kind) dòng sai độ rộng")
                    for ch in row where ch != "." {
                        #expect(art.palette[ch] != nil, "\(kind) thiếu màu cho '\(ch)'")
                    }
                }
            }
        }
        // Nhắm mắt thì không còn ô E.
        #expect(!art.pixels(.blink).joined().contains("E"))
        #expect(art.pixels(.idle).joined().contains("E"))
    }
}
