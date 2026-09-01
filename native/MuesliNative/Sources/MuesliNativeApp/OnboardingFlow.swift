import Foundation

enum OnboardingFlow {
    struct UseCaseSelectionState: Equatable {
        let selectedUseCase: OnboardingUseCase
        let selectionBeforeEverything: OnboardingUseCase?
    }

    enum PermissionAdvanceAction: Equatable {
        case restartForDictationTest
        case finish
        case next
    }

    enum DictationTestMonitorAction: Equatable {
        case start
        case stop(cancelTestDictation: Bool)
        case none
    }

    enum Step: Int {
        case welcome = 0
        case model = 1
        case hotkey = 2
        case permissions = 3
        case dictationTest = 4
        case meetingSummary = 5
        case googleCalendar = 6
    }

    static let dictationTestStep = Step.dictationTest.rawValue

    static func hasCompletedPermissionsStep(resumingAt step: Int) -> Bool {
        step > Step.permissions.rawValue
    }

    static func shouldSchedulePermissionAdvance(
        currentStep: Int,
        requiredPermissionsGranted: Bool,
        hasCompletedPermissionsStep: Bool,
        hasScheduledTask: Bool
    ) -> Bool {
        currentStep == Step.permissions.rawValue
            && requiredPermissionsGranted
            && !hasCompletedPermissionsStep
            && !hasScheduledTask
    }

    static func toggling(
        _ capability: OnboardingCapability,
        in state: UseCaseSelectionState
    ) -> UseCaseSelectionState {
        UseCaseSelectionState(
            selectedUseCase: state.selectedUseCase.toggling(capability),
            selectionBeforeEverything: nil
        )
    }

    static func togglingEverything(in state: UseCaseSelectionState) -> UseCaseSelectionState {
        if state.selectedUseCase == .everything {
            guard let previousSelection = state.selectionBeforeEverything else { return state }
            return UseCaseSelectionState(
                selectedUseCase: previousSelection,
                selectionBeforeEverything: nil
            )
        }
        return UseCaseSelectionState(
            selectedUseCase: .everything,
            selectionBeforeEverything: state.selectedUseCase
        )
    }

    static func permissionAdvanceAction(
        for useCase: OnboardingUseCase,
        currentStepIndex: Int,
        orderedStepCount: Int,
        hasCompletedPermissionsStep: Bool = false
    ) -> PermissionAdvanceAction {
        if hasCompletedPermissionsStep {
            return currentStepIndex == orderedStepCount - 1 ? .finish : .next
        }
        if useCase.includesPushToTalk { return .restartForDictationTest }
        if currentStepIndex == orderedStepCount - 1 { return .finish }
        return .next
    }

    static func shouldReclassifyVoiceNotesAsDictation(
        previousUseCase: OnboardingUseCase,
        permissions: OnboardingPermissionSnapshot
    ) -> Bool {
        previousUseCase == .voiceNotes
            && OnboardingPermissionGate.hasRequiredDictationPermissions(permissions)
    }

    static func shouldStartDictationTestMonitor(
        currentStep: Int,
        dictationTestStep: Int,
        modelReady: Bool
    ) -> Bool {
        modelReady && currentStep >= dictationTestStep
    }

    static func dictationTestMonitorAction(
        currentStep: Int,
        dictationTestStep: Int,
        modelReady: Bool,
        monitorActive: Bool,
        dictationTesting: Bool
    ) -> DictationTestMonitorAction {
        guard currentStep >= dictationTestStep else { return .none }
        guard currentStep == dictationTestStep else {
            return monitorActive ? .stop(cancelTestDictation: dictationTesting) : .none
        }
        guard modelReady else {
            return .stop(cancelTestDictation: dictationTesting)
        }
        return monitorActive ? .none : .start
    }

    static func orderedSteps(for useCase: OnboardingUseCase) -> [Int] {
        var steps = [Step.welcome.rawValue, Step.model.rawValue]
        if useCase.includesPushToTalk {
            steps += [Step.hotkey.rawValue, Step.permissions.rawValue, Step.dictationTest.rawValue]
        } else if useCase.includesMeetings {
            steps += [Step.permissions.rawValue]
        }
        if useCase.includesMeetings {
            steps += [Step.meetingSummary.rawValue, Step.googleCalendar.rawValue]
        }
        return steps
    }

    static func normalizedStep(_ step: Int, for useCase: OnboardingUseCase) -> Int {
        let steps = orderedSteps(for: useCase)
        if steps.contains(step) { return step }
        return steps.first { $0 > step } ?? steps.last ?? Step.welcome.rawValue
    }

    static func stepIndex(_ step: Int, for useCase: OnboardingUseCase) -> Int {
        orderedSteps(for: useCase).firstIndex(of: step) ?? 0
    }

    static func canGoBack(from step: Int, useCase: OnboardingUseCase, dictationTestSucceeded: Bool) -> Bool {
        guard stepIndex(step, for: useCase) > 0 else { return false }
        return !(step == Step.dictationTest.rawValue && dictationTestSucceeded)
    }

    static func completionTab(for useCase: OnboardingUseCase) -> DashboardTab {
        useCase.includesMeetings && !useCase.includesPushToTalk ? .meetings : .dictations
    }
}
