import Testing
@testable import MuesliNativeApp

@Suite("ContributionMilestone")
struct ContributionMilestoneTests {

    @Test("next milestone is strict thousand boundary")
    func nextMilestone() {
        #expect(ContributionMilestonePolicy.nextMilestone(after: 0) == 1_000)
        #expect(ContributionMilestonePolicy.nextMilestone(after: 999) == 1_000)
        #expect(ContributionMilestonePolicy.nextMilestone(after: 1_000) == 2_000)
        #expect(ContributionMilestonePolicy.nextMilestone(after: 30_500) == 31_000)
        #expect(ContributionMilestonePolicy.nextMilestone(after: 30_500, kind: .dictationWords) == 31_000)
        #expect(ContributionMilestonePolicy.nextMeetingMilestone(after: 0) == 25)
        #expect(ContributionMilestonePolicy.nextMeetingMilestone(after: 24) == 25)
        #expect(ContributionMilestonePolicy.nextMeetingMilestone(after: 25) == 50)
        #expect(ContributionMilestonePolicy.nextMeetingMilestone(after: 63) == 75)
        #expect(ContributionMilestonePolicy.nextMilestone(after: 63, kind: .meetings) == 75)
    }

    @Test("stored milestone is initialized from current total")
    func resolvedNextMilestone() {
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: nil,
            total: 30_500,
            intervalKind: .dictationWords,
            githubStarClicked: false,
            buyMeCoffeeClicked: false
        ) == 31_000)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 12_000,
            total: 30_500,
            intervalKind: .dictationWords,
            githubStarClicked: false,
            buyMeCoffeeClicked: false
        ) == 31_000)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: nil,
            total: 63,
            intervalKind: .meetings,
            githubStarClicked: false,
            buyMeCoffeeClicked: false
        ) == 75)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 31_000,
            total: 31_500,
            intervalKind: .dictationWords,
            githubStarClicked: true,
            buyMeCoffeeClicked: true
        ) == nil)
    }

    @Test("stale stored milestones advance past current total")
    func staleStoredMilestonesAdvance() {
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 31_000,
            total: 31_500,
            intervalKind: .dictationWords,
            githubStarClicked: false,
            buyMeCoffeeClicked: false
        ) == 31_000)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 31_000,
            total: 33_000,
            intervalKind: .dictationWords,
            githubStarClicked: false,
            buyMeCoffeeClicked: false
        ) == 34_000)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 25,
            total: 63,
            intervalKind: .meetings,
            githubStarClicked: false,
            buyMeCoffeeClicked: false
        ) == 75)
    }

    @Test("prompt is eligible only after crossing stored milestone")
    func promptEligibility() {
        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 30_999,
            nextMilestone: 31_000,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            dismissedThisLaunch: false
        ) == nil)

        let prompt = ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            dismissedThisLaunch: false
        )
        #expect(prompt?.kind == .dictationWords)
        #expect(prompt?.count == 31_000)
        #expect(prompt?.showGitHubStar == true)
        #expect(prompt?.showBuyMeCoffee == true)
    }

    @Test("meeting prompt is eligible after crossing stored meeting milestone")
    func meetingPromptEligibility() {
        #expect(ContributionMilestonePolicy.prompt(
            kind: .meetings,
            total: 24,
            nextMilestone: 25,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            dismissedThisLaunch: false
        ) == nil)

        let prompt = ContributionMilestonePolicy.prompt(
            kind: .meetings,
            total: 25,
            nextMilestone: 25,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            dismissedThisLaunch: false
        )
        #expect(prompt?.kind == .meetings)
        #expect(prompt?.count == 25)
        #expect(prompt?.title == "You captured 25 meetings!")
    }

    @Test("dismissal suppresses current launch and advances next prompt")
    func dismissalSuppression() {
        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            dismissedThisLaunch: true
        ) == nil)
        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            dismissedThisLaunch: false
        ) != nil)

        let nextAfterDismissal = ContributionMilestonePolicy.nextMilestone(after: 31_500, kind: .dictationWords)
        #expect(nextAfterDismissal == 32_000)
        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_500,
            nextMilestone: nextAfterDismissal,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            dismissedThisLaunch: false
        ) == nil)
    }

    @Test("completed actions control remaining prompt actions")
    func remainingActions() {
        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: true,
            buyMeCoffeeClicked: true,
            dismissedThisLaunch: false
        ) == nil)

        let prompt = ContributionMilestonePolicy.prompt(
            kind: .meetings,
            total: 25,
            nextMilestone: 25,
            githubStarClicked: true,
            buyMeCoffeeClicked: false,
            dismissedThisLaunch: false
        )
        #expect(prompt?.showGitHubStar == false)
        #expect(prompt?.showBuyMeCoffee == true)
    }
}
