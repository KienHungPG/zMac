import Testing
@testable import zMac

// Lời bài hát: đọc LRC, tìm dòng đang hát, làm sạch tên video, chọn bản ghi lrclib hợp nhất.
// Không import Foundation (xem NowPlayingAdapterTests).

@Test func parsesLRC() {
    let text = """
    [ar:Ca sĩ]
    [ti:Bài A]
    [00:12.50]Dòng một
    [00:15.00][01:20.25]Điệp khúc
    [00:18:40] Dòng ba
    [00:20.00]
    không có mốc thì bỏ
    """
    let lines = LRC.parse(text)
    #expect(lines.map(\.time) == [12.5, 15, 18.4, 20, 80.25])
    #expect(lines.map(\.text) == ["Dòng một", "Điệp khúc", "Dòng ba", "", "Điệp khúc"])
}

@Test func lrcOffsetShiftsEarlier() {
    let lines = LRC.parse("[offset:+500]\n[00:10.00]A\n[00:00.20]B")
    #expect(lines.map(\.time) == [0, 9.5])
    #expect(lines.map(\.text) == ["B", "A"])
}

@Test func currentLineIndex() {
    let lines = [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b"), LyricLine(time: 30, text: "c")]
    #expect(LRC.index(lines, at: 5) == nil)
    #expect(LRC.index(lines, at: 9.9) == 0)   // hiện sớm 0,15 s
    #expect(LRC.index(lines, at: 25) == 1)
    #expect(LRC.index(lines, at: 300) == 2)
    #expect(LRC.index([], at: 3) == nil)
}

@Test func cleansVideoTitles() {
    #expect(LRC.cleanTitle("Nơi Này Có Anh (Official Music Video)") == "Nơi Này Có Anh")
    #expect(LRC.cleanTitle("1 2 3 4, ĐIỀU ANH BIẾT | TUYỂN TẬP NHỮNG BÀI HÁT") == "1 2 3 4, ĐIỀU ANH BIẾT")
    #expect(LRC.cleanTitle("Song [Lyrics] (feat. Someone)") == "Song")
    #expect(LRC.cleanTitle("Bài (Live) [MV]") == "Bài (Live)")
    #expect(LRC.cleanTitle("  Khoảng   trắng  ") == "Khoảng trắng")
    #expect(LRC.cleanTitle("Đen - Mười Năm ft. Ngọc Linh (M/V)") == "Đen - Mười Năm")
    #expect(LRC.cleanTitle("Lift Me Up") == "Lift Me Up")
}

@Test func cleansYouTubeArtistAndSplitsTitle() {
    #expect(LRC.cleanArtist("Đen Vâu Official") == "Đen Vâu")
    #expect(LRC.cleanArtist("Hoàng Dũng - Topic") == "Hoàng Dũng")
    #expect(LRC.cleanArtist("AdeleVEVO") == "Adele")
    #expect(LRC.cleanArtist("Official") == "Official")
    let split = LRC.splitTitle("Đen - Mười Năm")
    #expect(split?.artist == "Đen")
    #expect(split?.title == "Mười Năm")
    #expect(LRC.splitTitle("Không có gạch") == nil)
    #expect(LRC.splitTitle("- Thiếu ca sĩ") == nil)
}

@Test func picksBestRecord() {
    let plainNear = LrclibRecord(duration: 201, instrumental: false, plain: "lời", synced: nil)
    let syncedNear = LrclibRecord(duration: 199, instrumental: false, plain: "lời", synced: "[00:01.00]lời")
    let syncedFar = LrclibRecord(duration: 250, instrumental: false, plain: nil, synced: "[00:01.00]khác")
    let empty = LrclibRecord(duration: 200, instrumental: false, plain: nil, synced: nil)
    #expect(LrclibRecord.best([plainNear, syncedFar, syncedNear, empty], duration: 200) == syncedNear)
    #expect(LrclibRecord.best([syncedFar], duration: 200) == nil)
    #expect(LrclibRecord.best([plainNear, syncedFar], duration: nil) == syncedFar)
    #expect(LrclibRecord.best([empty], duration: nil) == nil)
}

@Test func recordToLyrics() {
    #expect(LrclibRecord(duration: nil, instrumental: true, plain: nil, synced: nil).lyrics == .instrumental)
    #expect(LrclibRecord(duration: nil, instrumental: false, plain: "x", synced: "không có mốc").lyrics == .plain("x"))
    #expect(LrclibRecord(duration: nil, instrumental: false, plain: "x", synced: "[00:02.00]y").lyrics
        == .synced([LyricLine(time: 2, text: "y")]))
}
