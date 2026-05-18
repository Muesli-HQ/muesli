import Testing
import AppKit
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meetings navigation")
struct MeetingsNavigationTests {

    private func makeController() -> MuesliController {
        MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            )
        )
    }

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-nav-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @Test("app state defaults meetings to browser mode")
    func meetingsDefaultToBrowser() {
        let appState = AppState()

        #expect(appState.meetingsNavigationState == .browser)
        #expect(appState.selectedMeeting == nil)
    }

    @Test("discard confirmation maps checkbox selections to meeting discard resolutions")
    func discardConfirmationResolutionMapping() {
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: nil
            ) == .discardRecording
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: false
            ) == .keepManualNotes
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: true
            ) == .deleteDraft
        )
        #expect(
            MuesliController.discardResolution(
                for: .alertSecondButtonReturn,
                deleteManualNotes: false
            ) == nil
        )
    }

    @Test("selectedMeeting resolves the selected row only")
    func selectedMeetingUsesExplicitSelection() {
        let appState = AppState()
        let first = makeMeeting(id: 101, title: "First")
        let second = makeMeeting(id: 202, title: "Second")
        appState.meetingRows = [first, second]

        #expect(appState.selectedMeeting == nil)

        appState.selectedMeetingID = 202
        #expect(appState.selectedMeeting?.id == 202)
        #expect(appState.selectedMeeting?.title == "Second")
    }

    @Test("selectedMeeting falls back to the stored document record outside the browser slice")
    func selectedMeetingUsesStoredRecordWhenNotInRows() {
        let appState = AppState()
        let visible = makeMeeting(id: 101, title: "Visible")
        let selected = makeMeeting(id: 202, title: "Selected Outside Slice")
        appState.meetingRows = [visible]
        appState.selectedMeetingID = 202
        appState.selectedMeetingRecord = selected

        #expect(appState.selectedMeeting?.id == 202)
        #expect(appState.selectedMeeting?.title == "Selected Outside Slice")
    }

    @Test("showMeetingDocument enters meetings document route and records selection")
    func showMeetingDocumentRoutesToDocument() {
        let controller = makeController()

        controller.appState.selectedTab = .dictations
        controller.appState.selectedFolderID = 55

        controller.showMeetingDocument(id: 202)

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.selectedMeetingID == 202)
        #expect(controller.appState.meetingsNavigationState == .document(202))
        #expect(controller.appState.selectedFolderID == 55)
    }

    @Test("showMeetingsHome returns to browser and preserves prior meeting selection")
    func showMeetingsHomeReturnsToBrowser() {
        let controller = makeController()

        controller.appState.selectedMeetingID = 303
        controller.appState.meetingsNavigationState = .document(303)

        controller.showMeetingsHome(folderID: 99)

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.selectedFolderID == 99)
        #expect(controller.appState.meetingsNavigationState == .browser)
        #expect(controller.appState.selectedMeetingID == 303)
    }

    @Test("showMeetingsHome with nil folder resets browser to all meetings")
    func showMeetingsHomeResetsFolderFilter() {
        let controller = makeController()

        controller.appState.selectedFolderID = 11
        controller.appState.meetingsNavigationState = .document(404)

        controller.showMeetingsHome(folderID: nil)

        #expect(controller.appState.selectedFolderID == nil)
        #expect(controller.appState.meetingsNavigationState == .browser)
    }

    @Test("deleteMeeting clears selected detail state and removes saved recording")
    func deleteMeetingClearsSelection() throws {
        let store = try makeStore()
        let savedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-\(UUID().uuidString).wav")
        try Data("test".utf8).write(to: savedRecordingURL)

        let now = Date()
        try store.insertMeeting(
            title: "Delete Target",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )

        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        controller.appState.selectedMeetingID = meetingID
        controller.appState.selectedMeetingRecord = try store.meeting(id: meetingID)
        controller.appState.meetingsNavigationState = .document(meetingID)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(controller.appState.selectedMeetingID == nil)
        #expect(controller.appState.selectedMeetingRecord == nil)
        #expect(controller.appState.meetingsNavigationState == .browser)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
    }

    @Test("deleteMeeting refuses live meeting rows")
    func deleteMeetingRefusesLiveRows() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        let liveMeeting = try #require(try store.meeting(id: meetingID))
        #expect(controller.canDeleteMeeting(liveMeeting) == false)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) != nil)
    }

    @Test("retranscribe missing recording preserves completed meeting status")
    func retranscribeMissingRecordingPreservesCompletedStatus() async throws {
        let store = try makeStore()
        let missingRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-meeting-recording-\(UUID().uuidString).wav")
        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Recovered Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Existing transcript",
            formattedNotes: "## Existing notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: missingRecordingURL.path
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let meeting = try #require(try store.meeting(id: meetingID))

        let result = await withCheckedContinuation { continuation in
            controller.retranscribe(meeting: meeting) { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success:
            Issue.record("Expected re-transcription to fail when the retained recording is missing")
        case .failure(let error):
            #expect(error is MeetingRetranscriptionError)
        }

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.status == .completed)
        #expect(updated.rawTranscript == "Existing transcript")
        #expect(updated.formattedNotes == "## Existing notes")
    }

    @Test("retranscribe empty transcript restores original meeting status")
    func retranscribeEmptyTranscriptRestoresOriginalMeetingStatus() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.emptyTranscript
        ) == .completed)
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .failed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.emptyTranscript
        ) == .failed)
    }

    @Test("retranscribe status is unchanged before processing starts")
    func retranscribeStatusIsUnchangedBeforeProcessingStarts() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: false,
            error: MeetingRetranscriptionError.recordingUnavailable
        ) == nil)
    }

    @Test("retranscribe save failures restore original meeting status")
    func retranscribeSaveFailuresRestoreOriginalMeetingStatus() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.failedToSave(underlying: CocoaError(.fileWriteUnknown))
        ) == .completed)
    }

    @Test("retranscribe processing failures mark meeting failed")
    func retranscribeProcessingFailuresMarkMeetingFailed() {
        #expect(MuesliController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: CocoaError(.fileReadUnknown)
        ) == .failed)
    }

    @Test("cached manual notes are persisted before debounce")
    func cachedManualNotesPersistImmediately() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: meetingID, notes: "Decision before crash")

        let persisted = try #require(try store.meeting(id: meetingID))
        #expect(persisted.manualNotes == "Decision before crash")
    }

    @Test("failed manual note persistence retries on later flush")
    func failedManualNotePersistenceRetriesOnFlush() throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: 1, notes: "Draft survives retry")
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        #expect(meetingID == 1)

        controller.flushCachedMeetingManualNotes(id: meetingID, sync: false)

        let stored = try #require(try store.meeting(id: meetingID))
        #expect(stored.manualNotes == "Draft survives retry")
    }

    @Test("manual note cache coalesces repeated writes until flush")
    func cachedManualNotesCoalesceRepeatedWrites() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: meetingID, notes: "First durable note")
        #expect(controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "First durable note"))
        controller.cacheMeetingManualNotes(id: meetingID, notes: "Second cached note")
        #expect(!controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "Second cached note"))

        let beforeFlush = try #require(try store.meeting(id: meetingID))
        #expect(beforeFlush.manualNotes == "First durable note")

        controller.flushCachedMeetingManualNotes(id: meetingID, sync: false)
        #expect(controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "Second cached note"))

        let afterFlush = try #require(try store.meeting(id: meetingID))
        #expect(afterFlush.manualNotes == "Second cached note")
    }

    @Test("persistCompletedMeetingResult keeps transcript when recording save fails")
    func persistCompletedMeetingResultPreservesMeetingOnRecordingFailure() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .always }

        let invalidRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let result = MeetingSessionResult(
            title: "Customer Review",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(90),
            durationSeconds: 90,
            rawTranscript: "Discussed roadmap and blockers.",
            formattedNotes: "## Summary\nRoadmap reviewed.",
            retainedRecordingURL: invalidRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let persistenceResult = try controller.persistCompletedMeetingResult(result)

        #expect(persistenceResult.recordingSaveError != nil)
        let storedMeeting = try store.meeting(id: persistenceResult.meetingID)
        #expect(storedMeeting?.title == "Customer Review")
        #expect(storedMeeting?.rawTranscript == "Discussed roadmap and blockers.")
        #expect(storedMeeting?.savedRecordingPath == nil)
    }

    @Test("persistCompletedMeetingResult preserves user-edited live meeting title")
    func persistCompletedMeetingResultPreservesEditedLiveTitle() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        try store.updateMeetingTitle(id: liveID, title: "Investor Follow-up")

        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed fundraising updates.",
            formattedNotes: "## Summary\nFundraising updates discussed.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(result, existingMeetingID: liveID)

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.title == "Investor Follow-up")
        #expect(storedMeeting.formattedNotes == "## Summary\nFundraising updates discussed.")
    }

    @Test("persistCompletedMeetingResult preserves cached live title before debounce")
    func persistCompletedMeetingResultPreservesCachedLiveTitle() async throws {
        let store = try makeStore()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        controller.cacheMeetingTitle(id: liveID, title: "Status Bar Stop Title")

        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed follow-up items.",
            formattedNotes: "## Summary\nFollow-up items discussed.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(result, existingMeetingID: liveID)

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.title == "Status Bar Stop Title")
        #expect(storedMeeting.formattedNotes == "## Summary\nFollow-up items discussed.")
    }

    @Test("resummary context strips appended written notes section")
    func resummaryContextStripsWrittenNotesSection() {
        let meeting = makeMeeting(
            id: 909,
            title: "Resummarize",
            formattedNotes: "## Summary\n- Decision captured\n\n### Written notes\n\n- User typed this",
            status: .completed,
            manualNotes: "- User typed this"
        )

        let context = MuesliController.notesContextForResummary(meeting)

        #expect(context == "## Summary\n- Decision captured")
    }

    @Test("startup recovery preserves stale live meetings with notes")
    func startupRecoveryPreservesStaleLiveMeetingWithNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Crashed Draft", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Important draft")
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
        #expect(meeting.manualNotes == "Important draft")
    }

    @Test("startup recovery marks empty stale live drafts as failed")
    func startupRecoveryMarksEmptyStaleLiveDraftsFailed() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Empty Draft", calendarEventID: nil, startTime: Date())
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
    }

    @Test("showMeetingTemplatesManager preserves current meetings context and presents manager")
    func showMeetingTemplatesManagerPresentsManager() {
        let controller = makeController()

        controller.appState.selectedTab = .settings
        controller.appState.meetingsNavigationState = .document(404)
        controller.appState.isMeetingTemplatesManagerPresented = false

        controller.showMeetingTemplatesManager()

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.meetingsNavigationState == .document(404))
        #expect(controller.appState.isMeetingTemplatesManagerPresented == true)
    }

    @Test("deleteCustomMeetingTemplate resets default template when deleting the active default")
    func deletingDefaultCustomTemplateResetsDefaultToAuto() {
        let controller = makeController()
        let customTemplate = CustomMeetingTemplate(
            id: "tmpl_customer_followup",
            name: "Customer Follow-Up",
            prompt: "## Summary",
            icon: "person.2.fill"
        )

        controller.updateConfig {
            $0.customMeetingTemplates = [customTemplate]
            $0.defaultMeetingTemplateID = customTemplate.id
        }

        controller.deleteCustomMeetingTemplate(id: customTemplate.id)

        #expect(controller.config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(controller.appState.config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(controller.config.customMeetingTemplates.isEmpty)
    }

    @Test("meeting transcription backend selection is independent from dictation backend")
    func meetingTranscriptionBackendSelectionIsIndependent() {
        let controller = makeController()

        controller.selectBackend(.parakeetEnglish)
        controller.selectMeetingTranscriptionBackend(.whisperLargeTurbo, requireDownloaded: false)

        #expect(controller.appState.selectedBackend == .parakeetEnglish)
        #expect(controller.appState.selectedMeetingTranscriptionBackend == .whisperLargeTurbo)
        #expect(controller.appState.config.sttModel == BackendOption.parakeetEnglish.model)
        #expect(controller.appState.config.meetingTranscriptionModel == BackendOption.whisperLargeTurbo.model)
    }

    private func makeMeeting(
        id: Int64,
        title: String,
        formattedNotes: String = "## Summary",
        status: MeetingStatus = .completed,
        manualNotes: String = ""
    ) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            startTime: "2026-03-24 10:00",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: formattedNotes,
            wordCount: 42,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            status: status,
            manualNotes: manualNotes,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )
    }
}

