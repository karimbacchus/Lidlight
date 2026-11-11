import Foundation
import LidlightKit

/// Drives the logo: Steady, Breathe, Battery, Music and Agents on top of a `LogoDriving`.
///
/// The public API is main-thread only and returns immediately; the work runs on a private serial
/// queue (timers and driver writes never touch the main thread). `status` and `onStatusChange`
/// update on the main thread shortly after the call that caused the change.
public final class EffectEngine: LogoControlling {
    private let queue = DispatchQueue(label: "app.lidlight.engine", qos: .userInteractive)
    private let core: EngineCore

    public private(set) var status = EngineStatus()
    public var onStatusChange: ((EngineStatus) -> Void)?

    public init(driver: LogoDriving) {
        core = EngineCore(driver: driver, clock: DispatchEngineClock(queue: queue))
        core.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.status = status
                self?.onStatusChange?(status)
            }
        }
    }

    public func start(isOn: Bool, mode: LogoMode, settings: EffectSettings) {
        queue.async { [core] in core.start(isOn: isOn, mode: mode, settings: settings) }
    }

    public func setOn(_ on: Bool) {
        queue.async { [core] in core.setOn(on) }
    }

    public func setMode(_ mode: LogoMode) {
        queue.async { [core] in core.setMode(mode) }
    }

    public func setSettings(_ settings: EffectSettings) {
        queue.async { [core] in core.setSettings(settings) }
    }

    public func update(system: SystemStatus) {
        queue.async { [core] in core.update(system: system) }
    }

    public func update(agents: AgentSnapshot) {
        queue.async { [core] in core.update(agents: agents) }
    }

    public func handleBeat(_ beat: BeatEvent) {
        queue.async { [core] in core.handleBeat(beat) }
    }

    public func preview(_ activity: AgentActivity) {
        queue.async { [core] in core.preview(activity) }
    }

    /// Synchronous: returns only after queued work has run and the driver has been restored.
    public func shutdown(restoreDefaults: Bool, keepOff: Bool) {
        queue.sync { core.shutdown(restoreDefaults: restoreDefaults, keepOff: keepOff) }
        status.isOn = !keepOff
        status.isAnimating = false
        status.pausedReason = nil
    }
}
