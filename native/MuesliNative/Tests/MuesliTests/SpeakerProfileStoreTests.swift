import Testing
import Foundation
import MuesliCore
import SQLite3
@testable import MuesliNativeApp

@Suite("Speaker profile store", .serialized)
struct SpeakerProfileStoreTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-speakers-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    /// A pre-feature schema (no speaker tables) to verify additive migration.
    private func makeLegacyStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-speakers-legacy-\(UUID().uuidString).db")
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

    private func makeMeeting(_ store: DictationStore) throws -> Int64 {
        try store.createLiveMeeting(title: "M", calendarEventID: nil, startTime: Date())
    }

    private func expectClose(_ a: [Float], _ b: [Float], tolerance: Float = 1e-5) {
        #expect(a.count == b.count)
        for (lhs, rhs) in zip(a, b) {
            #expect(abs(lhs - rhs) < tolerance)
        }
    }

    @Test("fresh DB creates speaker tables; migration is idempotent")
    func freshMigration() throws {
        let store = try makeStore()
        try store.migrateIfNeeded() // idempotent re-run
        #expect(try store.speakerProfiles().isEmpty)
    }

    @Test("additive migration upgrades a legacy schema")
    func legacyMigration() throws {
        let store = try makeLegacyStore()
        try store.migrateIfNeeded()
        try store.upsertSpeakerProfile(id: "p1", name: "Bob", embedding: [0.1, 0.2])
        #expect(try store.speakerProfiles().count == 1)
    }

    @Test("upsert + fetch round-trips name and embedding")
    func profileRoundTrip() throws {
        let store = try makeStore()
        let embedding: [Float] = (0..<256).map { Float($0) / 256.0 }
        try store.upsertSpeakerProfile(id: "bob-1", name: "Bob", embedding: embedding, observationCount: 3)

        let fetched = try #require(try store.speakerProfile(id: "bob-1"))
        #expect(fetched.name == "Bob")
        #expect(fetched.observationCount == 3)
        expectClose(fetched.embedding, embedding)
    }

    @Test("upsert updates in place without orphaning linked rows")
    func upsertUpdatesInPlace() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(store)
        try store.upsertSpeakerProfile(id: "p1", name: "Bob", embedding: [0.1, 0.2])
        try store.insertMeetingSpeaker(
            meetingID: meetingID, speakerLabel: "Speaker 1", embedding: [0.1, 0.2],
            profileID: "p1", displayName: "Bob", matchDistance: 0.1, matchState: .confirmed
        )

        // Re-upsert (refine) the same profile.
        try store.upsertSpeakerProfile(id: "p1", name: "Bob", embedding: [0.3, 0.4], observationCount: 2)

        let profiles = try store.speakerProfiles()
        #expect(profiles.count == 1)
        // The linked row must still point at the profile (no REPLACE-induced SET NULL).
        let speakers = try store.meetingSpeakers(for: meetingID)
        #expect(speakers.first?.profileID == "p1")
    }

    @Test("rename changes the stored profile name")
    func renameProfile() throws {
        let store = try makeStore()
        try store.upsertSpeakerProfile(id: "p1", name: "Bob", embedding: [0.1])
        try store.renameSpeakerProfile(id: "p1", name: "Robert")
        #expect(try store.speakerProfile(id: "p1")?.name == "Robert")
    }

    @Test("insertMeetingSpeaker + fetch round-trips all fields")
    func meetingSpeakerRoundTrip() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(store)
        try store.upsertSpeakerProfile(id: "p1", name: "Bob", embedding: [0.1])
        let embedding: [Float] = [0.5, 0.25, 0.125]
        try store.insertMeetingSpeaker(
            meetingID: meetingID, speakerLabel: "Speaker 2", embedding: embedding,
            profileID: "p1", displayName: "Bob", matchDistance: 0.42, matchState: .auto
        )

        let rows = try store.meetingSpeakers(for: meetingID)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.speakerLabel == "Speaker 2")
        #expect(row.profileID == "p1")
        #expect(row.displayName == "Bob")
        #expect(row.matchDistance == 0.42)
        #expect(row.matchState == .auto)
        expectClose(row.embedding, embedding)
    }

    @Test("unmatched cluster persists with nil profile/name")
    func unmatchedSpeaker() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(store)
        try store.insertMeetingSpeaker(meetingID: meetingID, speakerLabel: "Speaker 1", embedding: [0.1, 0.2])
        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.profileID == nil)
        #expect(row.displayName == nil)
        #expect(row.matchDistance == nil)
        #expect(row.matchState == .unmatched)
    }

    @Test("updateMeetingSpeaker applies recognition/naming results")
    func updateSpeaker() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(store)
        try store.upsertSpeakerProfile(id: "p1", name: "Bob", embedding: [0.1])
        let id = try store.insertMeetingSpeaker(meetingID: meetingID, speakerLabel: "Speaker 1", embedding: [0.1])

        try store.updateMeetingSpeaker(id: id, profileID: "p1", displayName: "Bob", matchDistance: 0.3, matchState: .confirmed)

        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.matchState == .confirmed)
        #expect(row.displayName == "Bob")
        #expect(row.profileID == "p1")
    }

    @Test("deleting a meeting cascades its speaker rows")
    func cascadeDelete() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(store)
        try store.insertMeetingSpeaker(meetingID: meetingID, speakerLabel: "Speaker 1", embedding: [0.1])
        try store.insertMeetingSpeaker(meetingID: meetingID, speakerLabel: "Speaker 2", embedding: [0.2])
        #expect(try store.meetingSpeakers(for: meetingID).count == 2)

        try store.deleteMeeting(id: meetingID)
        #expect(try store.meetingSpeakers(for: meetingID).isEmpty)
    }

    @Test("deleteMeetingSpeakers clears only the target meeting")
    func deleteMeetingSpeakersScoped() throws {
        let store = try makeStore()
        let m1 = try makeMeeting(store)
        let m2 = try makeMeeting(store)
        try store.insertMeetingSpeaker(meetingID: m1, speakerLabel: "Speaker 1", embedding: [0.1])
        try store.insertMeetingSpeaker(meetingID: m2, speakerLabel: "Speaker 1", embedding: [0.2])

        try store.deleteMeetingSpeakers(for: m1)
        #expect(try store.meetingSpeakers(for: m1).isEmpty)
        #expect(try store.meetingSpeakers(for: m2).count == 1)
    }

    @Test("merge repoints linked rows and deletes the merged-away profile")
    func mergeProfiles() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(store)
        try store.upsertSpeakerProfile(id: "keep", name: "Robert", embedding: [0.1])
        try store.upsertSpeakerProfile(id: "remove", name: "Bob", embedding: [0.2])
        try store.insertMeetingSpeaker(
            meetingID: meetingID, speakerLabel: "Speaker 1", embedding: [0.2],
            profileID: "remove", displayName: "Bob", matchState: .confirmed
        )

        try store.mergeSpeakerProfiles(keepID: "keep", removeID: "remove")

        #expect(try store.speakerProfile(id: "remove") == nil)
        #expect(try store.speakerProfiles().count == 1)
        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.profileID == "keep")
        #expect(row.displayName == "Robert") // aligned to kept profile's name
    }

    @Test("hasSeenVoiceProfileNote round-trips; missing key decodes false")
    func voiceProfileNoteFlag() throws {
        var config = AppConfig()
        #expect(config.hasSeenVoiceProfileNote == false) // default
        config.hasSeenVoiceProfileNote = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.hasSeenVoiceProfileNote == true)

        // A config JSON missing the key decodes to false (note shows once).
        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(legacy.hasSeenVoiceProfileNote == false)
    }

    // Covers R9.
    @Test("deleting a profile removes it AND scrubs linked voiceprint copies")
    func deleteScrubsVoiceprint() throws {
        let store = try makeStore()
        let meetingID = try makeMeeting(store)
        try store.upsertSpeakerProfile(id: "p1", name: "Bob", embedding: [0.1, 0.2, 0.3])
        try store.insertMeetingSpeaker(
            meetingID: meetingID, speakerLabel: "Speaker 1", embedding: [0.1, 0.2, 0.3],
            profileID: "p1", displayName: "Bob", matchDistance: 0.1, matchState: .confirmed
        )

        try store.deleteSpeakerProfile(id: "p1")

        #expect(try store.speakerProfile(id: "p1") == nil)
        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.profileID == nil)             // FK SET NULL
        #expect(row.displayName == nil)           // name scrubbed
        #expect(row.matchState == .unmatched)     // state reset
        #expect(row.embedding.isEmpty)            // per-meeting voiceprint copy gone
    }
}
