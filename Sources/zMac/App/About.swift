import AppKit
import SwiftUI

// Trang Giới thiệu trong Cài đặt: phiên bản, tự cập nhật (Updater), đường dẫn, giấy phép.
// Chỉ sống khi cửa sổ Cài đặt mở; không tự kiểm tra gì khi vào trang.

struct AboutPane: View {
    var updater = Updater.shared

    static let site = "https://zmac.vercel.app"
    static let repo = "https://github.com/\(Updater.repo)"

    var body: some View {
        VStack(spacing: 0) {
            hero
            Form {
                updates
                resources
                licenses
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .zCompactForm()
        }
    }

    // MARK: Đầu trang

    private var hero: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: 16) {
            AppIconView(size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("zMac").font(.system(size: 22, weight: .bold))
                Text(L("Phiên bản ", "Version ") + Self.versionText)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(ZTheme.blue.light)
                Text(L("Nhiều tiện ích macOS gộp trong một app menu bar nhẹ.", "Many Mac utilities in one light menu bar app."))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 12)
            CircleIconButton(symbol: "power", help: L("Thoát zMac", "Quit zMac")) { NSApp.terminate(nil) }
        }
        .padding(18)
        .background {
            ZStack {
                shape.fill(.white.opacity(0.05))
                RadialGradient(colors: [ZTheme.blue.base.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 320)
                RadialGradient(colors: [ZTheme.purple.base.opacity(0.14), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 320)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 2)
    }

    /// "0.2.0 (3)"; bản chạy thử không có Info.plist thì "dev".
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "dev" }
        guard let b = info?["CFBundleVersion"] as? String, !b.isEmpty, b != v else { return v }
        return "\(v) (\(b))"
    }

    // MARK: Cập nhật

    private var noKey: Bool { Updater.publicKey == nil }

