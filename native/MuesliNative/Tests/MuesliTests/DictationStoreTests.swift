import Testing
import Foundation
import MuesliCore
import SQLite3
@testable import MuesliNativeApp

@Suite("DictationStore", .serialized)
struct DictationStoreTests {

    /// Creates a DictationStore backed by a temporary database file.
    /// Each test gets its own isolated DB — no production data is touched.
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeLegacyStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-legacy-test-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'meeting',
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return DictationStore(databaseURL: url)
    }

    @Test("migration creates tables without error")
    func migration() throws {
        let store = try makeStore()
        try store.migrateIfNeeded() // idempotent
    }

    @Test("migration adds template columns to legacy meeting schema")
    func migrationAddsTemplateColumns() throws {
        let store = try makeLegacyStore()

        try store.migrateIfNeeded()

        let meeting = try store.meeting(id: 1)
        #expect(meeting == nil)
        try store.insertMeeting(
            title: "Legacy Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(60),
            rawTranscript: "Legacy transcript",
            formattedNotes: "Legacy notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: "one-to-one",
            selectedTemplateName: "1 to 1",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Check-In"
        )
        let inserted = try store.recentMeetings(limit: 1).first
        #expect(inserted?.selectedTemplateID == "one-to-one")
        #expect(inserted?.selectedTemplateKind == .builtin)
        #expect(inserted?.savedRecordingPath == nil)
        #expect(inserted?.status == .completed)
        #expect(inserted?.manualNotes == "")
    }

    @Test("migration adds saved recording path column to legacy meeting schema")
    func migrationAddsSavedRecordingColumn() throws {
        let store = try makeLegacyStore()

        try store.migrateIfNeeded()

        let start = Date()
        try store.insertMeeting(
            title: "Saved Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "/tmp/meeting.wav"
        )

        let inserted = try store.recentMeetings(limit: 1).first
        #expect(inserted?.savedRecordingPath == "/tmp/meeting.wav")
    }

    @Test("live meeting starts as recording with empty manual notes")
    func createLiveMeeting() throws {
        let store = try makeStore()
        let start = Date()

        let id = try store.createLiveMeeting(
            title: "Quick Note",
            calendarEventID: nil,
            startTime: start,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.title == "Quick Note")
        #expect(meeting.status == .recording)
        #expect(meeting.manualNotes == "")
        #expect(meeting.rawTranscript == "")
        #expect(meeting.formattedNotes == "")
        #expect(meeting.selectedTemplateID == "auto")
    }

    @Test("manual notes update independently from final notes")
    func updateManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Quick Note", calendarEventID: nil, startTime: Date())

        try store.updateMeetingManualNotes(id: id, manualNotes: "- Decision: ship today")

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.manualNotes == "- Decision: ship today")
        #expect(meeting.formattedNotes == "")
    }

    @Test("manual notes update fails when the meeting row is missing")
    func updateManualNotesFailsWhenMeetingMissing() throws {
        let store = try makeStore()

        #expect(throws: Error.self) {
            try store.updateMeetingManualNotes(id: 9_999, manualNotes: "Lost note")
        }
    }

    @Test("status update fails when the meeting row is missing")
    func updateMeetingStatusFailsWhenMeetingMissing() throws {
        let store = try makeStore()

        #expect(throws: Error.self) {
            try store.updateMeetingStatus(id: 9_999, status: .failed)
        }
    }

    @Test("live meeting completes the same row")
    func completeLiveMeetingUpdatesExistingRow() throws {
        let store = try makeStore()
        let start = Date()
        let id = try store.createLiveMeeting(title: "Draft", calendarEventID: nil, startTime: start)
        try store.updateMeetingManualNotes(id: id, manualNotes: "- Keep this")

        try store.completeLiveMeeting(
            id: id,
            title: "Generated Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "hello world",
            formattedNotes: "## Summary\nHello\n\n## Manual Notes\n\n- Keep this",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let meetings = try store.recentMeetings(limit: 10)
        #expect(meetings.count == 1)
        let completed = try #require(meetings.first)
        #expect(completed.id == id)
        #expect(completed.status == .completed)
        #expect(completed.title == "Generated Title")
        #expect(completed.rawTranscript == "hello world")
        #expect(completed.wordCount == 5)
        #expect(completed.manualNotes == "- Keep this")
    }

    @Test("note-only status updates word count from manual notes")
    func noteOnlyStatusCountsManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Manual Draft", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Decision ship today")

        try store.updateMeetingStatus(id: id, status: .noteOnly)

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .noteOnly)
        #expect(meeting.wordCount == 3)
    }

    @Test("live meeting completion fails when the row disappeared")
    func completeLiveMeetingFailsWhenRowMissing() throws {
        let store = try makeStore()
        let start = Date()

        #expect(throws: Error.self) {
            try store.completeLiveMeeting(
                id: 9_999,
                title: "Generated Title",
                calendarEventID: nil,
                startTime: start,
                endTime: start.addingTimeInterval(120),
                rawTranscript: "hello world",
                formattedNotes: "## Summary\nHello",
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: nil,
                selectedTemplateID: "auto",
                selectedTemplateName: "Auto",
                selectedTemplateKind: .auto,
                selectedTemplatePrompt: "## Summary"
            )
        }
    }

    @Test("staleLiveMeetings returns only recording and processing rows")
    func staleLiveMeetingsFiltersLiveStatuses() throws {
        let store = try makeStore()
        let start = Date()

        let recordingID = try store.createLiveMeeting(title: "Recording", calendarEventID: nil, startTime: start)
        let processingID = try store.createLiveMeeting(title: "Processing", calendarEventID: nil, startTime: start.addingTimeInterval(1))
        let noteOnlyID = try store.createLiveMeeting(title: "Note Only", calendarEventID: nil, startTime: start.addingTimeInterval(2))
        try store.updateMeetingStatus(id: processingID, status: .processing)
        try store.updateMeetingStatus(id: noteOnlyID, status: .noteOnly)
        try store.insertMeeting(
            title: "Completed",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(3),
            endTime: start.addingTimeInterval(60),
            rawTranscript: "done",
            formattedNotes: "## Summary\nDone",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let stale = try store.staleLiveMeetings()

        #expect(stale.map(\.id) == [processingID, recordingID])
        #expect(stale.allSatisfy { $0.status == .recording || $0.status == .processing })
    }

    @Test("insert and retrieve dictation")
    func insertAndRetrieve() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertDictation(
            text: "Test dictation text here",
            durationSeconds: 3.5,
            startedAt: now.addingTimeInterval(-3.5),
            endedAt: now
        )

        let rows = try store.recentDictations(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first!.rawText == "Test dictation text here")
        #expect(rows.first!.wordCount == 4)
    }

    @Test("insert and retrieve meeting")
    func insertAndRetrieveMeeting() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Test Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(600),
            rawTranscript: "Speaker one said hello. Speaker two replied.",
            formattedNotes: "## Summary\nGood meeting",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first!.title == "Test Meeting")
        #expect(rows.first!.wordCount == 7)
        #expect(rows.first!.appliedTemplateID == MeetingTemplates.autoID)
    }

    @Test("meeting template snapshot persists on insert")
    func insertAndRetrieveMeetingTemplateSnapshot() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Template Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(300),
            rawTranscript: "Transcript body",
            formattedNotes: "## Summary\nStructured",
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: "stand-up",
            selectedTemplateName: "Stand-Up",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Yesterday"
        )

        let meeting = try store.recentMeetings(limit: 1).first
        #expect(meeting?.selectedTemplateID == "stand-up")
        #expect(meeting?.selectedTemplateName == "Stand-Up")
        #expect(meeting?.selectedTemplateKind == .builtin)
        #expect(meeting?.selectedTemplatePrompt == "## Yesterday")
    }

    @Test("update meeting notes and title")
    func updateMeeting() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Some transcript",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        let meetingId = rows.first!.id

        try store.updateMeeting(id: meetingId, title: "Sprint Planning", formattedNotes: "## Summary\nPlanned the sprint")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Sprint Planning")
        #expect(updated.first!.formattedNotes == "## Summary\nPlanned the sprint")
    }

    @Test("update meeting notes only")
    func updateMeetingNotesOnly() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Original Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Old notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        try store.updateMeetingNotes(id: rows.first!.id, formattedNotes: "New notes")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Original Title") // title unchanged
        #expect(updated.first!.formattedNotes == "New notes")
    }

    @Test("update meeting summary stores template snapshot")
    func updateMeetingSummaryWithTemplateSnapshot() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Original Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Old notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.updateMeetingSummary(
            id: meetingID,
            title: "Standup",
            formattedNotes: "## Yesterday\n- Fixed bugs",
            selectedTemplateID: "stand-up",
            selectedTemplateName: "Stand-Up",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Yesterday"
        )

        let updated = try store.recentMeetings(limit: 1).first
        #expect(updated?.title == "Standup")
        #expect(updated?.selectedTemplateID == "stand-up")
        #expect(updated?.selectedTemplateName == "Stand-Up")
        #expect(updated?.selectedTemplateKind == .builtin)
        #expect(updated?.selectedTemplatePrompt == "## Yesterday")
    }

    @Test("update meeting transcript and summary replaces empty transcription")
    func updateMeetingTranscriptAndSummary() throws {
        let store = try makeStore()

        let start = Date()
        let meetingID = try store.insertMeeting(
            title: "Recovered Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "/tmp/recovered.wav"
        )
        try store.updateMeetingManualNotes(id: meetingID, manualNotes: "Manual note")
        try store.updateMeetingStatus(id: meetingID, status: .failed)

        try store.updateMeetingTranscriptAndSummary(
            id: meetingID,
            rawTranscript: "Recovered transcript words",
            formattedNotes: "## Summary\nRecovered notes",
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "Auto prompt"
        )

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.rawTranscript == "Recovered transcript words")
        #expect(updated.formattedNotes == "## Summary\nRecovered notes")
        #expect(updated.status == .completed)
        #expect(updated.wordCount == 5)
        #expect(updated.savedRecordingPath == "/tmp/recovered.wav")
        #expect(updated.manualNotes == "Manual note")
    }

    @Test("update meeting transcript preserves notes and refreshes word count")
    func updateMeetingTranscript() throws {
        let store = try makeStore()

        let start = Date()
        let meetingID = try store.insertMeeting(
            title: "Editable Transcript",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Original words",
            formattedNotes: "## Summary\nExisting notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.updateMeetingManualNotes(id: meetingID, manualNotes: "Manual note")

        try store.updateMeetingTranscript(
            id: meetingID,
            rawTranscript: "[10:00:00] You: Edited transcript words"
        )

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.rawTranscript == "[10:00:00] You: Edited transcript words")
        #expect(updated.formattedNotes == "## Summary\nExisting notes")
        #expect(updated.manualNotes == "Manual note")
        #expect(updated.wordCount == 7)
    }

    @Test("fetch dictation by id returns the full record")
    func fetchDictationByID() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertDictation(
            text: "Capture this dictation",
            durationSeconds: 4.2,
            appContext: "Slack",
            startedAt: now.addingTimeInterval(-4.2),
            endedAt: now
        )

        let inserted = try store.recentDictations(limit: 1).first!
        let fetched = try store.dictation(id: inserted.id)

        #expect(fetched?.id == inserted.id)
        #expect(fetched?.rawText == "Capture this dictation")
        #expect(fetched?.appContext == "Slack")
    }

    @Test("fetch meeting by id returns audio paths and notes state")
    func fetchMeetingByID() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Recorded Meeting",
            calendarEventID: "evt_123",
            startTime: now,
            endTime: now.addingTimeInterval(90),
            rawTranscript: "Discussed roadmap items",
            formattedNotes: "## Summary\nRoadmap reviewed",
            micAudioPath: "/tmp/mic.wav",
            systemAudioPath: "/tmp/system.wav",
            savedRecordingPath: "/tmp/meeting.wav"
        )

        let inserted = try store.recentMeetings(limit: 1).first!
        let fetched = try store.meeting(id: inserted.id)

        #expect(fetched?.id == inserted.id)
        #expect(fetched?.calendarEventID == "evt_123")
        #expect(fetched?.micAudioPath == "/tmp/mic.wav")
        #expect(fetched?.systemAudioPath == "/tmp/system.wav")
        #expect(fetched?.savedRecordingPath == "/tmp/meeting.wav")
        #expect(fetched?.notesState == .structuredNotes)
        #expect(fetched?.appliedTemplateID == MeetingTemplates.autoID)
    }

    @Test("meeting notes state distinguishes raw transcript fallback from structured notes")
    func meetingNotesState() throws {
        let missing = MeetingRecord(
            id: 1,
            title: "Missing",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let fallback = MeetingRecord(
            id: 2,
            title: "Fallback",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Raw Transcript\n\nHello world",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let structured = MeetingRecord(
            id: 3,
            title: "Structured",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Summary\nNext steps captured",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let structuredWithTranscriptSection = MeetingRecord(
            id: 4,
            title: "Structured With Transcript Section",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Summary\nNext steps captured\n\n## Raw Transcript\n\nQuoted transcript for reference",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )

        #expect(missing.notesState == .missing)
        #expect(fallback.notesState == .rawTranscriptFallback)
        #expect(structured.notesState == .structuredNotes)
        #expect(structuredWithTranscriptSection.notesState == .structuredNotes)
    }

    @Test("dictation stats aggregate correctly")
    func dictationStats() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertDictation(text: "one two three", durationSeconds: 2.0, startedAt: now.addingTimeInterval(-2), endedAt: now)
        try store.insertDictation(text: "four five", durationSeconds: 1.5, startedAt: now.addingTimeInterval(-1.5), endedAt: now)

        let stats = try store.dictationStats()
        #expect(stats.totalWords == 5)
        #expect(stats.totalSessions == 2)
        #expect(stats.averageWPM > 0)
    }

    @Test("meeting stats aggregate correctly")
    func meetingStats() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Stats Meeting", calendarEventID: nil,
            startTime: start, endTime: start.addingTimeInterval(300),
            rawTranscript: "This is a test transcript with several words",
            formattedNotes: "", micAudioPath: nil, systemAudioPath: nil
        )
        let liveID = try store.createLiveMeeting(
            title: "Live Draft",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(60)
        )
        let noteOnlyID = try store.createLiveMeeting(
            title: "Written Notes",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(120)
        )
        try store.updateMeetingManualNotes(id: noteOnlyID, manualNotes: "manual note words")
        try store.updateMeetingStatus(id: noteOnlyID, status: .noteOnly)
        try store.updateMeetingStatus(id: liveID, status: .failed)

        let stats = try store.meetingStats()
        #expect(stats.totalMeetings == 2)
        #expect(stats.totalWords == 11)
    }

    @Test("clear dictations removes all records")
    func clearDictations() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(text: "to delete", durationSeconds: 1.0, startedAt: now, endedAt: now)
        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "Done",
            events: [ComputerUseTraceEvent(kind: "finish", title: "Final output", body: "Done")]
        )
        try store.clearDictations()
        #expect(try store.recentDictations(limit: 100).isEmpty)
        #expect(throws: Error.self) {
            try store.insertComputerUseTrace(
                dictationID: dictationID,
                finalStatus: "done",
                finalMessage: "Should fail",
                events: []
            )
        }
    }

    @Test("clear meetings removes all records")
    func clearMeetings() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertMeeting(title: "Del", calendarEventID: nil, startTime: now, endTime: now.addingTimeInterval(60), rawTranscript: "x", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        try store.clearMeetings()
        #expect(try store.recentMeetings(limit: 100).isEmpty)
    }

    @Test("delete meeting removes a single meeting row")
    func deleteMeeting() throws {
        let store = try makeStore()
        let now = Date()

        try store.insertMeeting(
            title: "Delete Me",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "first meeting",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.insertMeeting(
            title: "Keep Me",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180),
            rawTranscript: "second meeting",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meetings = try store.recentMeetings(limit: 10)
        let deleteID = meetings.first(where: { $0.title == "Delete Me" })!.id
        try store.deleteMeeting(id: deleteID)

        let remaining = try store.recentMeetings(limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.title == "Keep Me")
    }

    @Test("recent dictations respects limit")
    func limitRespected() throws {
        let store = try makeStore()
        let now = Date()
        for i in 0..<5 {
            try store.insertDictation(text: "Entry \(i)", durationSeconds: 1.0, startedAt: now.addingTimeInterval(Double(i)), endedAt: now.addingTimeInterval(Double(i) + 1))
        }
        #expect(try store.recentDictations(limit: 3).count == 3)
    }

    @Test("recent dictations treats fromDate as a bound value, not SQL")
    func recentDictationsBindsFromDate() throws {
        let store = try makeStore()
        let now = Date()

        try store.insertDictation(
            text: "Older entry",
            durationSeconds: 1.0,
            startedAt: now.addingTimeInterval(-120),
            endedAt: now.addingTimeInterval(-120)
        )
        try store.insertDictation(
            text: "Newer entry",
            durationSeconds: 1.0,
            startedAt: now,
            endedAt: now
        )

        let injectedDate = "9999-12-31T00:00:00Z' OR 1=1 --"
        let rows = try store.recentDictations(limit: 10, fromDate: injectedDate)

        #expect(rows.isEmpty)
    }

    // MARK: - Editable Meeting Title

    @Test("update meeting title only preserves notes")
    func updateMeetingTitleOnly() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Auto Title",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Some words",
            formattedNotes: "## Notes\nKeep these",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        try store.updateMeetingTitle(id: rows.first!.id, title: "Edited Title")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Edited Title")
        #expect(updated.first!.formattedNotes == "## Notes\nKeep these") // notes unchanged
    }

    @Test("update meeting saved recording path stores the retained file location")
    func updateMeetingSavedRecordingPath() throws {
        let store = try makeStore()

        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Auto Title",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Some words",
            formattedNotes: "## Notes\nKeep these",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        try store.updateMeetingSavedRecordingPath(id: meetingID, path: "/tmp/retained.wav")

        let updated = try store.meeting(id: meetingID)
        #expect(updated?.savedRecordingPath == "/tmp/retained.wav")
    }

    // MARK: - Folder CRUD

    @Test("create and list folders")
    func createAndListFolders() throws {
        let store = try makeStore()

        let id1 = try store.createFolder(name: "Engineering")
        let id2 = try store.createFolder(name: "Customer Calls")

        let folders = try store.listFolders()
        #expect(folders.count == 2)
        #expect(folders.contains(where: { $0.id == id1 && $0.name == "Engineering" }))
        #expect(folders.contains(where: { $0.id == id2 && $0.name == "Customer Calls" }))
    }

    @Test("rename folder")
    func renameFolder() throws {
        let store = try makeStore()

        let id = try store.createFolder(name: "Old Name")
        try store.renameFolder(id: id, name: "New Name")

        let folders = try store.listFolders()
        let folder = folders.first(where: { $0.id == id })
        #expect(folder?.name == "New Name")
    }

    @Test("delete folder removes it from list")
    func deleteFolderRemovesIt() throws {
        let store = try makeStore()

        let id = try store.createFolder(name: "To Delete")
        #expect(try store.listFolders().contains(where: { $0.id == id }))

        try store.deleteFolder(id: id)
        let remaining = try store.listFolders()
        #expect(!remaining.contains(where: { $0.id == id }))
    }

    // MARK: - Move Meeting to Folder

    @Test("move meeting to folder sets folderID")
    func moveMeetingToFolder() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Standup",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Daily standup",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let folderID = try store.createFolder(name: "Team")
        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil) // starts unfiled

        try store.moveMeeting(id: meeting.id, toFolder: folderID)

        let updated = try store.recentMeetings(limit: 1).first!
        #expect(updated.folderID == folderID)
    }

    @Test("move meeting to nil unfiles it")
    func moveMeetingToUnfiled() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Filed Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "words",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let folderID = try store.createFolder(name: "Temp")
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.moveMeeting(id: meetingID, toFolder: folderID)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == folderID)

        try store.moveMeeting(id: meetingID, toFolder: nil)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == nil)
    }

    @Test("delete folder moves its meetings to unfiled")
    func deleteFolderUnfilesMeetings() throws {
        let store = try makeStore()

        let now = Date()
        let folderID = try store.createFolder(name: "Doomed Folder")

        try store.insertMeeting(
            title: "Meeting A",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "a",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.moveMeeting(id: meetingID, toFolder: folderID)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == folderID)

        try store.deleteFolder(id: folderID)

        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil) // moved to unfiled
        #expect(meeting.title == "Meeting A") // meeting still exists
    }

    @Test("new meetings have nil folderID by default")
    func newMeetingsUnfiled() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Unfiled Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "test",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil)
    }

    // MARK: - Search Tests

    @Test("searchDictations returns matching records by raw_text")
    func searchDictationsMatches() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertDictation(text: "Hello world from muesli", durationSeconds: 2, startedAt: now, endedAt: now)
        try store.insertDictation(text: "Goodbye everyone", durationSeconds: 1, startedAt: now, endedAt: now)

        let results = try store.searchDictations(query: "muesli")
        #expect(results.count == 1)
        #expect(results.first!.rawText.contains("muesli"))
    }

    @Test("computer use dictation rows hydrate persisted trace")
    func computerUseTraceHydrates() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(
            text: "open Google Chrome",
            durationSeconds: 1.2,
            source: "cua",
            startedAt: now.addingTimeInterval(-1.2),
            endedAt: now
        )
        let events = [
            ComputerUseTraceEvent(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                kind: "model_output",
                title: "Model output",
                body: #"{"tool":"open_app","app_name":"Google Chrome"}"#,
                status: "planned",
                step: 1,
                timestamp: "2026-05-05T00:00:00Z"
            ),
            ComputerUseTraceEvent(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                kind: "finish",
                title: "Final output",
                body: "Done: open Google Chrome",
                status: "done",
                step: 1,
                timestamp: "2026-05-05T00:00:01Z"
            ),
        ]

        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "Done: open Google Chrome",
            events: events
        )

        let row = try #require(store.recentDictations(limit: 1).first)
        #expect(row.id == dictationID)
        #expect(row.source == "cua")
        #expect(row.computerUseTrace?.finalStatus == "done")
        #expect(row.computerUseTrace?.events == events)
    }

    @Test("searchDictations matches computer use trace text")
    func searchDictationsMatchesComputerUseTrace() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(
            text: "do the browser thing",
            durationSeconds: 1.0,
            source: "cua",
            startedAt: now,
            endedAt: now
        )
        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "Done: opened Google Chrome",
            events: [
                ComputerUseTraceEvent(kind: "tool_result", title: "Tool result", body: "Opened Google Chrome")
            ]
        )

        let results = try store.searchDictations(query: "Chrome")

        #expect(results.map(\.id).contains(dictationID))
        #expect(results.first(where: { $0.id == dictationID })?.computerUseTrace?.finalStatus == "done")
    }

    @Test("insertComputerUseTrace replaces existing trace atomically")
    func insertComputerUseTraceReplacesExistingTrace() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(
            text: "open chrome",
            durationSeconds: 1.0,
            source: "cua",
            startedAt: now,
            endedAt: now
        )

        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "failed",
            finalMessage: "Old",
            events: [ComputerUseTraceEvent(kind: "failed", title: "Failed", body: "Old")]
        )
        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "New",
            events: [ComputerUseTraceEvent(kind: "finish", title: "Final output", body: "New")]
        )

        let row = try #require(try store.dictation(id: dictationID))
        #expect(row.computerUseTrace?.finalStatus == "done")
        #expect(row.computerUseTrace?.finalMessage == "New")
        #expect(row.computerUseTrace?.events.map(\.body) == ["New"])
    }

    @Test("deleteDictation removes computer use trace")
    func deleteDictationRemovesComputerUseTrace() throws {
        let store = try makeStore()
        let now = Date()
        let dictationID = try store.insertDictation(
            text: "switch to Chrome",
            durationSeconds: 1.0,
            source: "cua",
            startedAt: now,
            endedAt: now
        )
        try store.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: "done",
            finalMessage: "Done",
            events: [ComputerUseTraceEvent(kind: "finish", title: "Final output", body: "Done")]
        )

        try store.deleteDictation(id: dictationID)

        #expect(try store.dictation(id: dictationID) == nil)
        #expect(try store.searchDictations(query: "Final output").isEmpty)
    }

    @Test("deleteDictation fails when row is missing")
    func deleteDictationFailsWhenRowMissing() throws {
        let store = try makeStore()
        #expect(throws: DictationStoreError.self) {
            try store.deleteDictation(id: 99_999)
        }
    }

    @Test("searchDictations returns empty for non-matching query")
    func searchDictationsNoMatch() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertDictation(text: "Hello world", durationSeconds: 2, startedAt: now, endedAt: now)

        let results = try store.searchDictations(query: "xyznonexistent")
        #expect(results.isEmpty)
    }

    @Test("searchMeetings matches across title, transcript, and notes")
    func searchMeetingsMultiField() throws {
        let store = try makeStore()
        let start = Date()
        try store.insertMeeting(
            title: "Sprint Planning",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(600),
            rawTranscript: "We discussed the backlog items",
            formattedNotes: "## Notes\nPrioritized features",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.insertMeeting(
            title: "Design Review",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(300),
            rawTranscript: "Reviewed the mockups",
            formattedNotes: "## Notes\nApproved designs",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let byTitle = try store.searchMeetings(query: "Sprint")
        #expect(byTitle.count == 1)
        #expect(byTitle.first!.title == "Sprint Planning")

        let byTranscript = try store.searchMeetings(query: "backlog")
        #expect(byTranscript.count == 1)

        let byNotes = try store.searchMeetings(query: "Prioritized")
        #expect(byNotes.count == 1)
    }

    @Test("searchMeetings matches manual notes")
    func searchMeetingsManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Quick Note", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Escalate renewal risk")

        let results = try store.searchMeetings(query: "renewal")

        #expect(results.map(\.id).contains(id))
    }

    @Test("search is case-insensitive for ASCII")
    func searchCaseInsensitive() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertDictation(text: "Meeting with Alice", durationSeconds: 2, startedAt: now, endedAt: now)

        let upper = try store.searchDictations(query: "ALICE")
        let lower = try store.searchDictations(query: "alice")
        let mixed = try store.searchDictations(query: "Alice")

        #expect(upper.count == 1)
        #expect(lower.count == 1)
        #expect(mixed.count == 1)
    }
}
