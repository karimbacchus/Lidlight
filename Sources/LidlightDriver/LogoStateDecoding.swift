import Foundation
import LidlightKit

extension LogoState {
    /// Decodes corebrightnessd's `LEPWMState` dictionary. Returns nil unless `FinalNits` and
    /// `Factor` are present; other missing fields keep their `LogoState` defaults.
    package init?(propertyList: Any?) {
        guard let dictionary = propertyList as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            guard let value = (dictionary[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }
        guard let finalNits = number("FinalNits"), let factor = number("Factor") else { return nil }
        self.init(
            finalNits: finalNits,
            appliedNits: number("AppliedNits") ?? 0,
            factor: factor,
            displayNits: number("DisplayNits") ?? 0,
            lux: number("Lux") ?? 0,
            minRestrictionNits: number("MinNitsRestriction") ?? 0,
            maxRestrictionNits: number("MaxNitsRestriction") ?? LogoLimits.maxNits,
            preRestrictionNits: number("PWMNitsPreRestriction") ?? 0,
            multiplier: number("NitsMultiplier") ?? 1
        )
    }
}

extension NitsTable {
    /// Equality tolerant of the float round trip through corebrightnessd.
    package func isClose(to other: NitsTable) -> Bool {
        guard points.count == other.points.count else { return false }
        func close(_ a: Double, _ b: Double) -> Bool {
            abs(a - b) <= 1e-4 * max(1, abs(a), abs(b))
        }
        return zip(points, other.points).allSatisfy { close($0.x, $1.x) && close($0.y, $1.y) }
    }
}

extension LogoTables {
    /// The three table keys paired with their values, in write order.
    package var keyedTables: [(key: String, table: NitsTable)] {
        [(LogoKey.mapping, mapping), (LogoKey.minRestriction, minRestriction), (LogoKey.maxRestriction, maxRestriction)]
    }

    /// Why this set of tables must not be written, or nil if all three are valid.
    package var validationProblem: String? {
        for (key, table) in keyedTables where !table.isValid {
            return "\(key) must have at least 2 points with strictly increasing x and finite, non-negative values"
        }
        return nil
    }
}
