import CoreGraphics
import Testing
@testable import zMac

// ⌥⇥ ở mọi Space: chọn Space đang không hiện và lọc cửa sổ thật theo tag của WindowServer.
// Giá trị tag lấy từ máy thật (macOS 26.5): Brave, Code, Terminal, Zalo.

@Test func hiddenSpacesSkipTheCurrentSpaceOfEachDisplay() {
    let displays: [[String: Any]] = [
        ["Current Space": ["ManagedSpaceID": 1], "Spaces": [["ManagedSpaceID": 1, "type": 0], ["ManagedSpaceID": 5, "type": 0]]],
        // Màn ngoài đang ở một app toàn màn hình (type 4): Space thường của nó thành Space ẩn.
        ["Current Space": ["ManagedSpaceID": 992], "Spaces": [["ManagedSpaceID": 997, "type": 0], ["ManagedSpaceID": 992, "type": 4]]],
    ]
    #expect(PrivateAPI.hiddenSpaceIDs(displays) == [5, 997])
}

@Test func hiddenSpacesEmptyWithOneSpace() {
    let displays: [[String: Any]] = [["Current Space": ["ManagedSpaceID": 1], "Spaces": [["ManagedSpaceID": 1]]]]
    #expect(PrivateAPI.hiddenSpaceIDs(displays).isEmpty)
    #expect(PrivateAPI.hiddenSpaceIDs([]).isEmpty)
}

@Test func userWindowsPassTheTagFilter() {
    // Cửa sổ chuẩn (Brave, Code), Zalo, Terminal, Brave toàn màn hình.
    for tags: UInt64 in [0x300000100082401, 0x300000100482401, 0x300000100482001, 0x300040100082401] {
        #expect(PrivateAPI.isUserWindow(parent: 0, attributes: 0x2, tags: tags))
    }
}

@Test func helperWindowsAreFilteredOut() {
    // Thanh công cụ con của Brave (có cửa sổ cha).
    #expect(!PrivateAPI.isUserWindow(parent: 252, attributes: 0x2, tags: 0x1400c2282))
    // Cửa sổ phụ đã ẩn nhưng vẫn thuộc Space (Brave 1710x40, cửa sổ tầng 103).
    #expect(!PrivateAPI.isUserWindow(parent: 0, attributes: 0x0, tags: 0x1400c0202))
    // Cửa sổ gốc không có cờ 0x1 (khung toàn màn hình của Brave).
    #expect(!PrivateAPI.isUserWindow(parent: 0, attributes: 0x2, tags: 0x8040401400c2080))
}

// Kiểu HUD ⌥⇥.

@Test func styleFollowsTheOldPreviewToggleUntilChosen() {
    #expect(SwitcherStyle.initial(stored: nil, legacyThumbnails: true) == .thumbnails)
    #expect(SwitcherStyle.initial(stored: nil, legacyThumbnails: false) == .icons)
    // Đã chọn kiểu thì công tắc cũ không còn tác dụng; giá trị lạ thì quay về như chưa chọn.
    #expect(SwitcherStyle.initial(stored: "titles", legacyThumbnails: true) == .titles)
    #expect(SwitcherStyle.initial(stored: "grid", legacyThumbnails: false) == .icons)
}

@Test func gridStylesFillTheWidth() {
    let area = CGSize(width: 1300, height: 760)
    #expect(SwitcherStyle.icons.columns(count: 5, area: area) == 5)
    #expect(SwitcherStyle.icons.columns(count: 40, area: area) == 13)
    #expect(SwitcherStyle.thumbnails.columns(count: 12, area: area) == 5)
    #expect(SwitcherStyle.icons.columns(count: 0, area: area) == 1)
    // Màn hình hẹp hơn một ô: vẫn một cột.
    #expect(SwitcherStyle.thumbnails.columns(count: 3, area: CGSize(width: 100, height: 400)) == 1)
}

@Test func titlesStayOneColumnUntilTheyOverflowTheHeight() {
    let area = CGSize(width: 1300, height: 760)   // vừa 21 dòng, 3 cột
    #expect(SwitcherStyle.titles.columns(count: 5, area: area) == 1)
    #expect(SwitcherStyle.titles.columns(count: 21, area: area) == 1)
    #expect(SwitcherStyle.titles.columns(count: 22, area: area) == 2)
    #expect(SwitcherStyle.titles.columns(count: 100, area: area) == 3)
}
