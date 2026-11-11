import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import LidlightKit

/// Read-only probes of the Mac's state. Each call returns the current value.
package enum SystemReaders {
    static func screenLocked() -> Bool {
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        return isScreenLocked(sessionDictionary: dictionary)
    }

    /// Reads `CGSSessionScreenIsLocked` from a `CGSessionCopyCurrentDictionary` result.
    package static func isScreenLocked(sessionDictionary: [String: Any]?) -> Bool {
        guard let value = sessionDictionary?["CGSSessionScreenIsLocked"] else { return false }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }

    static func battery() -> BatteryReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .none
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
        return BatteryReading.make(descriptions: descriptions, providingSourceType: providing)
    }

    /// Seconds since any input event. Works without Accessibility permission.
    static func userIdleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if seconds.isFinite, seconds >= 0 { return seconds }
        return hidIdleSeconds() ?? 0
    }

    /// Fallback: `HIDIdleTime` (nanoseconds) from IOHIDSystem.
    private static func hidIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber).map { $0.doubleValue / 1_000_000_000 }
    }
}