@Suite("Meeting browser logic")
struct MeetingBrowserLogicTests {

    @Test("available filters expand with older meeting history")
    func availableFiltersExpandWithHistory() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 1, daysAgo: 40, title: "Oldest"),
            makeMeeting(id: 2, daysAgo: 1, title: "Recent")
        ]

        let filters = MeetingBrowserLogic.availableFilters(for: meetings, now: now, calendar: calendar)

        #expect(filters == [.all, .last2Days, .lastWeek, .last2Weeks, .lastMonth, .last3Months])
    }

    @Test("filtering excludes invalid dates and sorts newest first")
    func filteringNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 1, daysAgo: 10, title: "Too old"),
            makeMeeting(id: 2, daysAgo: 2, title: "Recent A"),
            makeMeeting(id: 3, daysAgo: 1, title: "Recent B"),
            makeMeeting(id: 4, rawDate: "not-a-date", title: "Invalid")
        ]

        let filtered = MeetingBrowserLogic.filteredMeetings(
            from: meetings,
            filter: .lastWeek,
            sort: .newestFirst,
            now: now,
            calendar: calendar
        )

        #expect(filtered.map(\.id) == [3, 2])
    }

    @Test("all filter keeps invalid dates and oldest-first pushes them to the front")
    func allFilterOldestFirst() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 10, daysAgo: 2, title: "Recent"),
            makeMeeting(id: 11, daysAgo: 8, title: "Older"),
            makeMeeting(id: 12, rawDate: "invalid-date", title: "Invalid")
        ]

        let filtered = MeetingBrowserLogic.filteredMeetings(
            from: meetings,
            filter: .all,
            sort: .oldestFirst,
            now: now,
            calendar: calendar
        )

        #expect(filtered.map(\.id) == [12, 11, 10])
    }

    private static func isoDate(daysAgo: Int, now: Date, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func makeMeeting(id: Int64, daysAgo: Int, title: String) -> MeetingRecord {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        return makeMeeting(id: id, rawDate: Self.isoDate(daysAgo: daysAgo, now: now, calendar: calendar), title: title)
    }

    private func makeMeeting(id: Int64, rawDate: String, title: String) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            startTime: rawDate,
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Summary",
            wordCount: 42,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )
    }
}
