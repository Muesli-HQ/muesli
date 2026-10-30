import Testing
@testable import MuesliNativeApp

@Suite("Settings permission refresh reasons")
struct SettingsPermissionRefreshReasonTests {
    @Test("permission requests reuse lifecycle-managed state")
    func permissionRequestsReuseLifecycleManagedState() {
        #expect(SettingsPermissionRefreshReason.permissionRequested.refreshesSystemAudio == false)
        #expect(SettingsPermissionRefreshReason.permissionRequested.refreshesLaunchAtLogin == false)
    }

    @Test("settings lifecycle boundaries refresh system-audio permission")
    func lifecycleBoundariesRefreshSystemAudioPermission() {
        #expect(SettingsPermissionRefreshReason.initialDisplay.refreshesSystemAudio)
        #expect(SettingsPermissionRefreshReason.settingsSelected.refreshesSystemAudio)
        #expect(SettingsPermissionRefreshReason.appActivated.refreshesSystemAudio)
    }

    @Test("only app activation refreshes launch-at-login state")
    func onlyAppActivationRefreshesLaunchAtLogin() {
        #expect(SettingsPermissionRefreshReason.initialDisplay.refreshesLaunchAtLogin == false)
        #expect(SettingsPermissionRefreshReason.settingsSelected.refreshesLaunchAtLogin == false)
        #expect(SettingsPermissionRefreshReason.appActivated.refreshesLaunchAtLogin)
    }
}
