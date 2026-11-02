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
    case chatSidebar
    case timeTurnerSidebar
    case searchSidebar
    case liveDictation
    case cotypistSettings
    case appFormatting
    case cleanupModels
    case recordingIndicatorStyle
    case computerUseShortcut
    case meetingSummaryProvider
    case meetingRetranscription
    case dictationRecordingMode
    case quillSettings
    case dictationProviderSetting
    case parakeetFamilyCard
    case bodhanFlexCard
    case timelineSidebar
    case timelineApplications
    case appleSpeechCard
    case meetingPeople
    case timelineFilters
    case modelLibrary
    case insightsEntry
    case dictionarySuggestions
    case meetingsSidebar
    case liveCaptionsSetting
    case cloudCleanupSetting
    case streamingModels
    case experimentalModels

    var navigationRoute: FeatureTourNavigationRoute {
        switch self {
        case .quillSettings, .cotypistSettings:
            return .settings(.experimental)
        case .dictationProviderSetting, .cloudCleanupSetting, .liveDictation, .appFormatting:
            return .settings(.dictation)
        case .chatSidebar:
            return .tab(.meetingChat)
        case .timeTurnerSidebar:
            return .tab(.timeTurner)
        case .searchSidebar:
            return .tab(.timeline)
        case .cleanupModels:
            return .models(.postProcessing)
        case .recordingIndicatorStyle:
            return .settings(.appearance)
        case .computerUseShortcut, .dictationRecordingMode:
            return .tab(.shortcuts)
        case .meetingRetranscription:
            return .meetingRetranscription
        case .liveCaptionsSetting, .meetingSummaryProvider:
            return .settings(.meetings)
        case .timelineSidebar, .timelineFilters, .insightsEntry:
            return .tab(.timeline)
        case .timelineApplications:
            return .timelineApplications
        case .dictionarySuggestions:
            return .tab(.dictionary)
        case .meetingsSidebar:
            return .meetingsBrowser
        case .meetingPeople:
            return .meetingPeople
        case .modelLibrary, .appleSpeechCard, .parakeetFamilyCard, .bodhanFlexCard, .experimentalModels:
            return .models(.dictation)
        case .streamingModels:
            return .models(.streaming)
        }
    }

    var modelsCategory: ModelsCategory? {
        guard case let .models(category) = navigationRoute else { return nil }
        return category
    }
}

enum FeatureTourNavigationRoute: Equatable {
    case settings(SettingsPane)
    case tab(DashboardTab)
    case models(ModelsCategory)
    case timelineApplications
    case meetingsBrowser
    case meetingPeople
    case meetingRetranscription
}

enum FeatureTourIcon: Equatable {
    case symbol(String)
    case quill
    case timeTurner
}

struct FeatureTourStep: Identifiable, Equatable {
    let id: String
    let eyebrow: String
    let title: String
    let message: String
    let icon: FeatureTourIcon
    let target: FeatureTourTarget?
}

struct FeatureTour: Equatable {
    let version: String
    let steps: [FeatureTourStep]

