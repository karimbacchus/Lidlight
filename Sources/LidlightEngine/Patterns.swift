import Foundation
import LidlightKit

/// A source of keyframes for a repeating pattern. Pure: no clock, no driver.
protocol KeyframeSource {
    mutating func next() -> Keyframe
}

/// What the logo is asked to do, once modes, pauses and agent state are resolved.
enum Plan: Equatable {
    /// Constant level (tables only); the factor channel is released.
    case steady
    /// Smooth pulse between `trough` and `peak` of the factor.
    case pulse(PulseShape)
    /// Agents "needs you" double blink.
    case blink
    /// Beat-driven dips; keyframes come from `EngineCore.handleBeat`.
    case music
}

struct PulseShape: Equatable {
    var period: Double
    var trough: Double
    var peak: Double

    static func breathe(period: Double) -> PulseShape { PulseShape(period: period, trough: 0.04, peak: 0.96) }
    /// Agents: Claude is working.
    static let working = PulseShape(period: 2, trough: 0.5, peak: 0.97)
    /// Battery below 10 % and not charging.
    static let batteryLow = PulseShape(period: 4, trough: 0.5, peak: 0.97)
}

/// Smooth pulse by the reversal technique: every half period the ramp is reversed, and each ramp's
/// duration is chosen so the modeled factor lands on trough/peak exactly at the reversal. Targets
/// strictly alternate, and the factor never sits still.
struct PulseGenerator: KeyframeSource {
    var shape: PulseShape
    private let model: FactorRampModel
    private var time: TimeInterval
    private var factor: Double
    private var nextTarget: FactorTarget

    /// `start` is the time of the first keyframe; the first ramp heads away from `lastTarget`.
    init(shape: PulseShape, model: FactorRampModel, start: TimeInterval, factor: Double, lastTarget: FactorTarget) {
        self.shape = shape
        self.model = model
        self.time = start
        self.factor = factor
        self.nextTarget = lastTarget == .dark ? .lit : .dark
    }

    mutating func next() -> Keyframe {
        let half = shape.period / 2
        let target = nextTarget
        let level = target == .dark ? shape.trough : shape.peak
        let goal = target == .dark ? 0.0 : 1.0
        let fade = model.duration(toReach: level, from: factor, toward: goal, after: half) ?? half
        let keyframe = Keyframe(time: time, fade: fade, target: target)
        factor = model.factor(from: factor, toward: goal, duration: fade, elapsed: half)
        time += half
        nextTarget = target == .dark ? .lit : .dark
        return keyframe
    }
}

/// Dark 120 ms, lit 120 ms, dark 120 ms, lit, rest 1.6 s, repeat. At most two flashes per ~2 s cycle,
/// so it can never exceed the flash cap on its own.
struct BlinkGenerator: KeyframeSource {
    static let blinkFade = 0.05
    private static let offsets: [(TimeInterval, FactorTarget)] = [(0, .dark), (0.12, .lit), (0.24, .dark), (0.36, .lit)]
    private static let cycle: TimeInterval = 1.96

    private var cycleStart: TimeInterval
    private var step: Int

    /// Starts with a lit step instead of a dark one when the factor is already heading dark.
    init(start: TimeInterval, lastTarget: FactorTarget) {
        if lastTarget == .dark {
            step = 1
            cycleStart = start - Self.offsets[1].0
        } else {
            step = 0
            cycleStart = start
        }
    }

    mutating func next() -> Keyframe {
        let (offset, target) = Self.offsets[step]
        let keyframe = Keyframe(time: cycleStart + offset, fade: Self.blinkFade, target: target)
        step += 1
        if step == Self.offsets.count {
            step = 0
            cycleStart += Self.cycle
        }
        return keyframe
    }
}

/// A pattern generator of either kind.
enum Generator {
    case pulse(PulseGenerator)
    case blink(BlinkGenerator)

    mutating func next() -> Keyframe {
        switch self {
        case .pulse(var generator):
            defer { self = .pulse(generator) }
            return generator.next()
        case .blink(var generator):
            defer { self = .blink(generator) }
            return generator.next()
        }
    }
}
