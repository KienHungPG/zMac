import CoreGraphics
import Testing
import ZMacShared
@testable import zMac

// Test phần logic thuần: quyết định chặn sạc (chạy bằng root, sai là hại pin) và hình học chia cửa sổ.

private func battery(_ percent: Int, plugged: Bool = true, temp: Double = 30, full: Bool = false) -> BatterySnapshot {
    BatterySnapshot(percent: percent, isCharging: plugged && percent < 100, externalConnected: plugged, fullyCharged: full,
                    temperature: temp, cycleCount: 100, designCapacity: 5000, maxCapacity: 4500, adapterWatts: 45,
                    timeRemaining: nil)
}

private func policy(_ change: (inout BatteryPolicy) -> Void = { _ in }) -> BatteryPolicy {
    var p = BatteryPolicy()
    p.enabled = true
    p.limit = 80
    p.sailingDelta = 5
    change(&p)
    return p
}

private func decide(_ p: BatteryPolicy, _ b: BatterySnapshot, inhibited: Bool = false, heat: Bool = false,
                    sleeping: Bool = false, adapter: Bool = true) -> ChargeDecision {
    ChargeLogic.decide(policy: p, battery: b, currentlyInhibited: inhibited, heatLatched: heat,
                       sleeping: sleeping, canDisableAdapter: adapter)
}

@Suite("Quyết định sạc")
struct ChargeLogicTests {
    @Test func offNeverInhibits() {
        let d = decide(policy { $0.enabled = false }, battery(95))
        #expect(!d.inhibit && !d.adapterOff && d.reason == "off")
    }

    @Test func stopsAtLimit() {
        #expect(decide(policy(), battery(80)).inhibit)
        #expect(decide(policy(), battery(92)).inhibit)
        #expect(!decide(policy(), battery(60)).inhibit)
    }

    @Test func sailingKeepsCurrentState() {
        // 77% nằm giữa 75 và 80: giữ nguyên trạng thái trước đó.
        #expect(decide(policy(), battery(77), inhibited: true).inhibit)
        #expect(!decide(policy(), battery(77), inhibited: false).inhibit)
        #expect(decide(policy(), battery(77), inhibited: true).reason == "sailing")
        // Chạm 75% thì cho sạc lại.
        #expect(!decide(policy(), battery(75), inhibited: true).inhibit)
    }

    @Test func limit100NeverInhibits() {
        #expect(!decide(policy { $0.limit = 100 }, battery(100)).inhibit)
    }

    @Test func heatHasHysteresis() {
        let p = policy { $0.heatProtection = true; $0.maxTemperature = 35 }
        let hot = decide(p, battery(50, temp: 36))
        #expect(hot.inhibit && hot.heatLatched && hot.reason == "heat")
        // 34°C: vẫn trong khoảng trễ 2°C nên vẫn chặn.
        #expect(decide(p, battery(50, temp: 34), heat: true).inhibit)
        // 32.9°C: hết trễ, cho sạc.
        let cool = decide(p, battery(50, temp: 32.9), heat: true)
        #expect(!cool.inhibit && !cool.heatLatched)
    }

    @Test func dischargeOnlyWhenPluggedAboveLimitWithAdapterKey() {
        let p = policy { $0.dischargeToLimit = true }
        #expect(decide(p, battery(90)).adapterOff)
        #expect(!decide(p, battery(80)).adapterOff)
        #expect(!decide(p, battery(90, plugged: false)).adapterOff)
        #expect(!decide(p, battery(90), adapter: false).adapterOff)
    }

    @Test func sleepNearLimitInhibitsButLowBatteryStillCharges() {
        let near = decide(policy(), battery(78), sleeping: true)
        #expect(near.inhibit && near.reason == "sleep")
        let low = decide(policy(), battery(30), sleeping: true)
        #expect(!low.inhibit)
        // Không bao giờ ngắt adapter khi ngủ.
        let p = policy { $0.dischargeToLimit = true; $0.inhibitDuringSleep = false }
        let d = decide(p, battery(90), sleeping: true)
        #expect(!d.adapterOff && d.inhibit)
    }

