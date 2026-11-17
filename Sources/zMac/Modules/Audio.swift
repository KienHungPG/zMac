import AppKit
import AudioToolbox
import CoreAudio
import Observation
import SwiftUI

// Âm thanh kiểu FineTune: thiết bị vào / ra, âm lượng tổng, âm lượng và loa riêng từng app.
// Tối ưu: app ở 100%, không tắt tiếng, theo loa hệ thống thì zMac không đụng tới đường phát của nó
// (không tap, không aggregate device, không IOProc). Mọi cập nhật đi theo listener của Core Audio, không poll.

/// Cài đặt riêng của một app, lưu theo bundle ID.
struct AppAudioSetting: Codable, Equatable {
    var gain: Float = 1
    var muted = false
    /// UID loa riêng; nil = theo loa hệ thống.
    var deviceUID: String?

    var isDefault: Bool { gain == 1 && !muted && deviceUID == nil }
}

/// App đang có tiến trình âm thanh (gộp các helper về app chủ).
struct ZAudioApp: Identifiable, Equatable {
    let id: String          // bundle ID
    let name: String
    let pid: pid_t
    var active: Bool        // đang phát ra loa
    var processes: [AudioObjectID]
}

@MainActor @Observable
final class AudioModule: ZModule {
    static let id = "audio"
    static var name: String { L("Âm thanh", "Sound") }
    static let replaces = "FineTune"
    static let symbol = "speaker.wave.2"
    static var summary: String {
        L("Âm lượng riêng cho từng app, chọn loa riêng cho từng app, đổi thiết bị vào ra nhanh.",
          "Per-app volume, per-app output device and quick input/output switching.")
    }
    static var unavailableReason: String? {
        Hardware.supportsProcessTaps ? nil : L("Cần macOS 14.2 trở lên.", "Requires macOS 14.2 or later.")
    }

    static let maxGain: Float = 1.5
    private static let settingsKey = "audio.apps"

    private(set) var outputs: [ZAudioDevice] = []
    private(set) var inputs: [ZAudioDevice] = []
    private(set) var outputID = AudioDeviceID(0)
    private(set) var inputID = AudioDeviceID(0)
    private(set) var outputVolume: Float = 1
    private(set) var outputMuted = false
    private(set) var outputHasVolume = false
    private(set) var inputVolume: Float = 0
    private(set) var inputHasVolume = false
    /// App hiện trong danh sách: đang phát, hoặc đang chạy và có cài đặt khác mặc định.
    private(set) var apps: [ZAudioApp] = []
    private(set) var settings: [String: AppAudioSetting] = Pref.codable(AudioModule.settingsKey, [String: AppAudioSetting]())
    /// Tap chỉ nhận im lặng: thiếu quyền "Ghi âm thanh hệ thống".
    private(set) var permissionDenied = false

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    @ObservationIgnored private let engine = ZAudioTapEngine()
    @ObservationIgnored private var listeners: [Listener] = []
    @ObservationIgnored private var volumeListeners: [Listener] = []
    @ObservationIgnored private var processListeners: [AudioObjectID: Listener] = [:]
    @ObservationIgnored private var allApps: [String: ZAudioApp] = [:]
    @ObservationIgnored private var watchedOutput = AudioDeviceID(0)
    @ObservationIgnored private var watchedInput = AudioDeviceID(0)
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    init() {}

    // MARK: - Vòng đời

