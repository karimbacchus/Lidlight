import Foundation
import LidlightKit
import CoreBrightnessBridge

/// Reads the built-in keyboard backlight state through CoreBrightness. nil when unavailable.
///
/// A Mac can report several keyboard backlights (on the Mac17,12 development machine: 95158272 is the
/// built-in keyboard and 13 a second key light that is not the keyboard). Only IDs for which
/// CoreBrightness says `isKeyboardBuiltIn` count; the IDs are re-read on every call so hot-plugged
/// external keyboards never matter.
///
/// "Lit" means *would be lit*: the backlight is not idle-dimmed (the user is active) and the room is
/// not too bright for it (not saturated). Brightness and the suppressed flag are deliberately not used:
/// Lidlight's own `DisplayLogicalState` dark phases switch the keyboard backlight off and zero those
/// readings, which would hide the very conflict this probe exists to detect (measured on Mac17,12).
public final class CoreBrightnessKeyboardProbe: KeyboardBacklightProbing, @unchecked Sendable {
    private let bridge: LLCoreBrightness
    private let lock = NSLock()

    public init?() {
        guard let bridge = LLCoreBrightness() else { return nil }
        self.bridge = bridge
    }

    public func isBuiltInKeyboardLit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bridge.keyboardBacklightIDs().contains { id in
            let keyboardID = id.uint64Value
            return bridge.isKeyboardBuilt(in: keyboardID)
                && !bridge.isKeyboardBacklightDimmed(keyboardID)
                && !bridge.isKeyboardBacklightSaturated(keyboardID)
        }
    }
}
