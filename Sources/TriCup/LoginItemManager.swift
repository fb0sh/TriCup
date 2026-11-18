import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` for the "launch at login" toggle.
///
/// Only one implementation is maintained (no parallel LaunchAgent variant); if
/// this proves unreliable on device we revisit that decision separately.
final class LoginItemManager {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status == .enabled {
                try service.unregister()
            }
        }
    }
}
