import AppKit
import CoreGraphics
import Observation
import SwiftUI

// Màn hình kiểu BetterDisplay:
// - Độ sáng: màn tích hợp qua DisplayServices; màn ngoài qua DDC/CI; màn không nhận DDC (TV, adapter HDMI)
//   thì làm tối bằng gamma (phần mềm). Gamma tự trả về khi app thoát, kể cả khi crash.
// - Độ phân giải: liệt kê cả chế độ HiDPI, đổi bằng transaction cấu hình màn hình.
// - Không timer: chỉ chạy khi cắm/rút/đổi cấu hình màn hình (callback CoreGraphics) hoặc khi người dùng kéo.

enum BrightnessMethod: String {
    case native, ddc, software, detecting, none

    var label: String {
        switch self {
        case .native: return L("Gốc", "Native")
        case .ddc: return "DDC"
        case .software: return L("Phần mềm", "Software")
        case .detecting: return L("Đang dò…", "Detecting…")
        case .none: return L("Không chỉnh được", "Unsupported")
        }
    }

    var color: Color {
        switch self {
        case .native: return .green
        case .ddc: return .blue
        case .software: return .orange
        case .detecting, .none: return .secondary
        }
    }
}

struct DisplayModeInfo: Identifiable, Hashable {
    let id: Int32            // ioDisplayModeID
    let width: Int           // điểm (point)
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double

    var hiDPI: Bool { pixelWidth > width }

    var label: String {
        var s = "\(width) × \(height)"
        if refresh > 0 { s += ", \(Int(refresh.rounded())) Hz" }
        return s
    }
}

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltin: Bool
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    var method: BrightnessMethod
    var brightness: Double
    var modes: [DisplayModeInfo]
    var currentModeID: Int32?

    /// Khoá ổn định qua các lần cắm lại (id CGDirectDisplayID có thể đổi).
    var key: String { "\(vendor)-\(model)-\(serial)" }
    var currentMode: DisplayModeInfo? { modes.first { $0.id == currentModeID } }
}

/// Callback C của CoreGraphics; chuyển về main rồi gom nhiều lần gọi thành một lần làm mới.
private let displayReconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, info in
    guard !flags.contains(.beginConfigurationFlag), let info else { return }
    let module = Unmanaged<DisplayModule>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { module.scheduleRefresh() } }
}

@MainActor @Observable
final class DisplayModule: ZModule {
    static let id = "display"
    static var name: String { L("Màn hình", "Displays") }
    static let replaces = "BetterDisplay"
    static let symbol = "display"
    static var summary: String {
        L("Chỉnh độ sáng màn hình ngoài (DDC, hoặc làm tối bằng phần mềm nếu màn không hỗ trợ), đổi độ phân giải và chế độ HiDPI.",
          "Control external display brightness (DDC, or software dimming when unsupported), change resolution and HiDPI modes.")
    }

    /// Không cho làm tối hẳn bằng gamma để luôn còn nhìn thấy màn hình.
    static let softwareFloor = 0.15

    private(set) var displays: [DisplayInfo] = []

    @ObservationIgnored private let ddc = DDCController()
    @ObservationIgnored private var cgModes: [CGDirectDisplayID: [Int32: CGDisplayMode]] = [:]
    /// Kết quả dò DDC theo khoá màn hình: true = DDC, false = phần mềm.
    @ObservationIgnored private var ddcKnown: [String: Bool] = [:]
    @ObservationIgnored private var lastExternalSignature = ""
    @ObservationIgnored private var dimmed: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var refreshPending = false

    init() {}

