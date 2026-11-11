import Foundation
import LidlightKit

/// Table math for steady levels.
package enum LogoLevels {
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
