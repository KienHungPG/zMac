import AppKit
import Observation
import SwiftUI

// Thú cưng ở notch. Chỉ số No / Vui giảm theo giờ thật nhưng tính từ mốc thời gian lúc cần, không timer.
// Chuyển động chỉ khi đang nhìn: tab Thú cưng mở (TimelineView sống cùng view) hoặc vài giây sau một sự kiện
// (đổi bài, cắm sạc, Claude xin quyền). Còn lại là một khung hình đứng yên.

/// Chỉ số (hàm thuần, có test). Thời gian là giây kể từ 1970.
struct PetStats: Codable, Equatable {
    var food: Double
    var foodAt: Double
    var joy: Double
    var joyAt: Double
    var xp: Int
    var born: Double

    static let foodPerHour = 4.0
    static let joyPerHour = 3.0

    static func newborn(_ now: Double) -> PetStats {
        PetStats(food: 80, foodAt: now, joy: 80, joyAt: now, xp: 0, born: now)
    }

    func food(at now: Double) -> Double { max(0, food - max(now - foodAt, 0) / 3600 * Self.foodPerHour) }
    func joy(at now: Double) -> Double { max(0, joy - max(now - joyAt, 0) / 3600 * Self.joyPerHour) }

    var level: Int { 1 + xp / 100 }
    /// Phần trăm tới cấp sau.
    var levelProgress: Double { Double(xp % 100) / 100 }
    func days(at now: Double) -> Int { max(0, Int((now - born) / 86_400)) }

    /// No quá thì không ăn (trả false).
    mutating func feed(_ now: Double) -> Bool {
        let f = food(at: now)
        guard f < 90 else { return false }
        food = min(100, f + 40)
        foodAt = now
        xp += 10
        return true
    }

    mutating func pat(_ now: Double) { cheer(now, by: 15, xp: 5) }
    mutating func play(_ now: Double) { cheer(now, by: 30, xp: 8) }

    private mutating func cheer(_ now: Double, by amount: Double, xp gain: Int) {
        joy = min(100, joy(at: now) + amount)
        joyAt = now
        xp += gain
    }
}

@MainActor @Observable
final class PetModule: ZModule {
    static let id = "pet"
    static var name: String { L("Thú cưng", "Pet") }
    static let replaces = "Roost"
    static let symbol = "pawprint.fill"
    static var summary: String {
        L("Một thú cưng pixel sống ở notch: cho ăn, vuốt ve, chơi cùng để lên cấp. zMac tự vẽ, chỉ chuyển động khi bạn đang nhìn.",
          "A pixel pet that lives in the notch: feed it, pat it and play with it to level up. Drawn by zMac, and it only moves while you're looking.")
    }
    static var defaultEnabled: Bool { false }

    enum Reaction: Equatable { case happy, eat, refuse }

    var kind = PetKind(rawValue: Pref.string("pet.kind", PetKind.cat.rawValue)) ?? .cat {
        didSet { Pref.set("pet.kind", kind.rawValue) }
    }
    var petName = Pref.string("pet.name", "") {
        didSet { Pref.set("pet.name", petName) }
    }
    var showInNotch = Pref.bool("pet.showInNotch", true) {
        didSet { Pref.set("pet.showInNotch", showInNotch); refreshNotch() }
    }

    private(set) var stats = Pref.codable("pet.stats", PetStats?.none) ?? .newborn(Date().timeIntervalSince1970)
    private(set) var reaction: Reaction?
    private(set) var reactionAt = Date.distantPast
    /// Notch thu gọn: cử động tới lúc này rồi đứng yên.
    private(set) var activeUntil: Date?

    @ObservationIgnored private var calmWork: DispatchWorkItem?

    var displayName: String { petName.trimmingCharacters(in: .whitespaces).isEmpty ? kind.name : petName }

    init() {}

    func start() {
        save()
        refreshNotch()
    }

    func stop() {
        calmWork?.cancel()
        calmWork = nil
        refreshNotch()   // module đã rời ModuleManager: cánh thú cưng biến mất
    }

    private func refreshNotch() {
        ModuleManager.shared.module(NotchModule.self)?.refreshCollapsed()
    }

    private func save() { Pref.setCodable("pet.stats", stats) }