    func start() {
        running = true
        refresh()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    func stop() {
        running = false
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        ddc.reset()
        if !dimmed.isEmpty {
            CGDisplayRestoreColorSyncSettings()
            dimmed.removeAll()
        }
        displays = []
        cgModes = [:]
    }

    // MARK: - Làm mới

    func scheduleRefresh() {
        guard running, !refreshPending else { return }
        refreshPending = true
        // Một lần cắm màn hình bắn nhiều callback: đợi chúng xong rồi làm mới một lần.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                if self.running { self.refresh() }
            }
        }
    }

    func refresh() {
        let previous = Dictionary(displays.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var list: [DisplayInfo] = []
        var modesByDisplay: [CGDirectDisplayID: [Int32: CGDisplayMode]] = [:]

        for id in Self.activeDisplayIDs() {
            let builtin = CGDisplayIsBuiltin(id) != 0
            var info = DisplayInfo(
                id: id,
                name: Self.screenName(id) ?? (builtin ? L("Màn hình tích hợp", "Built-in Display") : L("Màn hình", "Display") + " \(id)"),
                isBuiltin: builtin,
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                method: .detecting,
                brightness: 1,
                modes: [],
                currentModeID: nil
            )
            let (modes, cg, current) = Self.loadModes(id)
            info.modes = modes
            info.currentModeID = current
            modesByDisplay[id] = cg

            if builtin, let b = Self.nativeBrightness(id) {
                info.method = .native
                info.brightness = b
            } else if builtin {
                info.method = PrivateAPI.setBrightness != nil ? .native : .none
            } else if let known = ddcKnown[info.key] {
                info.method = known ? .ddc : .software
                info.brightness = known ? (previous[info.key]?.brightness ?? 1) : softwareBrightness(info.key)
            } else {
                info.method = .detecting
                info.brightness = softwareBrightness(info.key)
            }
            list.append(info)
        }

        // Màn tích hợp lên đầu, còn lại theo id.
        list.sort { ($0.isBuiltin ? 0 : 1, $0.id) < ($1.isBuiltin ? 0 : 1, $1.id) }
        displays = list
        cgModes = modesByDisplay

        // Gamma bị reset sau khi đổi cấu hình: áp lại cho màn đang làm tối.
        dimmed = dimmed.filter { id in list.contains { $0.id == id } }
        for d in list where d.method == .software { applyGamma(d.id, d.brightness) }

        // Dò DDC lại khi tập màn hình ngoài thay đổi (cắm/rút), không dò khi chỉ đổi độ phân giải.
        let externals = list.filter { !$0.isBuiltin }
        let signature = externals.map { "\($0.id):\($0.key)" }.joined(separator: ",")
        if signature != lastExternalSignature {
            lastExternalSignature = signature
            detectDDC(externals)
        }
    }

    private func detectDDC(_ externals: [DisplayInfo]) {
        guard !externals.isEmpty else { ddc.reset(); return }
        let targets = externals.map { DDCTarget(id: $0.id, vendor: $0.vendor, model: $0.model, serial: $0.serial) }
        ddc.detect(targets) { [weak self] results in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyDetection(results) }
            }
        }
    }

    private func applyDetection(_ results: [CGDirectDisplayID: DDCController.Detected?]) {
        guard running else { return }
        for (id, detected) in results {
            guard let i = displays.firstIndex(where: { $0.id == id }) else { continue }
            let key = displays[i].key
            if let d = detected {
                ddcKnown[key] = true
                displays[i].method = .ddc
                displays[i].brightness = Double(d.current) / Double(max(d.max, 1))
                if dimmed.contains(id) { restoreGamma(id) }
            } else {
                ddcKnown[key] = false
                displays[i].method = .software
                displays[i].brightness = softwareBrightness(key)
                applyGamma(id, displays[i].brightness)
            }
        }
    }

    /// Đọc lại độ sáng màn tích hợp (người dùng có thể đã chỉnh bằng phím), gọi khi mở bảng.
    func refreshNativeBrightness() {
        for i in displays.indices where displays[i].method == .native {
            if let b = Self.nativeBrightness(displays[i].id) { displays[i].brightness = b }
        }
    }

    // MARK: - Độ sáng

    func setBrightness(_ id: CGDirectDisplayID, _ value: Double) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        let v = min(max(value, 0), 1)
        displays[i].brightness = v
        switch displays[i].method {
        case .native:
            _ = PrivateAPI.setBrightness?(id, Float(v))
        case .ddc:
            ddc.set(id, v)
        case .software:
            applyGamma(id, v)
            Pref.set("display.soft.\(displays[i].key)", v)
        case .detecting, .none:
            break
        }
    }

    private func softwareBrightness(_ key: String) -> Double {
        Pref.double("display.soft.\(key)", 1)
    }

    private func applyGamma(_ id: CGDirectDisplayID, _ value: Double) {
        if value >= 0.999 {
            if dimmed.contains(id) { restoreGamma(id) }
            return
        }
        let v = Float(Self.softwareFloor + (1 - Self.softwareFloor) * value)
        if CGSetDisplayTransferByFormula(id, 0, v, 1, 0, v, 1, 0, v, 1) == .success {
            dimmed.insert(id)
        }
    }

    /// ColorSync chỉ trả được cho mọi màn cùng lúc: trả rồi áp lại các màn khác đang làm tối.
    private func restoreGamma(_ id: CGDirectDisplayID) {
        dimmed.remove(id)
        CGDisplayRestoreColorSyncSettings()
        for d in displays where dimmed.contains(d.id) && d.method == .software {
            let v = Float(Self.softwareFloor + (1 - Self.softwareFloor) * d.brightness)
            CGSetDisplayTransferByFormula(d.id, 0, v, 1, 0, v, 1, 0, v, 1)
        }
    }

    // MARK: - Độ phân giải

    func setMode(_ displayID: CGDirectDisplayID, _ modeID: Int32) {
        guard let mode = cgModes[displayID]?[modeID] else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        if CGCompleteDisplayConfiguration(config, .permanently) != .success {
            CGCancelDisplayConfiguration(config)
        }
        // Callback cấu hình sẽ làm mới danh sách.
    }

    // MARK: - Đọc hệ thống

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func screenName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { $0.displayID == id }?.localizedName
    }

    static func nativeBrightness(_ id: CGDirectDisplayID) -> Double? {
        guard let get = PrivateAPI.getBrightness else { return nil }
        var b: Float = 0
        return get(id, &b) == 0 ? Double(b) : nil
    }

    /// Chế độ dùng được cho desktop, bỏ trùng theo (kích thước điểm, HiDPI, tần số quét).
    static func loadModes(_ id: CGDirectDisplayID) -> ([DisplayModeInfo], [Int32: CGDisplayMode], Int32?) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        let current = CGDisplayCopyDisplayMode(id)
        var seen: [String: Int] = [:]
        var infos: [DisplayModeInfo] = []
        var map: [Int32: CGDisplayMode] = [:]

        // Chế độ hiện tại xét trước để không bị bản trùng thay mất.
        let ordered = (current.map { [$0] } ?? []) + all
        for m in ordered where m.isUsableForDesktopGUI() {
            let info = DisplayModeInfo(id: m.ioDisplayModeID, width: m.width, height: m.height,
                                       pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, refresh: m.refreshRate)
            let key = "\(info.width)x\(info.height)-\(info.hiDPI)-\(Int(info.refresh.rounded()))"
            guard seen[key] == nil else { continue }
            seen[key] = infos.count
            infos.append(info)
            map[info.id] = m
        }
        infos.sort { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            return a.refresh > b.refresh
        }
        return (infos, map, current?.ioDisplayModeID)
    }

    // MARK: - Giao diện

    private func brightnessBinding(_ id: CGDirectDisplayID) -> Binding<Double> {
        Binding(get: { self.displays.first { $0.id == id }?.brightness ?? 1 },
                set: { self.setBrightness(id, $0) })
    }

    private func modeBinding(_ id: CGDirectDisplayID) -> Binding<Int32> {
        Binding(get: { self.displays.first { $0.id == id }?.currentModeID ?? -1 },
                set: { self.setMode(id, $0) })
    }

    func settingsView() -> AnyView {
        AnyView(moduleForm {
            if displays.isEmpty {
                Section { Text(L("Không thấy màn hình nào.", "No displays found.")).foregroundStyle(.secondary) }
            }
            ForEach(displays) { d in
                Section {
                    HStack {
                        Image(systemName: d.isBuiltin ? "laptopcomputer" : "display")
                            .foregroundStyle(.secondary)
                        Text(d.name).font(.headline)
                        Spacer()
                        MethodBadge(method: d.method)
                    }
                    LabeledContent(L("Độ sáng", "Brightness")) {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: self.brightnessBinding(d.id), in: 0...1)
                            Image(systemName: "sun.max").foregroundStyle(.secondary)
                            Text("\(Int((d.brightness * 100).rounded()))%")
                                .monospacedDigit().frame(width: 42, alignment: .trailing)
                        }
                        .disabled(d.method == .detecting || d.method == .none)
                    }
                    if d.method == .software {
                        Text(L("Màn này không nhận lệnh DDC nên zMac làm tối bằng phần mềm. Đèn nền vẫn giữ nguyên, chỉ hình ảnh tối đi.",
                               "This display doesn't accept DDC commands, so zMac dims the picture in software. The backlight stays the same."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !d.modes.isEmpty {
                        Picker(L("Độ phân giải", "Resolution"), selection: self.modeBinding(d.id)) {
                            let hidpi = d.modes.filter(\.hiDPI)
                            let standard = d.modes.filter { !$0.hiDPI }
                            if !hidpi.isEmpty {
                                Section(L("HiDPI (nét)", "HiDPI (sharp)")) {
                                    ForEach(hidpi) { m in Text(m.label).tag(m.id) }
                                }
                            }
                            if !standard.isEmpty {
                                Section(L("Thường", "Standard")) {
                                    ForEach(standard) { m in Text(m.label).tag(m.id) }
                                }
                            }
                        }
                        if let m = d.currentMode {
                            Text(L("Đang dùng ", "Current: ") + "\(m.label)" + (m.hiDPI ? ", HiDPI" : "")
                                 + L(", điểm ảnh thật \(m.pixelWidth) × \(m.pixelHeight)", ", \(m.pixelWidth) × \(m.pixelHeight) pixels"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text(L("Mô-đun này không chạy nền: chỉ làm việc khi bạn kéo thanh trượt hoặc khi cắm, rút, đổi cấu hình màn hình.",
                       "This module doesn't run in the background: it only works when you move a slider or when displays are connected, removed or reconfigured."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { self.refreshNativeBrightness() })
    }

    func quickView() -> AnyView? {
        AnyView(VStack(spacing: 6) {
            ForEach(displays) { d in
                HStack(spacing: 8) {
                    Image(systemName: d.isBuiltin ? "laptopcomputer" : "display")
                        .foregroundStyle(.secondary).frame(width: 18)
                    Text(d.name).font(.callout).lineLimit(1).frame(width: 96, alignment: .leading)
                    Slider(value: self.brightnessBinding(d.id), in: 0...1)
                        .controlSize(.small)
                        .disabled(d.method == .detecting || d.method == .none)
                    Text("\(Int((d.brightness * 100).rounded()))%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .help(d.method.label)
            }
        }
        .onAppear { self.refreshNativeBrightness() })
    }

    // MARK: - Chẩn đoán

    static func diagnose() {
        print("  màn hình:")
        let ids = activeDisplayIDs()
        let externals = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        let targets = externals.map { DDCTarget(id: $0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0),
                                                serial: CGDisplaySerialNumber($0)) }
        let services = DDC.available ? DDC.externalServices() : []
        let paired = DDC.pair(targets, services)
        let results = DDCController().detectNow(targets)
        print("    DDC: API \(DDC.available ? "có" : "không có"), \(services.count) dịch vụ ngoài, ghép được \(paired.count)")
        for s in services {
            print("      dịch vụ: \(s.name ?? "?") vendor=\(s.vendor ?? -1) product=\(s.product ?? -1) serial=\(s.serial ?? -1)")
        }
        for id in ids {
            let builtin = CGDisplayIsBuiltin(id) != 0
            let (modes, _, current) = loadModes(id)
            let cur = modes.first { $0.id == current }
            var method = "none"
            var bright = "?"
            if builtin {
                if let b = nativeBrightness(id) { method = "native"; bright = "\(Int((b * 100).rounded()))%" }
            } else if let r = results[id], let d = r {
                method = "ddc"; bright = "\(d.current)/\(d.max)"
            } else {
                method = "software (DDC không trả lời)"
                let key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
                bright = "\(Int((Pref.double("display.soft.\(key)", 1) * 100).rounded()))% (lưu)"
            }
            let curText = cur.map { "\($0.label)\($0.hiDPI ? " HiDPI" : "") (\($0.pixelWidth)x\($0.pixelHeight) px)" } ?? "?"
            print("    \(id) \(screenName(id) ?? "?"): \(builtin ? "tích hợp" : "ngoài"), vendor=\(CGDisplayVendorNumber(id)) "
                  + "model=\(CGDisplayModelNumber(id)) serial=\(CGDisplaySerialNumber(id)), cách chỉnh=\(method), sáng=\(bright), "
                  + "chế độ=\(curText), \(modes.count) chế độ (\(modes.filter(\.hiDPI).count) HiDPI)")
        }
    }
}

private struct MethodBadge: View {
    let method: BrightnessMethod
    var body: some View {
        Text(method.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(method.color.opacity(0.15)))
            .foregroundStyle(method.color)
    }
}
