import SwiftUI

// Thú cưng pixel do zMac tự vẽ (không dùng nhân vật của ai). Mỗi loài là một lưới ký tự rộng 14 cột:
// viết tay nửa trái rồi lật gương, nên luôn cân đối. Vẽ bằng Canvas, mỗi ký tự là một ô vuông.
//
// Ký tự: "." trong suốt, d viền, b thân, l sáng (bụng, tai trong), E mắt trên (nhắm thì mất), e mắt dưới,
// n mũi / miệng, p hồng (má, lưỡi), s điểm nhấn (tai cún, mỏ và chân gà), w ánh sáng.

enum PetKind: String, CaseIterable, Identifiable, Codable {
    case cat, dog, slime, chick

    var id: String { rawValue }

    var name: String {
        switch self {
        case .cat: L("Mèo", "Cat")
        case .dog: L("Cún", "Pup")
        case .slime: "Slime"
        case .chick: L("Gà con", "Chick")
        }
    }

    var art: PetArt {
        switch self {
        case .cat: .cat
        case .dog: .dog
        case .slime: .slime
        case .chick: .chick
        }
    }
}

enum PetPose: Equatable {
    case idle, blink, sleep, happy
    case step(Int)
}

struct PetArt {
    static let width = 14

    let body: [String]
    /// [đứng, bước 1, bước 2]. Rỗng = không có chân (slime nhún cả người).
    let feet: [String]
    /// Ô vẽ đè theo khung (đuôi vẫy, ánh sáng): [khung 0, khung 1].
    let overlay: [[(row: Int, col: Int, ch: Character)]]
    let palette: [Character: Color]

    var height: Int { body.count + (feet.isEmpty ? 0 : 1) }

    static func mirror(_ half: String) -> String { half + String(half.reversed()) }

    /// Lưới ký tự của một khung hình.
    func pixels(_ pose: PetPose, frame: Int = 0) -> [[Character]] {
        let closed = pose == .blink || pose == .sleep || pose == .happy
        var rows = body.map { row in Array(row).map { ch -> Character in closed && ch == "E" ? "b" : ch } }
        if !feet.isEmpty {
            switch pose {
            case .step(let n): rows.append(Array(feet[1 + abs(n) % 2]))
            default: rows.append(Array(feet[0]))
            }
        }
        if !overlay.isEmpty {
            for o in overlay[abs(frame) % overlay.count] where o.row < rows.count && o.col < Self.width {
                rows[o.row][o.col] = o.ch
            }
        }
        return rows
    }
}

extension PetArt {
    private static func rows(_ halves: [String]) -> [String] { halves.map(mirror) }

    static let cat = PetArt(
        body: rows([
            "..d....",
            ".dbd...",
            ".dlbd..",
            ".dbbbdd",
            "dbbbbbb",
            "dbbEbbb",
            "dbbebbn",
            "dbpbbbb",
            ".dbbbbb",
            "..ddbbb",
            "..dbbll",
            "..dbbll",
            "..dbbbb",
        ]),
        feet: ["...dd....dd...", "..dd.....dd...", "...dd.....dd.."],
        overlay: [
            [(12, 12, "b"), (11, 12, "b"), (10, 13, "b"), (9, 13, "b"), (8, 13, "d")],
            [(12, 12, "b"), (11, 13, "b"), (10, 13, "b"), (9, 12, "b"), (8, 12, "d")],
        ],
        palette: ["d": Color(hex: 0xB5652B), "b": Color(hex: 0xF2A65A), "l": Color(hex: 0xFCE3C6),
                  "E": Color(hex: 0x2B1B12), "e": Color(hex: 0x2B1B12), "n": Color(hex: 0xFF8FA3),
                  "p": Color(hex: 0xFF8FA3)]
    )

    static let dog = PetArt(
        body: rows([
            "..ddddd",
            ".dbbbbb",
            "ddbbbbb",
            "dsdbbbb",
            "dsdbEbb",
            "dsdbebb",
            ".sdbbll",
            "..dbbln",
            "...dblp",
            "..ddbbb",
            "..dbbll",
            "..dbbll",
            "..dbbbb",
        ]),
        feet: ["...dd....dd...", "..dd.....dd...", "...dd.....dd.."],
        overlay: [
            [(11, 12, "b"), (10, 12, "b"), (9, 13, "d")],
            [(11, 12, "b"), (10, 13, "b"), (9, 13, "d")],
        ],
        palette: ["d": Color(hex: 0x7A4E26), "b": Color(hex: 0xD9A066), "l": Color(hex: 0xF6E3CB),
                  "s": Color(hex: 0x5E3B1E), "E": Color(hex: 0x2A1F1A), "e": Color(hex: 0x2A1F1A),
                  "n": Color(hex: 0x2A1F1A), "p": Color(hex: 0xFF7A8A)]
    )

    static let slime = PetArt(
        body: rows([
            "....ddd",
            "...dbbb",
            "..dbbbb",
            ".dbbbbb",
            ".dbbEbb",
            "dbbbebb",
            "dbbpbbn",
            "dbbbbbb",
            ".dbbbbb",
            "..ddddd",
        ]),
        feet: [],
        overlay: [[(1, 4, "w"), (2, 3, "w"), (2, 4, "l")]],
        palette: ["d": Color(hex: 0x2C8C6A), "b": Color(hex: 0x5FD3A6), "l": Color(hex: 0xA8EFD3),
                  "w": Color(hex: 0xE8FFF6), "E": Color(hex: 0x12372B), "e": Color(hex: 0x12372B),
                  "n": Color(hex: 0x12372B), "p": Color(hex: 0xFF9FB0)]
    )