    var displayVersion: String {
        guard let marketingVersion = MarketingVersion(version) else { return version }
        var components = marketingVersion.components
        while components.count > 2, components.last == 0 {
            components.removeLast()
        }
        return components.map(String.init).joined(separator: ".")
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
        FeatureTour(version: "0.8.6", steps: [
            FeatureTourStep(
                id: "ask-meetings",
                eyebrow: "CHAT",
                title: "Ask your meetings",
                message: "Ask questions across saved meetings in Chat. Attach meetings with @, add images, PDFs or text files, and follow meeting citations to their source. Your selected provider processes the context you send.",
                icon: .symbol("bubble.left.and.bubble.right"),
                target: .chatSidebar
            ),
            FeatureTourStep(
                id: "time-turner",
                eyebrow: "EXPERIMENTAL",
                title: "Revisit your day with Time Turner",
                message: "Browse and search captured screen text and screenshots in Time Turner. Capture is off by default; enable it in Settings → Experimental. Screen history stays on this Mac. Generating a recap sends sampled text to your selected Meetings provider.",
                icon: .timeTurner,
                target: .timeTurnerSidebar
            ),
            FeatureTourStep(
                id: "live-dictation",
                eyebrow: "HANDS-FREE DICTATION",
                title: "Words as you speak",
                message: "With a supported local model, turn on “Watch text appear during hands-free mode” in Settings → Dictations. See words appear as you speak; enabled cleanup runs when you stop.",
                icon: .symbol("waveform"),
                target: .liveDictation
            ),
            FeatureTourStep(
                id: "quill-assistant",
                eyebrow: "QUILL",
                title: "Your spoken assistant",
                message: "Ask a question, follow up, or ask Quill to rewrite selected text. Answers appear in the notch; explicit editing requests can update your text. Configure Quill in Settings → Experimental. Hosted models receive the context needed for your request.",
                icon: .quill,
                target: .quillSettings
            ),
            FeatureTourStep(
                id: "cotypist",
                eyebrow: "EXPERIMENTAL",
                title: "A little help with your next words",
                message: "Cotypist suggests text as you type, using an on-device model. Set it up in Settings → Experimental, then use Tab to accept a suggestion or Option + Right Arrow to accept one word.",
                icon: .symbol("text.cursor"),
                target: .cotypistSettings
            ),
            FeatureTourStep(
                id: "app-formatting",
                eyebrow: "APP FORMATTING",
                title: "Dictation that fits each app",
                message: "Choose a writing style for each app in Settings → Dictations → App Formatting. Customize capitalization and the final period, or reuse a saved template. Your rules apply when you dictate into that app.",
                icon: .symbol("textformat"),
                target: .appFormatting
            ),
            FeatureTourStep(
                id: "meeting-screen-recording",
                eyebrow: "MEETINGS",
                title: "Keep the screen with your meeting",
                message: "During a meeting, open the recording controls and choose Record Screen… Select a window or display and confirm. The video is saved locally with the meeting; recording starts only when you choose it.",
                icon: .symbol("record.circle"),
                target: .meetingsSidebar
            ),
            FeatureTourStep(
                id: "global-search",
                eyebrow: "SEARCH",
                title: "One search across muesli",
                message: "Use Search in the sidebar or press ⌘F to find saved dictations, meetings, chats, writing history and Time Turner screen text. Filter by type, date or app, then open a result at its source.",
                icon: .symbol("magnifyingglass"),
                target: .searchSidebar
            ),
            FeatureTourStep(
                id: "asr-models",
                eyebrow: "LOCAL TRANSCRIPTION",
                title: "More models to try",
                message: "Explore Parakeet Redux and Phonon-2.5 for multilingual transcription, or try MedASR for English medical dictation. Download and compare them in Models → Dictation. MedASR requires acceptance of Google’s model terms.",
                icon: .symbol("cpu"),
                target: .modelLibrary
            ),
            FeatureTourStep(
                id: "cleanup-updates",
                eyebrow: "CLEANUP MODELS",
                title: "Better cleanup, easier updates",
                message: "Try the updated muesli Cleanup Lite and Pro Cleanup — Qwen 3.5 models. In Models → Cleanup, an Update button appears when an installed model has a newer release. Choose when to download it; your current model stays available until the update finishes.",
                icon: .symbol("sparkles"),
                target: .cleanupModels
            )
        ])
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

        let lastPresented = lastPresentedTourVersion.flatMap(MarketingVersion.init)
        if let lastPresented, lastPresented >= target {
            return false
        }

        guard let previousVersion else {
            // A completed onboarding with no version marker identifies an
            // existing install rather than a fresh install.
            return true
        }
        guard let previous = MarketingVersion(previousVersion) else { return true }
        if previous < target {
            return true
        }

        // Prerelease builds can share a marketing version even when a newer
        // walkthrough first ships between those builds. A prior tour marker
        // distinguishes that upgrade from a fresh install at the same version.
        return previous == target && lastPresented != nil
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

/// A scroll belongs to one tour target and its destination pane, never an old onAppear.
struct SettingsTourScrollRequest: Equatable {
    let target: FeatureTourTarget?
    let pane: SettingsPane

    var scrollTarget: FeatureTourTarget? {
        guard let target, case .settings(let destination) = target.navigationRoute,
              destination == pane else { return nil }
        return target
    }
}


/// Category changes cancel old model-card scrolls, including rapid Next/Back.
struct ModelsTourScrollRequest: Equatable {
    let target: FeatureTourTarget?
    let category: ModelsCategory

    var scrollTarget: FeatureTourTarget? {
        guard let target, target.modelsCategory == category else { return nil }
        return target
    }
}


extension DashboardTab {
    var sidebarFeatureTourTarget: FeatureTourTarget? {
        switch self {
        case .timeline: .timelineSidebar
        case .meetings: .meetingsSidebar
        case .meetingChat: .chatSidebar
        case .timeTurner: .timeTurnerSidebar
        default: nil
        }
    }
}
