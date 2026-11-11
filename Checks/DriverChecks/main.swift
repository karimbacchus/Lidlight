// Driver module checks. Run: swift run DriverChecks            (no hardware)
//                          swift run DriverChecks --hardware   (also exercises the real logo; restores everything)

import Foundation
import TestKit
import LidlightKit
import LidlightDriver

let t = TestRun("Driver")
let runHardware = CommandLine.arguments.contains("--hardware")

// MARK: Fake corebrightnessd

final class FakeTransport: LogoPropertyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [
        LogoKey.backlightMode: NSNumber(value: 2),
        LogoKey.state: ["FinalNits": 500.0, "Factor": 1.0, "AppliedNits": 500.0] as [String: Any],
        LogoKey.mapping: LogoTables.appleDefaults.mapping.propertyListValue,
        LogoKey.minRestriction: LogoTables.appleDefaults.minRestriction.propertyListValue,
        LogoKey.maxRestriction: LogoTables.appleDefaults.maxRestriction.propertyListValue,
    ]
    private(set) var writes: [(key: String, value: Any)] = []

    func property(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func setProperty(_ value: Any, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes.append((key, value))
        values[key] = value
        return true
    }

    func writes(to key: String) -> [Any] {
        lock.lock(); defer { lock.unlock() }
        return writes.filter { $0.key == key }.map(\.value)
    }
}

func tempMarkerURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lidlight-check-\(UUID().uuidString)/marker.json")
}

func intValues(_ values: [Any]) -> [Int] { values.compactMap { ($0 as? NSNumber)?.intValue } }

// MARK: Tables

t.test("table validation") {
    t.expect(LogoTables.appleDefaults.validationProblem == nil)
    t.expect(!NitsTable([(0, 1)]).isValid)
    t.expect(!NitsTable([(0, 1), (0, 2)]).isValid)
    t.expect(!NitsTable([(0, 1), (5, -2)]).isValid)
    t.expect(!NitsTable([(0, 1), (5, .nan)]).isValid)
}

t.test("table wire format round trip and interpolation") {
    let table = LogoTables.appleDefaults.mapping
    let decoded = NitsTable(propertyListValue: table.propertyListValue as NSArray)
    t.expect(decoded?.isClose(to: table) == true)
    t.expectClose(table.value(at: 25), 12.5 + (28.62 - 12.5) * (25 - 16.84) / (34.12 - 16.84), tolerance: 0.01)
    t.expectClose(table.value(at: 5000), 1000, tolerance: 0.001)
    t.expect(NitsTable(propertyListValue: "nope") == nil)
}

t.test("LEPWMState decoding") {
    let state = LogoState(propertyList: [
        "FinalNits": 612.5, "AppliedNits": 700.0, "Factor": 0.875, "DisplayNits": 400.0, "Lux": 190.0,
        "MinNitsRestriction": 150.0, "MaxNitsRestriction": 1000.0, "PWMNitsPreRestriction": 650.0, "NitsMultiplier": 1.0,
    ] as [String: Any])
    t.expectClose(state?.finalNits ?? -1, 612.5, tolerance: 1e-9)
    t.expectClose(state?.factor ?? -1, 0.875, tolerance: 1e-9)
    t.expectClose(state?.minRestrictionNits ?? -1, 150, tolerance: 1e-9)
    t.expect(LogoState(propertyList: ["FinalNits": 1.0] as [String: Any]) == nil)
    t.expect(LogoState(propertyList: nil) == nil)
}

// MARK: Simulated driver

final class VirtualClock: @unchecked Sendable {
    var now = 100.0
}

