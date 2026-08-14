import Foundation

enum ContributionMilestoneAction: String, CaseIterable {
    case githubStar = "github_star"
    case buyMeCoffee = "buy_me_coffee"
    case tweetAboutMuesli = "tweet_about_muesli"
    case postOnLinkedIn = "post_on_linkedin"

    var supportURL: URL? {
        switch self {
        case .githubStar:
            return URL(string: "https://github.com/Muesli-HQ/muesli")!
        case .buyMeCoffee:
            return URL(string: "https://buymeacoffee.com/phequals7")!
        case .tweetAboutMuesli, .postOnLinkedIn:
            return nil
        }
    }
}

enum ContributionMilestoneKind: String {
    case dictationWords = "dictation_words"
    case meetings
}

struct ContributionMilestonePrompt: Equatable, Identifiable {
    let kind: ContributionMilestoneKind
    let count: Int
    let showGitHubStar: Bool
    let showBuyMeCoffee: Bool
    let showTweetAboutMuesli: Bool
    let showPostOnLinkedIn: Bool

    var id: String { "\(kind.rawValue):\(count)" }

    var title: String {
        switch kind {
        case .dictationWords:
            return "You crossed \(ContributionSocialShare.formatCount(count)) words!"
        case .meetings:
            return "You captured \(ContributionSocialShare.formatCount(count)) meetings!"
        }
    }

    var message: String {
        switch kind {
        case .dictationWords:
            if !showGitHubStar && !showBuyMeCoffee && (showTweetAboutMuesli || showPostOnLinkedIn) {
                return "That is a serious pile of words. If Muesli has been saving your fingers and your flow, sharing your milestone helps more people find it."
            }
            return "That is a serious pile of words. If Muesli has been saving your fingers and your flow, a GitHub star or a coffee helps keep it moving."
        case .meetings:
            return "That is a lot of conversations turned into something useful. If Muesli has been keeping your meetings in order, a GitHub star or a coffee helps keep it moving."
        }
    }
}

enum ContributionSocialShare {
    static let muesliURL = URL(string: "https://muesli.works")!

    static func completedWordMilestone(totalWords: Int) -> Int? {
        let clampedTotal = max(totalWords, 0)
        guard clampedTotal >= ContributionMilestonePolicy.dictationWordInterval else { return nil }
        return (clampedTotal / ContributionMilestonePolicy.dictationWordInterval) * ContributionMilestonePolicy.dictationWordInterval
    }

    static func message(wordCount: Int) -> String {
        "I've dictated \(formatCount(wordCount)) words with Muesli. It's fast, open source, on-device, and free to use. Try it: \(muesliURL.absoluteString)"
    }

    static func tweetURL(wordCount: Int) -> URL {
        var components = URLComponents(string: "https://x.com/intent/tweet")!
        components.queryItems = [
            URLQueryItem(name: "text", value: message(wordCount: wordCount)),
        ]
        return components.url!
    }

    static func linkedInURL(wordCount: Int) -> URL {
        var components = URLComponents(string: "https://www.linkedin.com/feed/")!
        components.queryItems = [
            URLQueryItem(name: "shareActive", value: "true"),
            URLQueryItem(name: "text", value: message(wordCount: wordCount)),
            URLQueryItem(name: "url", value: muesliURL.absoluteString),
            URLQueryItem(name: "shareUrl", value: muesliURL.absoluteString),
            URLQueryItem(name: "linkOrigin", value: "LI_BADGE"),
        ]
        return components.url!
    }

    static func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

enum ContributionMilestonePolicy {
    static let dictationWordInterval = 1_000
    static let meetingInterval = 25

    static func nextMilestone(after totalWords: Int) -> Int {
        nextMilestone(after: totalWords, interval: dictationWordInterval)
    }

    static func nextMeetingMilestone(after totalMeetings: Int) -> Int {
        nextMilestone(after: totalMeetings, interval: meetingInterval)
    }

    static func nextMilestone(after total: Int, kind: ContributionMilestoneKind) -> Int {
        switch kind {
        case .dictationWords:
            return nextMilestone(after: total)
        case .meetings:
            return nextMeetingMilestone(after: total)
        }
    }

    private static func nextMilestone(after total: Int, interval: Int) -> Int {
        let clampedTotal = max(total, 0)
        return ((clampedTotal / interval) + 1) * interval
    }

    static func resolvedNextMilestone(
        storedNextMilestone: Int?,
        total: Int,
        intervalKind: ContributionMilestoneKind,
        githubStarClicked: Bool,
        buyMeCoffeeClicked: Bool,
        tweetClicked: Bool = false,
        linkedInClicked: Bool = false
    ) -> Int? {
        let isComplete: Bool
        switch intervalKind {
        case .dictationWords:
            isComplete = githubStarClicked && buyMeCoffeeClicked && tweetClicked && linkedInClicked
        case .meetings:
            isComplete = githubStarClicked && buyMeCoffeeClicked
        }
        guard !isComplete else { return nil }
        guard let storedNextMilestone else {
            switch intervalKind {
            case .dictationWords:
                return nextMilestone(after: total)
            case .meetings:
                return nextMeetingMilestone(after: total)
            }
        }

        switch intervalKind {
        case .dictationWords:
            guard total >= storedNextMilestone + dictationWordInterval else { return storedNextMilestone }
            return nextMilestone(after: total)
        case .meetings:
            guard total >= storedNextMilestone + meetingInterval else { return storedNextMilestone }
            return nextMeetingMilestone(after: total)
        }
    }

    static func prompt(
        kind: ContributionMilestoneKind,
        total: Int,
        nextMilestone: Int?,
        githubStarClicked: Bool,
        buyMeCoffeeClicked: Bool,
        tweetClicked: Bool = false,
        linkedInClicked: Bool = false,
        dismissedThisLaunch: Bool
    ) -> ContributionMilestonePrompt? {
        guard !dismissedThisLaunch,
              let nextMilestone,
              total >= nextMilestone else {
            return nil
        }

        let showGitHubStar = !githubStarClicked
        let showBuyMeCoffee = !buyMeCoffeeClicked
        let canShowSocialActions = kind == .dictationWords && (githubStarClicked || buyMeCoffeeClicked)
        let showTweetAboutMuesli = canShowSocialActions && !tweetClicked
        let showPostOnLinkedIn = canShowSocialActions && !linkedInClicked
        guard showGitHubStar || showBuyMeCoffee || showTweetAboutMuesli || showPostOnLinkedIn else {
            return nil
        }

        return ContributionMilestonePrompt(
            kind: kind,
            count: nextMilestone,
            showGitHubStar: showGitHubStar,
            showBuyMeCoffee: showBuyMeCoffee,
            showTweetAboutMuesli: showTweetAboutMuesli,
            showPostOnLinkedIn: showPostOnLinkedIn
        )
    }
}
