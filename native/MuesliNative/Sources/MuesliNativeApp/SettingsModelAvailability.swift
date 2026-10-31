import Foundation
import MuesliCore

/// Disk-backed facts for presentation. Mutation paths still validate the live files.
struct SettingsModelAvailability: Equatable, Sendable {
    var backendIDs: Set<String> = []
    var postProcessorIDs: Set<String> = []
    var liveCaptionIDs: Set<String> = []
    var gemmaIDs: Set<String> = []
    var claudeCodeAvailable = false
    var cotypistAvailable = false
    var localPlannerIDs: Set<String> = []

    func contains(_ option: BackendOption) -> Bool {
        backendIDs.contains(option.backend + ":" + option.model)
    }

    static func scan(claudeCodePath: String) -> Self {
        Self(
            backendIDs: Set(BackendOption.all.filter(\.isDownloaded).map { $0.backend + ":" + $0.model }),
            postProcessorIDs: Set(PostProcessorOption.downloaded.map(\.id)),
            liveCaptionIDs: Set(MeetingLiveCaptionBackend.allCases.filter(\.isDownloaded).map(\.rawValue)),
            gemmaIDs: Set(Gemma4LiteRTModel.allCases.filter { Gemma4LiteRTModelStore.isAvailableLocally(model: $0) }.map(\.rawValue)),
            claudeCodeAvailable: ClaudeCodeSummarizer.executableURL(configuredPath: claudeCodePath) != nil,
            cotypistAvailable: FileManager.default.fileExists(atPath: CotypistSetup.embeddedInputMethodURL.path),
            localPlannerIDs: Set(ComputerUseLocalPlanner.models.filter(\.available).map(\.id))
        )
    }
}

/// Owned by the Settings surface, so closure-backed definitions cannot retain the
/// controller through a controller-owned cache. Live readback stays in each definition.
@MainActor
final class SettingsPresentationCatalog {
    private var config: AppConfig?
    private var availability: SettingsModelAvailability?
    private var quietAppIDs: [String] = []
    private var calendarKey: [[String]] = []
    private var summaryBackend: MeetingSummaryBackendOption?
    private var definitions: [MuesliSetting] = []
    private(set) var rebuildCount = 0

    func definitions(for controller: MuesliController) -> [MuesliSetting] {
        let state = controller.appState
        let currentQuietAppIDs = CotypistQuietApps.chosen + CotypistQuietApps.running(excluding: []).map(\.bundleID)
        let calendars = state.availableEventKitCalendars.map { [$0.id, $0.sourceTitle, $0.title] }
        if config != state.config || availability != state.settingsModelAvailability
            || calendarKey != calendars || quietAppIDs != currentQuietAppIDs
            || summaryBackend != state.selectedMeetingSummaryBackend {
            config = state.config
            availability = state.settingsModelAvailability
            calendarKey = calendars
            quietAppIDs = currentQuietAppIDs
            summaryBackend = state.selectedMeetingSummaryBackend
            definitions = controller.settingsDefinitions(availability: state.settingsModelAvailability)
            rebuildCount += 1
        }
        return definitions
    }
}