t.test("simulated: pipeline from tables, power") {
    let driver = SimulatedLogoDriver()
    // Apple defaults: mapping(500) = 300 + (1000-300)*(200/300) = 766.7; min(300) = 300; max(300) = 1000.
    t.expectClose(driver.readState()?.finalNits ?? 0, 766.67, tolerance: 0.1)
    try driver.writeTables(LogoTables(mapping: .flat(200), minRestriction: .flat(0), maxRestriction: .flat(1000)))
    t.expectClose(driver.readState()?.finalNits ?? 0, 200, tolerance: 0.01)
    try driver.setPower(.off)
    t.expectEqual(driver.readPower(), .off)
    t.expectClose(driver.previewLevel(), 0, tolerance: 1e-9)
    try driver.setPower(.on)
    t.expectClose(driver.previewLevel(), 0.2, tolerance: 1e-3)
    try driver.restoreSystemDefaults(powerOn: true)
    t.expect(driver.readTables() == LogoTables.appleDefaults)
}

t.test("simulated: rejects invalid tables") {
    let driver = SimulatedLogoDriver()
    var threw = false
    do { try driver.writeTables(LogoTables(mapping: NitsTable([(0, 1)]), minRestriction: .flat(0), maxRestriction: .flat(1))) } catch { threw = true }
    t.expect(threw)
}

t.test("simulated: factor ramp follows the model against the clock") {
    let clock = VirtualClock()
    let driver = SimulatedLogoDriver(clock: { clock.now })
    try driver.writeTables(LogoTables(mapping: .flat(1000), minRestriction: .flat(0), maxRestriction: .flat(1000)))
    try driver.setFadeDuration(2)
    try driver.setFactorTarget(.dark)
    let model = FactorRampModel.measured
    clock.now += 0.5
    t.expectClose(driver.readState()?.factor ?? -1, model.factor(from: 1, toward: 0, duration: 2, elapsed: 0.5), tolerance: 1e-9)
    t.expectClose(driver.previewLevel(), (driver.readState()?.finalNits ?? -1) / 1000, tolerance: 1e-9)
    clock.now += 2
    t.expectClose(driver.previewLevel(), 0, tolerance: 1e-9)
}

t.test("simulated: reversal continues from the current factor; fade changes and repeats do not touch a ramp in flight") {
    let clock = VirtualClock()
    let driver = SimulatedLogoDriver(clock: { clock.now })
    try driver.setFadeDuration(2)
    try driver.setFactorTarget(.dark)
    clock.now += 0.5
    let mid = driver.readState()?.factor ?? -1
    try driver.setFadeDuration(0.3)
    try driver.setFactorTarget(.dark)
    t.expectClose(driver.readState()?.factor ?? -1, mid, tolerance: 1e-9)
    clock.now += 0.1
    t.expectClose(driver.readState()?.factor ?? -1,
                  FactorRampModel.measured.factor(from: 1, toward: 0, duration: 2, elapsed: 0.6), tolerance: 1e-9)
    let before = driver.readState()?.factor ?? -1
    try driver.setFactorTarget(.lit)
    t.expectClose(driver.readState()?.factor ?? -1, before, tolerance: 1e-9)
    clock.now += 0.15
    t.expectClose(driver.readState()?.factor ?? -1,
                  FactorRampModel.measured.factor(from: before, toward: 1, duration: 0.3, elapsed: 0.15), tolerance: 1e-9)
}

t.test("simulated: animation gate") {
    let clock = VirtualClock()
    let driver = SimulatedLogoDriver(clock: { clock.now })
    driver.setAnimationAllowed(false)
    try driver.setFadeDuration(1)
    try driver.setFactorTarget(.dark)
    clock.now += 5
    t.expectClose(driver.readState()?.factor ?? -1, 1, tolerance: 1e-9)
    driver.setAnimationAllowed(true)
    try driver.setFactorTarget(.dark)
    clock.now += 5
    t.expectClose(driver.readState()?.factor ?? -1, 0, tolerance: 1e-9)
    try driver.releaseFactor()
    clock.now += 5
    t.expectClose(driver.readState()?.factor ?? -1, 1, tolerance: 1e-9)
}

