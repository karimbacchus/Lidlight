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