    /// Ngủ đêm (23 h - 6 h) nếu 10 phút gần đây không ai chơi.
    func isSleeping(at date: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: date)
        return (h >= 23 || h < 6) && date.timeIntervalSince(reactionAt) > 600
    }

    // MARK: Hành động

    func feed() {
        let now = Date().timeIntervalSince1970
        react(stats.feed(now) ? .eat : .refuse)
        save()
    }

    func pat() {
        stats.pat(Date().timeIntervalSince1970)
        react(.happy)
        save()
    }

    func play() {
        stats.play(Date().timeIntervalSince1970)
        react(.happy)
        save()
    }

    func reset() {
        stats = .newborn(Date().timeIntervalSince1970)
        save()
    }

    /// Có chuyện ở notch (đổi bài, cắm sạc, Claude xin quyền): cử động vài giây.
    func poke() {
        guard reaction == nil else { return }
        wake(for: 3.5)
    }

    private func react(_ r: Reaction) {
        reaction = r
        reactionAt = Date()
        wake(for: r == .refuse ? 1.6 : 2.4)
    }

    /// Hẹn đúng một lần để thôi cử động (không lặp).
    private func wake(for seconds: Double) {
        activeUntil = Date().addingTimeInterval(seconds)
        calmWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reaction = nil
                self?.activeUntil = nil
            }
        }
        calmWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    // MARK: Cài đặt

    func settingsView() -> AnyView {
        let now = Date().timeIntervalSince1970
        return moduleForm {
            Section {
                HStack(spacing: 14) {
                    ForEach(PetKind.allCases) { k in
                        Button { self.kind = k } label: {
                            VStack(spacing: 6) {
                                PixelPet(kind: k, pixel: 3)
                                    .frame(width: 48, height: 44)
                                Text(k.name).font(.system(size: 11, weight: .medium))
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(k == self.kind ? 0.14 : 0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(k == self.kind ? ZTheme.purple.light : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                TextField(L("Tên", "Name"), text: Binding(get: { self.petName }, set: { self.petName = $0 }),
                          prompt: Text(kind.name))
                Toggle(L("Ngồi cạnh notch lúc thu gọn (khi không phát nhạc)", "Sit beside the notch when it's closed (when no music is playing)"),
                       isOn: Binding(get: { self.showInNotch }, set: { self.showInNotch = $0 }))
            }
            if ModuleManager.shared.module(NotchModule.self) == nil {
                Section {
                    Label(L("Cần bật Notch để thấy thú cưng.", "Turn on Notch to see your pet."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ZTheme.orange.light)
                }
            }
            Section(L("Tình trạng", "Status")) {
                LabeledContent(L("Cấp", "Level"), value: "\(stats.level) (\(Int(stats.levelProgress * 100))%)")
                LabeledContent(L("No", "Full"), value: "\(Int(stats.food(at: now)))%")
                LabeledContent(L("Vui", "Happy"), value: "\(Int(stats.joy(at: now)))%")
                LabeledContent(L("Ở với bạn", "Together for"), value: L("\(stats.days(at: now)) ngày", "\(stats.days(at: now)) days"))
                Button(L("Nuôi lại từ đầu", "Start over")) { self.reset() }
                Text(L("Mở notch, chọn tab Thú cưng để cho ăn, vuốt ve, chơi. Bỏ đói lâu thì No và Vui giảm dần, không có gì mất đi. Thú cưng chỉ chuyển động khi tab đang mở hoặc vài giây sau khi có chuyện ở notch, nên gần như không tốn pin.",
                       "Open the notch and pick the Pet tab to feed, pat and play. Leave it alone and Full and Happy slowly drop; nothing is ever lost. It only moves while the tab is open or for a few seconds after something happens at the notch, so it costs almost no battery."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Notch thu gọn: ngồi ở cánh trái

struct PetWingView: View {
    let pet: PetModule
    let height: CGFloat
    var musicPlaying = false

    var body: some View {
        let art = pet.kind.art
        // Cao thêm một ô để nhấc lên khi bước.
        let pixel = max(1, ((height - 2) / CGFloat(art.height + 1)).rounded(.down))
        let sleeping = pet.isSleeping(at: Date())
        let loop: PetLoop = pet.reaction != nil || pet.activeUntil != nil ? .happy
            : sleeping ? .sleep : musicPlaying ? .dance : .idle
        PetLoopView(kind: pet.kind, loop: loop, pixel: pixel)
            .frame(width: CGFloat(PetArt.width) * pixel, height: CGFloat(art.height + 1) * pixel)
            .overlay(alignment: .topTrailing) {
                if sleeping {
                    Text("z").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white.opacity(0.6)).offset(x: 6, y: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height - 1, alignment: .bottom)
            .frame(height: height, alignment: .top)
    }
}

// MARK: - Tab Thú cưng

struct PetTabView: View {
    let pet: PetModule
    let musicPlaying: Bool
    /// Notch có cột lịch: sân chơi hẹp lại, nút chỉ còn icon.
    var compact = false

    var body: some View {
        let now = Date().timeIntervalSince1970
        let food = pet.stats.food(at: now)
        let joy = pet.stats.joy(at: now)
        HStack(spacing: compact ? 16 : 22) {
            PetStage(pet: pet, musicPlaying: musicPlaying)
                .frame(width: compact ? 150 : 210, height: 100)
                .contentShape(Rectangle())
                .onTapGesture { pet.pat() }
                .help(L("Bấm để vuốt ve", "Click to pat"))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(pet.displayName).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(L("Cấp \(pet.stats.level)", "Lv \(pet.stats.level)"))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(ZTheme.purple.base.opacity(0.55)))
                    Spacer(minLength: 0)
                }
                .help(L("Ở với bạn \(pet.stats.days(at: now)) ngày", "Together for \(pet.stats.days(at: now)) days"))
                PetMeter(symbol: "fork.knife", value: food, color: ZTheme.orange.light)
                PetMeter(symbol: "heart.fill", value: joy, color: Color(hex: 0xFF8FB0))
                HStack(spacing: 6) {
                    action(L("Cho ăn", "Feed"), "fork.knife") { pet.feed() }
                    action(L("Vuốt ve", "Pat"), "hand.raised.fill") { pet.pat() }
                    action(L("Chơi", "Play"), "soccerball") { pet.play() }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .labelStyle(TabLabelStyle(iconOnly: compact))
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 11 : 9).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct PetMeter: View {
    let symbol: String
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color).frame(width: 12)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(color).frame(width: g.size.width * min(max(value / 100, 0), 1))
                }
            }
            .frame(height: 5)
            Text("\(Int(value))%").font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6)).frame(width: 30, alignment: .trailing)
        }
    }
}

/// Sân chơi: đi qua lại, nhún theo nhạc, ngủ đêm, nhảy khi được chơi. Chỉ sống khi tab đang mở.
struct PetStage: View {
    let pet: PetModule
    let musicPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
            GeometryReader { g in
                scene(ctx.date, size: g.size)
            }
        }
    }

    private func scene(_ date: Date, size: CGSize) -> some View {
        let pixel: CGFloat = 5
        let art = pet.kind.art
        let w = CGFloat(PetArt.width) * pixel
        let h = CGFloat(art.height) * pixel
        let t = date.timeIntervalSinceReferenceDate
        let since = date.timeIntervalSince(pet.reactionAt)
        let span = max(size.width - w, 0)

        var pose = PetPose.idle
        var x = span / 2
        var lift: CGFloat = 0
        if pet.reaction != nil && since < 2.4 {
            pose = .happy
            lift = CGFloat(abs(sin(since * 9))) * 10
        } else if pet.isSleeping(at: date) {
            pose = .sleep
        } else if musicPlaying {
            pose = .step(Int(t * 4))
            lift = CGFloat(abs(sin(t * 7))) * 4
        } else {
            // Đi qua lại 12 giây một vòng, nghỉ ở hai đầu. Thỉnh thoảng chớp mắt.
            let phase = t.truncatingRemainder(dividingBy: 12) / 12
            let walk = min(max((phase < 0.5 ? phase : 1 - phase) * 2.6 - 0.15, 0), 1)
            x = span * walk
            let moving = walk > 0 && walk < 1
            pose = moving ? .step(Int(t * 5)) : (t.truncatingRemainder(dividingBy: 3.5) < 0.15 ? .blink : .idle)
        }

        return ZStack(alignment: .topLeading) {
            Capsule().fill(.white.opacity(0.08)).frame(height: 3).offset(y: size.height - 3)
            PixelPet(kind: pet.kind, pose: pose, frame: Int(t * 3), pixel: pixel)
                .offset(x: x, y: size.height - h - 3 - lift)
            effects(date, since: since, petX: x, petTop: size.height - h - 3 - lift, petWidth: w)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func effects(_ date: Date, since: Double, petX: CGFloat, petTop: CGFloat, petWidth: CGFloat) -> some View {
        let cx = petX + petWidth / 2
        if pet.reaction != nil && since < 2.4 {
            let symbol = pet.reaction == .eat ? "fork.knife" : (pet.reaction == .refuse ? "xmark" : "heart.fill")
            let color = pet.reaction == .happy ? Color(hex: 0xFF8FB0) : ZTheme.orange.light
            ForEach(0..<3, id: \.self) { i in
                let p = max(0, since - Double(i) * 0.35)
                Image(systemName: symbol)
                    .font(.system(size: 9 + CGFloat(i) * 2, weight: .bold))
                    .foregroundStyle(color.opacity(max(0, 1 - p / 1.6)))
                    .offset(x: cx + CGFloat(i - 1) * 16 - 6, y: petTop - 8 - CGFloat(p) * 22)
            }
        } else if pet.isSleeping(at: date) {
            let t = date.timeIntervalSinceReferenceDate
            ForEach(0..<2, id: \.self) { i in
                let p = (t / 2 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: 10 + CGFloat(p) * 6, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7 * (1 - p)))
                    .offset(x: cx + 10 + CGFloat(p) * 14, y: petTop - CGFloat(p) * 26)
            }
        }
    }
}
