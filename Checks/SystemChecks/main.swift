// System module checks. Run: swift run SystemChecks
// Pure helper checks use fixtures; the smoke test runs the monitor read-only on this Mac for ~3 s.

import CoreGraphics
import Foundation
import IOKit.ps
import LidlightKit
import LidlightSystem
import TestKit


let t = TestRun("System")

func battery(current: Int, max: Int = 100, charging: Bool, state: String) -> [String: Any] {
    [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: max,
     kIOPSIsChargingKey: charging, kIOPSPowerSourceStateKey: state]
}

t.test("battery discharging") {
    let r = BatteryReading.make(descriptions: [battery(current: 42, charging: false, state: kIOPSBatteryPowerValue)],
                                providingSourceType: kIOPSBatteryPowerValue)
    t.expectEqual(r, BatteryReading(percent: 42, isCharging: false, onBattery: true))
}
t.test("battery charging on AC, percent from capacity ratio") {
    let r = BatteryReading.make(descriptions: [battery(current: 3000, max: 6000, charging: true, state: kIOPSACPowerValue)],
                                providingSourceType: kIOPSACPowerValue)
    t.expectEqual(r, BatteryReading(percent: 50, isCharging: true, onBattery: false))
}
t.test("battery full on AC, not charging") {
    let r = BatteryReading.make(descriptions: [battery(current: 100, charging: false, state: kIOPSACPowerValue)],
                                providingSourceType: nil)
    t.expectEqual(r, BatteryReading(percent: 100, isCharging: false, onBattery: false))
}
t.test("no battery") {
    t.expectEqual(BatteryReading.make(descriptions: [], providingSourceType: kIOPSACPowerValue), .none)
    let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 100]
    t.expectEqual(BatteryReading.make(descriptions: [ups], providingSourceType: nil), .none)
}
t.test("zero max capacity gives nil percent") {
    let r = BatteryReading.make(descriptions: [battery(current: 5, max: 0, charging: false, state: kIOPSACPowerValue)],
                                providingSourceType: nil)
    t.expectEqual(r.percent, nil)
}
t.test("display asleep rules") {
    t.expect(!MacHardware.isBuiltInAsleep(builtIn: 1, active: [1, 2], reportsAsleep: false))
    t.expect(MacHardware.isBuiltInAsleep(builtIn: 1, active: [1], reportsAsleep: true))
    t.expect(MacHardware.isBuiltInAsleep(builtIn: 1, active: [2], reportsAsleep: false), "lid closed, external only")
    t.expect(!MacHardware.isBuiltInAsleep(builtIn: nil, active: [2], reportsAsleep: false), "no built-in display")
}
t.test("session lock dictionary") {
    t.expect(SystemReaders.isScreenLocked(sessionDictionary: ["CGSSessionScreenIsLocked": true]))
    t.expect(SystemReaders.isScreenLocked(sessionDictionary: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]))
    t.expect(!SystemReaders.isScreenLocked(sessionDictionary: ["CGSSessionScreenIsLocked": false]))
    t.expect(!SystemReaders.isScreenLocked(sessionDictionary: [:]))
    t.expect(!SystemReaders.isScreenLocked(sessionDictionary: nil))
}

final class LitProbe: KeyboardBacklightProbing {
    func isBuiltInKeyboardLit() -> Bool { true }
}

t.test("live smoke test (read-only, ~3 s)") {
    let monitor = SystemMonitor(keyboardProbe: LitProbe())
    var emissions = 0
    monitor.start { _ in emissions += 1 }
    monitor.start { _ in t.fail("second start must be ignored") }
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    let s = monitor.status
    print("    status: \(s)")
    print("    emissions: \(emissions)")
    t.expect(emissions >= 1)
    t.expect(!s.lidClosed, "lid should be open while running this")
    if let p = s.batteryPercent { t.expect((0...100).contains(p), "battery \(p)") }
    t.expect(s.userIdleSeconds >= 0)
    t.expectEqual(s.userIdleSeconds, s.userIdleSeconds.rounded())
    t.expect(s.keyboardBacklightLit, "probe is sampled")
    monitor.stop()
    monitor.stop()
    let before = emissions
    RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    t.expectEqual(emissions, before, "no emissions after stop")
}

t.finish()
