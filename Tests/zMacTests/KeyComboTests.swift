import Testing
@testable import zMac

// Tên phím hiển thị trong ô phím tắt. Mã phím ghi dạng số để không phải import Carbon.
// Lỗi cũ: `kVK_F1...kVK_F20` là khoảng ngược (0x7A > 0x5A), phím chữ đi qua case đó là app dừng.

@Test func functionKeysAreNamedInOrder() {
    #expect(KeyCombo.keyName(0x7A) == "F1")
    #expect(KeyCombo.keyName(0x60) == "F5")
    #expect(KeyCombo.keyName(0x5A) == "F20")
    #expect(KeyCombo.functionKeys.count == 20)
    #expect(Set(KeyCombo.functionKeys).count == 20)
}

// Phím chữ đi qua bố cục bàn phím (TIS), API này chỉ gọi được trên main thread, giống trong app.
@MainActor @Test func letterKeysDoNotCrash() {
    // C (⌘⇧C của Clipboard), U (chia cửa sổ), ` (⌥` của chuyển cửa sổ)
    for code: UInt32 in [0x08, 0x20, 0x32] {
        #expect(!KeyCombo.keyName(code).isEmpty)
    }
}

@MainActor @Test func displayPutsModifiersFirst() {
    let combo = KeyCombo(0x08, KeyCombo.cmd | KeyCombo.shift)
    #expect(combo.display.hasPrefix("⇧⌘"))
    #expect(KeyCombo(0x7B, KeyCombo.ctrl | KeyCombo.opt).display == "⌃⌥←")
}
