import Foundation
import ServiceManagement

/// Registers the app as a login item.
package protocol LoginItemControlling: AnyObject {
    /// True when macOS will launch the app at login.
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// `SMAppService.mainApp`. Fails for unbundled runs (`swift run`); callers surface the error.
package final class SystemLoginItem: LoginItemControlling {
    package init() {}

    package var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    package func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
