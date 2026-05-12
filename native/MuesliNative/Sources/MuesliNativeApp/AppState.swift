import Foundation
import Observation
import MuesliCore

enum DashboardTab: String, CaseIterable {
    case dictations
    case meetings
    case dictionary
    case models
    case shortcuts
    case settings
    case about
}

enum MeetingsNavigationState: Equatable {
    case browser
    case document(Int64)
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

enum UserInitiatedUpdateAction: Equatable {
    case presentStandardUpdater
    case showBusy(message: String)
}

enum GoogleCalendarListLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum UpdateInteractionPolicy {
    static let busyMessage = "Sparkle is still finishing the previous update check. Try again in a moment."

    static func installAction(for status: SparkleUpdateStatus) -> UserInitiatedUpdateAction {
        switch status {
        case .checking, .busy, .installing:
            return .showBusy(message: busyMessage)
        case .idle, .available, .downloaded, .upToDate, .disabled, .failed:
            return .presentStandardUpdater
        }
    }
}

@MainActor
@Observable
final class AppState {
    // Dashboard data
    var dictationRows: [DictationRecord] = []
    var meetingRows: [MeetingRecord] = []
    var totalMeetingCount: Int = 0
    var meetingCountsByFolder: [Int64: Int] = [:]
    var selectedMeetingID: Int64?
    var selectedMeetingRecord: MeetingRecord?
    var folders: [MeetingFolder] = []
    var selectedFolderID: Int64?  // nil = "All Meetings"
    var meetingsNavigationState: MeetingsNavigationState = .browser
    var isMeetingTemplatesManagerPresented: Bool = false
    var dictationStats: DictationStats = DictationStats(
        totalWords: 0, totalSessions: 0, averageWordsPerSession: 0,
        averageWPM: 0, currentStreakDays: 0, longestStreakDays: 0
    )
    var meetingStats: MeetingStats = MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)

    // Config-driven state
    var selectedBackend: BackendOption = .whisper
    var selectedMeetingTranscriptionBackend: BackendOption = .whisper
    var selectedMeetingSummaryBackend: MeetingSummaryBackendOption = .chatGPT
    var activePostProcessor: PostProcessorOption = PostProcessorOption.defaultOption
    var config: AppConfig = AppConfig()
    var launchAtLoginRegistrationState: LaunchAtLoginRegistrationState = .disabled

    // Live status
    var isMeetingRecording: Bool = false
    var isMeetingRecordingPaused: Bool = false
    var dictationState: DictationState = .idle
    var isVoiceNoteRecording: Bool = false
    var isChatGPTAuthenticated: Bool = false
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
    var modelPreparationTitle: String?
    var modelPreparationDetail: String?
    var modelPreparationProgress: Double?
    var isModelPreparingAfterDownload: Bool = false
    var modelPreparationIsComplete: Bool = false

    // Dictation pagination & filtering
    var dictationPageSize: Int = 50
    var dictationFromDate: String? = nil
    var dictationToDate: String? = nil
    var hasMoreDictations: Bool = true

    // Search
    var searchQuery: String = ""
    var searchResultDictations: [DictationRecord] = []
    var searchResultMeetings: [MeetingRecord] = []
    var focusSearchField: Bool = false
    var isSearchActive: Bool { !searchQuery.isEmpty }

    // Navigation
    var selectedTab: DashboardTab = .dictations

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
