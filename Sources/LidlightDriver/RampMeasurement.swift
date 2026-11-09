import Foundation
import LidlightKit

/// One sampled factor ramp: `samples` are (seconds since the target write, factor).
package struct RampRecording {
    package var duration: Double
    package var target: FactorTarget
    package var startFactor: Double
    package var samples: [(t: Double, factor: Double)]

    package init(duration: Double, target: FactorTarget, startFactor: Double, samples: [(t: Double, factor: Double)]) {
        self.duration = duration
        self.target = target
        self.startFactor = startFactor
        self.samples = samples
    }

    package var targetFactor: Double { target == .lit ? 1 : 0 }

    /// Samples inside the ramp as (u = t / duration, fraction of the distance still remaining).
    package var normalizedRemaining: [(u: Double, remaining: Double)] {
        let distance = startFactor - targetFactor
        guard distance != 0, duration > 0 else { return [] }
        return samples.filter { $0.t >= 0 && $0.t <= duration }.map { ($0.t / duration, ($0.factor - targetFactor) / distance) }
    }

    /// First time the factor is within `tolerance` of the target, or nil if never.
    package func settleTime(tolerance: Double = 0.01) -> Double? {
        samples.first { abs($0.factor - targetFactor) <= tolerance }?.t
    }
}

/// Least-squares estimate of the steepness `k` of `FactorRampModel` from recorded ramps.
package enum RampFit {
    package static func fitK(_ recordings: [RampRecording]) -> Double? {
        let points = recordings.flatMap(\.normalizedRemaining)
        guard !points.isEmpty else { return nil }
        func error(_ k: Double) -> Double {
            let model = FactorRampModel(k: k)
            return points.reduce(0) { $0 + pow(model.remaining($1.u) - $1.remaining, 2) }
        }
        var best = (k: 0.5, error: Double.infinity)
        var k = 0.5
        while k <= 40 {
            let e = error(k)
            if e < best.error { best = (k, e) }
            k += 0.05
        }
        return best.k
    }
}

/// Drives the real factor channel and samples `LEPWMState.Factor` at about 100 Hz in-process.
struct RampMeasurement {
    let driver: CoreBrightnessLogoDriver
    var sampleInterval: TimeInterval = 0.01
    /// Extra recording time after the nominal end of the ramp.
    var tail: TimeInterval = 0.4

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Fades dark, then lit, for each duration. Leaves the factor lit and the override set;
    /// the caller restores.
    func run(durations: [Double]) throws -> [RampRecording] {
        var recordings: [RampRecording] = []
        for duration in durations {
            try driver.setFadeDuration(duration)
            for target in [FactorTarget.dark, .lit] {
                recordings.append(try record(target: target, duration: duration))
            }
        }
        return recordings
    }

    private func record(target: FactorTarget, duration: Double) throws -> RampRecording {
        let startFactor = driver.readState()?.factor ?? (target == .dark ? 1 : 0)
        let start = Self.now
        try driver.setFactorTarget(target)
        var samples: [(t: Double, factor: Double)] = []
        let end = start + duration + tail
        var next = start
        while next < end {
            let wait = next - Self.now
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let t = Self.now - start
            if let state = driver.readState() { samples.append((t, state.factor)) }
            next += sampleInterval
        }
        return RampRecording(duration: duration, target: target, startFactor: startFactor, samples: samples)
    }
}
