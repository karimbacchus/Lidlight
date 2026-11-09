import Foundation
import LidlightKit

/// In-memory model of the logo pipeline for `--simulate`, previews and checks.
///
/// Models the real pipeline with a fixed simulated display (500 nits, 300 lux): tables apply
/// immediately, power gates the output, and the factor follows `FactorRampModel.measured`
/// against a monotonic clock, so `previewLevel()` animates smoothly when polled at 60 fps.
public final class SimulatedLogoDriver: LogoDriving, LogoPreviewSource, @unchecked Sendable {
    /// Simulated built-in display brightness feeding the mapping table.
    static let displayNits = 500.0
    /// Simulated ambient light feeding the restriction tables.
    static let lux = 300.0
    /// Ramp length when no fade override is set (Apple's own ramps are roughly this long).
    static let defaultFadeDuration = 0.3

    private struct Ramp {
        var start: Double
        var from: Double
        var target: Double
        var duration: Double
    }

    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private let model = FactorRampModel.measured
    private var power: LogoPower = .on
    private var tables = LogoTables.appleDefaults
    private var animationAllowed = true
    private var fadeDuration: Double?
    private var ramp = Ramp(start: 0, from: 1, target: 1, duration: 0)

    public convenience init() {
        self.init(clock: { ProcessInfo.processInfo.systemUptime })
    }

    /// `clock` returns monotonic seconds; checks inject a virtual one.
    package init(clock: @escaping @Sendable () -> TimeInterval) {
        self.clock = clock
    }

    public var isSupported: Bool { true }
    public var isSimulated: Bool { true }

    public func readState() -> LogoState? {
        locked { stateLocked(at: clock()) }
    }

    public func readPower() -> LogoPower? {
        locked { power }
    }

    public func setPower(_ power: LogoPower) throws {
        locked { self.power = power }
    }

    public func readTables() -> LogoTables? {
        locked { tables }
    }

    public func writeTables(_ tables: LogoTables) throws {
        if let problem = tables.validationProblem { throw LogoDriverError.invalidTable(problem) }
        locked { self.tables = tables }
    }

    public func setAnimationAllowed(_ allowed: Bool) {
        locked {
            animationAllowed = allowed
            if !allowed { fadeDuration = nil }
        }
    }

    public func setFadeDuration(_ seconds: Double?) throws {
        locked {
            guard animationAllowed else { return }
            fadeDuration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
    }

    public func setFactorTarget(_ target: FactorTarget) throws {
        locked {
            guard animationAllowed else { return }
            startRampLocked(toward: target == .lit ? 1 : 0)
        }
    }

    public func releaseFactor() throws {
        locked {
            if animationAllowed { startRampLocked(toward: 1) }
            fadeDuration = nil
        }
    }

    public func restoreSystemDefaults(powerOn: Bool) throws {
        locked {
            tables = .appleDefaults
            fadeDuration = nil
            if animationAllowed { startRampLocked(toward: 1) }
            if powerOn { power = .on }
        }
    }

    public func previewLevel() -> Double {
        locked { min(max((stateLocked(at: clock()).finalNits) / LogoLimits.maxNits, 0), 1) }
    }

    // MARK: Pipeline

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// A new ramp starts from the factor as it is right now, with the fade duration in effect at this
    /// moment (changing the duration later does not affect a ramp in flight). Like corebrightnessd,
    /// a repeat of the current target is ignored, so it neither restarts nor re-times the ramp.
    private func startRampLocked(toward target: Double) {
        guard target != ramp.target else { return }
        let now = clock()
        ramp = Ramp(start: now, from: factorLocked(at: now), target: target, duration: fadeDuration ?? Self.defaultFadeDuration)
    }

    private func factorLocked(at now: TimeInterval) -> Double {
        model.factor(from: ramp.from, toward: ramp.target, duration: ramp.duration, elapsed: now - ramp.start)
    }

    private func stateLocked(at now: TimeInterval) -> LogoState {
        let pre = tables.mapping.value(at: Self.displayNits)
        let minNits = tables.minRestriction.value(at: Self.lux)
        let maxNits = tables.maxRestriction.value(at: Self.lux)
        let applied = max(min(pre, maxNits), minNits)
        let factor = factorLocked(at: now)
        return LogoState(
            finalNits: power == .on ? applied * factor : 0,
            appliedNits: applied,
            factor: factor,
            displayNits: Self.displayNits,
            lux: Self.lux,
            minRestrictionNits: minNits,
            maxRestrictionNits: maxNits,
            preRestrictionNits: pre,
            multiplier: 1
        )
    }
}
