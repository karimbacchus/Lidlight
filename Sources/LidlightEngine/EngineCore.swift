import Foundation
import LidlightKit

/// The engine's brain: single-threaded, driven by an `EngineClock`. `EffectEngine` runs one on a
/// private serial queue with a real clock; checks run it on a virtual clock with a recording driver.
package final class EngineCore {
    private enum Tuning {
        /// How long Agents previews last.
        static let previewDuration: TimeInterval = 6
        static let tableDebounce: TimeInterval = 0.3
        static let tableMinInterval: TimeInterval = 2
        static let tableRetryDelay: TimeInterval = 10
        /// A keyframe this overdue means the process was suspended; the pattern is re-based.
        static let lateTolerance: TimeInterval = 0.25
        /// Timer slack: keyframes due within this much are written now.
        static let epsilon: TimeInterval = 0.0005
        static let lowBatteryPercent = 10.0
        static let workingPulseShape = PulseShape.working
        // Music
        static let beatFade = 0.05
        static let dipDelay: TimeInterval = 0.06
        static let recoverFade = 0.12
        static let strobeGap: TimeInterval = 0.12
        static let strobeFade = 0.03
        static let strobeDark: TimeInterval = 0.06
        static let settleFade = 0.3
    }

    private let driver: LogoDriving
    private let clock: EngineClock
    private let model: FactorRampModel

    /// Receives a status whenever it changes.
    package var onStatus: ((EngineStatus) -> Void)?

    // Inputs
    private var started = false
    private var isShutDown = false
    private var isOn = true
    private var mode = LogoMode.steady
    private var settings = EffectSettings()
    private var system = SystemStatus()
    private var agents = AgentSnapshot()
    private var preview: (activity: AgentActivity, endsAt: TimeInterval)?

    // Animation state
    private var activePlan = Plan.steady
    private var generator: Generator?
    private var queue: [Keyframe] = []
    private var tracker: FactorTracker
    private var limiter = FlashLimiter()
    private var animationAllowed = true
    private var lastTarget = FactorTarget.lit
    private var lastFade: Double?
    /// True while the factor channel holds something that `releaseFactor` would undo.
    private var factorDirty = false

    // Tables
    private var pendingTables: LogoTables?
    private var writtenTables: LogoTables?
    private var lastTableWrite: TimeInterval?
    private var tableDeadline: TimeInterval?

    private var published: EngineStatus?

    package init(driver: LogoDriving, clock: EngineClock, model: FactorRampModel = .measured) {
        self.driver = driver
        self.clock = clock
        self.model = model
        self.tracker = FactorTracker(model: model)
        clock.onWake = { [unowned self] in tick() }
    }

    // MARK: - Inputs

    package func start(isOn: Bool, mode: LogoMode, settings: EffectSettings) {
        guard !isShutDown else { return }
        self.isOn = isOn
        self.mode = mode
        self.settings = Self.sanitized(settings)
        started = true
        if driver.isSupported {
            driver.setAnimationAllowed(system.animationPossible)
            let desired: LogoPower = isOn ? .on : .off
            if driver.readPower() != desired { attempt("set power") { try driver.setPower(desired) } }
        }
        reconcile(tableDebounce: 0)
    }

    package func setOn(_ on: Bool) {
        guard started, !isShutDown, on != isOn else { return }
        if on {
            if driver.isSupported { attempt("power on") { try driver.setPower(.on) } }
            isOn = true
            reconcile()
        } else {
            isOn = false
            reconcile()
            if driver.isSupported { attempt("power off") { try driver.setPower(.off) } }
        }
    }

    package func setMode(_ mode: LogoMode) {
        guard !isShutDown else { return }
        self.mode = mode
        reconcile()
    }

    package func setSettings(_ settings: EffectSettings) {
        guard !isShutDown else { return }
        self.settings = Self.sanitized(settings)
        reconcile()
    }

    package func update(system: SystemStatus) {
        guard !isShutDown else { return }
        self.system = system
        animationAllowed = system.animationPossible
        if driver.isSupported { driver.setAnimationAllowed(animationAllowed) }
        reconcile()
    }

    package func update(agents: AgentSnapshot) {
        guard !isShutDown else { return }
        self.agents = agents
        reconcile()
    }

    package func preview(_ activity: AgentActivity) {
        guard started, !isShutDown else { return }
        preview = (activity, clock.now + Tuning.previewDuration)
        reconcile()
    }

    /// Beat in Music mode: lit, then a short dip whose depth follows intensity, then back to lit.
    /// Strong beats add a quick extra dark/lit pair when strobe is on. Counted flashes are capped.
    package func handleBeat(_ beat: BeatEvent) {
        guard started, !isShutDown, activePlan == .music else { return }
        let now = clock.now
        let intensity = min(max(settings.musicIntensity, 0), 1)
        let floor = 1 - 0.9 * intensity
        let dipTime = 0.08 + 0.10 * intensity
        let needsLit = lastTarget == .dark
        let darkAt = now + Tuning.dipDelay
        // After a lit write at the beat the factor is back at 1 by the time the dip starts.
        let factorAtDip = needsLit ? 1.0 : tracker.factor(at: darkAt)

        var followUp: [Keyframe] = []
        if let fade = model.duration(toReach: floor, from: factorAtDip, toward: 0, after: dipTime) {
            followUp = [
                Keyframe(time: darkAt, fade: fade, target: .dark),
                Keyframe(time: darkAt + dipTime, fade: Tuning.recoverFade, target: .lit),
            ]
        }
        let flashes = (needsLit ? 1 : 0) + (followUp.isEmpty ? 0 : 1)
        guard flashes > 0, limiter.reserve(at: now, count: flashes) else { return }

        if beat.isStrong, settings.musicStrobe, let recovered = followUp.last {
            let strobeAt = recovered.time + Tuning.strobeGap
            if limiter.reserve(at: strobeAt + Tuning.strobeDark) {
                followUp.append(Keyframe(time: strobeAt, fade: Tuning.strobeFade, target: .dark))
                followUp.append(Keyframe(time: strobeAt + Tuning.strobeDark, fade: Tuning.strobeFade, target: .lit))
            }
        }

        queue.removeAll()
        if needsLit { issue(Keyframe(time: now, fade: Tuning.beatFade, target: .lit)) }
        queue.append(contentsOf: followUp)
        arm()
    }

    /// Between-beat modulation is not used: the dips already follow the beats.
    package func handleAudioLevel(_ level: Double) {}

    package func shutdown(restoreDefaults: Bool, keepOff: Bool) {
        guard !isShutDown else { return }
        isShutDown = true
        queue.removeAll()
        generator = nil
        tableDeadline = nil
        preview = nil
        activePlan = .steady
        clock.arm(at: nil)
        isOn = !keepOff
        publishStatus(pausedReason: nil)
        guard driver.isSupported else { return }
        attempt("release factor") { try driver.releaseFactor() }
        if restoreDefaults {
            attempt("restore defaults") { try driver.restoreSystemDefaults(powerOn: !keepOff) }
        } else {
            attempt("final power") { try driver.setPower(keepOff ? .off : .on) }
        }
    }

    // MARK: - Reconciling inputs with the driver

    /// Resolves the wanted plan against pauses, switches pattern if needed, and updates tables/status.
    private func reconcile(tableDebounce: TimeInterval = Tuning.tableDebounce) {
        guard started, !isShutDown else { return }
        let wanted = wantedPlan()
        let reason = pauseReason(wanted: wanted)
        let effective = reason == nil ? wanted : .steady
        if effective != activePlan { transition(to: effective) }
        updateTables(debounce: tableDebounce)
        publishStatus(pausedReason: reason)
        arm()
    }

    private func wantedPlan() -> Plan {
        if let preview { return agentsPlan(preview.activity, away: true) }
        switch mode {
        case .steady:
            return .steady
        case .breathe:
            return .pulse(.breathe(period: settings.breathePeriod))
        case .battery:
            if let percent = system.batteryPercent, percent < Tuning.lowBatteryPercent, !system.isCharging {
                return .pulse(.batteryLow)
            }
            return .steady
        case .music:
            return .music
        case .agents:
            let away = system.screenLocked || system.userIdleSeconds >= settings.agentAwayAfter
            return agentsPlan(agents.activity, away: away)
        }
    }

    private func agentsPlan(_ activity: AgentActivity, away: Bool) -> Plan {
        switch activity {
        case .none, .waiting: return .steady
        case .working: return .pulse(Tuning.workingPulseShape)
        case .needsYou: return away ? .blink : .steady
        }
    }

    private func pauseReason(wanted: Plan) -> PauseReason? {
        if !driver.isSupported { return .unsupported }
        if !isOn { return .logoOff }
        guard wanted != .steady else { return nil }
        if system.lidClosed { return .lidClosed }
        if system.displayAsleep { return .displayAsleep }
        let agentsShown = mode == .agents || preview != nil
        if !agentsShown {
            if system.screenLocked { return .screenLocked }
            if system.lowPowerMode { return .lowPowerMode }
        }
        if system.keyboardBacklightLit && settings.pauseWhileKeyboardLit { return .keyboardLit }
        return nil
    }

    private func transition(to plan: Plan) {
        let previous = activePlan
        activePlan = plan
        switch plan {
        case .steady:
            queue.removeAll()
            generator = nil
            releaseFactor()
        case .pulse(let shape):
            // A running pulse just takes the new shape from its next ramp on (e.g. the speed slider).
            if case .pulse = previous, case .pulse(var running)? = generator {
                running.shape = shape
                generator = .pulse(running)
                return
            }
            queue.removeAll()
            generator = .pulse(PulseGenerator(
                shape: shape, model: model, start: clock.now,
                factor: tracker.factor(at: clock.now), lastTarget: lastTarget))
            queueGeneratedKeyframe()
        case .blink:
            queue.removeAll()
            generator = .blink(BlinkGenerator(start: clock.now, lastTarget: lastTarget))
            queueGeneratedKeyframe()
        case .music:
            queue.removeAll()
            generator = nil
            // Settle lit: beats only ever dip from there.
            if lastTarget == .dark {
                queue = [Keyframe(time: clock.now, fade: Tuning.settleFade, target: .lit)]
            }
        }
    }

    /// Cancels pending keyframes' effect on the hardware: factor back to lit, fade override cleared.
    private func releaseFactor() {
        guard factorDirty else { return }
        if animationAllowed { attempt("release factor") { try driver.releaseFactor() } }
        // If the gate is closed the hardware re-syncs itself (display wake / lid open).
        tracker.reset()
        lastTarget = .lit
        lastFade = nil
        factorDirty = false
    }

    // MARK: - Keyframes

    private func queueGeneratedKeyframe() {
        guard var current = generator else { return }
        queue.append(current.next())
        generator = current
    }

    private func issue(_ keyframe: Keyframe) {
        guard driver.isSupported, animationAllowed else { return }
        // The hardware question "does repeating a target restart the ramp" is open: never repeat one.
        guard keyframe.target != lastTarget else {
            Log.engine.debug("dropped keyframe repeating target \(String(describing: keyframe.target))")
            return
        }
        let fade = max(keyframe.fade, 0.01)
        do {
            if lastFade.map({ abs($0 - fade) > 1e-6 }) ?? true {
                try driver.setFadeDuration(fade)
                lastFade = fade
            }
            try driver.setFactorTarget(keyframe.target)
        } catch {
            Log.engine.error("factor write failed: \(String(describing: error))")
            return
        }
        tracker.ramp(to: keyframe.target, duration: fade, at: clock.now)
        lastTarget = keyframe.target
        factorDirty = true
    }

    private func runKeyframes(now: TimeInterval) {
        while let next = queue.first, next.time <= now + Tuning.epsilon {
            queue.removeFirst()
            if generator != nil, now - next.time > Tuning.lateTolerance {
                rebaseGenerator(at: now)
                continue
            }
            issue(next)
            if queue.isEmpty { queueGeneratedKeyframe() }
        }
    }

    private func rebaseGenerator(at now: TimeInterval) {
        queue.removeAll()
        switch generator {
        case .pulse(let old)?:
            generator = .pulse(PulseGenerator(
                shape: old.shape, model: model, start: now,
                factor: tracker.factor(at: now), lastTarget: lastTarget))
        case .blink?:
            generator = .blink(BlinkGenerator(start: now, lastTarget: lastTarget))
        case nil:
            return
        }
        queueGeneratedKeyframe()
    }

    // MARK: - Tables

    private var targetNits: Double {
        let level = LogoLevels.nits(forBrightness: settings.brightness)
        guard mode == .battery, let percent = system.batteryPercent else { return level }
        return level * LogoLevels.batteryScale(percent: percent)
    }

    private func updateTables(debounce: TimeInterval) {
        guard driver.isSupported else { return }
        let desired = LogoLevels.tables(nits: targetNits, fullBrightnessInAnyRoom: settings.fullBrightnessInAnyRoom)
        guard desired != pendingTables else { return }
        let now = clock.now
        if desired == writtenTables {
            pendingTables = nil
            tableDeadline = nil
            return
        }
        pendingTables = desired
        let earliest = lastTableWrite.map { $0 + Tuning.tableMinInterval } ?? now
        tableDeadline = max(now + debounce, earliest)
    }

    private func flushTables(now: TimeInterval) {
        guard let tables = pendingTables else {
            tableDeadline = nil
            return
        }
        lastTableWrite = now
        do {
            try driver.writeTables(tables)
            writtenTables = tables
            pendingTables = nil
            tableDeadline = nil
        } catch {
            Log.engine.error("table write failed: \(String(describing: error))")
            tableDeadline = now + Tuning.tableRetryDelay
        }
    }

    // MARK: - Timer

    private func tick() {
        guard !isShutDown else { return }
        let now = clock.now
        if let preview, now >= preview.endsAt - Tuning.epsilon {
            self.preview = nil
            reconcile()
        }
        if let deadline = tableDeadline, deadline <= now + Tuning.epsilon { flushTables(now: now) }
        runKeyframes(now: now)
        arm()
    }

    private func arm() {
        let candidates = [queue.first?.time, tableDeadline, preview?.endsAt]
        clock.arm(at: candidates.compactMap { $0 }.min())
    }

    // MARK: - Status

    private func publishStatus(pausedReason: PauseReason?) {
        let shown: AgentActivity
        if let preview {
            shown = preview.activity
        } else {
            shown = mode == .agents ? agents.activity : .none
        }
        let status = EngineStatus(
            isOn: isOn,
            mode: mode,
            isAnimating: pausedReason == nil && activePlan != .steady,
            pausedReason: pausedReason,
            targetNits: targetNits,
            shownActivity: shown)
        guard status != published else { return }
        published = status
        onStatus?(status)
    }

    // MARK: - Helpers

    private static func sanitized(_ settings: EffectSettings) -> EffectSettings {
        var s = settings
        s.brightness = min(max(s.brightness, 0), 1)
        s.breathePeriod = min(max(s.breathePeriod, EffectSettings.breathePeriodRange.lowerBound),
                              EffectSettings.breathePeriodRange.upperBound)
        s.musicIntensity = min(max(s.musicIntensity, 0), 1)
        return s
    }

    private func attempt(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Log.engine.error("\(what) failed: \(String(describing: error))")
        }
    }
}
