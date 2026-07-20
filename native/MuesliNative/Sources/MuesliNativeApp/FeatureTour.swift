import Foundation

struct MarketingVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ value: String) {
        let numericPrefix = value.split(separator: "-", maxSplits: 1).first ?? Substring(value)
        let parts = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        var parsedComponents: [Int] = []
        parsedComponents.reserveCapacity(parts.count)
        for part in parts {
            guard let component = Int(part) else { return nil }
            parsedComponents.append(component)
        }
        components = parsedComponents
    }

    static func == (lhs: MarketingVersion, rhs: MarketingVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: MarketingVersion, rhs: MarketingVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum FeatureTourTarget: String, Hashable {
    case insightsEntry
    case dictionarySuggestions
    case meetingsSidebar
    case liveCaptionsSetting
    case cloudCleanupSetting
    case streamingModels
    case experimentalModels

    var modelsCategory: ModelsCategory? {
        switch self {
        case .streamingModels:
            return .streaming
        case .experimentalModels:
            return .dictation
        case .insightsEntry, .dictionarySuggestions, .meetingsSidebar, .liveCaptionsSetting, .cloudCleanupSetting:
            return nil
        }
    }
}

struct FeatureTourStep: Identifiable, Equatable {
    let id: String
    let eyebrow: String
    let title: String
    let message: String
    let systemImage: String
    let target: FeatureTourTarget
}

struct FeatureTour: Equatable {
    let version: String
    let steps: [FeatureTourStep]

    var displayVersion: String {
        guard let marketingVersion = MarketingVersion(version) else { return version }
        return marketingVersion.components.prefix(2).map(String.init).joined(separator: ".")
    }
}

extension AppState {
    var activeFeatureTourTarget: FeatureTourTarget? {
        guard let activeFeatureTour,
              activeFeatureTour.steps.indices.contains(featureTourStepIndex) else { return nil }
        return activeFeatureTour.steps[featureTourStepIndex].target
    }
}

enum FeatureTourCatalog {
    static var latest: FeatureTour {
        latest(includeCloudCleanup: false)
    }

    static func latest(includeCloudCleanup: Bool) -> FeatureTour {
        var steps = [
            FeatureTourStep(
                id: "insights",
                eyebrow: "LOCAL INSIGHTS",
                title: "Your stats now open Insights",
                message: "Select any stat card to explore private word, meeting, pace, streak, and daily activity trends calculated from your local history.",
                systemImage: "chart.bar.xaxis",
                target: .insightsEntry
            ),
            FeatureTourStep(
                id: "dictionary-suggestions",
                eyebrow: "SMARTER DICTIONARY",
                title: "Turn corrections into custom words",
                message: "Dictionary suggestions stay off by default. Turn them on to let Muesli notice corrections after dictation and offer a one-click way to remember names, brands, and domain terms.",
                systemImage: "text.book.closed.fill",
                target: .dictionarySuggestions
            ),
            FeatureTourStep(
                id: "meeting-workspace",
                eyebrow: "MEETING WORKSPACE",
                title: "Continue work after the call",
                message: "Open Meetings to see what is coming up, resume a recording, follow detected links, organize folders, and export notes, transcripts, or compressed audio.",
                systemImage: "person.2.fill",
                target: .meetingsSidebar
            ),
            FeatureTourStep(
                id: "live-captions",
                eyebrow: "LIVE MEETING CAPTIONS",
                title: "Choose how meetings appear live",
                message: "Live captions remain off by default. Download a supported streaming model, then choose it here to preview speech while a meeting is running.",
                systemImage: "captions.bubble.fill",
                target: .liveCaptionsSetting
            ),
        ]

        if includeCloudCleanup {
            steps.append(FeatureTourStep(
                id: "cloud-cleanup",
                eyebrow: "CLOUD DICTATION CLEANUP",
                title: "Your ChatGPT connection can refine dictation",
                message: "Choose ChatGPT as the cleanup backend to remove filler words, format spoken lists, and apply your cleanup preset after local transcription.",
                systemImage: "wand.and.stars",
                target: .cloudCleanupSetting
            ))
        }

        steps.append(contentsOf: [
            FeatureTourStep(
                id: "streaming-models",
                eyebrow: "LIVE MODEL OPTIONS",
                title: "Choose your live transcription engine",
                message: "The Streaming tab groups Nemotron 3.5 for live and final meeting transcripts with Parakeet Realtime for low-latency live preview.",
                systemImage: "waveform.badge.mic",
                target: .streamingModels
            ),
            FeatureTourStep(
                id: "experimental-models",
                eyebrow: "EXPERIMENTAL MODELS",
                title: "Try new local dictation backends",
                message: "Expand Experimental to evaluate SenseVoice, Qwen3 ASR, Indic ASR, and Gemma 4 without mixing them into the default model choices.",
                systemImage: "cpu",
                target: .experimentalModels
            )
        ])

        return FeatureTour(version: "0.8.0", steps: steps)
    }
}

enum FeatureTourPresentationPolicy {
    static func shouldPresentAutomatically(
        currentVersion: String,
        previousVersion: String?,
        lastPresentedTourVersion: String?,
        hasCompletedOnboarding: Bool,
        tour: FeatureTour
    ) -> Bool {
        guard hasCompletedOnboarding,
              let current = MarketingVersion(currentVersion),
              let target = MarketingVersion(tour.version),
              current >= target else {
            return false
        }

        if let lastPresentedTourVersion,
           let lastPresented = MarketingVersion(lastPresentedTourVersion),
           lastPresented >= target {
            return false
        }

        guard let previousVersion else {
            // 0.8 is the first release with this marker. A completed onboarding
            // identifies an existing pre-0.8 install rather than a fresh install.
            return true
        }
        guard let previous = MarketingVersion(previousVersion) else { return true }
        return previous < target
    }
}

final class FeatureTourStore {
    private enum Key {
        static let lastLaunchedVersion = "featureTour.lastLaunchedVersion"
        static let lastPresentedVersion = "featureTour.lastPresentedVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func automaticTour(
        currentVersion: String,
        hasCompletedOnboarding: Bool,
        canPresent: Bool,
        tour: FeatureTour = FeatureTourCatalog.latest
    ) -> FeatureTour? {
        if !hasCompletedOnboarding {
            defaults.set(currentVersion, forKey: Key.lastLaunchedVersion)
            return nil
        }

        // Permission-repair onboarding owns the foreground. Leave the previous
        // version untouched so the tour remains eligible on the next healthy launch.
        guard canPresent else { return nil }

        let shouldPresent = FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: currentVersion,
            previousVersion: defaults.string(forKey: Key.lastLaunchedVersion),
            lastPresentedTourVersion: defaults.string(forKey: Key.lastPresentedVersion),
            hasCompletedOnboarding: true,
            tour: tour
        )
        defaults.set(currentVersion, forKey: Key.lastLaunchedVersion)
        return shouldPresent ? tour : nil
    }

    func markOffered(_ tour: FeatureTour) {
        defaults.set(tour.version, forKey: Key.lastPresentedVersion)
    }
}
