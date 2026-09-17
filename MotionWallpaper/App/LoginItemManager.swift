import Foundation
import ServiceManagement

enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Disabled"
        case .requiresApproval: return "Requires approval in System Settings → General → Login Items"
        case .notFound: return "App was not found as a login item"
        @unknown default: return "Unknown status"
        }
    }
}
