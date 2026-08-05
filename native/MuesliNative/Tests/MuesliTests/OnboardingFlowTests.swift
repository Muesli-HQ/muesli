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

    @Test("dictation monitor stops and cancels active testing when readiness is lost")
    func dictationMonitorStopsWhenReadinessIsLost() {
        #expect(OnboardingFlow.dictationTestMonitorAction(
            currentStep: OnboardingFlow.dictationTestStep,
            dictationTestStep: OnboardingFlow.dictationTestStep,
            modelReady: false,
            monitorActive: true,
            dictationTesting: true
        ) == .stop(cancelTestDictation: true))
    }

    @Test("dictation monitor does not start twice for repeated ready updates")
    func dictationMonitorDoesNotDuplicateStarts() {
        #expect(OnboardingFlow.dictationTestMonitorAction(
            currentStep: OnboardingFlow.dictationTestStep,
            dictationTestStep: OnboardingFlow.dictationTestStep,
            modelReady: true,
            monitorActive: false,
            dictationTesting: false
        ) == .start)
        #expect(OnboardingFlow.dictationTestMonitorAction(
            currentStep: OnboardingFlow.dictationTestStep,
            dictationTestStep: OnboardingFlow.dictationTestStep,
            modelReady: true,
            monitorActive: true,
            dictationTesting: false
        ) == .none)
    }

    @Test("dictation monitor does not start on a later meeting step")
    func dictationMonitorDoesNotStartAfterSkippedStep() {
        #expect(OnboardingFlow.dictationTestMonitorAction(
            currentStep: OnboardingFlow.Step.meetingSummary.rawValue,
            dictationTestStep: OnboardingFlow.dictationTestStep,
            modelReady: true,
            monitorActive: false,
            dictationTesting: false
        ) == .none)
        #expect(OnboardingFlow.dictationTestMonitorAction(
            currentStep: OnboardingFlow.Step.meetingSummary.rawValue,
            dictationTestStep: OnboardingFlow.dictationTestStep,
            modelReady: true,
            monitorActive: true,
            dictationTesting: true
        ) == .stop(cancelTestDictation: true))
    }

    @Test("extreme ETA values are omitted instead of overflowing")
    func extremeETAReturnsUnknown() {
        #expect(ModelDownloadDisplayFormatting.eta(Double.greatestFiniteMagnitude) == nil)
        #expect(ModelDownloadDisplayFormatting.eta(.infinity) == nil)
        #expect(ModelDownloadDisplayFormatting.eta(3_600) == "1h 00m")
    }
}
