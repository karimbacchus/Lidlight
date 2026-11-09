import Foundation

/// Model of corebrightnessd's factor ramp (see docs/HARDWARE.md, "Measured factor ramp").
///
/// A ramp starts at factor `f0`, heads to `target` (0 or 1) and lasts `duration` seconds; it lands
/// exactly on the target at `duration`. Writing a new target starts a fresh ramp from the current
/// factor with zero initial velocity; re-writing the current target is ignored; a fade-duration change
/// only applies to the next target write.
///
/// The shape is expressed as the fraction of the distance still `remaining` after a normalized time
/// `u = elapsed / duration`:
///
///     factor(elapsed) = target + (f0 − target) · remaining(u)
///
/// Measured on macOS 27.2 (Mac17,12) the ramp is S-shaped — a critically damped spring released from
/// rest — and identical for every duration and direction:
///
///     g(x) = (1 + x) · e^(−x),   remaining(u) = (g(a·u) − g(a)) / (1 − g(a)),   a ≈ 5.9
public struct FactorRampModel: Sendable, Equatable {
    public enum Shape: Sendable, Equatable {
        /// Normalized exponential, `e^(−k·u)`: front-loaded, no initial dwell.
        case exponential(k: Double)
        /// Normalized critically damped response, `(1 + a·u)·e^(−a·u)`: slow start, S-shaped.
        case criticallyDamped(a: Double)
    }

    public var shape: Shape

    public init(shape: Shape) {
        switch shape {
        case .exponential(let k): precondition(k > 0, "k must be positive")
        case .criticallyDamped(let a): precondition(a > 0, "a must be positive")
        }
        self.shape = shape
    }

    /// Exponential model with steepness `k` (kept for fitting and tests).
    public init(k: Double) {
        self.init(shape: .exponential(k: k))
    }

    /// Best fit for macOS 27.2 on Mac17,12 (RMS error 0.011 over 1400 samples).
    public static let measured = FactorRampModel(shape: .criticallyDamped(a: 5.9))

    /// Remaining fraction of the distance to the target after `u` (0...1) of the duration.
    /// Decreases monotonically from 1 at u = 0 to 0 at u = 1.
    public func remaining(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        switch shape {
        case .exponential(let k):
            let floor = exp(-k)
            return (exp(-k * u) - floor) / (1 - floor)
        case .criticallyDamped(let a):
            let floor = Self.dampedResponse(a)
            return (Self.dampedResponse(a * u) - floor) / (1 - floor)
        }
    }

    /// Factor `elapsed` seconds into a ramp from `f0` toward `target` lasting `duration` seconds.
    public func factor(from f0: Double, toward target: Double, duration: Double, elapsed: Double) -> Double {
        guard duration > 0 else { return target }
        return target + (f0 - target) * remaining(elapsed / duration)
    }

    /// Inverse of `remaining`: the fraction of the duration after which `fraction` of the distance remains.
    public func progress(forRemaining fraction: Double) -> Double {
        let f = min(max(fraction, 0), 1)
        if f >= 1 { return 0 }
        if f <= 0 { return 1 }
        switch shape {
        case .exponential(let k):
            let floor = exp(-k)
            let value = f * (1 - floor) + floor
            return min(max(-log(value) / k, 0), 1)
        case .criticallyDamped:
            // `remaining` is strictly decreasing on [0, 1]; bisection converges to ~1e-12 in 40 steps.
            var low = 0.0, high = 1.0
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if remaining(mid) > f { low = mid } else { high = mid }
            }
            return (low + high) / 2
        }
    }

    /// Seconds until a ramp from `f0` toward `target` (lasting `duration`) reaches `level`.
    /// Returns nil if `level` is not between `f0` and `target`.
    public func time(toReach level: Double, from f0: Double, toward target: Double, duration: Double) -> Double? {
        let distance = f0 - target
        guard distance != 0 else { return 0 }
        let fraction = (level - target) / distance
        guard fraction >= 0, fraction <= 1 else { return nil }
        return progress(forRemaining: fraction) * duration
    }

    /// Duration to choose so that a ramp from `f0` toward `target` reaches `level` after `elapsed` seconds.
    /// Useful for reversing a ramp at a precise moment (breathing, partial dips).
    public func duration(toReach level: Double, from f0: Double, toward target: Double, after elapsed: Double) -> Double? {
        let distance = f0 - target
        guard distance != 0, elapsed > 0 else { return nil }
        let fraction = (level - target) / distance
        guard fraction > 0, fraction < 1 else { return nil }
        let u = progress(forRemaining: fraction)
        guard u > 0 else { return nil }
        return elapsed / u
    }

    /// Step response of a critically damped system released from rest: `(1 + x)·e^(−x)`.
    private static func dampedResponse(_ x: Double) -> Double {
        (1 + x) * exp(-x)
    }
}
