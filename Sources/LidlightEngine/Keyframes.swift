import Foundation
import LidlightKit

/// One write to the factor channel: at `time`, set the fade duration to `fade` and ramp toward `target`.
struct Keyframe: Equatable {
    var time: TimeInterval
    var fade: Double
    var target: FactorTarget
}

/// Tracks the factor corebrightnessd is expected to be at, using `FactorRampModel`, from the writes
/// the engine issued. Patterns use it to start new ramps from the right value.
struct FactorTracker {
    private let model: FactorRampModel
    private var origin = 1.0
    private var goal = 1.0
    private var start: TimeInterval = 0
    private var duration = 0.0

    init(model: FactorRampModel) {
        self.model = model
    }

    /// The factor is lit and not moving (after a release, or when the hardware re-synced itself).
    mutating func reset() {
        origin = 1
        goal = 1
        duration = 0
    }

    func factor(at time: TimeInterval) -> Double {
        model.factor(from: origin, toward: goal, duration: duration, elapsed: time - start)
    }

    mutating func ramp(to target: FactorTarget, duration: Double, at time: TimeInterval) {
        origin = factor(at: time)
        goal = target == .lit ? 1 : 0
        start = time
        self.duration = duration
    }
}

/// Rolling-window cap on flashes. A flash is a lit write that follows a dark phase shorter than 0.5 s.
struct FlashLimiter {
    let maxFlashes: Int
    let window: TimeInterval
    private var times: [TimeInterval] = []

    init(maxFlashes: Int = 3, window: TimeInterval = 1) {
        self.maxFlashes = maxFlashes
        self.window = window
    }

    /// Books `count` flashes at `time` if the cap allows it; returns false (and books nothing) otherwise.
    mutating func reserve(at time: TimeInterval, count: Int = 1) -> Bool {
        times.removeAll { $0 <= time - window }
        guard times.count + count <= maxFlashes else { return false }
        times.append(contentsOf: Array(repeating: time, count: count))
        return true
    }
}
