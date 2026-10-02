import Foundation
import MuesliCore
import SQLite3
import Testing

@Suite("Guarded meeting speaker state", .serialized)
struct MeetingSpeakerStateTests {
    private func withStore(_ body: (DictationStore, Int64) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("fixture.db"))
        try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: "[00:00:01] Speaker 1: Original words", formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil, source: .meeting)
        try body(store, id)
    }

    private func state() -> MeetingSpeakerState {
        let session = UUID()
        let key = MeetingSpeakerKey(session: session, source: .system, clusterID: "a")
        return MeetingSpeakerState(session: session, segments: [.init(key: key, start: 1, end: 3, timestamp: "00:00:01", text: "Original words")], assignments: [key: .init(label: "Speaker 1", evidence: .unknown)])
    }

    @Test("label updates atomically preserve utterances and advance the generation")
    func guardedRename() throws {
        try withStore { store, id in
            let initial = state()
            #expect(try store.saveInitialSpeakerState(meetingID: id, state: initial, rendered: initial.renderedTranscript()) == .updated)
            var loaded = try #require(store.meetingSpeakerState(meetingID: id))
            let previous = loaded.generation
            loaded.assignments[loaded.segments[0].key] = .init(label: "Example Person", evidence: .manual, participantID: "contact:fixture")
            #expect(try store.renderSpeakerStateIfCurrent(meetingID: id, state: loaded) == .updated)
            #expect(try store.meetingRawTranscript(id: id) == "[00:00:01] Example Person: Original words")
            #expect(try store.meetingSpeakerState(meetingID: id)?.generation == previous + 1)
            #expect(try store.renderSpeakerStateIfCurrent(meetingID: id, state: loaded) == .invalidatedByTextEdit)
        }
    }

    @Test("free text and direct SQL edits survive stale structured label updates")
    func externalEditWins() throws {
        try withStore { store, id in
            let initial = state()
            _ = try store.saveInitialSpeakerState(meetingID: id, state: initial, rendered: initial.renderedTranscript())
            var loaded = try #require(store.meetingSpeakerState(meetingID: id))
            try store.updateMeetingTranscript(id: id, rawTranscript: "User corrected the words")
            loaded.assignments[loaded.segments[0].key] = .init(label: "Example Person", evidence: .manual)
            #expect(try store.renderSpeakerStateIfCurrent(meetingID: id, state: loaded) == .invalidatedByTextEdit)
            #expect(try store.meetingRawTranscript(id: id) == "User corrected the words")
        }
    }

    @Test("cloud-like SQL update invalidates automatic naming even without app callbacks")
    func directSQLMutation() throws {
        try withStore { store, id in
            let initial = state()
            _ = try store.saveInitialSpeakerState(meetingID: id, state: initial, rendered: initial.renderedTranscript())
            let loaded = try #require(store.meetingSpeakerState(meetingID: id))
            var db: OpaquePointer?
            #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "UPDATE meetings SET raw_transcript = 'Incoming corrected words'", nil, nil, nil) == SQLITE_OK)
            #expect(try store.renderSpeakerStateIfCurrent(meetingID: id, state: loaded) == .invalidatedByTextEdit)
            #expect(try store.meetingRawTranscript(id: id) == "Incoming corrected words")
        }
    }

    @Test("a state for a different session cannot rename the current transcript")
    func sessionIsolation() throws {
        try withStore { store, id in
            let initial = state()
            _ = try store.saveInitialSpeakerState(meetingID: id, state: initial, rendered: initial.renderedTranscript())
            #expect(try store.renderSpeakerStateIfCurrent(meetingID: id, state: state()) == .invalidatedByTextEdit)
            #expect(try store.meetingRawTranscript(id: id) == "[00:00:01] Speaker 1: Original words")
        }
    }

    @Test("duplicate display names do not consolidate unrelated stable speakers")
    func stableKeys() {
        var value = state()
        let other = MeetingSpeakerKey(session: value.session, source: .system, clusterID: "b")
        value.segments.append(.init(key: other, start: 3, end: 4, timestamp: "00:00:03", text: "Other words"))
        value.assignments[value.segments[0].key] = .init(label: "Example", evidence: .manual)
        value.assignments[other] = .init(label: "Example (2)", evidence: .manual)
        #expect(value.renderedTranscript() == "[00:00:01] Example: Original words\n[00:00:03] Example (2): Other words")
    }
    @Test("resume retains original keys and speech while separating capture epochs")
    func resumedState() {
        var prior = state()
        prior.lastGeneratedHash = MeetingSpeakerState.hash(prior.renderedTranscript())
        let next = state()
        let separator = "\n\n— Resumed —\n\n"
        let combined = next.appending(prior: prior, priorTranscript: prior.renderedTranscript(), separator: separator)
        #expect(combined.renderedTranscript() == prior.renderedTranscript() + separator + next.renderedTranscript())
        #expect(combined.segments.map(\.key) == [prior.segments[0].key, next.segments[0].key])
        #expect(combined.segments.map(\.text) == ["Original words", "Original words"])
    }

    @Test("resume preserves edited prior speech as opaque text")
    func resumedEditedSpeech() {
        let next = state()
        let edited = "Corrected prior words: a literal sentence"
        let separator = "\n\n— Resumed —\n\n"
        let combined = next.appending(prior: state(), priorTranscript: edited, separator: separator)
        #expect(combined.renderedTranscript() == edited + separator + next.renderedTranscript())
        #expect(combined.segments.count == 1)
        #expect(combined.literalPrefix == edited)
    }

    @Test("voice removal invalidates automatic evidence and retains explicit correction")
    func voiceRemovalKeepsManualMapping() {
        var value = state()
        let key = value.segments[0].key
        value.voiceGeneration = 2
        value.candidates = [.init(key: key, evidence: .voiceVerified)]
        value.assignments[key] = .init(label: "You", evidence: .manual, isOwner: true)
        value.invalidateVoiceEvidence()
        #expect(value.candidates[0].evidence == .unknown)
        #expect(value.assignments[key]?.evidence == .manual)
        #expect(value.assignments[key]?.label == "You")
        #expect(value.voiceGeneration == nil)
        value.assignments[key] = .init(label: "You", evidence: .voiceVerified, isOwner: true, dependsOnVoice: true)
        value.invalidateVoiceEvidence()
        #expect(value.assignments[key]?.label == "Unknown speaker")
    }

    @Test("rename marks existing summary stale without mutating summary or meeting date")
    func staleSummary() throws {
        try withStore { store, id in
            let before = try #require(store.meeting(id: id))
            let initial = state()
            _ = try store.saveInitialSpeakerState(meetingID: id, state: initial, rendered: initial.renderedTranscript())
            var loaded = try #require(store.meetingSpeakerState(meetingID: id))
            loaded.assignments[loaded.segments[0].key] = .init(label: "Example Person", evidence: .manual)
            _ = try store.renderSpeakerStateIfCurrent(meetingID: id, state: loaded)
            #expect(try store.meetingSpeakerState(meetingID: id)?.summaryIsStale == true)
            #expect(try store.meeting(id: id)?.formattedNotes == before.formattedNotes)
            #expect(try store.meeting(id: id)?.startTime == before.startTime)
        }
    }

    @Test("a resume summary snapshot cannot overwrite text edited during the await")
    func resumeSnapshotConflict() throws {
        try withStore { store, id in
            let captured = try #require(store.meetingRawTranscript(id: id))
            _ = try store.prepareMeetingForResume(id: id)
            try store.updateMeetingTranscript(id: id, rawTranscript: "Edited while summary was pending")
            #expect(throws: DictationStoreError.self) {
                try store.completeLiveMeeting(id: id, title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                    rawTranscript: captured + " appended speech", formattedNotes: "Stale notes", micAudioPath: nil, systemAudioPath: nil,
                    expectedRawTranscript: captured)
            }
            #expect(try store.meetingRawTranscript(id: id) == "Edited while summary was pending")
        }
    }

    @Test("deleting history removes local recovery speech and role identifiers")
    func deletionClearsIdentityState() throws {
        for operation in [0, 1, 2] {
            try withStore { store, id in
                let initial = state()
                _ = try store.saveInitialSpeakerState(meetingID: id, state: initial, rendered: initial.renderedTranscript())
                try store.attachMeetingParticipant(meetingID: id, participant: .init(participantIdentifier: "contact:fixture", displayName: "Example Person"))
                try store.setMeetingParticipantRole(meetingID: id, participantID: "contact:fixture", role: .owner)
                if operation == 0 { try store.deleteMeeting(id: id) }
                else if operation == 1 { try store.clearMeetings() }
                else {
                    var db: OpaquePointer?
                    #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
                    defer { sqlite3_close(db) }
                    #expect(sqlite3_exec(db, "UPDATE meetings SET deleted_at = 1", nil, nil, nil) == SQLITE_OK)
                }
                #expect(try store.meetingSpeakerState(meetingID: id) == nil)
                var db: OpaquePointer?
                #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
                defer { sqlite3_close(db) }
                var statement: OpaquePointer?
                #expect(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meeting_identity_roles", -1, &statement, nil) == SQLITE_OK)
                defer { sqlite3_finalize(statement) }
                #expect(sqlite3_step(statement) == SQLITE_ROW)
                #expect(sqlite3_column_int(statement, 0) == 0)
            }
        }
    }

    @Test("calendar refresh never overwrites an explicitly unknown participant role")
    func explicitRoleWinsCalendarRefresh() throws {
        try withStore { store, id in
            try store.attachCalendarMeetingParticipants(meetingID: id, participants: [.init(participantIdentifier: "calendar:fixture", displayName: "Example Person")])
            try store.setMeetingParticipantRole(meetingID: id, participantID: "calendar:fixture", role: .unknown)
            try store.setMeetingParticipantRole(meetingID: id, participantID: "calendar:fixture", role: .remote, onlyIfUnspecified: true)
            #expect(try store.meetingParticipantRoles(meetingID: id)["calendar:fixture"] == .unknown)
        }
    }

    @Test("a matching opaque prefix resumes with the exact separator")
    func matchingPrefixResume() {
        var prior = state()
        prior.segments = []
        prior.literalPrefix = "Edited prior words"
        prior.lastGeneratedHash = MeetingSpeakerState.hash(prior.literalPrefix)
        let next = state()
        let separator = "\n\n— Resumed —\n\n"
        let combined = next.appending(prior: prior, priorTranscript: prior.literalPrefix, separator: separator)
        #expect(combined.renderedTranscript() == prior.literalPrefix + separator + next.renderedTranscript())
    }

    @Test("profile invalidation skips fresh evidence and survives a process generation reset")
    func stableProfileIdentity() {
        let identity = UUID()
        var value = state()
        value.voiceGeneration = 2
        value.voiceProfileID = identity
        #expect(!value.requiresVoiceInvalidation(for: identity))
        #expect(value.requiresVoiceInvalidation(for: nil))
        #expect(value.requiresVoiceInvalidation(for: UUID()))
        var next = state()
        next.voiceGeneration = 1
        next.voiceProfileID = identity
        value.lastGeneratedHash = MeetingSpeakerState.hash(value.renderedTranscript())
        value.candidates = [.init(key: value.segments[0].key, evidence: .voiceVerified)]
        let combined = next.appending(prior: value, priorTranscript: value.renderedTranscript(), separator: "\n\n— Resumed —\n\n")
        #expect(combined.candidates[0].evidence == .voiceVerified)
    }

    @Test("resume invalidates prior evidence without erasing fresh current-profile evidence")
    func resumeKeepsFreshEvidenceWhenProfileChanges() {
        let oldProfileID = UUID()
        let newProfileID = UUID()
        var prior = state()
        let priorKey = prior.segments[0].key
        prior.voiceGeneration = 4
        prior.voiceProfileID = oldProfileID
        prior.candidates = [.init(key: priorKey, evidence: .voiceVerified)]
        prior.assignments[priorKey] = .init(label: "You", evidence: .voiceVerified, isOwner: true, dependsOnVoice: true)
        prior.lastGeneratedHash = MeetingSpeakerState.hash(prior.renderedTranscript())

        var current = state()
        let currentKey = current.segments[0].key
        current.segments[0] = .init(key: currentKey, start: 4, end: 5, timestamp: "00:00:04", text: "New capture")
        current.voiceGeneration = 1
        current.voiceProfileID = newProfileID
        current.candidates = [.init(key: currentKey, evidence: .voiceVerified)]
        current.assignments[currentKey] = .init(label: "You", evidence: .voiceVerified, isOwner: true, dependsOnVoice: true)

        let combined = current.appending(prior: prior, priorTranscript: prior.renderedTranscript(), separator: "\n\n— Resumed —\n\n")

        #expect(combined.candidates.first(where: { $0.key == priorKey })?.evidence == .unknown)
        #expect(combined.assignments[priorKey]?.label == "Unknown speaker")
        #expect(combined.candidates.first(where: { $0.key == currentKey })?.evidence == .voiceVerified)
        #expect(combined.assignments[currentKey]?.label == "You")
        #expect(combined.voiceProfileID == newProfileID)
    }

    @Test("successful summary freshness requires the exact rendered speech")
    func summaryFreshness() {
        var value = state()
        value.summaryIsStale = true
        value.markSummaryCurrent(for: "Different words")
        #expect(value.summaryIsStale)
        value.markSummaryCurrent(for: value.renderedTranscript())
        #expect(!value.summaryIsStale)
    }

}
