import Foundation
import ServiceManagement

enum LaunchAtLoginRegistrationState: Equatable {
    case disabled
    case enabled
    case requiresApproval

    var isRequested: Bool {
        switch self {
        case .disabled:
            return false
        case .enabled, .requiresApproval:
            return true
        }
    }
}

protocol LaunchAtLoginManaging {
    var registrationState: LaunchAtLoginRegistrationState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettingsLoginItems()
}

struct LaunchAtLoginUpdateResult {
    let config: AppConfig
    let registrationState: LaunchAtLoginRegistrationState
    let error: Error?
}

struct LaunchAtLoginCoordinator {
    let manager: LaunchAtLoginManaging

    func reconcileOnStartup(config: AppConfig) -> LaunchAtLoginUpdateResult {
        if config.launchAtLogin, !manager.registrationState.isRequested {
            return setEnabled(true, config: config)
        }

        return refreshStatus(config: config)
    }

    func refreshStatus(config: AppConfig) -> LaunchAtLoginUpdateResult {
        var updated = config
        let state = manager.registrationState
        updated.launchAtLogin = state.isRequested
        return LaunchAtLoginUpdateResult(config: updated, registrationState: state, error: nil)
    }

    func setEnabled(_ enabled: Bool, config: AppConfig) -> LaunchAtLoginUpdateResult {
        var updated = config
        do {
            try manager.setEnabled(enabled)
            let state = manager.registrationState
            updated.launchAtLogin = state.isRequested
            return LaunchAtLoginUpdateResult(config: updated, registrationState: state, error: nil)
        } catch {
            let state = manager.registrationState
            updated.launchAtLogin = state.isRequested
            return LaunchAtLoginUpdateResult(config: updated, registrationState: state, error: error)
        }
    }

    func openSystemSettingsLoginItems() {
        manager.openSystemSettingsLoginItems()
    }
}

final class SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    var registrationState: LaunchAtLoginRegistrationState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        switch (enabled, registrationState) {
        case (true, .enabled), (true, .requiresApproval), (false, .disabled):
            return
        case (true, _):
            try service.register()
        case (false, _):
            try service.unregister()
        }
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
