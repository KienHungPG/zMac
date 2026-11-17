import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// Core Audio cho module Âm thanh: hàm tiện ích HAL + tap âm lượng từng app.
// Cách làm (process tap -> aggregate device riêng -> IOProc nhân gain) theo hướng của
// SoundMixer trong notch-app (MIT, github.com/letoan1/notch-app) và mẫu AudioCap của Apple.

struct ZAudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

// MARK: - HAL

enum ZAudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Tên aggregate device của zMac, để lọc khỏi danh sách thiết bị.
    static let tapDeviceName = "zMac Tap"

    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    static func scope(output: Bool) -> AudioObjectPropertyScope {
        output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        guard st == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func objects(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = addr(sel)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func u32(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> UInt32? {
        var a = a
        guard obj != 0, AudioObjectHasProperty(obj, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func devices() -> [ZAudioDevice] {
        objects(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  !name.hasPrefix(tapDeviceName) else { return nil }
            return ZAudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func hasStreams(_ id: AudioDeviceID, output: Bool) -> Bool {
        var a = addr(kAudioDevicePropertyStreams, scope(output: output))
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static func defaultDevice(output: Bool) -> AudioDeviceID {
        var a = addr(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
        return id
    }

    static func setDefaultDevice(_ id: AudioDeviceID, output: Bool) {
        var v = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = addr(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectSetPropertyData(system, &a, 0, nil, size, &v)
        if output {   // âm báo hệ thống đi theo loa mới
            var s = addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(system, &s, 0, nil, size, &v)
        }
    }

    /// Các địa chỉ âm lượng thử lần lượt: virtual main (giữ cân bằng L/R), kênh chính, rồi kênh 1 và 2.
    private static func volumeAddresses(output: Bool) -> [[AudioObjectPropertyAddress]] {
        let sc = scope(output: output)
        return [
            [addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, sc)],
            [addr(kAudioDevicePropertyVolumeScalar, sc)],
            [addr(kAudioDevicePropertyVolumeScalar, sc, 1), addr(kAudioDevicePropertyVolumeScalar, sc, 2)],
        ]
    }

    /// Địa chỉ cần lắng nghe để biết âm lượng / mute của thiết bị đổi.
    static func volumeWatchAddresses(output: Bool) -> [AudioObjectPropertyAddress] {
        volumeAddresses(output: output).flatMap { $0 } + [addr(kAudioDevicePropertyMute, scope(output: output))]
    }

    static func volume(_ id: AudioDeviceID, output: Bool) -> Float? {
        guard id != 0 else { return nil }
        for group in volumeAddresses(output: output) {
            var values: [Float] = []
            for a in group {
                var a = a
                guard AudioObjectHasProperty(id, &a) else { continue }
                var v: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr { values.append(v) }
            }
            if !values.isEmpty { return values.reduce(0, +) / Float(values.count) }
        }
        return nil
    }

    static func setVolume(_ id: AudioDeviceID, output: Bool, _ value: Float) {
        guard id != 0 else { return }
        var v = Float32(min(max(value, 0), 1))
        for group in volumeAddresses(output: output) {
            var done = false
            for a in group {
                var a = a
                var settable = DarwinBoolean(false)
                guard AudioObjectHasProperty(id, &a),
                      AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue else { continue }
                if AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr { done = true }
            }
            if done { return }
        }
    }

    /// Có ít nhất một địa chỉ âm lượng ghi được (loa HDMI thường không có).
    static func canSetVolume(_ id: AudioDeviceID, output: Bool) -> Bool {
        guard id != 0 else { return false }
        return volumeAddresses(output: output).joined().contains { a in
            var a = a
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr
                && settable.boolValue
        }
    }

    static func hasMute(_ id: AudioDeviceID, output: Bool) -> Bool {
        var a = addr(kAudioDevicePropertyMute, scope(output: output))
        var settable = DarwinBoolean(false)
        return id != 0 && AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr
            && settable.boolValue
    }

    static func isMuted(_ id: AudioDeviceID, output: Bool) -> Bool {
        (u32(id, addr(kAudioDevicePropertyMute, scope(output: output))) ?? 0) != 0
    }

    static func setMuted(_ id: AudioDeviceID, output: Bool, _ on: Bool) {
        var a = addr(kAudioDevicePropertyMute, scope(output: output))
        guard id != 0, AudioObjectHasProperty(id, &a) else { return }
        var v: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    // Tiến trình âm thanh (macOS 14.2+).

    static func processObjects() -> [AudioObjectID] {
        guard #available(macOS 14.2, *) else { return [] }
        return objects(system, kAudioHardwarePropertyProcessObjectList)
    }

    static func pid(_ obj: AudioObjectID) -> pid_t {
        guard #available(macOS 14.2, *) else { return 0 }
        var a = addr(kAudioProcessPropertyPID)
        var v = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    static func bundleID(_ obj: AudioObjectID) -> String? {
        guard #available(macOS 14.2, *) else { return nil }
        return string(obj, kAudioProcessPropertyBundleID)
    }

    static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        return (u32(obj, addr(kAudioProcessPropertyIsRunningOutput)) ?? 0) != 0
    }
}

// MARK: - Tiến trình -> app chủ

enum ZAudioResponsible {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    /// API riêng của libSystem: tiến trình "chịu trách nhiệm" (vd. tiến trình GPU của WebKit -> Safari).
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func pid(for pid: pid_t) -> pid_t {
        guard let fn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }

    /// App có giao diện sở hữu tiến trình âm thanh `pid`.
    static func owner(of pid: pid_t, bundleID: String?, in running: [NSRunningApplication]) -> NSRunningApplication? {
        let responsible = Self.pid(for: pid)
        if let app = running.first(where: { $0.processIdentifier == responsible }), app.activationPolicy == .regular {
            return app
        }
        if let app = running.first(where: { $0.processIdentifier == pid }), app.activationPolicy == .regular {
            return app
        }
        // Helper kiểu "com.google.Chrome.helper": ghép theo tiền tố bundle ID.
        guard let bundleID else { return nil }
        return running.first { app in
            guard app.activationPolicy == .regular, let bid = app.bundleIdentifier else { return false }
            return bundleID.hasPrefix(bid + ".")
        }
    }
}

// MARK: - Bộ quản lý tap

/// Giữ các tap đang chạy, mỗi app tối đa một tap. Tạo / huỷ trên hàng đợi riêng
/// (tạo aggregate device mất ~100 ms, không được chặn main thread).
final class ZAudioTapEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zmac.audio.taps", qos: .userInitiated)
    /// Chỉ đụng tới trên `queue`. Giá trị là ZAudioAppTap (macOS 14.2+).
    private var taps: [String: AnyObject] = [:]
    private let lock = NSLock()
    private var activeSnapshot: Set<String> = []
    /// Gọi trên `queue` khi phát hiện thiếu quyền ghi âm thanh hệ thống (tham số: bundle ID).
    var onDenied: ((String) -> Void)?

    /// App đang có tap (đọc từ main thread).
    var activeApps: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return activeSnapshot
    }

    /// needsTap = false hoặc app không còn tiến trình: gỡ tap, app phát thẳng như bình thường.
    func update(app: String, gain: Float, processes: [AudioObjectID], deviceID: AudioDeviceID,
                deviceUID: String?, needsTap: Bool, rebuild: Bool) {
        queue.async { [self] in
            guard #available(macOS 14.2, *) else { return }
            guard needsTap, !processes.isEmpty, deviceID != 0, let deviceUID else {
                remove(app)
                return
            }
            if !rebuild, let tap = taps[app] as? ZAudioAppTap,
               tap.processes == Set(processes), tap.deviceID == deviceID {
                tap.setGain(gain)
                return
            }
            remove(app)
            guard let tap = ZAudioAppTap(processes: processes, deviceID: deviceID, deviceUID: deviceUID, gain: gain) else {
                return
            }
            taps[app] = tap
            publish()
            watchSilence(app: app, tap: tap, processes: processes, attempt: 0)
        }
    }

    /// Không có quyền thì tap chỉ nhận im lặng trong khi app gốc đã bị tắt tiếng.
    /// Kiểm hai lần (2,5 s và 5 s) để không nhầm với trình duyệt vừa dừng phát.
    @available(macOS 14.2, *)
    private func watchSilence(app: String, tap: ZAudioAppTap, processes: [AudioObjectID], attempt: Int) {
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self, weak tap] in
            guard let self, let tap, self.taps[app] === tap, !tap.heardSignal,
                  processes.contains(where: ZAudioHAL.isRunningOutput) else { return }
            if attempt == 0 {
                self.watchSilence(app: app, tap: tap, processes: processes, attempt: 1)
                return
            }
            self.remove(app)
            self.onDenied?(app)
        }
    }

    /// Gỡ toàn bộ, chờ xong mới trả về (khi tắt module / thoát app).
    func removeAll() {
        queue.sync {
            for app in Array(taps.keys) { remove(app) }
        }
    }

    private func remove(_ app: String) {
        guard let tap = taps.removeValue(forKey: app) else { return }
        if #available(macOS 14.2, *) { (tap as? ZAudioAppTap)?.stop() }
        publish()
    }

    private func publish() {
        let keys = Set(taps.keys)
        lock.lock()
        activeSnapshot = keys
        lock.unlock()
    }
}

// MARK: - Tap của một app

@available(macOS 14.2, *)
final class ZAudioAppTap {
    let processes: Set<AudioObjectID>
    let deviceID: AudioDeviceID
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Chia sẻ với luồng real-time, không khoá: [0] gain đích, [1] gain hiện tại, [2] đã nghe thấy tiếng (0/1).
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: 3)

    var heardSignal: Bool { state[2] != 0 }

    init?(processes: [AudioObjectID], deviceID: AudioDeviceID, deviceUID: String, gain: Float) {
        self.processes = Set(processes)
        self.deviceID = deviceID
        state[0] = gain
        state[1] = gain
        state[2] = 0

        // 1. Tap: trộn stereo các tiến trình của app, tắt tiếng đường phát gốc khi đang tap.
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.name = ZAudioHAL.tapDeviceName
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return nil }
        tapID = tap

        var interleaved = true
        var tapBuffers = 1
        var fa = ZAudioHAL.addr(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tap, &fa, 0, nil, &size, &asbd) == noErr {
            interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            tapBuffers = interleaved ? 1 : Int(max(asbd.mChannelsPerFrame, 1))
        }

        // 2. Aggregate device riêng: đồng hồ theo loa đích, tap là đầu vào (bù trôi đồng hồ).
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: ZAudioHAL.tapDeviceName,
            kAudioAggregateDeviceUIDKey: "com.zmac.audio.tap." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &agg) == noErr else { stop(); return nil }
        aggregateID = agg

        // 3. IOProc chạy thẳng trên luồng IO (queue nil): không cấp phát, không khoá.
        let state = self.state
        var proc: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, input, _, output, _ in
            ZAudioAppTap.render(input, output, tapBuffers: tapBuffers, interleaved: interleaved, state: state)
        }
        guard st == noErr, let proc else { stop(); return nil }
        procID = proc
        guard AudioDeviceStart(agg, proc) == noErr else { stop(); return nil }
    }

    func setGain(_ g: Float) { state[0] = g }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        stop()
        state.deallocate()
    }

    /// Chép tiếng của app (các buffer cuối của đầu vào) ra kênh 0/1 của loa, gain đổi tuyến tính trong buffer.
    static func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>,
                               tapBuffers: Int, interleaved: Bool, state: UnsafeMutablePointer<Float>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for i in 0..<outs.count {
            if let d = outs[i].mData { memset(d, 0, Int(outs[i].mDataByteSize)) }
        }
        guard tapBuffers > 0, ins.count >= tapBuffers else { return }
        let first = ins.count - tapBuffers

        // Nguồn trái / phải và bước nhảy giữa hai frame.
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
        if interleaved {
            let b = ins[first]
            guard let d = b.mData else { return }
            let ch = max(Int(b.mNumberChannels), 1)
            stride = ch
            frames = Int(b.mDataByteSize) / (4 * ch)
            left = d.assumingMemoryBound(to: Float.self)
            right = ch > 1 ? left + 1 : left
        } else {
            guard let d = ins[first].mData else { return }
            stride = 1
            frames = Int(ins[first].mDataByteSize) / 4
            left = d.assumingMemoryBound(to: Float.self)
            right = tapBuffers > 1 ? (ins[first + 1].mData?.assumingMemoryBound(to: Float.self) ?? left) : left
        }
        guard frames > 0 else { return }

        if state[2] == 0 {
            var peak: Float = 0
            vDSP_maxmgv(left, vDSP_Stride(stride), &peak, vDSP_Length(frames))
            if peak > 1e-6 { state[2] = 1 }
        }

        let target = state[0]
        let start = state[1]
        state[1] = target
        if target == 0 && start == 0 { return }   // tắt tiếng: đầu ra đã là im lặng
        let step = (target - start) / Float(frames)
        let limit = max(target, start) > 1

        var channel = 0
        for i in 0..<outs.count {
            guard channel < 2 else { break }
            let b = outs[i]
            let ch = max(Int(b.mNumberChannels), 1)
            defer { channel += ch }
            guard let d = b.mData else { continue }
            let out = d.assumingMemoryBound(to: Float.self)
            let n = min(Int(b.mDataByteSize) / (4 * ch), frames)
            let mono = outs.count == 1 && ch == 1
            for c in 0..<min(ch, 2 - channel) {
                let src = channel + c == 0 ? left : right
                var g = start
                for f in 0..<n {
                    var s = mono ? 0.5 * (left[f * stride] + right[f * stride]) : src[f * stride]
                    s *= g
                    if limit { s = softClip(s) }
                    out[f * ch + c] = s
                    g += step
                }
            }
        }
    }

    /// Giữ nguyên dưới 0,8, nén mềm phần vượt để khi tăng quá 100% không bị vỡ tiếng.
    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        let y = 0.8 + 0.2 * tanhf((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }
}
