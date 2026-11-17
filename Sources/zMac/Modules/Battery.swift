import AppKit
import IOKit.ps
import Observation
import SwiftUI
import ZMacShared

// Pin kiểu AlDente. App chỉ hiển thị và gửi chính sách; việc chặn sạc do zmac-helper (daemon root) làm,
// nên ngưỡng vẫn giữ khi app tắt. App nhận cập nhật pin qua IOPS (theo sự kiện), không poll.

@MainActor @Observable
final class BatteryModule: ZModule {
    static let id = "battery"
    static var name: String { L("Pin", "Battery") }
    static let replaces = "AlDente"
    static let symbol = "battery.75percent"
    static var summary: String {
        L("Giới hạn mức sạc (vd 80%) để pin bền hơn. Daemon nhỏ giữ ngưỡng kể cả khi zMac tắt.",
          "Limit charging (e.g. to 80%) for a longer battery lifespan. A tiny daemon enforces it even when zMac is closed.")
    }
    static var unavailableReason: String? {
        Hardware.hasBattery ? nil : L("Máy này không có pin.", "This Mac has no battery.")
    }

    enum HelperState { case checking, notInstalled, outdated, unreachable, running }

    private(set) var snapshot: BatterySnapshot?
    private(set) var helperState: HelperState = .checking
    private(set) var status: HelperStatus?
    private(set) var policy = BatteryPolicy()
    private(set) var busy = false
    private(set) var lastError: String?

    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private let sendLater = Debouncer(0.4)
    @ObservationIgnored private var editing = false

    init() {}

    func start() {
        refreshSnapshot()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<BatteryModule>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated {
                m.refreshSnapshot()
                if m.helperState == .running { m.refreshHelper() }
            }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        refreshHelper()
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
        sendLater.cancel()
        connection?.invalidate()
        connection = nil
    }

    func refreshSnapshot() { snapshot = BatteryReader.snapshot() }

    // MARK: XPC

