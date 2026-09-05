import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("PushToTalkEnablementPolicy")
struct PushToTalkEnablementPolicyTests {

    @Test("disabled Push to Talk does not start the dictation hotkey monitor")
    func disabledPushToTalkDoesNotStartDictationMonitor() {
        #expect(!PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: true,
            hasDictationPermissions: true,
            isEnabled: false
        ))
        #expect(PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: true,
            hasDictationPermissions: true,
            isEnabled: true
        ))
    }

    @Test("incomplete onboarding never starts the dictation hotkey monitor")
    func incompleteOnboardingDoesNotStartDictationMonitor() {
        #expect(!PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: false,
            hasDictationPermissions: true,
            isEnabled: true
        ))
        #expect(!PushToTalkEnablementPolicy.shouldStartDictationHotkeyMonitor(
            hasCompletedOnboarding: true,
            hasDictationPermissions: false,
            isEnabled: true
        ))
    }

    @Test("enabled Push to Talk waits for dictation permissions")
    func enableWaitsForDictationPermissions() {
        #expect(
            PushToTalkEnablementPolicy.outcome(
                isEnabled: true,
                hasDictationPermissions: false
            ) == .waitForPermissions
        )
        #expect(
            PushToTalkEnablementPolicy.outcome(
                isEnabled: true,
                hasDictationPermissions: true
            ) == .ready
        )
    }

    @Test("disabled Push to Talk remains disabled regardless of permissions")
    func disabledPushToTalkRemainsDisabled() {
        #expect(
            PushToTalkEnablementPolicy.outcome(
                isEnabled: false,
                hasDictationPermissions: true
            ) == .disabled
        )
    }

    @Test("permission reconciliation stops after pending enablement clears")
    func reconciliationOnlyRunsWhileEnablementIsPending() {
        #expect(PushToTalkEnablementPolicy.shouldReconcilePendingEnable(
            hasCompletedOnboarding: true,
            isPending: true
        ))
        #expect(!PushToTalkEnablementPolicy.shouldReconcilePendingEnable(
            hasCompletedOnboarding: true,
            isPending: false
        ))
        #expect(!PushToTalkEnablementPolicy.shouldReconcilePendingEnable(
            hasCompletedOnboarding: false,
            isPending: true
        ))
    }

    @Test("pending enablement survives controller recreation")
    func pendingEnablementSurvivesRestart() throws {
        let suiteName = "PushToTalkEnablementIntentStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PushToTalkEnablementIntentStore(defaults: defaults).markPending()

        let relaunchedStore = PushToTalkEnablementIntentStore(defaults: defaults)
        #expect(relaunchedStore.isPending)
        #expect(
            PushToTalkEnablementPolicy.outcome(
                isEnabled: true,
                hasDictationPermissions: true
            ) == .ready
        )

        relaunchedStore.clear()
        #expect(!PushToTalkEnablementIntentStore(defaults: defaults).isPending)
    }
}
