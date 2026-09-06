import Foundation

/// Runtime availability for shortcuts that record speech and then act on text in
/// another app. Onboarding intent chooses initial defaults, but must not remain a
/// permanent eligibility gate after setup.
enum ShortcutFeatureEnablementPolicy {
    enum Outcome: Equatable {
        case disabled
        case waitForPermissions
        case ready
    }

    static let missingPermissionsMessage =
        "Grant Microphone, Accessibility, and Input Monitoring to use this shortcut."

    static func hasRequiredPermissions(_ permissions: OnboardingPermissionSnapshot) -> Bool {
        OnboardingPermissionGate.hasRequiredDictationPermissions(permissions)
    }

    static func outcome(
        hasCompletedOnboarding: Bool,
        isEnabled: Bool,
        permissions: OnboardingPermissionSnapshot
    ) -> Outcome {
        guard hasCompletedOnboarding, isEnabled else { return .disabled }
        return hasRequiredPermissions(permissions) ? .ready : .waitForPermissions
    }
}
