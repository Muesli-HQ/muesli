import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("PushToTalkEnablementPolicy")
struct PushToTalkEnablementPolicyTests {

    @Test("meetings-only onboarding does not start the dictation hotkey monitor")
    func meetingsOnlyDoesNotStartDictationMonitor() {
        #expect(!PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: true,
            hasRequiredStartupPermissions: true,
            useCase: .meetings
        ))
        #expect(PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: true,
            hasRequiredStartupPermissions: true,
            useCase: .dictation
        ))
        #expect(PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: true,
            hasRequiredStartupPermissions: true,
            useCase: .dictationAndMeetings
        ))
        #expect(PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: true,
            hasRequiredStartupPermissions: true,
            useCase: .voiceNotes
        ))
    }

    @Test("incomplete onboarding never starts the dictation hotkey monitor")
    func incompleteOnboardingDoesNotStartDictationMonitor() {
        #expect(!PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: false,
            hasRequiredStartupPermissions: true,
            useCase: .dictation
        ))
        #expect(!PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: true,
            hasRequiredStartupPermissions: false,
            useCase: .dictation
        ))
    }

    @Test("enabling push-to-talk waits for dictation permissions before promoting meetings")
    func enableWaitsForDictationPermissions() {
        #expect(
            PushToTalkEnablementPolicy.outcome(
                currentUseCase: .meetings,
                hasDictationPermissions: false
            ) == .waitForPermissions(.dictationAndMeetings)
        )
        #expect(
            PushToTalkEnablementPolicy.outcome(
                currentUseCase: .meetings,
                hasDictationPermissions: true
            ) == .promote(.dictationAndMeetings)
        )
    }

    @Test("push-to-talk use cases are already enabled")
    func pushToTalkUseCasesAreAlreadyEnabled() {
        for useCase: OnboardingUseCase in [
            .voiceNotes,
            .dictation,
            .voiceNotesAndDictation,
            .voiceNotesAndMeetings,
            .dictationAndMeetings,
            .everything,
        ] {
            #expect(
                PushToTalkEnablementPolicy.outcome(
                    currentUseCase: useCase,
                    hasDictationPermissions: false
                ) == .alreadyEnabled
            )
        }
    }

    @Test("pending enablement survives controller recreation and can promote meetings")
    func pendingEnablementSurvivesRestart() throws {
        let suiteName = "PushToTalkEnablementIntentStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PushToTalkEnablementIntentStore(defaults: defaults).markPending()

        let relaunchedStore = PushToTalkEnablementIntentStore(defaults: defaults)
        #expect(relaunchedStore.isPending)
        #expect(
            PushToTalkEnablementPolicy.outcome(
                currentUseCase: .meetings,
                hasDictationPermissions: true
            ) == .promote(.dictationAndMeetings)
        )

        relaunchedStore.clear()
        #expect(!PushToTalkEnablementIntentStore(defaults: defaults).isPending)
    }
}
