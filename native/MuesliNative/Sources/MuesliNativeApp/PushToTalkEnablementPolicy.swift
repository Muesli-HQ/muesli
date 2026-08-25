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
    enum Outcome: Equatable {
        case alreadyEnabled
        case promote(OnboardingUseCase)
        case waitForPermissions(OnboardingUseCase)
    }

    static func shouldStartDictationHotkeyMonitor(
        hasCompletedOnboarding: Bool,
        hasRequiredStartupPermissions: Bool,
        useCase: OnboardingUseCase
    ) -> Bool {
        hasCompletedOnboarding && hasRequiredStartupPermissions && useCase.includesPushToTalk
    }

    static func outcome(
        currentUseCase: OnboardingUseCase,
        hasDictationPermissions: Bool
    ) -> Outcome {
        if currentUseCase.includesPushToTalk {
            return .alreadyEnabled
        }
        let promoted = currentUseCase.enablingPushToTalk
        if hasDictationPermissions {
            return .promote(promoted)
        }
        return .waitForPermissions(promoted)
    }
}
