// Vẽ icon app (không cần ảnh nguồn): swift scripts/make-icon.swift Resources/AppIcon.icns
// Ô bo góc nền tối, lưới 2×2 ô màu: nhiều app gộp làm một.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                         CGFloat(hex & 0xff) / 255, a])!
}

func gradient(_ a: UInt32, _ b: UInt32) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.4))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x15172E))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient(0x2A2D5C, 0x0C0E1E), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let tile: CGFloat = 262, gap: CGFloat = 46
    let x0 = 512 - tile - gap / 2, y0 = 512 - tile - gap / 2
    let tiles: [(UInt32, UInt32)] = [(0xFF9F43, 0xFF5E62), (0x36D1DC, 0x5B86E5), (0x43E97B, 0x16A085), (0xC471F5, 0xFA71CD)]
    for (i, t) in tiles.enumerated() {
        let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)
        let r = CGRect(x: x0 + col * (tile + gap), y: y0 + row * (tile + gap), width: tile, height: tile)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 66, cornerHeight: 66, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient(t.0, t.1), start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zMac-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "→ \(out)" : "iconutil lỗi")
