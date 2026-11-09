import Foundation
import LidlightKit

/// Shared state of the fake logo: what the engine "set" and what the logo would look like.
/// Deterministic given an uptime, so checks can sample it.
package final class FakeLogoScene: @unchecked Sendable {
    private let lock = NSLock()
    private var _isOn = true
    private var _mode = LogoMode.steady
    private var _effects = EffectSettings()
    private var _paused = false
    private var _activity = AgentActivity.waiting
    private var _batteryFraction = 0.8

    package init() {}

    package func update(isOn: Bool? = nil, mode: LogoMode? = nil, effects: EffectSettings? = nil,
                        paused: Bool? = nil, activity: AgentActivity? = nil, batteryFraction: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let isOn { _isOn = isOn }
        if let mode { _mode = mode }
        if let effects { _effects = effects }
        if let paused { _paused = paused }
        if let activity { _activity = activity }
        if let batteryFraction { _batteryFraction = batteryFraction }
    }

    /// Output as a fraction of `LogoLimits.maxNits`, at `uptime` seconds.
    package func level(at uptime: TimeInterval) -> Double {
        lock.lock()
        let (isOn, mode, effects, paused, activity, battery) = (_isOn, _mode, _effects, _paused, _activity, _batteryFraction)
        lock.unlock()
        guard isOn else { return 0 }
        let base = BrightnessCurve.nits(forSlider: effects.brightness) / LogoLimits.maxNits
        if paused { return base }
        switch mode {
        case .steady:
            return base
        case .breathe:
            let wave = 0.5 - 0.5 * cos(2 * .pi * uptime / effects.breathePeriod)
            return base * (0.04 + 0.96 * wave)
        case .battery:
            return base * (0.05 + 0.95 * battery)
        case .music:
            // 120 BPM: a beat every half second, decaying in between.
            let phase = uptime.truncatingRemainder(dividingBy: 0.5) / 0.5
            return base * (1 - effects.musicIntensity * (1 - exp(-5 * phase)) * 0.95)
        case .agents:
            switch activity {
            case .none, .waiting:
                return base * 0.6
            case .working:
                let wave = 0.5 - 0.5 * cos(2 * .pi * uptime / 2)
                return base * (0.5 + 0.5 * wave)
            case .needsYou:
                let t = uptime.truncatingRemainder(dividingBy: 2)
                let blink = (t < 0.15) || (0.3..<0.45).contains(t)
                return base * (blink ? 0.05 : 1)
            }
        }
    }
}

/// A logo driver that reads from a `FakeLogoScene`. Also the preview source.
package final class FakeLogoDriver: LogoDriving, LogoPreviewSource, @unchecked Sendable {
    package let scene: FakeLogoScene
    package let isSupported = true
    package let isSimulated: Bool
    private let lock = NSLock()
    private var power = LogoPower.on
    private(set) package var restoreCalls = 0

    package init(scene: FakeLogoScene = FakeLogoScene(), isSimulated: Bool = true) {
        self.scene = scene
        self.isSimulated = isSimulated
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    package func previewLevel() -> Double { scene.level(at: now()) }

    package func readState() -> LogoState? {
        let level = previewLevel()
        return LogoState(finalNits: level * LogoLimits.maxNits, appliedNits: level * LogoLimits.maxNits)
    }

    package func readPower() -> LogoPower? { lock.lock(); defer { lock.unlock() }; return power }
    package func setPower(_ power: LogoPower) throws { lock.lock(); self.power = power; lock.unlock() }
    package func readTables() -> LogoTables? { LogoTables.appleDefaults }
    package func writeTables(_ tables: LogoTables) throws {}
    package func setAnimationAllowed(_ allowed: Bool) {}
    package func setFadeDuration(_ seconds: Double?) throws {}
    package func setFactorTarget(_ target: FactorTarget) throws {}
    package func releaseFactor() throws {}
    package func restoreSystemDefaults(powerOn: Bool) throws {
        lock.lock(); restoreCalls += 1; lock.unlock()
    }
}
