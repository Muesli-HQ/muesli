import Testing
@testable import MuesliNativeApp

@Suite("ShortcutFeatureEnablementPolicy")
struct ShortcutFeatureEnablementPolicyTests {
    private let allShortcutPermissions = OnboardingPermissionSnapshot(
        microphone: true,
        accessibility: true,
        inputMonitoring: true,
        systemAudio: false,
        screenRecording: false
    )

    @Test("enabled shortcut is ready regardless of original onboarding use case")
    func enabledShortcutUsesCurrentPermissions() {
        #expect(ShortcutFeatureEnablementPolicy.outcome(
            hasCompletedOnboarding: true,
            isEnabled: true,
            permissions: allShortcutPermissions
        ) == .ready)
    }

    @Test("permission grants do not enable a shortcut whose toggle is off")
    func permissionsDoNotChangeFeaturePreference() {
        #expect(ShortcutFeatureEnablementPolicy.outcome(
            hasCompletedOnboarding: true,
            isEnabled: false,
            permissions: allShortcutPermissions
        ) == .disabled)
    }

    @Test("enabled shortcut waits until all interaction permissions are granted")
    func enabledShortcutWaitsForPermissions() {
        let missingAccessibility = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: true,
            systemAudio: true,
            screenRecording: true
        )

        #expect(ShortcutFeatureEnablementPolicy.outcome(
            hasCompletedOnboarding: true,
            isEnabled: true,
            permissions: missingAccessibility
        ) == .waitForPermissions)
    }

    @Test("shortcuts remain inactive until onboarding completes")
    func incompleteOnboardingDoesNotStartShortcuts() {
        #expect(ShortcutFeatureEnablementPolicy.outcome(
            hasCompletedOnboarding: false,
            isEnabled: true,
            permissions: allShortcutPermissions
        ) == .disabled)
    }
}
