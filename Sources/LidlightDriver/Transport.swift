import Foundation
import CoreBrightnessBridge

/// Property access to corebrightnessd. The production implementation wraps `LLCoreBrightness`;
/// checks substitute a recording fake so the driver's rate limiting and bookkeeping can be
/// verified without touching hardware.
package protocol LogoPropertyTransport: AnyObject, Sendable {
    func property(forKey key: String) -> Any?
    /// Returns corebrightnessd's acceptance flag.
    func setProperty(_ value: Any, forKey key: String) -> Bool
}

/// `LLCoreBrightness` as a `LogoPropertyTransport`.
final class BridgeTransport: LogoPropertyTransport, @unchecked Sendable {
    private let bridge: LLCoreBrightness

    init?() {
        guard let bridge = LLCoreBrightness() else { return nil }
        self.bridge = bridge
    }

    func property(forKey key: String) -> Any? {
        bridge.property(forKey: key)
    }

    func setProperty(_ value: Any, forKey key: String) -> Bool {
        bridge.setProperty(value, forKey: key)
    }
}
