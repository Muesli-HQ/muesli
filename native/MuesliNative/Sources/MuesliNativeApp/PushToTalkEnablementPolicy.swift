import Foundation

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