// MARK: Hardware driver against a fake transport

t.test("driver: refuses unsupported transport") {
    final class Empty: LogoPropertyTransport, @unchecked Sendable {
        func property(forKey key: String) -> Any? { nil }
        func setProperty(_ value: Any, forKey key: String) -> Bool { false }
    }
    t.expect(CoreBrightnessLogoDriver(transport: Empty(), markerURL: tempMarkerURL()) == nil)
}

t.test("driver: power skips unchanged and defers writes inside the interval, latest wins") {
    let fake = FakeTransport()
    guard let driver = CoreBrightnessLogoDriver(transport: fake, markerURL: tempMarkerURL(), powerInterval: 0.3, tableInterval: 0.3) else {
        return t.fail("no driver")
    }
    try driver.setPower(.on)
    t.expectEqual(fake.writes(to: LogoKey.backlightMode).count, 0)
    try driver.setPower(.off)
    try driver.setPower(.on)   // too soon: deferred
    try driver.setPower(.off)  // latest wins
    t.expectEqual(intValues(fake.writes(to: LogoKey.backlightMode)), [0])
    Thread.sleep(forTimeInterval: 0.1)
    try driver.setPower(.on)
    Thread.sleep(forTimeInterval: 0.6)
    t.expectEqual(intValues(fake.writes(to: LogoKey.backlightMode)), [0, 2])
    t.expectEqual(driver.readPower(), .on)
}

t.test("driver: tables validated, unchanged skipped, coalesced with the latest value written") {
    let fake = FakeTransport()
    let url = tempMarkerURL()
    guard let driver = CoreBrightnessLogoDriver(transport: fake, markerURL: url, powerInterval: 0.3, tableInterval: 0.3) else {
        return t.fail("no driver")
    }
    try driver.writeTables(.appleDefaults)
    t.expectEqual(fake.writes.count, 0)
    t.expect(!FileManager.default.fileExists(atPath: url.path), "no marker without modification")
    var threw = false
    do { try driver.writeTables(LogoTables(mapping: NitsTable([(5, 1), (1, 2)]), minRestriction: .flat(0), maxRestriction: .flat(1))) } catch { threw = true }
    t.expect(threw)
    func tables(_ nits: Double) -> LogoTables { LogoTables(mapping: .flat(nits), minRestriction: .flat(0), maxRestriction: .flat(1000)) }
    try driver.writeTables(tables(100))
    t.expectEqual(fake.writes(to: LogoKey.mapping).count, 1)
    t.expect(FileManager.default.fileExists(atPath: url.path), "marker written before the first modification")
    try driver.writeTables(tables(200))
    try driver.writeTables(tables(300))
    t.expectEqual(fake.writes(to: LogoKey.mapping).count, 1)
    Thread.sleep(forTimeInterval: 0.6)
    t.expectEqual(fake.writes(to: LogoKey.mapping).count, 2)
    t.expect(driver.readTables()?.mapping.isClose(to: .flat(300)) == true)
    // min/max were identical in all three requests: written once.
    t.expectEqual(fake.writes(to: LogoKey.minRestriction).count, 1)
    try driver.restoreSystemDefaults(powerOn: false)
    t.expect(driver.readTables() == LogoTables.appleDefaults || driver.readTables()?.mapping.isClose(to: LogoTables.appleDefaults.mapping) == true)
    t.expect(!FileManager.default.fileExists(atPath: url.path), "marker removed after clean restore")
}

