import AppKit
import SwiftUI

// Nhận diện zMac: xanh than của icon và bốn màu ô (cam, xanh, lục, tím), cùng bộ với trang web.
// Mỗi module một màu, giống trang web: chuyển cửa sổ, âm thanh xanh; chia cửa sổ, màn hình cam;
// clipboard, giữ máy thức tím; notch, pin lục.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

enum ZTheme {
    struct Hue {
        let light: Color
        let base: Color
        let dark: Color
        var gradient: LinearGradient {
            LinearGradient(colors: [light, dark], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    static let orange = Hue(light: Color(hex: 0xFF9747), base: Color(hex: 0xFF8052), dark: Color(hex: 0xFF695D))
    static let blue = Hue(light: Color(hex: 0x3CC6DD), base: Color(hex: 0x49ABE1), dark: Color(hex: 0x5691E4))
    static let green = Hue(light: Color(hex: 0x3CDE7C), base: Color(hex: 0x2DC480), dark: Color(hex: 0x1DAB84))
    static let purple = Hue(light: Color(hex: 0xCD71EE), base: Color(hex: 0xE171E0), dark: Color(hex: 0xF471D2))
    /// Mục chung (Chung, Hiệu năng): xanh than sáng, không lẫn với màu module.
    static let slate = Hue(light: Color(hex: 0x5A5F99), base: Color(hex: 0x40447A), dark: Color(hex: 0x2A2D5C))

    static let navyTop = Color(hex: 0x282B59)
    static let navy = Color(hex: 0x1B1D3D)
    static let navyBottom = Color(hex: 0x0D0F20)
    static let accent = blue.base

    static func hue(_ moduleID: String) -> Hue {
        switch moduleID {
        case "switcher", "audio": blue
        case "snap", "display", "claude": orange
        case "clipboard", "keepawake", "pet": purple
        case "notch", "battery": green
        default: slate
        }
    }
}

/// Ô icon gradient, giống bốn ô của icon app.
struct ZTile: View {
    let symbol: String
    let hue: ZTheme.Hue
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(shape.fill(hue.gradient))
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: hue.dark.opacity(0.35), radius: size * 0.14, y: size * 0.05)
    }
}

/// Bốn ô màu của icon zMac.
struct ZBrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        let gap = size * 0.1
        let cell = (size - gap) / 2
        VStack(spacing: gap) {
            HStack(spacing: gap) { square(ZTheme.orange, cell); square(ZTheme.blue, cell) }
            HStack(spacing: gap) { square(ZTheme.green, cell); square(ZTheme.purple, cell) }
        }
        .frame(width: size, height: size)
    }

    private func square(_ hue: ZTheme.Hue, _ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: s * 0.3, style: .continuous).fill(hue.gradient).frame(width: s, height: s)
    }
}

/// Nền xanh than có quầng màu, như phần đầu trang web.
struct ZBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [ZTheme.navyTop, ZTheme.navy, ZTheme.navyBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [ZTheme.orange.base.opacity(0.16), .clear], center: UnitPoint(x: 0.05, y: 0.0),
                           startRadius: 0, endRadius: 420)
            RadialGradient(colors: [ZTheme.blue.base.opacity(0.16), .clear], center: UnitPoint(x: 1.0, y: 0.1),
                           startRadius: 0, endRadius: 440)
            RadialGradient(colors: [ZTheme.purple.base.opacity(0.11), .clear], center: UnitPoint(x: 0.8, y: 1.0),
                           startRadius: 0, endRadius: 480)
            RadialGradient(colors: [ZTheme.green.base.opacity(0.08), .clear], center: UnitPoint(x: 0.0, y: 1.0),
                           startRadius: 0, endRadius: 420)
        }
    }
}

extension View {
    /// Thẻ kính trên nền xanh than: nền trắng mờ, viền mảnh, bo lớn.
    func zCard(radius: CGFloat = 14, fill: Double = 0.06) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(.white.opacity(fill)))
            .overlay(shape.strokeBorder(.white.opacity(0.09), lineWidth: 1))
    }

    /// Bảng nổi trên màn hình (HUD ⌥⇥, clipboard): kính mờ thật của macOS, phủ xanh than, viền sáng.
    func zFloatingPanel(radius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            ZStack {
                VisualEffectBlur(material: .hudWindow)
                LinearGradient(colors: [ZTheme.navyTop.opacity(0.62), ZTheme.navyBottom.opacity(0.78)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}