    private var updates: some View {
        Section {
            AboutRow(symbol: "arrow.triangle.2.circlepath", title: L("Tự kiểm tra bản mới", "Check for updates automatically"),
                     detail: L("Lúc mở app và khi máy thức dậy, mỗi ngày tối đa một lần.",
                               "When zMac opens and when the Mac wakes, at most once a day.")) {
                Toggle("", isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            .disabled(noKey)
            AboutRow(symbol: "arrow.down.circle", title: L("Kiểm tra ngay", "Check now"),
                     detail: status.text, detailColor: status.color) {
                if let r = updater.available {
                    PillButton(title: L("Cài \(r.version) và mở lại", "Install \(r.version) and relaunch"), prominent: true) {
                        Task { await updater.install() }
                    }
                } else {
                    PillButton(title: L("Kiểm tra", "Check")) { Task { await updater.check() } }
                        .disabled(updater.busy || noKey)
                }
            }
            if let r = updater.available, !r.notes.isEmpty {
                Text(r.notes).font(.caption).foregroundStyle(.secondary).lineLimit(6)
            }
        } header: {
            Text(L("Cập nhật", "Updates"))
        } footer: {
            Text(L("zMac tìm bản mới qua GitHub Releases (api.github.com). Mỗi bản được ký bằng khoá riêng của zMac; chữ ký không khớp thì zMac không cài. Cài bằng Homebrew thì cập nhật bằng brew upgrade --cask zmac.",
                   "zMac looks for new versions on GitHub Releases (api.github.com). Every release is signed with zMac's own key; if the signature doesn't match, zMac won't install it. Installed with Homebrew? Use brew upgrade --cask zmac."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var status: (text: String, color: Color) {
        if noKey {
            return (L("Bản build này chưa có khoá cập nhật nên không tự cập nhật được.",
                      "This build has no update key, so it can't update itself."), .secondary)
        }
        switch updater.state {
        case .idle:
            guard let t = updater.lastCheck else { return (L("Chưa kiểm tra lần nào.", "Not checked yet."), .secondary) }
            return (L("Lần kiểm tra gần nhất: \(Self.ago(t)).", "Last checked \(Self.ago(t))."), .secondary)
        case .checking: return (L("Đang kiểm tra…", "Checking…"), .secondary)
        case .upToDate: return (L("Đang dùng bản mới nhất.", "You're up to date."), ZTheme.green.light)
        case .available(let r): return (L("Có bản \(r.version).", "Version \(r.version) is out."), ZTheme.orange.light)
        case .downloading: return (L("Đang tải và kiểm chữ ký…", "Downloading and verifying…"), .secondary)
        case .installing: return (L("Đang cài…", "Installing…"), .secondary)
        case .failed(let m): return (m, Color(hex: 0xFF8A80))
        }
    }

    /// "24 phút trước" / "24 minutes ago", theo ngôn ngữ của zMac.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: L("vi", "en"))
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f.localizedString(for: min(date, now), relativeTo: now)
    }

    // MARK: Tài nguyên

    private var resources: some View {
        Section(L("Tài nguyên", "Resources")) {
            AboutRow(symbol: "sparkles", title: L("Có gì mới", "What's new"),
                     detail: L("Ghi chú của từng phiên bản.", "Notes for every version.")) {
                PillLink(title: L("Xem", "View"), url: Self.site + "/#changelog")
            }
            AboutRow(symbol: "checklist", title: L("Hướng dẫn cài đặt", "Setup guide"),
                     detail: L("Cài, cấp quyền và bật từng tính năng.", "Install, grant permissions and turn features on.")) {
                PillLink(title: L("Mở", "Open"), url: Self.site + "/#install")
            }
            AboutRow(symbol: "chevron.left.forwardslash.chevron.right", title: L("Mã nguồn", "Source code")) {
                PillLink(title: "GitHub", url: Self.repo)
            }
            AboutRow(symbol: "ladybug", title: L("Báo lỗi, góp ý", "Report a bug or suggest an idea"),
                     detail: L("Dán kèm kết quả zMac --diagnose khi báo lỗi.", "Include the output of zMac --diagnose with bug reports.")) {
                PillLink(title: L("Mở", "Open"), url: Self.repo + "/issues")
            }
        }
    }

    // MARK: Giấy phép

    private var licenses: some View {
        Section {
            AboutRow(symbol: "doc.text", title: "zMac", detail: "© KienHungPG") {
                PillLink(title: "MIT", url: Self.repo + "/blob/main/LICENSE")
            }
            AboutRow(symbol: "doc.text", title: "mediaremote-adapter",
                     detail: L("Giúp notch đọc bài đang phát · ungive", "Lets the notch read what's playing · ungive")) {
                if let url = Bundle.main.url(forResource: "MediaRemoteAdapter-LICENSE", withExtension: "txt") {
                    PillButton(title: "BSD 3-Clause") { NSWorkspace.shared.open(url) }
                } else {
                    Text("BSD 3-Clause").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("Giấy phép", "Licenses"))
        } footer: {
            Text(L("Miễn phí và mã nguồn mở: ai cũng được dùng, sửa và phân phối lại, chỉ cần giữ dòng bản quyền.",
                   "Free and open source: anyone may use, change and redistribute it, as long as the copyright notice stays."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Icon thật của app; bản chạy thử (không phải .app) thì vẽ bốn ô màu trên nền xanh than.
private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        if Bundle.main.bundleURL.pathExtension == "app", let icon = NSApp.applicationIconImage {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            ZBrandMark(size: size * 0.56)
                .frame(width: size * 0.82, height: size * 0.82)
                .background(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .fill(LinearGradient(colors: [ZTheme.navyTop, ZTheme.navyBottom], startPoint: .top, endPoint: .bottom)))
                .frame(width: size, height: size)
        }
    }
}

/// Một dòng: biểu tượng, tên, dòng phụ, điều khiển bên phải.
private struct AboutRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    var detailColor: Color = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
    }
}

/// Nút viên thuốc màu nhấn.
private struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : ZTheme.blue.light)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(prominent ? AnyShapeStyle(ZTheme.blue.gradient)
                                                     : AnyShapeStyle(ZTheme.blue.base.opacity(0.16))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
    }
}

private struct PillLink: View {
    let title: String
    let url: String

    var body: some View {
        PillButton(title: title) {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
        .help(url)
    }
}
