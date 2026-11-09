import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import LidlightKit

/// Read-only probes of the Mac's state. Each call returns the current value.
enum SystemReaders {
    static func builtInDisplayAsleep() -> Bool {
        var count: UInt32 = 0
        var online = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(online.count), &online, &count) == .success else {
            Log.system.error("CGGetOnlineDisplayList failed")
            return false
        }
        let builtIn = online.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
        var activeCount: UInt32 = 0
        var active = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(active.count), &active, &activeCount) == .success else {
            Log.system.error("CGGetActiveDisplayList failed")
            return false
        }
        return DisplayRules.isBuiltInAsleep(
            builtIn: builtIn,
            active: Array(active.prefix(Int(activeCount))),
            reportsAsleep: builtIn.map { CGDisplayIsAsleep($0) != 0 } ?? false)
    }

    static func screenLocked() -> Bool {
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        return DisplayRules.isScreenLocked(sessionDictionary: dictionary)
    }

    static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
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