t.test("driver: animation channel, gate, dirty marker flags") {
    let fake = FakeTransport()
    let url = tempMarkerURL()
    guard let driver = CoreBrightnessLogoDriver(transport: fake, markerURL: url) else { return t.fail("no driver") }
    try driver.setFadeDuration(nil)
    t.expectEqual(fake.writes(to: LogoKey.factorFadeDuration).count, 1)
    try driver.setFadeDuration(nil)
    t.expectEqual(fake.writes(to: LogoKey.factorFadeDuration).count, 1, "identical consecutive values skipped")
    t.expect(!FileManager.default.fileExists(atPath: url.path))
    try driver.setFadeDuration(1.5)
    try driver.setFactorTarget(.dark)
    try driver.setFactorTarget(.dark)
    t.expectEqual(intValues(fake.writes(to: LogoKey.displayLogicalState)), [1, 1], "targets are not deduplicated")
    t.expectEqual(fake.writes(to: LogoKey.userActivityUpdate).count, 2, "every Blank is followed by a keyboard restore")
    t.expectEqual(fake.writes.suffix(3).map(\.key),
                  [LogoKey.displayLogicalState, LogoKey.userActivityUpdate, LogoKey.keyboardSuspendDimming],
                  "the restore comes straight after the Blank")
    t.expectEqual((fake.writes.last?.value as? NSNumber)?.boolValue, false, "suspend-dimming keeps its value")
    let marker = DirtyMarker.read(from: url)
    t.expectEqual(marker?.factorModified, true)
    t.expectEqual(marker?.tablesModified, false)
    t.expectEqual(marker?.pid, getpid())
    driver.setAnimationAllowed(false)
    let count = fake.writes.count
    try driver.setFadeDuration(3)
    try driver.setFactorTarget(.lit)
    t.expectEqual(fake.writes.count - count, 0, "gate closed: no writes")
    driver.setAnimationAllowed(true)
    try driver.setFactorTarget(.dark)
    try driver.releaseFactor()
    t.expectEqual(intValues(fake.writes(to: LogoKey.displayLogicalState)).last, 2)
    t.expectEqual(fake.writes(to: LogoKey.userActivityUpdate).count, 3, "Unblank needs no keyboard restore")
    t.expectEqual(((fake.writes(to: LogoKey.factorFadeDuration).last) as? NSNumber)?.doubleValue, 0)
    try driver.restoreSystemDefaults(powerOn: true)
    t.expect(!FileManager.default.fileExists(atPath: url.path))
}

t.test("driver: previewLevel is cached and refreshes in the background") {
    let fake = FakeTransport()
    guard let driver = CoreBrightnessLogoDriver(transport: fake, markerURL: tempMarkerURL()) else { return t.fail("no driver") }
    _ = driver.previewLevel()
    Thread.sleep(forTimeInterval: 0.25)
    t.expectClose(driver.previewLevel(), 0.5, tolerance: 1e-9)
}

// MARK: Safety recovery and guardian

t.test("recovery: restores when a stale marker exists, never touches power") {
    let url = tempMarkerURL()
    let fake = FakeTransport()
    guard let driver = CoreBrightnessLogoDriver(transport: fake, markerURL: url, powerInterval: 0, tableInterval: 0) else { return t.fail("no driver") }
    try driver.writeTables(LogoTables(mapping: .flat(50), minRestriction: .flat(0), maxRestriction: .flat(1000)))
    t.expect(SafetyRecovery.recover(driver: driver, markerURL: url, requireOwnerExit: false))
    t.expect(driver.readTables()?.mapping.isClose(to: LogoTables.appleDefaults.mapping) == true)
    t.expectEqual(fake.writes(to: LogoKey.backlightMode).count, 0)
    t.expect(!SafetyRecovery.recover(driver: driver, markerURL: url, requireOwnerExit: false), "no marker, nothing to do")
}

t.test("recovery: a marker owned by a live foreign process is left alone") {
    let url = tempMarkerURL()
    try DirtyMarker(pid: getppid(), since: Date(), tablesModified: true, factorModified: false).write(to: url)
    t.expect(!SafetyRecovery.recover(driver: SimulatedLogoDriver(), markerURL: url, requireOwnerExit: true))
    t.expect(SafetyRecovery.recover(driver: SimulatedLogoDriver(), markerURL: url, requireOwnerExit: false))
}