    func start() {
        engine.onDenied = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.permissionDenied = true } }
        }
        let system = ZAudioHAL.system
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                    kAudioHardwarePropertyDefaultInputDevice] {
            if let l = listen(system, ZAudioHAL.addr(sel), { [weak self] in self?.refreshDevices() }) { listeners.append(l) }
        }
        if #available(macOS 14.2, *) {
            if let l = listen(system, ZAudioHAL.addr(kAudioHardwarePropertyProcessObjectList), { [weak self] in self?.refreshApps() }) {
                listeners.append(l)
            }
        }
        // Sau khi ngủ dậy aggregate device có thể hỏng: dựng lại tap.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAll(rebuild: true) }
        }
        refreshDevices()
        refreshApps()
    }

    func stop() {
        for l in listeners + volumeListeners + Array(processListeners.values) { unlisten(l) }
        listeners = []
        volumeListeners = []
        processListeners = [:]
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        engine.onDenied = nil
        engine.removeAll()
        allApps = [:]
        icons = [:]
    }

    // MARK: - Listener Core Audio (block chạy trên main queue)

    private func listen(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        _ action: @escaping @MainActor () -> Void) -> Listener? {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        guard AudioObjectAddPropertyListenerBlock(obj, &a, .main, block) == noErr else { return nil }
        return Listener(object: obj, address: address, block: block)
    }

    private func unlisten(_ l: Listener) {
        var a = l.address
        AudioObjectRemovePropertyListenerBlock(l.object, &a, .main, l.block)
    }

    // MARK: - Thiết bị

    private func refreshDevices() {
        let all = ZAudioHAL.devices()
        let outs = all.filter { ZAudioHAL.hasStreams($0.id, output: true) }
        let ins = all.filter { ZAudioHAL.hasStreams($0.id, output: false) }
        if outs != outputs { outputs = outs }
        if ins != inputs { inputs = ins }
        let newOut = ZAudioHAL.defaultDevice(output: true)
        let newIn = ZAudioHAL.defaultDevice(output: false)
        let outChanged = newOut != outputID
        if outChanged { outputID = newOut }
        if newIn != inputID { inputID = newIn }
        if watchedOutput != newOut || watchedInput != newIn { watchVolumes() }
        readVolumes()
        // Đổi loa / rút thiết bị: tap theo loa hệ thống phải dựng lại trên thiết bị mới.
        applyAll(rebuild: outChanged)
    }

    private func watchVolumes() {
        volumeListeners.forEach(unlisten)
        volumeListeners = []
        watchedOutput = outputID
        watchedInput = inputID
        for (device, output) in [(outputID, true), (inputID, false)] where device != 0 {
            for a in ZAudioHAL.volumeWatchAddresses(output: output) {
                var probe = a
                guard AudioObjectHasProperty(device, &probe) else { continue }
                if let l = listen(device, a, { [weak self] in self?.readVolumes() }) { volumeListeners.append(l) }
            }
        }
    }

    private func readVolumes() {
        let ov = ZAudioHAL.volume(outputID, output: true)
        outputHasVolume = ov != nil
        outputVolume = ov ?? 1
        outputMuted = ZAudioHAL.isMuted(outputID, output: true)
        let iv = ZAudioHAL.volume(inputID, output: false)
        inputHasVolume = iv != nil
        inputVolume = iv ?? 0
    }

    var outputName: String {
        outputs.first { $0.id == outputID }?.name ?? L("Không có loa", "No output")
    }

    func setOutputDevice(_ id: AudioDeviceID) { ZAudioHAL.setDefaultDevice(id, output: true) }
    func setInputDevice(_ id: AudioDeviceID) { ZAudioHAL.setDefaultDevice(id, output: false) }

    func setOutputVolume(_ v: Float) {
        outputVolume = min(max(v, 0), 1)
        ZAudioHAL.setVolume(outputID, output: true, outputVolume)
        if outputMuted && v > 0 { ZAudioHAL.setMuted(outputID, output: true, false) }
    }

    func setInputVolume(_ v: Float) {
        inputVolume = min(max(v, 0), 1)
        ZAudioHAL.setVolume(inputID, output: false, inputVolume)
    }

    func toggleOutputMute() {
        ZAudioHAL.setMuted(outputID, output: true, !outputMuted)
        readVolumes()
    }

    // MARK: - App đang phát

    private func refreshApps() {
        guard #available(macOS 14.2, *) else { return }
        let own = Bundle.main.bundleIdentifier ?? "com.zmac.app"
        let running = NSWorkspace.shared.runningApplications
        var byApp: [String: ZAudioApp] = [:]
        var seen = Set<AudioObjectID>()
        for obj in ZAudioHAL.processObjects() {
            let pid = ZAudioHAL.pid(obj)
            guard pid > 0, pid != getpid(),
                  let app = ZAudioResponsible.owner(of: pid, bundleID: ZAudioHAL.bundleID(obj), in: running),
                  let bid = app.bundleIdentifier, bid != own else { continue }
            seen.insert(obj)
            if processListeners[obj] == nil,
               let l = listen(obj, ZAudioHAL.addr(kAudioProcessPropertyIsRunningOutput), { [weak self] in self?.refreshApps() }) {
                processListeners[obj] = l
            }
            let on = ZAudioHAL.isRunningOutput(obj)
            var entry = byApp[bid] ?? ZAudioApp(id: bid, name: app.localizedName ?? bid, pid: app.processIdentifier,
                                               active: false, processes: [])
            entry.processes.append(obj)
            entry.active = entry.active || on
            byApp[bid] = entry
        }
        // Tiến trình đã biến mất: gỡ listener.
        for (obj, l) in processListeners where !seen.contains(obj) {
            unlisten(l)
            processListeners[obj] = nil
        }
        allApps = byApp
        icons = icons.filter { byApp[$0.key] != nil }
        let shown = byApp.values
            .filter { $0.active || !(settings[$0.id]?.isDefault ?? true) }
            .sorted { ($0.active ? 0 : 1, $0.name.lowercased()) < ($1.active ? 0 : 1, $1.name.lowercased()) }
        if shown != apps { apps = shown }
        applyAll(rebuild: false)
    }

    func icon(for app: ZAudioApp) -> NSImage? {
        if let i = icons[app.id] { return i }
        let i = NSRunningApplication(processIdentifier: app.pid)?.icon
        icons[app.id] = i
        return i
    }

    // MARK: - Cài đặt từng app

    func setting(_ app: String) -> AppAudioSetting { settings[app] ?? AppAudioSetting() }

    func setGain(_ value: Float, for app: String) {
        var s = setting(app)
        var g = min(max(value, 0), Self.maxGain)
        if abs(g - 1) < 0.02 { g = 1 }   // hít về 100% để gỡ tap
        s.gain = g
        if g > 0 { s.muted = false }
        save(s, for: app)
    }

    func toggleMute(_ app: String) {
        var s = setting(app)
        s.muted.toggle()
        save(s, for: app)
    }

    func setDevice(_ uid: String?, for app: String) {
        var s = setting(app)
        s.deviceUID = uid
        save(s, for: app)
    }

    func reset(_ app: String) { save(AppAudioSetting(), for: app) }

    private func save(_ s: AppAudioSetting, for app: String) {
        guard s != setting(app) else { return }
        settings[app] = s.isDefault ? nil : s
        Pref.setCodable(Self.settingsKey, settings)
        permissionDenied = false   // người dùng chỉnh: thử lại
        apply(app, explicit: true)
    }

    // MARK: - Áp vào engine

    private func apply(_ app: String, rebuild: Bool = false, explicit: Bool = false) {
        // Đã biết thiếu quyền: chỉ thử lại khi người dùng tự chỉnh, tránh tắt / bật tiếng app liên tục.
        if permissionDenied && !explicit { return }
        let s = setting(app)
        let system = outputs.first { $0.id == outputID }
        // Loa riêng đã rút ra thì quay về loa hệ thống.
        let target = s.deviceUID.flatMap { uid in outputs.first { $0.uid == uid } } ?? system
        let needsTap = s.gain != 1 || s.muted || (target != nil && target?.id != outputID)
        engine.update(app: app, gain: s.muted ? 0 : s.gain, processes: allApps[app]?.processes ?? [],
                      deviceID: target?.id ?? 0, deviceUID: target?.uid, needsTap: needsTap, rebuild: rebuild)
    }

    private func applyAll(rebuild: Bool) {
        for app in Set(settings.keys).union(engine.activeApps) { apply(app, rebuild: rebuild) }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Giao diện

    func settingsView() -> AnyView {
        moduleForm { AudioSettingsSections(m: self) }
    }

    func quickView() -> AnyView? {
        AnyView(AudioQuickView(m: self))
    }

    // MARK: - Chẩn đoán

    static func diagnose() {
        print("  âm thanh:")
        let defOut = ZAudioHAL.defaultDevice(output: true)
        let defIn = ZAudioHAL.defaultDevice(output: false)
        for d in ZAudioHAL.devices() {
            let o = ZAudioHAL.hasStreams(d.id, output: true)
            let i = ZAudioHAL.hasStreams(d.id, output: false)
            var tags: [String] = []
            if o { tags.append("ra") }
            if i { tags.append("vào") }
            if d.id == defOut { tags.append("loa mặc định") }
            if d.id == defIn { tags.append("mic mặc định") }
            print("    [\(d.id)] \(d.name) (\(tags.joined(separator: ", ")))")
        }
        let vol = ZAudioHAL.volume(defOut, output: true).map { String(format: "%.0f%%", $0 * 100) } ?? "không chỉnh được"
        print("    âm lượng tổng: \(vol)\(ZAudioHAL.isMuted(defOut, output: true) ? ", đang tắt tiếng" : "")")
        guard #available(macOS 14.2, *) else { return }
        let running = NSWorkspace.shared.runningApplications
        let procs = ZAudioHAL.processObjects()
        let playing = procs.filter(ZAudioHAL.isRunningOutput)
        print("    tiến trình âm thanh: \(procs.count), đang phát: \(playing.count)")
        for obj in playing {
            let pid = ZAudioHAL.pid(obj)
            let bid = ZAudioHAL.bundleID(obj) ?? "?"
            let owner = ZAudioResponsible.owner(of: pid, bundleID: bid, in: running)
            print("      pid \(pid) \(bid) -> \(owner?.localizedName ?? "không rõ app") (responsible \(ZAudioResponsible.pid(for: pid)))")
        }
    }
}

