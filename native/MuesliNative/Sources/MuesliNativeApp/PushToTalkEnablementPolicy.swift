import Foundation

struct PushToTalkEnablementIntentStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "pushToTalk.pendingEnable"
    ) {
        self.defaults = defaults
        self.key = key
    }

    var isPending: Bool {
        defaults.bool(forKey: key)
    }

    func markPending() {
        defaults.set(true, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

enum PushToTalkEnablementPolicy {
    enum PermissionProfile: String, Equatable {
        case voiceNote = "voice_note"
        case paste = "paste"

        static func resolved(for useCase: OnboardingUseCase) -> Self {
            useCase.includesVoiceNotes && !useCase.includesDictation
                ? .voiceNote
                : .paste
        }

        func hasRequiredPermissions(_ permissions: OnboardingPermissionSnapshot) -> Bool {
            switch self {
            case .voiceNote:
                OnboardingPermissionGate.hasRequiredVoiceNotesPermissions(permissions)
            case .paste:
                OnboardingPermissionGate.hasRequiredDictationPermissions(permissions)
            }
        }

        var requiresAccessibility: Bool {
            self == .paste
        }
    }

    enum Outcome: Equatable {
        case disabled
        case ready
        case waitForPermissions
    }

    static func shouldStartDictationHotkeyMonitor(
        hasCompletedOnboarding: Bool,
        hasRequiredPermissions: Bool,
        isEnabled: Bool
    ) -> Bool {
        hasCompletedOnboarding && hasRequiredPermissions && isEnabled
    }

    static func shouldReconcilePendingEnable(
        hasCompletedOnboarding: Bool,
        isPending: Bool
    ) -> Bool {
        hasCompletedOnboarding && isPending
    }

    static func outcome(
        isEnabled: Bool,
        hasRequiredPermissions: Bool
    ) -> Outcome {
        guard isEnabled else { return .disabled }
        return hasRequiredPermissions ? .ready : .waitForPermissions
    }
}
