import Foundation
import Observation
import MuesliCore

enum DashboardTab: String, CaseIterable {
    case timeline
    case dictations
    case insights
    case meetings
    case dictionary
    case models
    case shortcuts
    case settings
    case about
}

enum InsightsSection: String, CaseIterable, Sendable {
    case streak
    case words
    case pace
    case meetings
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case sync
    case dictation
    case computerUse
    case meetings
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .sync: return "Sync"
        case .dictation: return "Dictation"
        case .computerUse: return "Computer Use"
        case .meetings: return "Meetings"
        case .appearance: return "Appearance"
        }
    }
}

enum ModelsCategory: String, CaseIterable, Identifiable {
    case dictation
    case streaming
    case postProcessing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .streaming: return "Live Meetings"
        case .postProcessing: return "Cleanup"
        }
    }
}

enum MeetingsNavigationState: Equatable {
    case browser
    case document(Int64)
}

enum MeetingDetailReturnDestination: Equatable {
    case meetings
    case timeline
}

enum HistoryDateFilter: String, CaseIterable, Hashable {
    case all
    case last2Days
    case lastWeek
    case last2Weeks
    case lastMonth
    case last3Months

    var label: String {
        switch self {
        case .all: return "All time"
        case .last2Days: return "Last 2 days"
        case .lastWeek: return "Last week"
        case .last2Weeks: return "Last 2 weeks"
        case .lastMonth: return "Last month"
        case .last3Months: return "Last 3 months"
        }
    }

    func fromDate(relativeTo now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .all:
            return nil
        case .last2Days:
            return calendar.date(byAdding: .day, value: -2, to: now)
        case .lastWeek:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .last2Weeks:
            return calendar.date(byAdding: .day, value: -14, to: now)
        case .lastMonth:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .last3Months:
            return calendar.date(byAdding: .month, value: -3, to: now)
        }
    }
}

enum SparkleUpdateStatus: Equatable {
    case idle
    case checking
    case busy(message: String)
    case available(version: String)
    case downloaded(version: String)
    case installing(version: String)
    case upToDate
    case disabled(message: String)
    case failed(message: String)
}

enum GoogleCalendarListLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum ICloudBridgeState: Equatable {
    case notConfigured
    case checkingICloud
    case syncing
    case active
    case needsICloud
    case needsReconnection
    case needsAccountReplacement
    case error
}

enum ICloudBridgeCompanionDiscoveryState: Equatable {
    case idle
    case waiting
    case timedOut
}

struct ActiveMeetingAudioWarning: Equatable {
    let meetingID: Int64
    let message: String
}

enum OpenRouterModelCatalogLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class AppState {
    // Dashboard data
    var timelineRows: [TimelineEntry] = []
    var dictationRows: [DictationRecord] = []
    var meetingRows: [MeetingRecord] = []
    var totalMeetingCount: Int = 0
    var meetingCountsByFolder: [Int64: Int] = [:]
    var directMeetingCountsByFolder: [Int64: Int] = [:]
    var selectedMeetingID: Int64?
    var selectedMeetingRecord: MeetingRecord?
    var folders: [MeetingFolder] = []
    var selectedFolderID: Int64?  // nil = "All Meetings"
    var meetingsNavigationState: MeetingsNavigationState = .browser
    var meetingDetailReturnDestination: MeetingDetailReturnDestination = .meetings
    var meetingNotesFocusRequest = 0
    var isMeetingTemplatesManagerPresented: Bool = false
    var dictationStats: DictationStats = DictationStats(
        totalWords: 0, totalSessions: 0, averageWordsPerSession: 0,
        averageWPM: 0, currentStreakDays: 0, longestStreakDays: 0
    )
    var filteredDictationStats: DictationStats = DictationStats(
        totalWords: 0, totalSessions: 0, averageWordsPerSession: 0,
        averageWPM: 0, currentStreakDays: 0, longestStreakDays: 0
    )
    var meetingStats: MeetingStats = MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)

    // Config-driven state
    var selectedBackend: BackendOption = .whisper
    var dictationProvider: DictationProvider = .local
    var selectedMeetingTranscriptionBackend: BackendOption = .whisper
    var selectedMeetingSummaryBackend: MeetingSummaryBackendOption = .chatGPT
    var selectedPostProcessorBackend: TranscriptCleanupBackendOption = .local
    var activePostProcessor: PostProcessorOption = PostProcessorOption.defaultOption
    var config: AppConfig = AppConfig()
    var launchAtLoginRegistrationState: LaunchAtLoginRegistrationState = .disabled

    // Live status
    var isMeetingRecording: Bool = false
    var isMeetingRecordingPaused: Bool = false
    var isMeetingStarting: Bool = false
    var meetingStartStatus: String?
    var liveMeetingTranscript: String = ""
    var liveMeetingTranscriptOwnerID: Int64? = nil
    /// Provisional streaming tails for the live transcript view, one per
    /// source; owner-gated by `liveMeetingTranscriptOwnerID` like the transcript.
    var liveMeetingPartialYou: String = ""
    var liveMeetingPartialOthers: String = ""
    var activeMeetingAudioWarning: ActiveMeetingAudioWarning?
    var dictationState: DictationState = .idle
    var isVoiceNoteRecording: Bool = false
    var isChatGPTAuthenticated: Bool = false
    var isOpenRouterAuthenticated: Bool = false
    var isOpenRouterEnvironmentManaged: Bool = false
    var hasStoredOpenRouterCredential: Bool = false
    var openRouterSummaryModels: [SummaryModelPreset] = []
    var openRouterSummaryCatalogState: OpenRouterModelCatalogLoadState = .idle
    var openRouterTranscriptionModels: [SummaryModelPreset] = []
    var openRouterTranscriptionCatalogState: OpenRouterModelCatalogLoadState = .idle
    var isGoogleCalendarAvailable: Bool = false
    var isGoogleCalendarVerified: Bool = false
    var isGoogleCalendarAuthenticated: Bool = false
    var upcomingCalendarEvents: [UnifiedCalendarEvent] = []
    var hiddenCalendarEventIDs: Set<String> = []
    var availableEventKitCalendars: [AvailableCalendar] = []
    var availableGoogleCalendars: [GoogleCalendarSummary] = []
    var googleCalendarListLoadState: GoogleCalendarListLoadState = .idle
    var sparkleUpdateStatus: SparkleUpdateStatus = .idle
    var sparkleLastCheckedAt: Date?
    var iCloudSyncStatus: String?
    var isICloudSyncInProgress: Bool = false
    var isICloudBridgeActivationPending: Bool = false
    var iCloudBridgeCompanionDiscoveryState: ICloudBridgeCompanionDiscoveryState = .idle
    var iCloudBridgeState: ICloudBridgeState = .notConfigured
    var iCloudBridgeMessage: String?
    var iCloudBridgeRemoteDeviceName: String?
    var iCloudBridgeRemoteDevicePlatform: String?
    var iCloudBridgeCompanionDeviceName: String? {
        guard isICloudBridgeCompanionPlatform else { return nil }
        return iCloudBridgeRemoteDeviceName
    }
    var isICloudBridgeCompanionPlatform: Bool {
        guard let platform = iCloudBridgeRemoteDevicePlatform else { return false }
        switch platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios", "ipados":
            return true
        default:
            return false
        }
    }
    var iCloudLastSyncSummary: String?
    var iCloudLastSyncedAt: Date?
    var contributionMilestonePrompt: ContributionMilestonePrompt?
    var pendingDiagnosticIncident: DiagnosticIncident?
    var modelPreparationTitle: String?
    var modelPreparationDetail: String?
    var modelPreparationProgress: Double?
    var isModelPreparingAfterDownload: Bool = false
    var modelPreparationIsComplete: Bool = false

    // Dictation pagination & filtering
    var dictationPageSize: Int = 50
    var dictationFromDate: String? = nil
    var dictationToDate: String? = nil
    var dictationOriginFilter: RecordOriginFilter = .all
    var dictationApplicationFilter: DictationTargetApplication?
    var dictationTargetApplications: [DictationTargetApplication] = []
    var hasMoreDictations: Bool = true
    var meetingOriginFilter: RecordOriginFilter = .all

    // Timeline pagination, filtering, and session navigation state
    var timelinePageSize: Int = 50
    var timelineFromDate: String? = nil
    var timelineToDate: String? = nil
    var timelineOriginFilter: RecordOriginFilter = .all
    var timelineApplicationFilter: DictationTargetApplication?
    var timelineDateFilter: HistoryDateFilter = .all
    var hasMoreTimelineEntries: Bool = true
    var timelineScrollAnchor: String?

    // Search
    var searchQuery: String = ""
    var searchResultDictations: [DictationRecord] = []
    var searchResultMeetings: [MeetingRecord] = []
    var focusSearchField: Bool = false
    var isSearchActive: Bool { !searchQuery.isEmpty }

    // Navigation
    var selectedTab: DashboardTab = .timeline
    var insightsReturnTab: DashboardTab = .timeline
    var insightsBackLabel: String {
        insightsReturnTab == .dictations ? "Back to Dictations" : "Back to Timeline"
    }
    var insightsInitialSection: InsightsSection = .words
    var selectedSettingsPane: SettingsPane = .general
    var selectedModelsCategory: ModelsCategory = .dictation
    var pendingFeatureTourInvitation: FeatureTour?
    var activeFeatureTour: FeatureTour?
    var featureTourStepIndex: Int = 0

    // Computed
    var selectedMeeting: MeetingRecord? {
        guard let id = selectedMeetingID else { return nil }
        if let row = meetingRows.first(where: { $0.id == id }) {
            return row
        }
        guard selectedMeetingRecord?.id == id else { return nil }
        return selectedMeetingRecord
    }
}
