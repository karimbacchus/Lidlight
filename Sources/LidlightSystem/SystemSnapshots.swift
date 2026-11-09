import CoreGraphics
import Foundation
import IOKit.ps

/// Battery fields derived from IOPowerSources.
package struct BatteryReading: Equatable {
    package var percent: Double?
    package var isCharging: Bool
    package var onBattery: Bool

    package init(percent: Double?, isCharging: Bool, onBattery: Bool) {
        self.percent = percent
        self.isCharging = isCharging
        self.onBattery = onBattery
    }

    package static let none = BatteryReading(percent: nil, isCharging: false, onBattery: false)

    /// Builds a reading from power source description dictionaries (`IOPSGetPowerSourceDescription`)
    /// and the providing source type (`IOPSGetProvidingPowerSourceType`).
    /// Only the internal battery counts; with none present the Mac is a desktop-style machine.
    package static func make(descriptions: [[String: Any]], providingSourceType: String?) -> BatteryReading {
        guard let battery = descriptions.first(where: {
            ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }) else { return .none }

        var percent: Double?
        if let current = (battery[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
           let max = (battery[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, max > 0 {
            percent = Swift.min(100, Swift.max(0, current / max * 100))
        }
        let isCharging = (battery[kIOPSIsChargingKey] as? Bool) ?? false
        let sourceState = battery[kIOPSPowerSourceStateKey] as? String
        let onBattery = (providingSourceType ?? sourceState) == kIOPSBatteryPowerValue
        return BatteryReading(percent: percent, isCharging: isCharging, onBattery: onBattery)
    }
}

/// Pure decisions about the built-in display and session, separated from the system calls.
package enum DisplayRules {
    /// The built-in display counts as asleep when it reports asleep, or when it is online but not
    /// active (lid closed while an external display is in use). No built-in display at all is "not asleep".
    package static func isBuiltInAsleep(builtIn: CGDirectDisplayID?, active: [CGDirectDisplayID],
                                        reportsAsleep: Bool) -> Bool {
        guard let builtIn else { return false }
        return reportsAsleep || !active.contains(builtIn)
    }

    /// Reads `CGSSessionScreenIsLocked` from a `CGSessionCopyCurrentDictionary` result.
    package static func isScreenLocked(sessionDictionary: [String: Any]?) -> Bool {
        guard let value = sessionDictionary?["CGSSessionScreenIsLocked"] else { return false }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }
}
