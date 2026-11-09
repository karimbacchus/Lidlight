import Foundation
import LidlightKit
import LidlightEngine

/// Everything the engine can ask of a driver, in call order.
enum Call: Equatable {
    case power(LogoPower)
    case tables(LogoTables)
    case allowed(Bool)
    case fade(Double?)
    case target(FactorTarget)
    case release
    case restore(powerOn: Bool)
}

/// Records every driver call with a timestamp from the supplied clock.
final class RecordingDriver: LogoDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(time: TimeInterval, call: Call)] = []
    private var power: LogoPower? = .on
    private let timeSource: () -> TimeInterval
    var isSupported = true
    let isSimulated = true

    init(time: @escaping () -> TimeInterval) {
        timeSource = time
    }

    var calls: [(time: TimeInterval, call: Call)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        recorded.removeAll()
    }

    private func record(_ call: Call) {
        lock.lock(); defer { lock.unlock() }
        recorded.append((timeSource(), call))
    }

    func readState() -> LogoState? { nil }
    func readPower() -> LogoPower? { power }
    func readTables() -> LogoTables? { nil }
    func setPower(_ power: LogoPower) throws { self.power = power; record(.power(power)) }
    func writeTables(_ tables: LogoTables) throws { record(.tables(tables)) }
    func setAnimationAllowed(_ allowed: Bool) { record(.allowed(allowed)) }
    func setFadeDuration(_ seconds: Double?) throws { record(.fade(seconds)) }
    func setFactorTarget(_ target: FactorTarget) throws { record(.target(target)) }
    func releaseFactor() throws { record(.release) }
    func restoreSystemDefaults(powerOn: Bool) throws { record(.restore(powerOn: powerOn)) }
}

/// A clock that only moves when `advance` says so.
final class VirtualClock: EngineClock {
    var now: TimeInterval = 1000
    var onWake: (() -> Void)?
    private var wake: TimeInterval?

    func arm(at time: TimeInterval?) { wake = time }

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        var guardCount = 0
        while let due = wake, due <= end {
            guardCount += 1
            precondition(guardCount < 100_000, "engine keeps re-arming without progress")
            now = max(now, due)
            wake = nil
            onWake?()
        }
        now = end
    }
}

/// An engine core on a virtual clock with a recording driver.
final class Rig {
    let clock = VirtualClock()
    let driver: RecordingDriver
    let core: EngineCore
    let origin: TimeInterval
    var statuses: [EngineStatus] = []

    init(supported: Bool = true) {
        let clock = self.clock
        driver = RecordingDriver(time: { clock.now })
        driver.isSupported = supported
        core = EngineCore(driver: driver, clock: clock)
        origin = clock.now
        core.onStatus = { [unowned self] in statuses.append($0) }
    }

    var status: EngineStatus { statuses.last ?? EngineStatus() }
    /// Seconds since the rig was created.
    var elapsed: TimeInterval { clock.now - origin }

    func advance(_ seconds: TimeInterval) { clock.advance(by: seconds) }

    func start(_ mode: LogoMode, isOn: Bool = true, _ configure: (inout EffectSettings) -> Void = { _ in }) {
        var settings = EffectSettings()
        configure(&settings)
        core.start(isOn: isOn, mode: mode, settings: settings)
    }

    func system(_ configure: (inout SystemStatus) -> Void) {
        var s = currentSystem
        configure(&s)
        currentSystem = s
        core.update(system: s)
    }

    private var currentSystem = SystemStatus()

    func agents(_ activity: AgentActivity) {
        core.update(agents: AgentSnapshot(activity: activity, sessions: 1, working: activity == .working ? 1 : 0,
                                          needingYou: activity == .needsYou ? 1 : 0, updatedAt: Date()))
    }

    func beat(strong: Bool = false) {
        core.handleBeat(BeatEvent(uptime: clock.now, strength: 0.8, isStrong: strong))
    }

    /// Factor writes (target and effective fade) in order, with times relative to the rig's start.
    var factorWrites: [Write] {
        var fade: Double?
        var result: [Write] = []
        for (time, call) in driver.calls {
            switch call {
            case .fade(let value): fade = value
            case .target(let target): result.append(Write(time: time - origin, fade: fade ?? 0, target: target))
            default: break
            }
        }
        return result
    }

    func calls(_ matching: (Call) -> Bool) -> [(time: TimeInterval, call: Call)] {
        driver.calls.filter { matching($0.call) }.map { (time: $0.time - origin, call: $0.call) }
    }
}

struct Write: Equatable {
    var time: TimeInterval
    var fade: Double
    var target: FactorTarget
}

/// Re-derives the factor over time from recorded writes with the shared ramp model.
struct FactorTrace {
    let writes: [Write]
    let model = FactorRampModel.measured

    func factor(at time: TimeInterval) -> Double {
        var origin = 1.0, goal = 1.0, start = 0.0, duration = 0.0
        for write in writes where write.time <= time {
            origin = model.factor(from: origin, toward: goal, duration: duration, elapsed: write.time - start)
            goal = write.target == .lit ? 1 : 0
            start = write.time
            duration = write.fade
        }
        return model.factor(from: origin, toward: goal, duration: duration, elapsed: time - start)
    }

    func samples(from: TimeInterval, to: TimeInterval, step: TimeInterval = 0.005) -> [Double] {
        stride(from: from, through: to, by: step).map { factor(at: $0) }
    }
}
