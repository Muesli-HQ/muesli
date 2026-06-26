import Foundation

enum ContributionMilestoneAction: String, CaseIterable {
    case githubStar = "github_star"
    case buyMeCoffee = "buy_me_coffee"

    var url: URL {
        switch self {
        case .githubStar:
            return URL(string: "https://github.com/Muesli-HQ/muesli")!
        case .buyMeCoffee:
            return URL(string: "https://buymeacoffee.com/phequals7")!
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

    var id: String { "\(kind.rawValue):\(count)" }

    var title: String {
        switch kind {
        case .dictationWords:
            return "You crossed \(Self.formatCount(count)) words!"
        case .meetings:
            return "You captured \(Self.formatCount(count)) meetings!"
        }
    }

    var message: String {
        switch kind {
        case .dictationWords:
            return "That is a serious pile of words. If Muesli has been saving your fingers and your flow, a GitHub star or a coffee helps keep it moving."
        case .meetings:
            return "That is a lot of conversations turned into something useful. If Muesli has been keeping your meetings in order, a GitHub star or a coffee helps keep it moving."
        }
    }

    private static func formatCount(_ value: Int) -> String {
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
        buyMeCoffeeClicked: Bool
    ) -> Int? {
        guard !githubStarClicked || !buyMeCoffeeClicked else { return nil }
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
        dismissedThisLaunch: Bool
    ) -> ContributionMilestonePrompt? {
        guard !dismissedThisLaunch,
              let nextMilestone,
              total >= nextMilestone,
              !githubStarClicked || !buyMeCoffeeClicked else {
            return nil
        }

        return ContributionMilestonePrompt(
            kind: kind,
            count: nextMilestone,
            showGitHubStar: !githubStarClicked,
            showBuyMeCoffee: !buyMeCoffeeClicked
        )
    }
}