    private func proxy(_ onError: @escaping @MainActor (Error) -> Void) -> ZMacHelperXPC? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: ZMacHelperXPC.self)
            let drop: () -> Void = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.connection = nil } }
            }
            c.invalidationHandler = drop
            c.interruptionHandler = drop
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { e in
            DispatchQueue.main.async { MainActor.assumeIsolated { onError(e) } }
        } as? ZMacHelperXPC
    }

    func refreshHelper() {
        guard FileManager.default.fileExists(atPath: HelperConstants.installedBinary) else {
            helperState = .notInstalled
            status = nil
            return
        }
        proxy { [weak self] _ in self?.helperState = .unreachable }?.status { data in
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.apply(data) } }
        }
    }

    private func apply(_ data: Data?) {
        guard let data, let s = try? JSONDecoder().decode(HelperStatus.self, from: data) else {
            helperState = .unreachable
            return
        }
        status = s
        helperState = s.version == HelperConstants.version ? .running : .outdated
        if !editing { policy = s.policy }
    }

    /// Sửa chính sách trên UI ngay, gửi helper sau 0,4 s (kéo thanh trượt chỉ gửi giá trị cuối).
    func update(_ change: (inout BatteryPolicy) -> Void) {
        change(&policy)
        editing = true
        sendLater.call { [weak self] in self?.send() }
    }

    private func send() {
        editing = false
        guard let data = try? JSONEncoder().encode(policy) else { return }
        proxy { [weak self] e in self?.lastError = e.localizedDescription }?.setPolicy(data) { reply, err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    self?.lastError = err
                    self?.apply(reply)
                }
            }
        }
    }

    // MARK: Cài / gỡ helper (hỏi mật khẩu admin một lần)

    func runInstaller(uninstall: Bool) {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zmac-helper")
        guard let script = Bundle.main.url(forResource: "helper-install", withExtension: "sh"),
              FileManager.default.fileExists(atPath: helper.path) else {
            lastError = L("Hãy chạy bản đóng gói (./build.sh) để cài helper.", "Run the packaged app (./build.sh) to install the helper.")
            return
        }
        func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "/bin/bash \(sh(script.path)) \(uninstall ? "uninstall" : "install") \(sh(helper.path))"
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let err = Pipe()
        p.standardError = err
        busy = true
        lastError = nil
        p.terminationHandler = { proc in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.busy = false
                    if !ok && !msg.contains("-128") { self.lastError = msg.trimmingCharacters(in: .whitespacesAndNewlines) }
                    self.connection?.invalidate()
                    self.connection = nil
                    self.refreshHelper()
                }
            }
        }
        do { try p.run() } catch { busy = false; lastError = error.localizedDescription }
    }

    // MARK: Văn bản

    var reasonText: String {
        guard helperState == .running, let s = status else {
            return L("Sạc theo mặc định của macOS", "Charging as macOS decides")
        }
        switch s.reason {
        case "off": return L("Sạc bình thường, chưa bật giới hạn", "Charging normally, limit off")
        case "charging": return L("Đang cho sạc", "Charging allowed")
        case "limit": return L("Đã tới ngưỡng, ngừng sạc", "At the limit, charging paused")
        case "sailing": return L("Đang giữ quanh ngưỡng", "Sailing around the limit")
        case "heat": return L("Pin nóng, tạm ngừng sạc", "Battery hot, charging paused")
        case "sleep": return L("Máy ngủ, ngừng sạc", "Asleep, charging paused")
        case "topup": return L("Đang sạc đầy một lần", "Topping up to 100%")
        case "discharge": return L("Đang xả về ngưỡng bằng pin", "Discharging down to the limit")
        case "unsupported": return L("Máy không hỗ trợ khoá sạc", "Charge control not supported on this Mac")
        default: return s.reason
        }
    }

    var powerText: String {
        guard let b = snapshot else { return "" }
        if !b.externalConnected { return L("Đang dùng pin", "On battery") }
        if b.isCharging { return L("Đang sạc", "Charging") + (b.adapterWatts > 0 ? " (\(b.adapterWatts) W)" : "") }
        return L("Đang cắm sạc, không sạc", "Plugged in, not charging")
    }

    // MARK: Giao diện

    func settingsView() -> AnyView {
        moduleForm {
            Section(L("Pin", "Battery")) {
                if let b = snapshot {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(b.percent)%").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        VStack(alignment: .leading) {
                            Text(powerText)
                            Text(reasonText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(L("Sức khoẻ", "Health"), value: String(format: "%.0f%%", b.health * 100))
                    LabeledContent(L("Số lần sạc (chu kỳ)", "Cycle count"), value: "\(b.cycleCount)")
                    LabeledContent(L("Nhiệt độ", "Temperature"), value: String(format: "%.1f °C", b.temperature))
                    LabeledContent(L("Dung lượng", "Capacity"), value: "\(b.maxCapacity) / \(b.designCapacity) mAh")
                } else {
                    Text(L("Không đọc được pin.", "Couldn't read the battery."))
                }
            }
            helperSection
            if helperState == .running { limitSection }
        }
    }

    @ViewBuilder private var helperSection: some View {
        Section(L("Bộ điều khiển sạc", "Charge controller")) {
            HStack {
                switch helperState {
                case .checking: ProgressView().controlSize(.small); Text(L("Đang kiểm tra…", "Checking…"))
                case .notInstalled: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(L("Chưa cài. Cần cài một lần (hỏi mật khẩu admin).", "Not installed. Install once (asks for an admin password)."))
                case .outdated: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text(L("Phiên bản cũ, cần cài lại.", "Outdated, please reinstall."))
                case .unreachable: Image(systemName: "xmark.circle").foregroundStyle(.red)
                    Text(L("Đã cài nhưng không kết nối được.", "Installed but not reachable."))
                case .running: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("Đang chạy", "Running") + (status?.chargingKey.map { " (SMC \($0))" } ?? ""))
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if helperState != .running && helperState != .checking {
                    Button(helperState == .notInstalled ? L("Cài", "Install") : L("Cài lại", "Reinstall")) {
                        self.runInstaller(uninstall: false)
                    }.disabled(busy)
                }
                if helperState != .notInstalled && helperState != .checking {
                    Button(L("Gỡ", "Remove")) { self.runInstaller(uninstall: true) }.disabled(busy)
                }
            }
            if let lastError { Text(lastError).font(.caption).foregroundStyle(.red) }
            Text(L("Daemon chạy bằng root, chỉ thức dậy khi pin thay đổi, cắm rút sạc hoặc máy ngủ. Gỡ là máy sạc lại như mặc định.",
                   "The daemon runs as root and only wakes when the battery changes, power is (un)plugged or the Mac sleeps. Removing it restores default charging."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var limitSection: some View {
        Section(L("Giới hạn sạc", "Charge limit")) {
            Toggle(L("Bật giới hạn sạc", "Limit charging"), isOn: Binding(get: { self.policy.enabled }, set: { v in self.update { $0.enabled = v } }))
            HStack {
                Text(L("Dừng sạc ở", "Stop at"))
                Slider(value: Binding(get: { Double(self.policy.limit) }, set: { v in self.update { $0.limit = Int(v) } }), in: 50...100, step: 1)
                Text("\(policy.limit)%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .disabled(!policy.enabled)
            Stepper(value: Binding(get: { self.policy.sailingDelta }, set: { v in self.update { $0.sailingDelta = v } }), in: 1...20) {
                Text(L("Sạc lại khi xuống dưới ", "Resume charging below ") + "\(policy.limit - policy.sailingDelta)%")
            }
            .disabled(!policy.enabled)
            Toggle(L("Ngừng sạc khi pin nóng", "Pause charging when hot"),
                   isOn: Binding(get: { self.policy.heatProtection }, set: { v in self.update { $0.heatProtection = v } }))
                .disabled(!policy.enabled)
            if policy.heatProtection {
                HStack {
                    Text(L("Ngưỡng nhiệt", "Temperature limit"))
                    Slider(value: Binding(get: { self.policy.maxTemperature }, set: { v in self.update { $0.maxTemperature = v.rounded() } }), in: 30...45)
                    Text("\(Int(policy.maxTemperature)) °C").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            if status?.adapterKey != nil {
                Toggle(L("Xả về ngưỡng khi đang cắm sạc", "Discharge to the limit while plugged in"),
                       isOn: Binding(get: { self.policy.dischargeToLimit }, set: { v in self.update { $0.dischargeToLimit = v } }))
                    .disabled(!policy.enabled)
            }
            Toggle(L("Không sạc thêm khi máy ngủ nếu pin đã gần ngưỡng", "Don't charge while asleep once near the limit"),
                   isOn: Binding(get: { self.policy.inhibitDuringSleep }, set: { v in self.update { $0.inhibitDuringSleep = v } }))
                .disabled(!policy.enabled)
            HStack {
                Button(policy.topUp ? L("Huỷ sạc đầy", "Cancel top-up") : L("Sạc đầy 100% một lần", "Top up to 100% once")) {
                    self.update { $0.topUp.toggle() }
                }
                .disabled(!policy.enabled)
                Spacer()
                Text(reasonText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func quickView() -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(snapshot.map { "\($0.percent)%" } ?? "?").font(.title3.weight(.semibold)).monospacedDigit()
                Text(powerText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if helperState == .running {
                    Toggle("", isOn: Binding(get: { self.policy.enabled }, set: { v in self.update { $0.enabled = v } }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            if helperState == .running && policy.enabled {
                HStack {
                    Slider(value: Binding(get: { Double(self.policy.limit) }, set: { v in self.update { $0.limit = Int(v) } }), in: 50...100, step: 5)
                    Text("\(policy.limit)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Text(reasonText).font(.caption).foregroundStyle(.secondary)
            } else if helperState != .running {
                Text(L("Cài bộ điều khiển sạc trong Cài đặt để giới hạn sạc.", "Install the charge controller in Settings to limit charging."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        })
    }

    static func diagnose() {
        print("  pin:")
        if let b = BatteryReader.snapshot() {
            print("    \(b.percent)%, sạc=\(b.isCharging), cắm=\(b.externalConnected), \(b.temperature)°C, chu kỳ=\(b.cycleCount), " +
                  "sức khoẻ=\(Int(b.health * 100))%, adapter=\(b.adapterWatts)W")
        }
        if let smc = SMC() {
            for key in ["CHTE", "CH0B", "CHIE", "CH0I"] where smc.exists(key) {
                print("    SMC \(key) = " + (smc.read(key) ?? []).map { String(format: "%02x", $0) }.joined(separator: " "))
            }
        }
        print("    helper đã cài: \(FileManager.default.fileExists(atPath: HelperConstants.installedBinary))")
    }
}
