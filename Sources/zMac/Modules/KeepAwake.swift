import Foundation
import IOKit.pwr_mgt
import Observation
import SwiftUI

/// Giữ máy thức (kiểu Amphetamine). Không bật thì không tốn gì; bật thì giữ một IOPM assertion
/// và một hẹn giờ một lần (không lặp) để tự nhả.
@MainActor @Observable
final class KeepAwakeModule: ZModule {
    static let id = "keepawake"
    static var name: String { L("Giữ máy thức", "Keep Awake") }
    static let replaces = "Amphetamine / caffeinate"
    static let symbol = "cup.and.saucer"
    static var summary: String {
        L("Không cho màn hình tắt và máy ngủ trong khoảng thời gian bạn chọn.",
          "Keeps the display and Mac awake for as long as you choose.")
    }

    private(set) var activeUntil: Date?
    private var assertion: IOPMAssertionID = 0
    private var expiry: DispatchWorkItem?

    var allowDisplaySleep = Pref.bool("keepawake.allowDisplaySleep", false) {
        didSet {
            Pref.set("keepawake.allowDisplaySleep", allowDisplaySleep)
            if isActive { activate(until: activeUntil) }
        }
    }

    var isActive: Bool { assertion != 0 }

    init() {}
    func start() {}
    func stop() { deactivate() }

    func activate(minutes: Int?) {
        activate(until: minutes.map { Date().addingTimeInterval(Double($0) * 60) })
    }

    private func activate(until: Date?) {
        deactivate()
        let type = allowDisplaySleep ? "PreventUserIdleSystemSleep" : "PreventUserIdleDisplaySleep"
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "zMac Keep Awake" as CFString, &id) == kIOReturnSuccess else { return }
        assertion = id
        activeUntil = until
        if let until {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.deactivate() } }
            expiry = w
            DispatchQueue.main.asyncAfter(deadline: .now() + max(until.timeIntervalSinceNow, 1), execute: w)
        }
    }

    func deactivate() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        expiry?.cancel()
        expiry = nil
        activeUntil = nil
    }

    var statusText: String {
        guard isActive else { return L("Tắt", "Off") }
        guard let until = activeUntil else { return L("Bật, không giới hạn", "On, indefinitely") }
        let f = DateFormatter()
        f.timeStyle = .short
        return L("Bật đến ", "On until ") + f.string(from: until)
    }

    static let durations: [(Int?, String)] = [
        (15, "15 min"), (60, "1 h"), (120, "2 h"), (300, "5 h"), (nil, "∞"),
    ]

    func settingsView() -> AnyView {
        moduleForm {
            Section {
                LabeledContent(L("Trạng thái", "Status"), value: statusText)
                HStack {
                    ForEach(Self.durations, id: \.1) { d in
                        Button(d.1) { self.activate(minutes: d.0) }
                    }
                    Spacer()
                    if isActive { Button(L("Tắt", "Stop")) { self.deactivate() } }
                }
                Toggle(L("Cho phép tắt màn hình (chỉ giữ máy không ngủ)", "Allow display sleep (only keep the Mac awake)"),
                       isOn: Binding(get: { self.allowDisplaySleep }, set: { self.allowDisplaySleep = $0 }))
            }
        }
    }

    func quickView() -> AnyView? {
        AnyView(HStack {
            Text(statusText).font(.callout)
            Spacer()
            Menu(isActive ? L("Đổi", "Change") : L("Bật", "Start")) {
                ForEach(Self.durations, id: \.1) { d in
                    Button(d.1) { self.activate(minutes: d.0) }
                }
                if isActive { Divider(); Button(L("Tắt", "Stop")) { self.deactivate() } }
            }
            .fixedSize()
        })
    }
}
