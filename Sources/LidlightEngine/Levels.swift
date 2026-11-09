import Foundation
import LidlightKit

/// Brightness slider and table math.
package enum LogoLevels {
    /// Slider position 0...1 → nits: `3 + 997 · s^2.2`.
    package static func nits(forBrightness slider: Double) -> Double {
        let s = min(max(slider, 0), 1)
        return LogoLimits.minNits + (LogoLimits.maxNits - LogoLimits.minNits) * pow(s, 2.2)
    }

    /// Tables for a steady level: flat mapping, restrictions that never fight it.
    package static func tables(nits: Double, fullBrightnessInAnyRoom: Bool) -> LogoTables {
        LogoTables(
            mapping: .flat(nits),
            minRestriction: .flat(0),
            maxRestriction: fullBrightnessInAnyRoom ? .flat(LogoLimits.maxNits) : LogoTables.appleDefaults.maxRestriction
        )
    }

    /// Battery mode: full charge shows the slider level, empty shows 5 % of it (linear in nits).
    package static func batteryScale(percent: Double) -> Double {
        0.05 + 0.95 * min(max(percent, 0), 100) / 100
    }
}

extension EffectEngine {
    /// The steady level (nits) the brightness slider position stands for: `3 + 997 · s^2.2`.
    public static func nits(forBrightness slider: Double) -> Double {
        LogoLevels.nits(forBrightness: slider)
    }
}
