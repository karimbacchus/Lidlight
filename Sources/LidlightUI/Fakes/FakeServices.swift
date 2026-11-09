import Foundation
import LidlightKit

/// Echoes every call into its status, records the calls and simulates pauses from `SystemStatus`.
package final class FakeEngine: LogoControlling {
    package private(set) var status = EngineStatus()
    package var onStatusChange: ((EngineStatus) -> Void)?
    /// Every call in order, e.g. "setMode(music)".
    package private(set) var calls: [String] = []
    package private(set) var settings = EffectSettings()
    package private(set) var beatCount = 0
    package private(set) var lastShutdown: (restoreDefaults: Bool, keepOff: Bool)?
    private var system = SystemStatus()
    private let scene: FakeLogoScene?

    package init(scene: FakeLogoScene? = nil) { self.scene = scene }

    private func publish() {
        var reason: PauseReason?
        if !status.isOn {
            reason = .logoOff
        } else if system.displayAsleep {
            reason = .displayAsleep
        } else if system.lidClosed {
            reason = .lidClosed
        } else if status.mode.isAnimated {
            if status.mode != .agents && system.screenLocked {
                reason = .screenLocked
            } else if status.mode != .agents && system.lowPowerMode {
                reason = .lowPowerMode
            } else if settings.pauseWhileKeyboardLit && system.keyboardBacklightLit {
                reason = .keyboardLit
            }
        }
        status.pausedReason = reason
        status.isAnimating = status.isOn && status.mode.isAnimated && reason == nil
        status.targetNits = BrightnessCurve.nits(forSlider: settings.brightness)
        scene?.update(isOn: status.isOn, mode: status.mode, effects: settings, paused: reason != nil,
                      batteryFraction: (system.batteryPercent ?? 100) / 100)
        onStatusChange?(status)
    }

    package func start(isOn: Bool, mode: LogoMode, settings: EffectSettings) {
        calls.append("start(\(isOn),\(mode.rawValue))")
        status.isOn = isOn
        status.mode = mode
        self.settings = settings
        publish()
    }

    package func setOn(_ on: Bool) { calls.append("setOn(\(on))"); status.isOn = on; publish() }
    package func setMode(_ mode: LogoMode) { calls.append("setMode(\(mode.rawValue))"); status.mode = mode; publish() }
    package func setSettings(_ settings: EffectSettings) { calls.append("setSettings"); self.settings = settings; publish() }
    package func update(system: SystemStatus) { calls.append("update(system)"); self.system = system; publish() }

    package func update(agents: AgentSnapshot) {
        calls.append("update(agents)")
        status.shownActivity = agents.activity
        scene?.update(activity: agents.activity)
        publish()
    }

    package func handleBeat(_ beat: BeatEvent) { beatCount += 1 }
    package func handleAudioLevel(_ level: Double) {}

    package func preview(_ activity: AgentActivity) {
        calls.append("preview(\(activity.rawValue))")
        scene?.update(activity: activity)
    }

    package func shutdown(restoreDefaults: Bool, keepOff: Bool) {
        calls.append("shutdown")
        lastShutdown = (restoreDefaults, keepOff)
    }
}

package final class FakeSystemMonitor: SystemMonitoring {
    package var status: SystemStatus
    package private(set) var isRunning = false
    private var onChange: ((SystemStatus) -> Void)?

    package init(status: SystemStatus = FakeSystemMonitor.laptop) { self.status = status }

    /// A MacBook on battery at 78 %.
    package static var laptop: SystemStatus {
        var s = SystemStatus()
        s.onBattery = true
        s.batteryPercent = 78
        return s
    }

    package func start(onChange: @escaping (SystemStatus) -> Void) { isRunning = true; self.onChange = onChange }
    package func stop() { isRunning = false; onChange = nil }

    /// Changes the status and notifies, like the real monitor.
    package func emit(_ change: (inout SystemStatus) -> Void) {
        change(&status)
        onChange?(status)
    }
}

package final class FakeAgentMonitor: AgentMonitoring {
    package var snapshot = AgentSnapshot()
    package private(set) var isRunning = false
    private var onChange: ((AgentSnapshot) -> Void)?

    package init() {}

    package func start(onChange: @escaping (AgentSnapshot) -> Void) { isRunning = true; self.onChange = onChange }
    package func stop() { isRunning = false; onChange = nil }

    package func emit(_ snapshot: AgentSnapshot) {
        self.snapshot = snapshot
        onChange?(snapshot)
    }

    /// Cycles through none → waiting → working → needs you every few seconds (demo only).
    package func startDemoCycle(every seconds: TimeInterval = 6) {
        let steps: [AgentSnapshot] = [
            AgentSnapshot(),
            AgentSnapshot(activity: .waiting, sessions: 1, working: 0, needingYou: 0, updatedAt: Date()),
            AgentSnapshot(activity: .working, sessions: 2, working: 1, needingYou: 0, updatedAt: Date()),
            AgentSnapshot(activity: .needsYou, sessions: 2, working: 0, needingYou: 1, updatedAt: Date()),
        ]
        var index = 0
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            index = (index + 1) % steps.count
            self?.emit(steps[index])
        }
    }
}

package final class FakeHooksManager: ClaudeHooksManaging {
    package var currentStatus: HooksStatus
    package var failure: Error?
    package private(set) var connectedPaths: [String] = []

    package init(status: HooksStatus = .notInstalled) { currentStatus = status }

    package func status() -> HooksStatus { currentStatus }

    package func connect(helperPath: String) throws {
        if let failure { throw failure }
        connectedPaths.append(helperPath)
        currentStatus = .installed
    }

    package func disconnect() throws {
        if let failure { throw failure }
        currentStatus = .notInstalled
    }
}

/// Emits a beat every half second (120 BPM), every fourth one strong, and a level at 30 Hz.
package final class FakeBeatSource: BeatSource {
    package private(set) var isRunning = false
    package var permission: AudioCapturePermission
    package var startError: Error?
    package private(set) var startCount = 0
    package private(set) var stopCount = 0
    private var timers: [Timer] = []

    package init(permission: AudioCapturePermission = .granted) { self.permission = permission }

    package func start(onBeat: @escaping (BeatEvent) -> Void, onLevel: @escaping (Double) -> Void) throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
        var count = 0
        timers = [
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                count += 1
                onBeat(BeatEvent(uptime: ProcessInfo.processInfo.systemUptime, strength: 0.8, isStrong: count % 4 == 0))
            },
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                let phase = ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 0.5) / 0.5
                onLevel(exp(-5 * phase))
            },
        ]
    }

    package func stop() {
        stopCount += 1
        isRunning = false
        timers.forEach { $0.invalidate() }
        timers = []
    }
}

package final class FakeLoginItem: LoginItemControlling {
    package var isEnabled = false
    package var failure: Error?

    package init() {}

    package func setEnabled(_ enabled: Bool) throws {
        if let failure { throw failure }
        isEnabled = enabled
    }
}
