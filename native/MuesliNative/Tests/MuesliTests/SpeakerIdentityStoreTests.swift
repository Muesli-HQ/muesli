import Foundation
import MuesliCore
import SQLite3
import Testing

@Suite("Speaker identity store", .serialized)
struct SpeakerIdentityStoreTests {
    private static let transcript = """
    [10:00:00] You: hello Speaker 1: are you there
    [10:00:03] Speaker 1: hi from one
    [10:00:06] Speaker 12: hi from twelve
    [10:00:09] Speaker 1: back to one
    """

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-speakers-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @discardableResult
    private func insertMeeting(_ store: DictationStore, transcript: String = Self.transcript) throws -> Int64 {
        let now = Date()
        return try store.insertMeeting(
            title: "Call",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: transcript,
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    private func unit(_ axis: Int, toward other: Int? = nil, mix: Float = 0) -> [Float] {
        var values = [Float](repeating: 0, count: 256)
        values[axis] = 1 - mix
        if let other { values[other] += mix }
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return values.map { $0 / norm }
    }

    private func observation(_ label: String, _ centroid: [Float]?) -> MeetingSpeakerObservation {
        MeetingSpeakerObservation(label: label, centroid: centroid, speechSeconds: centroid == nil ? 2 : 60)
    }

    private func rawTranscript(_ store: DictationStore, _ id: Int64) throws -> String {
        try store.meeting(id: id)?.rawTranscript ?? ""
    }

    private func count(_ store: DictationStore, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Schema

    @Test("legacy database gains the speaker tables and migrates twice")
    func legacyMigration() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-speakers-legacy-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let legacy = """
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
        #expect(sqlite3_exec(db, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        try store.migrateIfNeeded()
        for table in ["speaker_profiles", "speaker_voiceprints", "meeting_speakers"] {
            #expect(try count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'") == 1)
        }
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        #expect(try store.meetingSpeakers(meetingID: id).map(\.label) == ["Speaker 1"])
    }

    // MARK: - Pipeline recording

    @Test("no profiles: nothing renamed, rows and centroids remembered")
    func recordWithoutProfiles() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        let names = try store.recordMeetingSpeakers(
            meetingID: id,
            observations: [observation("Speaker 1", unit(0)), observation("Speaker 12", nil)],
            renderNames: true
        )
        #expect(names.isEmpty)
        let speakers = try store.meetingSpeakers(meetingID: id)
        #expect(speakers.map(\.label) == ["Speaker 1", "Speaker 12"])
        #expect(speakers.map(\.hasVoiceprintSource) == [true, false])
        #expect(speakers.allSatisfy { $0.profileID == nil })
    }

    @Test("a named speaker is recognized in a later meeting; a stranger is not")
    func matchesAcrossMeetings() throws {
        let store = try makeStore()
        let first = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: first, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: first, label: "Speaker 1", name: "Alex")

        let second = try insertMeeting(store)
        let names = try store.recordMeetingSpeakers(
            meetingID: second,
            observations: [observation("Speaker 1", unit(1)), observation("Speaker 12", unit(0, toward: 1, mix: 0.1))],
            renderNames: true
        )
        #expect(names == ["Speaker 12": "Alex"])
        let speakers = try store.meetingSpeakers(meetingID: second)
        #expect(speakers.first { $0.label == "Alex" }?.profileName == "Alex")
        #expect(speakers.first { $0.label == "Speaker 1" }?.profileID == nil)
    }

    @Test("private meetings record the match but never render the name")
    func privateMeetingDoesNotRender() throws {
        let store = try makeStore()
        let first = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: first, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: first, label: "Speaker 1", name: "Alex")

        let second = try insertMeeting(store)
        try store.setMeetingPrivate(id: second, isPrivate: true)
        let names = try store.recordMeetingSpeakers(
            meetingID: second, observations: [observation("Speaker 1", unit(0))], renderNames: false
        )
        #expect(names.isEmpty)
        let speaker = try #require(try store.meetingSpeakers(meetingID: second).first)
        #expect(speaker.label == "Speaker 1")
        #expect(speaker.profileName == "Alex")

        // Manual naming in a private meeting keeps the transcript untouched too.
        let third = try insertMeeting(store)
        try store.setMeetingPrivate(id: third, isPrivate: true)
        _ = try store.recordMeetingSpeakers(meetingID: third, observations: [observation("Speaker 12", unit(5))], renderNames: false)
        let result = try store.assignSpeaker(meetingID: third, label: "Speaker 12", name: "Blair")
        #expect(result.transcriptRewritten == false)
        #expect(try rawTranscript(store, third) == Self.transcript)
        #expect(try store.meetingSpeakers(meetingID: third).first?.profileName == "Blair")
    }

    // MARK: - Rename

    @Test("rename rewrites only the exact line label; Speaker 1 never touches Speaker 12 or body text")
    func renameRewritesExactLabel() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(
            meetingID: id,
            observations: [observation("Speaker 1", unit(0)), observation("Speaker 12", unit(1))],
            renderNames: true
        )
        let result = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: "  Alex  ")
        #expect(result.transcriptRewritten)
        #expect(result.voiceprintStored)
        #expect(try rawTranscript(store, id) == """
        [10:00:00] You: hello Speaker 1: are you there
        [10:00:03] Alex: hi from one
        [10:00:06] Speaker 12: hi from twelve
        [10:00:09] Alex: back to one
        """)
        #expect(try store.meetingSpeakers(meetingID: id).map(\.label).sorted() == ["Alex", "Speaker 12"])
    }

    @Test("rewrite helper escapes labels and ignores substrings")
    func rewriteHelper() {
        let text = "[00:00:01] A.B: x\n[00:00:02] AxB: y\n[00:00:03] A.B C: z"
        #expect(DictationStore.rewriteSpeakerLabel(in: text, from: "A.B", to: "Dee") == "[00:00:01] Dee: x\n[00:00:02] AxB: y\n[00:00:03] A.B C: z")
        #expect(DictationStore.rewriteSpeakerLabel(in: text, from: "A.B", to: "$1 \\") == "[00:00:01] $1 \\: x\n[00:00:02] AxB: y\n[00:00:03] A.B C: z")
    }

    @Test("rename persists across a reload and teaches future meetings")
    func renamePersists() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: "Alex")

        let reloaded = DictationStore(databaseURL: store.databasePath())
        try reloaded.migrateIfNeeded()
        #expect(try reloaded.meetingSpeakers(meetingID: id).first?.profileName == "Alex")
        #expect(try rawTranscript(reloaded, id).contains("[10:00:03] Alex: hi from one"))
        let profiles = try reloaded.speakerProfiles()
        #expect(profiles.map(\.name) == ["Alex"])
        #expect(profiles.first?.voiceprintCount == 1)
        #expect(profiles.first?.meetingCount == 1)
    }

    @Test("renaming to an existing name (any case) merges into that profile")
    func renameMergesIntoExistingProfile() throws {
        let store = try makeStore()
        let first = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: first, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: first, label: "Speaker 1", name: "Alex")
        let second = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: second, observations: [observation("Speaker 12", unit(3))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: second, label: "Speaker 12", name: "alex")

        let profiles = try store.speakerProfiles()
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Alex")
        #expect(profiles.first?.voiceprintCount == 2)
        #expect(try rawTranscript(store, second).contains("[10:00:06] Alex: hi from twelve"))
    }

    @Test("empty, whitespace, and reserved names are rejected without changes")
    func invalidNamesRejected() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        for bad in ["", "   ", "\n\t", "You", "Speaker 3", "others", "Alex: Smith", "Line\nBreak"] {
            #expect(throws: SpeakerIdentityError.self) {
                _ = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: bad)
            }
        }
        #expect(throws: SpeakerIdentityError.self) {
            _ = try store.assignSpeaker(meetingID: id, label: "You", name: "Alex")
        }
        #expect(try store.speakerProfiles().isEmpty)
        #expect(try rawTranscript(store, id) == Self.transcript)
    }

    @Test("two speakers in one meeting cannot share a name")
    func duplicateNameInMeetingRejected() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(
            meetingID: id,
            observations: [observation("Speaker 1", unit(0)), observation("Speaker 12", unit(1))],
            renderNames: true
        )
        _ = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: "Alex")
        #expect(throws: SpeakerIdentityError.self) {
            _ = try store.assignSpeaker(meetingID: id, label: "Speaker 12", name: "ALEX")
        }
    }

    @Test("repeated and concurrent renames are idempotent")
    func concurrentRenameIdempotent() async throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        let url = store.databasePath()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try DictationStore(databaseURL: url).assignSpeaker(meetingID: id, label: "Speaker 1", name: "Alex")
                }
            }
            try await group.waitForAll()
        }
        _ = try store.assignSpeaker(meetingID: id, label: "Alex", name: "Alex")
        #expect(try store.speakerProfiles().map(\.voiceprintCount) == [1])
        #expect(try rawTranscript(store, id).components(separatedBy: "] Alex:").count - 1 == 2)
    }

    @Test("reassigning a speaker to another person moves this meeting's voiceprint")
    func reassignMovesVoiceprint() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: "Alex")
        _ = try store.assignSpeaker(meetingID: id, label: "Alex", name: "Blair")
        let profiles = Dictionary(uniqueKeysWithValues: try store.speakerProfiles().map { ($0.name, $0.voiceprintCount) })
        #expect(profiles == ["Alex": 0, "Blair": 1])
        #expect(try rawTranscript(store, id).contains("[10:00:03] Blair: hi from one"))
    }

    @Test("a speaker with too little audio can be named but stores no voiceprint")
    func shortSpeakerNamedWithoutVoiceprint() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 12", nil)], renderNames: true)
        let result = try store.assignSpeaker(meetingID: id, label: "Speaker 12", name: "Casey")
        #expect(result.voiceprintStored == false)
        #expect(try store.speakerProfiles().first?.voiceprintCount == 0)
        #expect(try rawTranscript(store, id).contains("[10:00:06] Casey: hi from twelve"))
    }

    // MARK: - Forget and delete

    @Test("forget voiceprint deletes the rows and keeps the person")
    func forgetVoiceprint() throws {
        let store = try makeStore()
        let first = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: first, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: first, label: "Speaker 1", name: "Alex")
        let profileID = try #require(try store.speakerProfiles().first?.id)

        try store.forgetVoiceprints(profileID: profileID, sourceMeetingID: first)
        #expect(try store.speakerProfiles().first?.voiceprintCount == 0)
        #expect(try store.speakerProfiles().first?.name == "Alex")
        #expect(try store.meetingSpeakers(meetingID: first).first?.profileID == profileID)

        let second = try insertMeeting(store)
        let names = try store.recordMeetingSpeakers(meetingID: second, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        #expect(names.isEmpty)
    }

    @Test("delete person cascades voiceprints, un-names meeting speakers, keeps transcript text")
    func deletePersonCascades() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: "Alex")
        let profileID = try #require(try store.speakerProfiles().first?.id)

        try store.deleteSpeakerProfile(id: profileID)
        #expect(try store.speakerProfiles().isEmpty)
        #expect(try count(store, "SELECT COUNT(*) FROM speaker_voiceprints") == 0)
        let speaker = try #require(try store.meetingSpeakers(meetingID: id).first)
        #expect(speaker.profileID == nil)
        #expect(speaker.label == "Alex")
        #expect(try rawTranscript(store, id).contains("[10:00:03] Alex: hi from one"))

        // The orphaned label can still be renamed later.
        _ = try store.assignSpeaker(meetingID: id, label: "Alex", name: "Alexandra")
        #expect(try rawTranscript(store, id).contains("[10:00:03] Alexandra: hi from one"))
    }

    @Test("deleting a meeting removes its speaker rows and centroids")
    func deletingMeetingRemovesSpeakers() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        try store.deleteMeeting(id: id)
        #expect(try count(store, "SELECT COUNT(*) FROM meeting_speakers") == 0)
    }

    @Test("retranscription drops stale speaker rows so old centroids cannot be named onto new labels")
    func retranscriptionDropsSpeakerRows() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        _ = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: "Alex")
        try store.updateMeetingTranscriptAndSummary(
            id: id, rawTranscript: "[10:00:03] Speaker 1: redo", formattedNotes: "",
            selectedTemplateID: "auto", selectedTemplateName: "Auto", selectedTemplateKind: .auto, selectedTemplatePrompt: ""
        )
        #expect(try store.meetingSpeakers(meetingID: id).isEmpty)
        // Voiceprints already confirmed by the user stay valid.
        #expect(try store.speakerProfiles().first?.voiceprintCount == 1)
    }

    @Test("speakers for a deleted or missing meeting are not recorded")
    func deletedMeetingNotRecorded() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        try store.deleteMeeting(id: id)
        let names = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        #expect(names.isEmpty)
        _ = try store.recordMeetingSpeakers(meetingID: 999_999, observations: [observation("Speaker 1", unit(0))], renderNames: true)
        #expect(try count(store, "SELECT COUNT(*) FROM meeting_speakers") == 0)
    }

    // MARK: - Privacy

    @Test("sync records carry no speaker profile, voiceprint, or centroid data")
    func syncRecordHasNoSpeakerData() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let centroid = unit(0)
        _ = try store.recordMeetingSpeakers(meetingID: id, observations: [observation("Speaker 1", centroid)], renderNames: false)
        _ = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: "Zebulon Quarry")

        // While the meeting is private, nothing about it is offered to sync at all.
        #expect(try store.textRecordsNeedingSync(limit: 50).filter { $0.kind == .meeting }.isEmpty)

        // Once it is a normal meeting, its record still carries no speaker data.
        try store.setMeetingPrivate(id: id, isPrivate: false)
        let records = try store.textRecordsNeedingSync(limit: 50).filter { $0.kind == .meeting }
        #expect(!records.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!encoded.contains("Zebulon"))
        let centroidBytes = centroid.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(!encoded.contains(centroidBytes.base64EncodedString().prefix(24)))
        let fieldNames = Mirror(reflecting: records[0]).children.compactMap(\.label).map { $0.lowercased() }
        #expect(fieldNames.contains { $0.contains("embedding") || $0.contains("voiceprint") || $0.contains("profile") } == false)
    }

    // MARK: - Resume preservation and speaker numbering offset (Finding 5)

    @Test("resumed meeting preserves existing speaker rows and offsets new Speaker N labels")
    func resumePreservesSpeakersAndOffsetsLabels() throws {
        let store = try makeStore()
        let session1Transcript = """
        [10:00:00] Speaker 1: opening point
        [10:00:05] Speaker 2: second point
        """
        let id = try store.createLiveMeeting(title: "Call", calendarEventID: nil, startTime: Date())
        try store.completeLiveMeeting(
            id: id,
            title: "Call",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date(),
            durationSeconds: 60,
            rawTranscript: session1Transcript,
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        _ = try store.recordMeetingSpeakers(
            meetingID: id,
            observations: [observation("Speaker 1", unit(0)), observation("Speaker 2", unit(1))],
            renderNames: true
        )

        let prior = try store.prepareMeetingForResume(id: id)
        #expect(try store.nextSpeakerNumber(forMeetingID: id, priorTranscript: prior) == 3)

        // Session 2 arrives with offset labels Speaker 3 and Speaker 4, preserving session 1.
        _ = try store.recordMeetingSpeakers(
            meetingID: id,
            observations: [observation("Speaker 3", unit(2)), observation("Speaker 4", unit(3))],
            renderNames: true,
            preservingExisting: true
        )
        let combined = prior + "\n\n— Resumed —\n\n" + """
        [10:05:00] Speaker 3: resumed point
        [10:05:05] Speaker 4: follow-up point
        """
        try store.completeLiveMeeting(
            id: id,
            title: "Call",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date(),
            durationSeconds: 120,
            rawTranscript: combined,
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let speakers = try store.meetingSpeakers(meetingID: id)
        #expect(speakers.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4"])

        let result = try store.assignSpeaker(meetingID: id, label: "Speaker 3", name: "Casey")
        #expect(result.transcriptRewritten)
        let updated = try rawTranscript(store, id)
        #expect(updated.contains("[10:00:00] Speaker 1: opening point"))
        #expect(updated.contains("[10:00:05] Speaker 2: second point"))
        #expect(updated.contains("[10:05:00] Casey: resumed point"))
        #expect(updated.contains("[10:05:05] Speaker 4: follow-up point"))
    }

    @Test("resumed meeting with un-offset observations shifts colliding labels without overwriting session 1")
    func resumeWithUnOffsetObservationsShiftsSafely() throws {
        let store = try makeStore()
        let session1Transcript = """
        [10:00:00] Speaker 1: first session
        [10:00:05] Speaker 2: first session two
        """
        let id = try insertMeeting(store, transcript: session1Transcript)
        _ = try store.recordMeetingSpeakers(
            meetingID: id,
            observations: [observation("Speaker 1", unit(0)), observation("Speaker 2", unit(1))],
            renderNames: true
        )
        _ = try store.assignSpeaker(meetingID: id, label: "Speaker 1", name: "Alex")

        // Even if called directly with Speaker 1 / Speaker 2, preservingExisting keeps
        // Alex and Speaker 2 intact and shifts new observations past Speaker 2.
        _ = try store.recordMeetingSpeakers(
            meetingID: id,
            observations: [observation("Speaker 1", unit(2)), observation("Speaker 2", unit(3))],
            renderNames: true,
            preservingExisting: true
        )
        let labels = try store.meetingSpeakers(meetingID: id).map(\.label)
        #expect(labels == ["Alex", "Speaker 2", "Speaker 3", "Speaker 4"])
    }
}
