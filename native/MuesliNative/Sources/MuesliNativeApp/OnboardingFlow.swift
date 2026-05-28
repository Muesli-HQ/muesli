import Foundation

enum OnboardingFlow {
    enum Step: Int {
        case welcome = 0
        case model = 1
        case hotkey = 2
        case permissions = 3
        case dictationTest = 4
        case meetingSummary = 5
        case googleCalendar = 6
    }

    static func orderedSteps(for useCase: OnboardingUseCase) -> [Int] {
        var steps = [Step.welcome.rawValue, Step.model.rawValue]
        if useCase.includesMeetings {
            steps += [Step.googleCalendar.rawValue]
        }
        if useCase.includesPushToTalk {
            steps += [Step.hotkey.rawValue, Step.permissions.rawValue, Step.dictationTest.rawValue]
        } else if useCase.includesMeetings {
            steps += [Step.permissions.rawValue]
        }
        if useCase.includesMeetings {
            steps += [Step.meetingSummary.rawValue]
        }
        return steps
    }

    static func normalizedStep(_ step: Int, for useCase: OnboardingUseCase) -> Int {
        let steps = orderedSteps(for: useCase)
        if steps.contains(step) { return step }
        let requestedRank = flowRank(for: step)
        return steps.first { flowRank(for: $0) > requestedRank } ?? steps.last ?? Step.welcome.rawValue
    }

    static func stepIndex(_ step: Int, for useCase: OnboardingUseCase) -> Int {
        orderedSteps(for: useCase).firstIndex(of: step) ?? 0
    }

    static func canGoBack(from step: Int, useCase: OnboardingUseCase, dictationTestSucceeded: Bool) -> Bool {
        guard stepIndex(step, for: useCase) > 0 else { return false }
        return !(step == Step.dictationTest.rawValue && dictationTestSucceeded)
    }

    static func completionTab(for useCase: OnboardingUseCase) -> DashboardTab {
        useCase == .meetings ? .meetings : .dictations
    }

    private static func flowRank(for step: Int) -> Int {
        switch Step(rawValue: step) {
        case .welcome: return 0
        case .model: return 1
        case .googleCalendar: return 2
        case .hotkey: return 3
        case .permissions: return 4
        case .dictationTest: return 5
        case .meetingSummary: return 6
        case nil: return step
        }
    }
}