// MARK: - Views

private struct AudioSettingsSections: View {
    let m: AudioModule

    var body: some View {
        if m.permissionDenied {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Chưa có quyền ghi âm thanh hệ thống", "System audio recording isn't allowed"))
                            .font(.headline)
                        Text(L("Để chỉnh âm lượng từng app, hãy bật zMac trong Quyền riêng tư, mục Ghi âm thanh hệ thống, rồi chỉnh lại.",
                               "To change per-app volume, allow zMac under Privacy, System Audio Recording, then adjust again."))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(L("Mở Cài đặt", "Open Settings")) { m.openPrivacySettings() }
                }
            }
        }

        Section(L("Đầu ra", "Output")) {
            Picker(L("Loa", "Device"), selection: Binding(get: { m.outputID }, set: { m.setOutputDevice($0) })) {
                ForEach(m.outputs) { Text($0.name).tag($0.id) }
            }
            if m.outputHasVolume {
                AudioMasterRow(m: m)
            } else {
                Text(L("Thiết bị này không cho chỉnh âm lượng.", "This device has no volume control."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }

        Section(L("Đầu vào", "Input")) {
            Picker(L("Micro", "Device"), selection: Binding(get: { m.inputID }, set: { m.setInputDevice($0) })) {
                ForEach(m.inputs) { Text($0.name).tag($0.id) }
            }
            if m.inputHasVolume {
                HStack {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary).frame(width: 20)
                    Slider(value: Binding(get: { Double(m.inputVolume) }, set: { m.setInputVolume(Float($0)) }), in: 0...1)
                    Text("\(Int((m.inputVolume * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
        }

        Section {
            if m.apps.isEmpty {
                Text(L("Chưa có app nào đang phát âm thanh.", "No app is playing audio right now."))
                    .foregroundStyle(.secondary)
            }
            ForEach(m.apps) { app in AudioAppRow(m: m, app: app, compact: false) }
        } header: {
            Text(L("Từng app", "Per app"))
        } footer: {
            Text(L("App ở 100%, không tắt tiếng và theo loa hệ thống thì phát thẳng như bình thường, zMac không xử lý âm thanh của nó. Lần đầu chỉnh, macOS sẽ hỏi quyền ghi âm thanh hệ thống.",
                   "Apps at 100%, unmuted and on the system output play directly; zMac doesn't process their audio. The first time you adjust one, macOS asks for system audio recording permission."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AudioMasterRow: View {
    let m: AudioModule

    var body: some View {
        HStack {
            Button { m.toggleOutputMute() } label: {
                Image(systemName: m.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help(m.outputMuted ? L("Bật tiếng", "Unmute") : L("Tắt tiếng", "Mute"))
            Slider(value: Binding(get: { Double(m.outputVolume) }, set: { m.setOutputVolume(Float($0)) }), in: 0...1)
            Text("\(Int((m.outputVolume * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}

private struct AudioAppRow: View {
    let m: AudioModule
    let app: ZAudioApp
    let compact: Bool

    var body: some View {
        let s = m.setting(app.id)
        let shown = s.muted ? 0 : s.gain
        HStack(spacing: 8) {
            Group {
                if let icon = m.icon(for: app) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable()
                }
            }
            .frame(width: 18, height: 18)
            Text(app.name)
                .lineLimit(1)
                .frame(width: compact ? 78 : 120, alignment: .leading)
                .foregroundStyle(app.active ? .primary : .secondary)
            Button { m.toggleMute(app.id) } label: {
                Image(systemName: s.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(s.muted ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(s.muted ? L("Bật tiếng", "Unmute") : L("Tắt tiếng", "Mute"))
            Slider(value: Binding(get: { Double(shown) }, set: { m.setGain(Float($0), for: app.id) }),
                   in: 0...Double(AudioModule.maxGain))
            Text("\(Int((shown * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(shown > 1 ? .orange : .primary)
                .frame(width: 44, alignment: .trailing)
            if !compact {
                Menu {
                    Button { m.setDevice(nil, for: app.id) } label: {
                        if s.deviceUID == nil { Label(L("Theo hệ thống", "Follow system"), systemImage: "checkmark") }
                        else { Text(L("Theo hệ thống", "Follow system")) }
                    }
                    Divider()
                    ForEach(m.outputs) { d in
                        Button { m.setDevice(d.uid, for: app.id) } label: {
                            if s.deviceUID == d.uid { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                        }
                    }
                } label: {
                    Image(systemName: s.deviceUID == nil ? "hifispeaker" : "hifispeaker.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Loa cho app này", "Output for this app"))
                Button { m.reset(app.id) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .disabled(s.isDefault)
                    .help(L("Về mặc định", "Reset"))
            }
        }
    }
}

private struct AudioQuickView: View {
    let m: AudioModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu(m.outputName) {
                ForEach(m.outputs) { d in
                    Button { m.setOutputDevice(d.id) } label: {
                        if d.id == m.outputID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if m.outputHasVolume { AudioMasterRow(m: m) }
            ForEach(Array(m.apps.filter(\.active).prefix(5))) { app in
                AudioAppRow(m: m, app: app, compact: true)
            }
            if m.permissionDenied {
                Button(L("Cấp quyền ghi âm thanh hệ thống…", "Allow system audio recording…")) { m.openPrivacySettings() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}
