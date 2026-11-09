import Foundation
import CoreGraphics
import IOKit

/// Whether the animation channel may be written right now: the built-in display must be awake and
/// the lid open (docs/HARDWARE.md, safety rule 6). Used by processes that have no engine telling
/// them (the CLI, the guardian, launch-time recovery).
package enum AnimationEnvironment {
    package static func isPossible() -> Bool {
        builtInDisplayIsAwake() && !lidIsClosed()
    }

    static func builtInDisplayIsAwake() -> Bool {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }

    /// `AppleClamshellState` of IOPMrootDomain; false when the Mac reports no lid state.
    static func lidIsClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (property?.takeRetainedValue() as? Bool) ?? false
    }
}
