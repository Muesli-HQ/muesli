import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Launch at login")
struct LaunchAtLoginManagerTests {
    @Test("startup reconciliation reflects actual enabled status when config is off")
    func startupReconciliationReflectsActualEnabledStatus() {
        var config = AppConfig()
        config.launchAtLogin = false
        let manager = FakeLaunchAtLoginManager(registrationState: .enabled)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.reconcileOnStartup(config: config)

        #expect(result.error == nil)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests.isEmpty)
    }

    @Test("startup reconciliation applies legacy saved enabled setting")
    func startupReconciliationAppliesLegacySavedEnabledSetting() {
        var config = AppConfig()
        config.launchAtLogin = true
        let manager = FakeLaunchAtLoginManager(registrationState: .disabled)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.reconcileOnStartup(config: config)

        #expect(result.error == nil)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests == [true])
    }

    @Test("setting launch at login delegates to backend and stores actual status")
    func settingLaunchAtLoginUsesBackendStatus() {
        var config = AppConfig()
        config.launchAtLogin = false
        let manager = FakeLaunchAtLoginManager(registrationState: .disabled)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.setEnabled(true, config: config)

        #expect(result.error == nil)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests == [true])
    }

    @Test("failed backend update rolls config back to actual status")
    func failedBackendUpdateRollsBackConfig() {
        var config = AppConfig()
        config.launchAtLogin = true
        let manager = FakeLaunchAtLoginManager(registrationState: .disabled)
        manager.errorToThrow = TestLaunchAtLoginError.denied
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.setEnabled(true, config: config)

        #expect(result.error != nil)
        #expect(result.config.launchAtLogin == false)
        #expect(manager.requests == [true])
    }

    @Test("requires approval stays requested instead of reverting to off")
    func requiresApprovalStaysRequested() {
        var config = AppConfig()
        config.launchAtLogin = false
        let manager = FakeLaunchAtLoginManager(registrationState: .disabled)
        manager.stateAfterSuccessfulSet = .requiresApproval
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.setEnabled(true, config: config)

        #expect(result.error == nil)
        #expect(result.registrationState == .requiresApproval)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests == [true])
    }

    @Test("startup reconciliation reflects pending approval as requested")
    func startupReconciliationReflectsPendingApprovalAsRequested() {
        var config = AppConfig()
        config.launchAtLogin = false
        let manager = FakeLaunchAtLoginManager(registrationState: .requiresApproval)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.reconcileOnStartup(config: config)

        #expect(result.error == nil)
        #expect(result.registrationState == .requiresApproval)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests.isEmpty)
    }

    @Test("status refresh re-queries approval without re-registering")
    func statusRefreshRequeriesApprovalWithoutReregistering() {
        var config = AppConfig()
        config.launchAtLogin = true
        let manager = FakeLaunchAtLoginManager(registrationState: .enabled)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.refreshStatus(config: config)

        #expect(result.error == nil)
        #expect(result.registrationState == .enabled)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests.isEmpty)
    }

    @Test("status refresh reflects external disable")
    func statusRefreshReflectsExternalDisable() {
        var config = AppConfig()
        config.launchAtLogin = true
        let manager = FakeLaunchAtLoginManager(registrationState: .disabled)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.refreshStatus(config: config)

        #expect(result.error == nil)
        #expect(result.registrationState == .disabled)
        #expect(result.config.launchAtLogin == false)
        #expect(manager.requests.isEmpty)
    }

    @Test("opening login item settings delegates to backend")
    func openLoginItemSettingsDelegatesToBackend() {
        let manager = FakeLaunchAtLoginManager(registrationState: .requiresApproval)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        coordinator.openSystemSettingsLoginItems()

        #expect(manager.openedSettings)
    }
}

private enum TestLaunchAtLoginError: Error {
    case denied
}

private final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    var registrationState: LaunchAtLoginRegistrationState
    var requests: [Bool] = []
    var errorToThrow: Error?
    var openedSettings = false
    var stateAfterSuccessfulSet: LaunchAtLoginRegistrationState?

    init(registrationState: LaunchAtLoginRegistrationState) {
        self.registrationState = registrationState
    }

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        if let errorToThrow {
            throw errorToThrow
        }
        registrationState = stateAfterSuccessfulSet ?? (enabled ? .enabled : .disabled)
    }

    func openSystemSettingsLoginItems() {
        openedSettings = true
    }
}
