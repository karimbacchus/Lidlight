import CoreGraphics
import Foundation
import IOKit

/// Read-only probes of the built-in display and lid, shared by the system monitor and by processes
/// that have no monitor (the CLI, the guardian, launch-time recovery).
public enum MacHardware {
    /// True when the logo can be animated at all: built-in display awake and lid open
    /// (docs/HARDWARE.md, safety rule 6).
    public static func animationPossible() -> Bool {
        !builtInDisplayAsleep() && !lidClosed()
    }

    public static func builtInDisplayAsleep() -> Bool {
        guard let online = displayList(CGGetOnlineDisplayList), let active = displayList(CGGetActiveDisplayList) else {
            return false
        }
        let builtIn = online.first { CGDisplayIsBuiltin($0) != 0 }
        return isBuiltInAsleep(
            builtIn: builtIn, active: active, reportsAsleep: builtIn.map { CGDisplayIsAsleep($0) != 0 } ?? false)
    }

    /// The built-in display counts as asleep when it reports asleep, or when it is online but not
    /// active (lid closed while an external display is in use). No built-in display at all is "not asleep".
    public static func isBuiltInAsleep(builtIn: CGDirectDisplayID?, active: [CGDirectDisplayID],
                                       reportsAsleep: Bool) -> Bool {
        guard let builtIn else { return false }
        return reportsAsleep || !active.contains(builtIn)
    }

    /// `AppleClamshellState` of IOPMrootDomain; false when the Mac reports no lid state.
    public static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private static func displayList(
        _ list: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard list(UInt32(displays.count), &displays, &count) == .success else { return nil }
        return Array(displays.prefix(Int(count)))
    }
}
