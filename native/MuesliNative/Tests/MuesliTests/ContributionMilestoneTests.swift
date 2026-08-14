import Foundation
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
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false
        ) == 31_000)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 12_000,
            total: 30_500,
            intervalKind: .dictationWords,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false
        ) == 31_000)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: nil,
            total: 63,
            intervalKind: .meetings,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false
        ) == 75)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 31_000,
            total: 31_500,
            intervalKind: .dictationWords,
            githubStarClicked: true,
            buyMeCoffeeClicked: true,
            tweetClicked: true,
            linkedInClicked: true
        ) == nil)
    }

    @Test("stale stored milestones advance past current total")
    func staleStoredMilestonesAdvance() {
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 31_000,
            total: 31_500,
            intervalKind: .dictationWords,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false
        ) == 31_000)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 31_000,
            total: 33_000,
            intervalKind: .dictationWords,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false
        ) == 34_000)
        #expect(ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: 25,
            total: 63,
            intervalKind: .meetings,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false
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
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        ) == nil)

        let prompt = ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        )
        #expect(prompt?.kind == .dictationWords)
        #expect(prompt?.count == 31_000)
        #expect(prompt?.showGitHubStar == true)
        #expect(prompt?.showBuyMeCoffee == true)
        #expect(prompt?.showTweetAboutMuesli == false)
        #expect(prompt?.showPostOnLinkedIn == false)
    }

    @Test("meeting prompt is eligible after crossing stored meeting milestone")
    func meetingPromptEligibility() {
        #expect(ContributionMilestonePolicy.prompt(
            kind: .meetings,
            total: 24,
            nextMilestone: 25,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        ) == nil)

        let prompt = ContributionMilestonePolicy.prompt(
            kind: .meetings,
            total: 25,
            nextMilestone: 25,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        )
        #expect(prompt?.kind == .meetings)
        #expect(prompt?.count == 25)
        #expect(prompt?.title == "You captured 25 meetings!")
        #expect(prompt?.showTweetAboutMuesli == false)
        #expect(prompt?.showPostOnLinkedIn == false)
    }

    @Test("dismissal suppresses current launch and advances next prompt")
    func dismissalSuppression() {
        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: true
        ) == nil)
        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false,
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
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        ) == nil)
    }

    @Test("completed support actions reveal remaining word social actions")
    func remainingActions() {
        let wordPrompt = ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: true,
            buyMeCoffeeClicked: true,
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        )
        #expect(wordPrompt?.showGitHubStar == false)
        #expect(wordPrompt?.showBuyMeCoffee == false)
        #expect(wordPrompt?.showTweetAboutMuesli == true)
        #expect(wordPrompt?.showPostOnLinkedIn == true)
        #expect(wordPrompt?.message.contains("sharing your milestone") == true)
        #expect(wordPrompt?.message.contains("GitHub star") == false)
        #expect(wordPrompt?.message.contains("coffee") == false)

        let prompt = ContributionMilestonePolicy.prompt(
            kind: .meetings,
            total: 25,
            nextMilestone: 25,
            githubStarClicked: true,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        )
        #expect(prompt?.showGitHubStar == false)
        #expect(prompt?.showBuyMeCoffee == true)
        #expect(prompt?.showTweetAboutMuesli == false)
        #expect(prompt?.showPostOnLinkedIn == false)
    }

    @Test("word social actions are hidden until one support action is complete")
    func socialActionsRequireSupportAction() {
        let prompt = ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: false,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        )
        #expect(prompt?.showTweetAboutMuesli == false)
        #expect(prompt?.showPostOnLinkedIn == false)

        let socialPrompt = ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: true,
            buyMeCoffeeClicked: false,
            tweetClicked: false,
            linkedInClicked: false,
            dismissedThisLaunch: false
        )
        #expect(socialPrompt?.showTweetAboutMuesli == true)
        #expect(socialPrompt?.showPostOnLinkedIn == true)
    }

    @Test("all word actions must complete before word prompts stop")
    func allWordActionsComplete() {
        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: true,
            buyMeCoffeeClicked: true,
            tweetClicked: true,
            linkedInClicked: false,
            dismissedThisLaunch: false
        ) != nil)

        #expect(ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: 31_000,
            nextMilestone: 31_000,
            githubStarClicked: true,
            buyMeCoffeeClicked: true,
            tweetClicked: true,
            linkedInClicked: true,
            dismissedThisLaunch: false
        ) == nil)
    }

    @Test("share message and URLs include encoded milestone content")
    func shareMessageAndURLs() throws {
        let message = ContributionSocialShare.message(wordCount: 31_000)
        #expect(message == "I've dictated 31,000 words with Muesli. It's fast, open source, on-device, and free to use. Try it: https://muesli.works")

        let tweetURL = ContributionSocialShare.tweetURL(wordCount: 31_000)
        #expect(tweetURL.absoluteString.starts(with: "https://x.com/intent/tweet?text="))
        #expect(tweetURL.absoluteString.contains("31,000"))
        #expect(tweetURL.absoluteString.contains("Try%20it"))

        let linkedInURL = ContributionSocialShare.linkedInURL(wordCount: 31_000)
        let components = try #require(URLComponents(url: linkedInURL, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.scheme == "https")
        #expect(components.host == "www.linkedin.com")
        #expect(components.path == "/feed/")
        #expect(queryItems["shareActive"] == "true")
        #expect(queryItems["text"] == message)
        #expect(queryItems["url"] == "https://muesli.works")
        #expect(queryItems["shareUrl"] == "https://muesli.works")
        #expect(queryItems["linkOrigin"] == "LI_BADGE")
    }

    @Test("sidebar completed word milestone uses latest thousand boundary")
    func completedWordMilestone() {
        #expect(ContributionSocialShare.completedWordMilestone(totalWords: 999) == nil)
        #expect(ContributionSocialShare.completedWordMilestone(totalWords: 1_000) == 1_000)
        #expect(ContributionSocialShare.completedWordMilestone(totalWords: 31_999) == 31_000)
    }
}