t.test("guardian launch: child sees EOF when the parent closes its end") {
    guard let spawned = GuardianLauncher.spawn(helperURL: URL(fileURLWithPath: "/bin/cat"), arguments: []) else {
        return t.fail("cannot spawn")
    }
    t.expect(spawned.process.isRunning)
    try spawned.stdin.close()
    let deadline = Date().addingTimeInterval(3)
    while spawned.process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    t.expect(!spawned.process.isRunning, "child exited on EOF")
}

// MARK: Ramp fitting

t.test("ramp fit recovers k from synthetic data") {
    let model = FactorRampModel(k: 6)
    let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { u in
        (t: u, factor: model.factor(from: 1, toward: 0, duration: 1, elapsed: u))
    }
    let recording = RampRecording(duration: 1, target: .dark, startFactor: 1, samples: samples)
    t.expectClose(RampFit.fitK([recording]) ?? 0, 6, tolerance: 0.1)
    t.expectClose(recording.settleTime() ?? 9, 0.76, tolerance: 0.1)
}

// MARK: CLI parsing

func parsed(_ arguments: [String]) -> DriverCommand? { try? DriverCLI.parse(arguments) }

t.test("CLI parsing") {
    t.expectEqual(parsed([]), .help)
    t.expectEqual(parsed(["status", "--json"]), .status(json: true))
    t.expectEqual(parsed(["status"]), .status(json: false))
    t.expectEqual(parsed(["on"]), .on)
    t.expectEqual(parsed(["off"]), .off)
    t.expectEqual(parsed(["level", "250"]), .level(nits: 250))
    t.expectEqual(parsed(["restore", "--on"]), .restore(powerOn: true))
    t.expectEqual(parsed(["fade", "dark", "1.5"]), .fade(.dark, seconds: 1.5))
    t.expectEqual(parsed(["fade", "lit"]), .fade(.lit, seconds: nil))
    t.expectEqual(parsed(["measure-ramp"]), .measureRamp(durations: [0.3, 1, 2, 4]))
    t.expectEqual(parsed(["measure-ramp", "0.5", "3"]), .measureRamp(durations: [0.5, 3]))
    t.expectEqual(parsed(["guard", "--parent-pid", "42"]), .guardian(parentPID: 42))
    for bad in [["level"], ["level", "-3"], ["level", "5000"], ["level", "abc"], ["fade"], ["fade", "grey"],
                ["fade", "dark", "0"], ["on", "now"], ["guard"], ["guard", "--parent-pid", "x"], ["bogus"],
                ["measure-ramp", "-1"]] {
        var threw = false
        do { _ = try DriverCLI.parse(bad) } catch { threw = true }
        t.expect(threw, "\(bad) should be rejected")
    }
}

// MARK: Hardware (opt-in)

if runHardware {
    t.test("hardware: read-only pipeline and power round trip is restored") {
        guard let driver = CoreBrightnessLogoDriver() else { return t.fail("no logo on this Mac") }
        t.expect(driver.readState() != nil)
        t.expectEqual(driver.readPower(), .on)
        defer { try? driver.restoreSystemDefaults(powerOn: true) }
        guard AnimationEnvironment.isPossible() else {
            print("    (display asleep or lid closed: animation part skipped)")
            return
        }
        try driver.setFadeDuration(0.3)
        try driver.setFactorTarget(.dark)
        Thread.sleep(forTimeInterval: 0.6)
        t.expectClose(driver.readState()?.factor ?? -1, 0, tolerance: 0.02)
        try driver.releaseFactor()
        Thread.sleep(forTimeInterval: 0.6)
        t.expectClose(driver.readState()?.factor ?? -1, 1, tolerance: 0.02)
        try driver.restoreSystemDefaults(powerOn: false)
        t.expect(driver.readTables() != nil)
    }
}

t.finish()
