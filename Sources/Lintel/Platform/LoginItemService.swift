import Observation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`.
/// The system's registration is the source of truth; nothing is mirrored into settings.
@MainActor
@Observable
final class LoginItemService {
    private(set) var status: SMAppService.Status
    private(set) var lastError: String?

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var statusDescription: String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
