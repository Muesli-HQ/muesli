import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("OnboardingFlow")
struct OnboardingFlowTests {
    @Test("voice notes orders push-to-talk steps without paste permission")
    func voiceNotesOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .voiceNotes) == [0, 1, 2, 3, 4])
    }

    @Test("dictation orders dictation-only steps")
    func dictationOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .dictation) == [0, 1, 2, 3, 4])
    }

    @Test("meetings orders meetings-only steps")
    func meetingsOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .meetings) == [0, 1, 3, 5, 6])
    }

    @Test("dictation and meetings orders combined steps")
    func dictationAndMeetingsOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .dictationAndMeetings) == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test("normalized step advances over skipped steps")
    func normalizedStepAdvancesOverSkippedSteps() {
        #expect(OnboardingFlow.normalizedStep(2, for: .meetings) == 3)
        #expect(OnboardingFlow.normalizedStep(4, for: .meetings) == 5)
    }

    @Test("normalized step keeps valid steps and clamps after final step")
    func normalizedStepKeepsValidAndClampsAfterFinalStep() {
        #expect(OnboardingFlow.normalizedStep(3, for: .meetings) == 3)
        #expect(OnboardingFlow.normalizedStep(99, for: .dictation) == 4)
        #expect(OnboardingFlow.normalizedStep(4, for: .voiceNotes) == 4)
    }

    @Test("can go back is disabled after successful dictation test")
    func canGoBackAfterSuccessfulDictationTest() {
        #expect(!OnboardingFlow.canGoBack(
            from: OnboardingFlow.Step.dictationTest.rawValue,
            useCase: .dictation,
            dictationTestSucceeded: true
        ))
        #expect(OnboardingFlow.canGoBack(
            from: OnboardingFlow.Step.dictationTest.rawValue,
            useCase: .dictation,
            dictationTestSucceeded: false
        ))
    }

    @Test("can go back is disabled at first step")
    func canGoBackAtFirstStep() {
        #expect(!OnboardingFlow.canGoBack(
            from: OnboardingFlow.Step.welcome.rawValue,
            useCase: .dictationAndMeetings,
            dictationTestSucceeded: false
        ))
    }

    @Test("completion tab routes meetings-only to meetings and others to dictations")
    func completionTab() {
        #expect(OnboardingFlow.completionTab(for: .meetings) == .meetings)
        #expect(OnboardingFlow.completionTab(for: .voiceNotes) == .dictations)
        #expect(OnboardingFlow.completionTab(for: .dictation) == .dictations)
        #expect(OnboardingFlow.completionTab(for: .dictationAndMeetings) == .dictations)
    }

    @Test("stale permission hint waits for elapsed settings time")
    func stalePermissionHintWaitsForElapsedSettingsTime() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        #expect(!OnboardingStalePermissionHintPolicy.shouldShowHint(
            now: startedAt.addingTimeInterval(29),
            startedAt: startedAt,
            grantingPermissionName: "Microphone",
            nativePermissionPromptName: nil,
            alreadyShown: false,
            delay: 30
        ))

        #expect(OnboardingStalePermissionHintPolicy.shouldShowHint(
            now: startedAt.addingTimeInterval(30),
            startedAt: startedAt,
            grantingPermissionName: "Microphone",
            nativePermissionPromptName: nil,
            alreadyShown: false,
            delay: 30
        ))
    }

    @Test("stale permission hint is suppressed while native prompt is visible")
    func stalePermissionHintSuppressesNativePromptWait() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        #expect(!OnboardingStalePermissionHintPolicy.shouldShowHint(
            now: startedAt.addingTimeInterval(45),
            startedAt: startedAt,
            grantingPermissionName: "Microphone",
            nativePermissionPromptName: "Microphone",
            alreadyShown: false,
            delay: 30
        ))
    }

    @Test("stale permission hint requires active grant attempt")
    func stalePermissionHintRequiresActiveGrantAttempt() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        #expect(!OnboardingStalePermissionHintPolicy.shouldShowHint(
            now: startedAt.addingTimeInterval(45),
            startedAt: nil,
            grantingPermissionName: "Microphone",
            nativePermissionPromptName: nil,
            alreadyShown: false,
            delay: 30
        ))

        #expect(!OnboardingStalePermissionHintPolicy.shouldShowHint(
            now: startedAt.addingTimeInterval(45),
            startedAt: startedAt,
            grantingPermissionName: nil,
            nativePermissionPromptName: nil,
            alreadyShown: false,
            delay: 30
        ))

        #expect(!OnboardingStalePermissionHintPolicy.shouldShowHint(
            now: startedAt.addingTimeInterval(45),
            startedAt: startedAt,
            grantingPermissionName: "Microphone",
            nativePermissionPromptName: nil,
            alreadyShown: true,
            delay: 30
        ))
    }
}