    @Test func topUpChargesThenFinishes() {
        let p = policy { $0.topUp = true }
        let charging = decide(p, battery(85))
        #expect(!charging.inhibit && charging.reason == "topup" && !charging.finishTopUp)
        let done = decide(p, battery(100, full: true))
        #expect(done.finishTopUp && done.inhibit)
    }

    @Test func policyIsClamped() {
        var p = BatteryPolicy()
        p.limit = 5
        p.sailingDelta = 90
        p.maxTemperature = 99
        let c = p.clamped()
        #expect(c.limit == 20 && c.sailingDelta == 20 && c.maxTemperature == 50)
    }
}

@Suite("Hình học chia cửa sổ")
struct SnapGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let window = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func halvesWithoutGap() {
        #expect(SnapGeometry.rect(.leftHalf, in: screen, current: window, gap: 0) == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(SnapGeometry.rect(.rightHalf, in: screen, current: window, gap: 0) == CGRect(x: 600, y: 0, width: 600, height: 800))
        #expect(SnapGeometry.rect(.topHalf, in: screen, current: window, gap: 0) == CGRect(x: 0, y: 400, width: 1200, height: 400))
    }

    @Test func gapIsAppliedOutsideAndBetween() {
        let l = SnapGeometry.rect(.leftHalf, in: screen, current: window, gap: 10)!
        let r = SnapGeometry.rect(.rightHalf, in: screen, current: window, gap: 10)!
        #expect(l.minX == 10 && l.minY == 10 && l.height == 780)
        #expect(r.maxX == 1190)
        #expect(r.minX - l.maxX == 10)
    }

    @Test func repeatCyclesHalfTwoThirdsThird() {
        let w0 = SnapGeometry.rect(.leftHalf, in: screen, current: window, gap: 0, step: 0)!.width
        let w1 = SnapGeometry.rect(.leftHalf, in: screen, current: window, gap: 0, step: 1)!.width
        let w2 = SnapGeometry.rect(.leftHalf, in: screen, current: window, gap: 0, step: 2)!.width
        #expect(w0 == 600 && abs(w1 - 800) < 0.01 && abs(w2 - 400) < 0.01)
    }

    @Test func thirdsCoverTheScreen() {
        let a = SnapGeometry.rect(.firstThird, in: screen, current: window, gap: 0)!
        let b = SnapGeometry.rect(.centerThird, in: screen, current: window, gap: 0)!
        let c = SnapGeometry.rect(.lastThird, in: screen, current: window, gap: 0)!
        #expect(a.minX == 0 && abs(a.maxX - b.minX) < 0.01 && abs(b.maxX - c.minX) < 0.01 && abs(c.maxX - 1200) < 0.01)
        let two = SnapGeometry.rect(.firstTwoThirds, in: screen, current: window, gap: 0)!
        #expect(abs(two.width - 800) < 0.01)
    }

    @Test func portraitThirdsAreVertical() {
        let tall = CGRect(x: 0, y: 0, width: 800, height: 1200)
        let first = SnapGeometry.rect(.firstThird, in: tall, current: window, gap: 0)!
        #expect(first.width == 800 && abs(first.height - 400) < 0.01 && abs(first.maxY - 1200) < 0.01)
    }

    @Test func centerKeepsSize() {
        let c = SnapGeometry.rect(.center, in: screen, current: window, gap: 0)!
        #expect(c.size == window.size && c.midX == 600 && c.midY == 400)
    }

    @Test func largerIsClampedToScreen() {
        let big = CGRect(x: 0, y: 0, width: 1190, height: 790)
        let r = SnapGeometry.rect(.larger, in: screen, current: big, gap: 0)!
        #expect(screen.contains(r))
    }

    @Test func moveBetweenScreensKeepsProportions() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 0, width: 2000, height: 1600)
        let moved = SnapGeometry.move(CGRect(x: 0, y: 0, width: 500, height: 800), from: a, to: b)
        #expect(moved == CGRect(x: 1000, y: 0, width: 1000, height: 1600))
    }
}