    static let chick = PetArt(
        body: rows([
            "......d",
            ".....db",
            "...ddbb",
            "..dbbbb",
            ".dbbbbb",
            ".dbbEbb",
            ".dbbebs",
            "dbpbbbs",
            "dlbbbbb",
            "dlbbbbb",
            ".dbbbbb",
            "..ddddd",
        ]),
        feet: ["....s....s....", "...s.....s....", "....s.....s..."],
        overlay: [],
        palette: ["d": Color(hex: 0xC9971A), "b": Color(hex: 0xFFD84D), "l": Color(hex: 0xFFF0A6),
                  "s": Color(hex: 0xFF9747), "E": Color(hex: 0x3A2A10), "e": Color(hex: 0x3A2A10),
                  "p": Color(hex: 0xFFA3A3)]
    )
}

/// Vẽ một khung hình, mỗi ô `pixel` điểm.
struct PixelPet: View {
    let kind: PetKind
    var pose: PetPose = .idle
    var frame = 0
    var pixel: CGFloat = 2

    var body: some View {
        let art = kind.art
        let grid = art.pixels(pose, frame: frame)
        Canvas { ctx, _ in
            for (y, row) in grid.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    guard let color = art.palette[ch] else { continue }
                    let r = CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)
                    ctx.fill(Path(r), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(PetArt.width) * pixel, height: CGFloat(art.height) * pixel)
    }
}

// MARK: - Hoạt hình bằng Core Animation (notch thu gọn)

/// Các vòng lặp hoạt hình. Mỗi bước: tư thế, khung đuôi, nhấc lên 1 ô hay không.
enum PetLoop: Equatable {
    case idle, dance, happy, sleep

    var steps: [(pose: PetPose, frame: Int, lift: Int)] {
        switch self {
        case .idle:
            return [(.idle, 0, 0), (.idle, 1, 0), (.idle, 0, 0), (.blink, 1, 0), (.idle, 0, 0), (.idle, 1, 0),
                    (.step(0), 0, 1), (.step(1), 1, 0), (.step(0), 0, 1), (.step(1), 1, 0), (.idle, 0, 0), (.idle, 1, 0)]
        case .dance:
            return [(.step(0), 0, 1), (.step(1), 1, 0), (.step(0), 0, 1), (.step(1), 1, 0), (.happy, 0, 1), (.happy, 1, 0)]
        case .happy:
            return [(.happy, 0, 1), (.happy, 1, 0)]
        case .sleep:
            return [(.sleep, 0, 0)]
        }
    }

    var stepDuration: Double {
        switch self {
        case .idle: 0.32
        case .dance: 0.22
        case .happy: 0.14
        case .sleep: 1
        }
    }
}

extension PetArt {
    /// Một khung hình thành CGImage, cao thêm một ô phía trên để nhấc lên. `cell` là số điểm ảnh thật mỗi ô.
    func image(_ pose: PetPose, frame: Int, lift: Int, cell: Int) -> CGImage? {
        let grid = pixels(pose, frame: frame)
        let w = Self.width * cell, h = (height + 1) * cell
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var colors: [Character: CGColor] = [:]
        for (ch, c) in palette { colors[ch] = NSColor(c).usingColorSpace(.sRGB)?.cgColor }
        for (y, row) in grid.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                guard let color = colors[ch] else { continue }
                ctx.setFillColor(color)
                // Gốc CG ở dưới; hàng y nằm ở ô (y + 1 - lift) tính từ trên.
                let top = y + 1 - lift
                ctx.fill(CGRect(x: x * cell, y: h - (top + 1) * cell, width: cell, height: cell))
            }
        }
        return ctx.makeImage()
    }
}

/// Lật khung bằng CAKeyframeAnimation trên `contents`: WindowServer tự chạy, zMac không làm gì mỗi khung hình.
struct PetLoopView: NSViewRepresentable {
    let kind: PetKind
    let loop: PetLoop
    let pixel: CGFloat

    func makeNSView(context: Context) -> PetLoopNSView { PetLoopNSView() }

    func updateNSView(_ view: PetLoopNSView, context: Context) {
        view.configure(kind: kind, loop: loop, pixel: pixel)
    }
}

final class PetLoopNSView: NSView {
    private let sprite = CALayer()
    private var params: (kind: PetKind, loop: PetLoop, pixel: CGFloat)?
    private var applied = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sprite.magnificationFilter = .nearest
        sprite.contentsGravity = .resize
        sprite.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(sprite)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        sprite.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applied = ""   // độ phân giải màn hình có thể khác
        apply()
    }

    func configure(kind: PetKind, loop: PetLoop, pixel: CGFloat) {
        params = (kind, loop, pixel)
        apply()
    }

    private func apply() {
        guard let p = params, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(p.kind.rawValue)-\(p.loop)-\(p.pixel)-\(scale)"
        guard key != applied else { return }
        applied = key
        let art = p.kind.art
        let cell = max(1, Int((p.pixel * scale).rounded()))
        let frames = p.loop.steps.compactMap { art.image($0.pose, frame: $0.frame, lift: $0.lift, cell: cell) }
        sprite.removeAllAnimations()
        sprite.contents = frames.first
        guard frames.count > 1 else { return }
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = frames
        a.calculationMode = .discrete
        a.duration = Double(frames.count) * p.loop.stepDuration
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        sprite.add(a, forKey: "loop")
    }
}
