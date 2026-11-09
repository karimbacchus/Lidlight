import Foundation

/// Detects kick-drum style beats in a mono audio stream.
///
/// Audio is band-limited to the bass range (about 40–150 Hz), reduced to an energy envelope at
/// 200 Hz, and an onset is reported when the envelope's positive flux exceeds an adaptive threshold
/// (running mean + c·standard deviation over ~1.5 s) while also standing clearly above the recent
/// average level. Pure and deterministic; not thread-safe (use from one queue).
public final class BeatDetector {
    /// A detected beat.
    public struct Beat: Equatable, Sendable {
        /// Seconds of audio processed before the onset (start of the stream is 0).
        public var time: Double
        /// 0...1, relative to recent beat peaks.
        public var strength: Double
        /// Clearly stronger than the recent typical beat.
        public var isStrong: Bool
    }

    /// Smoothed bass level, 0...1, updated by `process`.
    public private(set) var level: Double = 0

    private let sampleRate: Double
    private var filters: [Biquad]

    // Envelope framing.
    private let hopSize: Int
    private var hopSamples = 0
    private var hopEnergy = 0.0
    private var hopIndex = 0
    private var envelope = 0.0
    private var peakTracker = 0.0

    // Rolling history (~1.5 s at 200 Hz) with running sums.
    private static let historyLength = 300
    private var envHistory = [Double](repeating: 0, count: historyLength)
    private var fluxHistory = [Double](repeating: 0, count: historyLength)
    private var historyCount = 0
    private var historyPos = 0
    private var envSum = 0.0
    private var fluxSum = 0.0
    private var fluxSumSquares = 0.0

    // Onset state.
    private var lastBeatHop = -1_000_000
    private var pending: (hop: Int, peak: Double, hopsLeft: Int)?
    private var recentPeaks: [Double] = []

    private static let hopSeconds = 0.005
    private static let refractorySeconds = 0.12
    private static let peakSettleHops = 4
    private static let silenceFloor = 0.002
    private static let thresholdDeviations = 3.0
    private static let minimumRiseOverMean = 1.8
    private static let minimumFluxOverMean = 0.5
    private static let minimumRiseOverTrough = 4.0
    private static let troughHops = 8

    /// Creates a detector for mono audio at `sampleRate` Hz.
    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hopSize = max(1, Int((sampleRate * Self.hopSeconds).rounded()))
        filters = [
            Biquad.highPass(frequency: 40, sampleRate: sampleRate),
            Biquad.lowPass(frequency: 150, sampleRate: sampleRate),
            Biquad.lowPass(frequency: 150, sampleRate: sampleRate),
        ]
    }

    /// Forgets all history.
    public func reset() {
        for i in filters.indices { filters[i].clearState() }
        hopSamples = 0; hopEnergy = 0; hopIndex = 0; envelope = 0; peakTracker = 0; level = 0
        envHistory = [Double](repeating: 0, count: Self.historyLength)
        fluxHistory = envHistory
        historyCount = 0; historyPos = 0; envSum = 0; fluxSum = 0; fluxSumSquares = 0
        lastBeatHop = -1_000_000; pending = nil; recentPeaks.removeAll()
    }

    /// Feeds mono samples; returns the beats completed by this chunk.
    @discardableResult
    public func process(_ samples: [Float]) -> [Beat] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    /// Feeds mono samples; returns the beats completed by this chunk.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [Beat] {
        var beats: [Beat] = []
        for sample in samples {
            var x = Double(sample)
            for i in filters.indices { x = filters[i].process(x) }
            hopEnergy += x * x
            hopSamples += 1
            if hopSamples == hopSize {
                let rms = (hopEnergy / Double(hopSize)).squareRoot()
                hopSamples = 0
                hopEnergy = 0
                if let beat = advance(rms: rms) { beats.append(beat) }
            }
        }
        return beats
    }

    private func advance(rms: Double) -> Beat? {
        hopIndex += 1
        let previous = envelope
        envelope = 0.6 * rms + 0.4 * previous
        let flux = max(0, envelope - previous)
        updateLevel()

        // Statistics exclude the current frame so a sharp onset can't inflate its own threshold.
        let n = Double(max(historyCount, 1))
        let envMean = envSum / n
        let fluxMean = fluxSum / n
        let fluxStd = max(0, fluxSumSquares / n - fluxMean * fluxMean).squareRoot()
        let warmedUp = historyCount >= Self.historyLength / 5
        let trough = recentTrough()
        pushHistory(env: envelope, flux: flux)

        if var p = pending {
            p.peak = max(p.peak, envelope)
            p.hopsLeft -= 1
            if p.hopsLeft == 0 {
                pending = nil
                return finish(onsetHop: p.hop, peak: p.peak)
            }
            pending = p
            return nil
        }

        let refractoryHops = Int(Self.refractorySeconds / Self.hopSeconds)
        guard warmedUp,
              envelope > Self.silenceFloor,
              hopIndex - lastBeatHop > refractoryHops,
              flux > fluxMean + Self.thresholdDeviations * fluxStd,
              flux > Self.minimumFluxOverMean * envMean,
              envelope > Self.minimumRiseOverMean * envMean,
              envelope > Self.minimumRiseOverTrough * trough
        else { return nil }
        lastBeatHop = hopIndex
        pending = (hopIndex, envelope, Self.peakSettleHops)
        return nil
    }

    private func finish(onsetHop: Int, peak: Double) -> Beat {
        recentPeaks.append(peak)
        if recentPeaks.count > 8 { recentPeaks.removeFirst() }
        let reference = recentPeaks.max() ?? peak
        let ratio = peak / reference
        let strength = min(1, max(0, ratio * ratio))
        let median = recentPeaks.sorted()[recentPeaks.count / 2]
        let isStrong = recentPeaks.count >= 3 && strength > 0.85 && peak > 1.3 * median
        // The onset was detected at the start of the hop that rose; report its beginning.
        let time = Double(onsetHop - 1) * Self.hopSeconds
        return Beat(time: time, strength: strength, isStrong: isStrong)
    }

    private func updateLevel() {
        // Slow-decaying peak reference so the level is relative to how loud the bass has recently been.
        peakTracker = max(envelope, peakTracker * 0.9995)
        let reference = max(peakTracker, 0.02)
        let target = min(1, envelope / reference)
        let coefficient = target > level ? 0.5 : 0.05
        level += (target - level) * coefficient
        level = min(1, max(0, level))
    }

    /// Smallest envelope value over the last `troughHops` frames (before the current one).
    private func recentTrough() -> Double {
        let count = min(Self.troughHops, historyCount)
        var smallest = Double.infinity
        for back in 1...max(count, 1) {
            smallest = min(smallest, envHistory[(historyPos - back + Self.historyLength) % Self.historyLength])
        }
        return smallest
    }

    private func pushHistory(env: Double, flux: Double) {
        if historyCount == Self.historyLength {
            let oldEnv = envHistory[historyPos], oldFlux = fluxHistory[historyPos]
            envSum -= oldEnv
            fluxSum -= oldFlux
            fluxSumSquares -= oldFlux * oldFlux
        } else {
            historyCount += 1
        }
        envHistory[historyPos] = env
        fluxHistory[historyPos] = flux
        envSum += env
        fluxSum += flux
        fluxSumSquares += flux * flux
        historyPos = (historyPos + 1) % Self.historyLength
    }
}

/// Second-order IIR section (RBJ cookbook, Q = 1/√2), direct form II transposed.
struct Biquad {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    static func lowPass(frequency: Double, sampleRate: Double) -> Biquad {
        make(frequency, sampleRate) { cosW, alpha in
            ((1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2, 1 + alpha, -2 * cosW, 1 - alpha)
        }
    }

    static func highPass(frequency: Double, sampleRate: Double) -> Biquad {
        make(frequency, sampleRate) { cosW, alpha in
            ((1 + cosW) / 2, -(1 + cosW), (1 + cosW) / 2, 1 + alpha, -2 * cosW, 1 - alpha)
        }
    }

    private static func make(
        _ frequency: Double, _ sampleRate: Double,
        _ coefficients: (_ cosW: Double, _ alpha: Double) -> (Double, Double, Double, Double, Double, Double)
    ) -> Biquad {
        let w = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * 0.7071067811865476)
        let (b0, b1, b2, a0, a1, a2) = coefficients(cos(w), alpha)
        var f = Biquad()
        f.b0 = b0 / a0; f.b1 = b1 / a0; f.b2 = b2 / a0
        f.a1 = a1 / a0; f.a2 = a2 / a0
        return f
    }

    mutating func clearState() { z1 = 0; z2 = 0 }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
