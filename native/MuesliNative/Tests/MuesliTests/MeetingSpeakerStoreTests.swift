import Foundation
import MuesliCore
import SQLite3
import Testing

@Suite("Guarded meeting speaker storage")
struct MeetingSpeakerStoreTests {
    @Test func renameRoundtripAndStaleWriter() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try store.speakerStateMeetingIDs().contains(id))
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var renamed = snapshot.state
        _ = renamed.assign(.init(name: "長い名前: Example\\Host", provenance: .manual), to: state.speakers[0].key)
        #expect(try store.updateMeetingSpeakerState(id: id, state: renamed, expected: snapshot) == .updated)
        #expect(try store.meeting(id: id)?.rawTranscript == MeetingSpeakerState.renderTranscriptTurn(
            timestamp: "00:00:01", speaker: "長い名前: Example\\Host", text: "Original words"
        ))
        #expect(try store.meetingSpeakerSnapshot(id: id)?.summaryIsStale == true)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .conflict)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state.turns == state.turns)
    }

    @Test func ownerVoiceCandidateQuerySkipsStatesWithoutAProfileID() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try store.speakerStateMeetingIDsWithOwnerVoiceEvidence().isEmpty)

        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var stateWithOwnerProfile = snapshot.state
        stateWithOwnerProfile.voiceProfileID = UUID()
        #expect(try store.updateMeetingSpeakerState(id: id, state: stateWithOwnerProfile, expected: snapshot) == .updated)
        #expect(try store.speakerStateMeetingIDsWithOwnerVoiceEvidence() == [id])
    }

    @Test func legacyColonTranscriptCanInstallAndRestoreStructuredSpeakerState() throws {
        let (store, id, original) = try fixture()
        var state = original
        _ = state.assign(.init(name: "Team: Example", provenance: .manual), to: state.speakers[0].key)
        let legacy = state.renderLegacy()
        try store.updateMeetingTranscript(id: id, rawTranscript: legacy)
        let version = try #require(try store.meetingTranscriptVersion(id: id))

        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let savedSnapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        #expect(savedSnapshot.state.matchesTranscript(legacy))

        try store.updateMeetingStatus(id: id, status: .processing)
        let retryVersion = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.restoreMeetingSpeakerState(id: id, snapshot: savedSnapshot, expected: retryVersion) == .updated)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state.matchesTranscript(legacy) == true)
    }

    @Test func changedTextEditInvalidatesAuthority() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingTranscript(id: id, rawTranscript: "Changed words")

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 1)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .invalidated)
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .conflict)
        #expect(try store.meeting(id: id)?.rawTranscript == "Changed words")
    }

    @Test func clearingMeetingsErasesSerializedSpeakerTranscript() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 1)

        try store.clearMeetings()

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func syncedMeetingTombstoneErasesDeferredSpeakerJob() throws {
        let (store, id, state) = try fixture()
        let recordName = "speaker-job-delete-fixture"
        try setCloudRecordName(recordName, meetingID: id, store: store)
        let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: state)
        try store.completeLiveMeeting(id: id, title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                                      rawTranscript: state.render(), formattedNotes: "Notes", micAudioPath: nil,
                                      systemAudioPath: nil, deferredSpeakerLabeling: pending)
        #expect(try store.meetingSpeakerLabelingJobs().count == 1)
        let updatedAt = Date().addingTimeInterval(60)
        let tombstone = SyncTextRecord(id: recordName, kind: .meeting, title: "Deleted Meeting", text: "",
                                       speakerTranscript: "", createdAt: updatedAt, updatedAt: updatedAt,
                                       startedAt: updatedAt, endedAt: updatedAt, durationSeconds: 0,
                                       wordCount: 0, isDeleted: true)
        #expect(try store.upsertSyncedTextRecord(tombstone))
        #expect(try store.meetingSpeakerLabelingJobs().isEmpty)
    }

    @Test func metadataOnlySyncPreservesSpeakerMappingButTranscriptSyncInvalidatesIt() throws {
        let (store, id, state) = try fixture()
        let recordName = "speaker-sync-fixture"
        try setCloudRecordName(recordName, meetingID: id, store: store)
        let base = Date()
        let transcript = state.render()

        func syncedRecord(title: String, transcript: String, updatedAt: Date) -> SyncTextRecord {
            SyncTextRecord(
                id: recordName,
                kind: .meeting,
                title: title,
                text: transcript,
                speakerTranscript: transcript,
                summaryText: "Notes for \(title)",
                source: "ios",
                meetingStatus: .completed,
                createdAt: base,
                updatedAt: updatedAt,
                startedAt: base,
                endedAt: base.addingTimeInterval(60),
                durationSeconds: 60,
                wordCount: 2
            )
        }

        #expect(try store.upsertSyncedTextRecord(syncedRecord(
            title: "Remote title", transcript: transcript, updatedAt: base.addingTimeInterval(60)
        )))
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let installed = try #require(try store.meetingSpeakerSnapshot(id: id))

        #expect(try store.upsertSyncedTextRecord(syncedRecord(
            title: "Updated title", transcript: transcript, updatedAt: base.addingTimeInterval(120)
        )))

        #expect(try store.meeting(id: id)?.title == "Updated title")
        #expect(try store.meeting(id: id)?.formattedNotes == "Notes for Updated title")
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state == installed.state)

        #expect(try store.upsertSyncedTextRecord(syncedRecord(
            title: "Transcript changed", transcript: "Changed transcript", updatedAt: base.addingTimeInterval(180)
        )))
    }

    @Test func sameValueExplicitTranscriptWriteInvalidatesAuthority() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        let transcript = try #require(try store.meeting(id: id)?.rawTranscript)

        // Recreate the trigger shipped by the first S3 build to exercise its upgrade path.
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        let oldTrigger = """
        DROP TRIGGER local_meeting_speaker_text_changed;
        CREATE TRIGGER local_meeting_speaker_text_changed
        AFTER UPDATE OF raw_transcript ON meetings
        BEGIN
            INSERT INTO local_meeting_transcript_versions(meeting_id, generation, summary_stale)
            VALUES (NEW.id, 1, CASE WHEN COALESCE(OLD.raw_transcript, '') != COALESCE(NEW.raw_transcript, '') THEN 1 ELSE 0 END)
            ON CONFLICT(meeting_id) DO UPDATE SET generation = generation + 1,
                summary_stale = MAX(summary_stale, excluded.summary_stale);
            UPDATE local_meeting_speaker_state SET authoritative = 0 WHERE meeting_id = NEW.id;
        END;
        """
        #expect(sqlite3_exec(db, oldTrigger, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        db = nil

        try store.migrateIfNeeded()

        try store.updateMeetingTranscript(id: id, rawTranscript: transcript)
        let invalidatedVersion = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(invalidatedVersion.generation == version.generation + 1)
        #expect(invalidatedVersion.digest == version.digest)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meetingSummaryIsStale(id: id) == snapshot.summaryIsStale)
        #expect(try store.updateMeetingSpeakerState(id: id, state: snapshot.state, expected: snapshot) == .invalidated)
    }

    @Test func sampleRangeUsesRecordingTimelineAfterUnequalPause() throws {
        let epoch = UUID()
        let mic = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "mic")
        let system = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "system")
        var state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: mic, rank: 1, fallbackLabel: "Local speaker 1"),
                       .init(key: system, rank: 2, fallbackLabel: "Speaker 1")],
            turns: [.init(speaker: mic, timestamp: "00:00:02", start: 2.5, end: 3.5, text: "Local words"),
                    .init(speaker: system, timestamp: "00:00:03", start: 3.75, end: 4.25, text: "Remote words")],
            sampleEligibilityVersion: MeetingSpeakerState.currentSampleEligibilityVersion)
        let mappings = [
            MeetingSpeakerSampleTimeMapping(channel: .microphone, sourceTime: 2, recordingTime: 3),
            MeetingSpeakerSampleTimeMapping(channel: .system, sourceTime: 3, recordingTime: 3)
        ]

        state.applySampleTimeMappings(mappings)
        #expect(state.sampleRange(for: mic) == nil)

        state.turns[1] = .init(speaker: system, timestamp: "00:00:05", start: 5, end: 5.5, text: "Later words")
        let sample = try #require(state.sampleRange(for: mic))
        #expect(sample.start == 3.5)
        #expect(sample.end == 4.5)
    }

    @Test func sqlCloudLikeEditCannotBeUndoneByStaleEpoch() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE meetings SET raw_transcript = 'User words'", nil, nil, nil) == SQLITE_OK)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .invalidated)
        #expect(try store.meeting(id: id)?.rawTranscript == "User words")
    }

    @Test func failedSummaryRegenerationDoesNotClaimCurrentNotes() throws {
        let (store, id, _) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        try store.updateMeetingTranscriptAndSummary(id: id, rawTranscript: "New speech", formattedNotes: "Retained notes",
            selectedTemplateID: "test", selectedTemplateName: "Test", selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "", expectedTranscript: before, summaryIsCurrent: false)
        #expect(try store.meetingSummaryIsStale(id: id))
    }

    @Test func meetingRecordTracksSummaryFreshness() throws {
        let (store, id, _) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))

        #expect(try store.meeting(id: id)?.summaryIsStale == false)
        try store.markMeetingSummaryStale(id: id, expected: version)
        #expect(try store.meeting(id: id)?.summaryIsStale == true)
        try store.markMeetingSummaryCurrent(id: id, expected: version)
        #expect(try store.meeting(id: id)?.summaryIsStale == false)
    }

    @Test func failedInitialSummaryCreatesFreshnessRowForNewMeeting() throws {
        let (store, id, _) = try fixture()
        let initial = try #require(try store.meetingTranscriptVersion(id: id))

        try store.setMeetingSummaryFreshness(id: id, expected: initial, isCurrent: false)

        #expect(try store.meetingSummaryIsStale(id: id))
        let current = try #require(try store.meetingTranscriptVersion(id: id))
        try store.setMeetingSummaryFreshness(id: id, expected: current, isCurrent: true)
        #expect(try !store.meetingSummaryIsStale(id: id))
    }

    @Test func processingInvalidatesPriorIdentityBeforeNewInference() throws {
        let (store, id, state) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: before) == .updated)
        try store.updateMeetingStatus(id: id, status: .processing)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meetingTranscriptVersion(id: id)?.generation != before.generation)
    }

    @Test func failedProcessingCanRestoreSpeakerHistoryWhenTranscriptIsUnchanged() throws {
        let (store, id, state) = try fixture()
        let initialVersion = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: initialVersion) == .updated)
        let initialSnapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var namedState = initialSnapshot.state
        let assigned = namedState.assign(.init(name: "Alice", provenance: .manual), to: state.speakers[0].key)
        #expect(assigned)
        #expect(try store.updateMeetingSpeakerState(id: id, state: namedState, expected: initialSnapshot) == .updated)
        let savedSnapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingStatus(id: id, status: .processing)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        try store.updateMeetingStatus(id: id, status: .completed)
        let restoredVersion = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(restoredVersion.digest == savedSnapshot.version.digest)
        #expect(restoredVersion.generation != savedSnapshot.version.generation)

        #expect(try store.restoreMeetingSpeakerState(id: id, snapshot: savedSnapshot, expected: restoredVersion) == .updated)
        let restored = try #require(try store.meetingSpeakerSnapshot(id: id))
        #expect(restored.state == savedSnapshot.state)
        #expect(restored.state.speakers[0].assignment?.name == "Alice")
        #expect(restored.summaryIsStale == savedSnapshot.summaryIsStale)
    }

    @Test func failedProcessingCannotRestoreSpeakerHistoryAfterTranscriptChanges() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let savedSnapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingStatus(id: id, status: .processing)
        try store.updateMeetingTranscript(id: id, rawTranscript: "Changed by another edit")
        try store.updateMeetingStatus(id: id, status: .completed)
        let currentVersion = try #require(try store.meetingTranscriptVersion(id: id))

        #expect(try store.restoreMeetingSpeakerState(id: id, snapshot: savedSnapshot, expected: currentVersion) == .invalidated)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meeting(id: id)?.rawTranscript == "Changed by another edit")
    }

    @Test func failedRetranscriptionDoesNotRestoreRevokedVoiceEvidence() throws {
        let (store, id, initial) = try fixture()
        let profileID = UUID()
        let ownerKey = MeetingSpeakerKey(epoch: initial.epoch, channel: .microphone, clusterID: "owner")
        var state = MeetingSpeakerState(epoch: initial.epoch,
            speakers: [.init(key: ownerKey, rank: 1, fallbackLabel: "Microphone")],
            turns: [.init(speaker: ownerKey, timestamp: "00:00:01", start: 1, end: 2, text: "Original words")])
        state.speakers[0].isSelf = true
        state.speakers[0].selfProvenance = .voice
        state.speakers[0].assignment = .init(name: "Example", provenance: .voice)
        state.voiceProfileID = profileID
        try store.updateMeetingTranscript(id: id, rawTranscript: state.render())
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingStatus(id: id, status: .processing)
        let retryVersion = try #require(try store.meetingTranscriptVersion(id: id))

        #expect(try store.restoreMeetingSpeakerStateIfTranscriptUnchanged(
            id: id, snapshot: snapshot, permittedVoiceProfileID: nil))
        #expect(try store.restoreMeetingSpeakerState(
            id: id,
            snapshot: snapshot,
            expected: retryVersion
        ) == .conflict)
        let restored = try #require(try store.meetingSpeakerSnapshot(id: id))
        #expect(restored.state.voiceProfileID == nil)
        #expect(restored.state.speakers[0].selfProvenance == nil)
        #expect(restored.state.speakers[0].assignment == nil)
        #expect(!restored.state.speakers[0].isSelf)
        #expect(try store.meeting(id: id)?.rawTranscript == "[00:00:01] Microphone: Original words")
        #expect(restored.summaryIsStale)
    }

    @Test func failedRetranscriptionRestoresLegacySpeakerStateWithColonName() throws {
        let (store, id, initial) = try fixture()
        let speakerKey = MeetingSpeakerKey(epoch: initial.epoch, channel: .system, clusterID: "speaker")
        let state = MeetingSpeakerState(epoch: initial.epoch,
            speakers: [.init(key: speakerKey, rank: 1, fallbackLabel: "Speaker 1",
                             assignment: .init(name: "Team: Room", provenance: .manual))],
            turns: [.init(speaker: speakerKey, timestamp: "00:00:01", start: 1, end: 2, text: "Original words")])
        let legacyTranscript = state.renderLegacy()
        try store.updateMeetingTranscript(id: id, rawTranscript: legacyTranscript)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingStatus(id: id, status: .processing)

        #expect(try store.restoreMeetingSpeakerStateIfTranscriptUnchanged(id: id, snapshot: snapshot))
        let restored = try #require(try store.meetingSpeakerSnapshot(id: id))
        #expect(restored.state == state)
        #expect(try store.meeting(id: id)?.rawTranscript == legacyTranscript)
    }

    @Test func profileRevocationScrubsVoiceEvidenceAfterConcurrentSpeakerCorrection() throws {
        let (store, id, initial) = try fixture()
        let ownerKey = MeetingSpeakerKey(epoch: initial.epoch, channel: .microphone, clusterID: "owner")
        let guestKey = MeetingSpeakerKey(epoch: initial.epoch, channel: .microphone, clusterID: "guest")
        let profileID = UUID()
        var state = MeetingSpeakerState(epoch: initial.epoch,
            speakers: [.init(key: ownerKey, rank: 1, fallbackLabel: "Microphone"),
                       .init(key: guestKey, rank: 2, fallbackLabel: "Microphone")],
            turns: [.init(speaker: ownerKey, timestamp: "00:00:01", start: 1, end: 2, text: "Owner words"),
                    .init(speaker: guestKey, timestamp: "00:00:03", start: 3, end: 4, text: "Guest words")])
        state.speakers[0].isSelf = true
        state.speakers[0].selfProvenance = .voice
        state.speakers[0].assignment = .init(name: "Owner", provenance: .voice)
        state.voiceProfileID = profileID
        try store.updateMeetingTranscript(id: id, rawTranscript: state.render())
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let staleSweepSnapshot = try #require(try store.meetingSpeakerSnapshot(id: id))

        var corrected = staleSweepSnapshot.state
        let guestAssignmentChanged = corrected.assign(.init(name: "Guest", provenance: .manual), to: guestKey)
        #expect(guestAssignmentChanged)
        #expect(try store.updateMeetingSpeakerState(id: id, state: corrected, expected: staleSweepSnapshot) == .updated)

        var staleCleanup = staleSweepSnapshot.state
        staleCleanup.removeSelfEvidence()
        #expect(try store.updateMeetingSpeakerState(id: id, state: staleCleanup, expected: staleSweepSnapshot) == .conflict)
        #expect(try store.revokeMeetingSpeakerSelfEvidence(id: id, permittedVoiceProfileID: nil))

        let cleaned = try #require(try store.meetingSpeakerSnapshot(id: id))
        #expect(cleaned.state.voiceProfileID == nil)
        #expect(cleaned.state.speakers.first { $0.key == ownerKey }?.selfProvenance == nil)
        #expect(cleaned.state.speakers.first { $0.key == ownerKey }?.assignment == nil)
        #expect(cleaned.state.speakers.first { $0.key == ownerKey }?.isSelf == false)
        #expect(cleaned.state.speakers.first { $0.key == guestKey }?.assignment == .init(name: "Guest", provenance: .manual))
        #expect(try store.meeting(id: id)?.rawTranscript == cleaned.state.render())
    }

    @Test func failedRetranscriptionDoesNotRestoreMappingAfterTranscriptChange() throws {
        let (store, id, state) = try fixture()
        let initialVersion = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: initialVersion) == .updated)
        let prior = try #require(try store.meetingSpeakerSnapshot(id: id))

        try store.updateMeetingStatus(id: id, status: .processing)
        let retryVersion = try #require(try store.meetingTranscriptVersion(id: id))
        try store.updateMeetingStatus(id: id, status: .completed)
        try store.updateMeetingTranscript(id: id, rawTranscript: "Replacement transcript")

        #expect(!(try store.restoreMeetingSpeakerStateIfTranscriptUnchanged(id: id, snapshot: prior)))
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
    }

    @Test func deletingMeetingScrubsLocalSpeakerState() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 1)

        try store.deleteMeeting(id: id)

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func clearingMeetingsScrubsLocalSpeakerState() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        try store.clearMeetings()

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func syncedMeetingDeletionScrubsLocalSpeakerState() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let synced = try #require(try store.textRecordsNeedingSync().first { $0.kind == .meeting })
        let deletionTime = synced.updatedAt.addingTimeInterval(60)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: synced.id,
            kind: .meeting,
            text: "",
            createdAt: synced.createdAt,
            updatedAt: deletionTime,
            durationSeconds: 0,
            wordCount: 0,
            isDeleted: true
        )))

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func migrationScrubsSpeakerStateFromEarlierSoftDeletedMeetings() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 1)

        do {
            var db: OpaquePointer?
            guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else {
                throw NSError(domain: "MeetingSpeakerStoreTests", code: 4)
            }
            defer { sqlite3_close(db) }
            let sql = "DROP TRIGGER local_meeting_speaker_deleted; UPDATE meetings SET raw_transcript = '', deleted_at = 1 WHERE id = \(id)"
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }

        try store.migrateIfNeeded()

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func onlyMatchingSummaryGenerationCanClearStaleness() throws {
        let (store, id, state) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        try store.updateMeetingTranscript(id: id, rawTranscript: "New speech")
        try store.markMeetingSummaryCurrent(id: id, expected: before)
        #expect(try store.meetingSummaryIsStale(id: id))
        let current = try #require(try store.meetingTranscriptVersion(id: id))
        try store.markMeetingSummaryCurrent(id: id, expected: current)
        #expect(try !store.meetingSummaryIsStale(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: current) == .invalidated)
    }

    @Test func legacyAndResumeStayUnavailable() throws {
        let (store, id, state) = try fixture()
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        _ = try store.prepareMeetingForResume(id: id)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
    }

    @Test func deletingMeetingRemovesPersistedSpeakerJSON() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        try store.deleteMeeting(id: id)

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func clearingMeetingsRemovesPersistedSpeakerJSON() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        try store.clearMeetings()

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func syncedMeetingTombstoneRemovesPersistedSpeakerJSON() throws {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("synced-speakers-\(UUID()).db"))
        try store.migrateIfNeeded()
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "remote")
        let state = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
                                       turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Synced words")])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recordName = "meeting-speaker-state-delete"
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting, title: "Synced fixture", text: state.render(),
            speakerTranscript: state.render(), summaryText: "Summary", source: "mac", localSource: "meeting",
            meetingStatus: .completed, createdAt: createdAt, updatedAt: createdAt,
            startedAt: createdAt, endedAt: createdAt.addingTimeInterval(2), durationSeconds: 2, wordCount: 2
        )))
        let id = try #require(try store.recentMeetings(limit: 10).first(where: { $0.title == "Synced fixture" })?.id)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting, title: "Deleted Meeting", text: "", speakerTranscript: "",
            source: "mac", localSource: "meeting", meetingStatus: .completed,
            createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(1),
            startedAt: createdAt, endedAt: createdAt.addingTimeInterval(2), durationSeconds: 0,
            wordCount: 0, isDeleted: true
        )))

        #expect(try rawSpeakerStateCount(meetingID: id, store: store) == 0)
    }

    @Test func titleOnlySyncUpdatePreservesSpeakerState() throws {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("synced-speakers-title-\(UUID()).db"))
        try store.migrateIfNeeded()
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "remote")
        let state = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
                                       turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Synced words")])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recordName = "meeting-speaker-title-update"
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting, title: "Original title", text: state.render(),
            speakerTranscript: state.render(), summaryText: "Current summary", summaryIsCurrent: true,
            source: "mac", localSource: "meeting", meetingStatus: .completed,
            createdAt: createdAt, updatedAt: createdAt, startedAt: createdAt,
            endedAt: createdAt.addingTimeInterval(2), durationSeconds: 2, wordCount: 2
        )))
        let id = try #require(try store.recentMeetings(limit: 10).first(where: { $0.title == "Original title" })?.id)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting, title: "Renamed title", text: state.render(),
            speakerTranscript: state.render(), summaryText: "Current summary", summaryIsCurrent: true,
            source: "mac", localSource: "meeting", meetingStatus: .completed,
            createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(1),
            startedAt: createdAt, endedAt: createdAt.addingTimeInterval(2), durationSeconds: 2, wordCount: 2
        )))

        #expect(try store.meetingSpeakerSnapshot(id: id)?.state == state)
        #expect(try !store.meetingSummaryIsStale(id: id))
    }

    @Test func freshSyncedSummaryClearsStalenessForIncomingTranscript() throws {
        let (store, id, _) = try fixture()
        try store.updateMeetingTranscript(id: id, rawTranscript: "Incoming transcript")
        #expect(try store.meetingSummaryIsStale(id: id))

        let recordName = try #require(try store.textRecordsNeedingSync().first?.id)
        let createdAt = Date()
        let updatedAt = createdAt.addingTimeInterval(60)
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: recordName, kind: .meeting,
            title: "Fixture", text: "Incoming transcript", summaryText: "Fresh summary",
            summaryIsCurrent: true, source: "mac", localSource: "meeting",
            meetingStatus: .completed, createdAt: createdAt,
            updatedAt: updatedAt, startedAt: createdAt,
            endedAt: createdAt.addingTimeInterval(2), durationSeconds: 2, wordCount: 2
        )))

        #expect(try !store.meetingSummaryIsStale(id: id))
    }

    @Test func syncSnapshotExportsSummaryFreshnessForItsTranscript() throws {
        let (store, id, _) = try fixture()
        let recordName = try #require(try store.textRecordsNeedingSync().first?.id)

        try store.updateMeetingTranscript(id: id, rawTranscript: "Edited transcript")
        let stale = try #require(try store.textRecordsNeedingSync().first { $0.id == recordName })
        #expect(stale.summaryIsCurrent == false)

        let version = try #require(try store.meetingTranscriptVersion(id: id))
        try store.markMeetingSummaryCurrent(id: id, expected: version)
        let current = try #require(try store.textRecordsNeedingSync().first { $0.id == recordName })
        #expect(current.summaryIsCurrent == true)
    }

    @Test func legacySyncWithChangedSummaryKeepsStaleness() throws {
        let (store, id, _) = try fixture()
        try store.updateMeetingTranscript(id: id, rawTranscript: "Edited transcript")
        #expect(try store.meetingSummaryIsStale(id: id))

        var incoming = try #require(try store.textRecordsNeedingSync().first)
        incoming.summaryText = "Regenerated summary"
        incoming.summaryIsCurrent = nil
        incoming.updatedAt = Date().addingTimeInterval(60)
        #expect(try store.upsertSyncedTextRecord(incoming))

        #expect(try store.meetingSummaryIsStale(id: id))
    }

    private func fixture() throws -> (DictationStore, Int64, MeetingSpeakerState) {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("speakers-\(UUID()).db"))
        try store.migrateIfNeeded()
        let epoch = UUID()
        let actual = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "a")
        let state = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: actual, rank: 1, fallbackLabel: "Speaker 1")],
                                       turns: [.init(speaker: actual, timestamp: "00:00:01", start: 1, end: 2, text: "Original words")])
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                                        rawTranscript: state.render(), formattedNotes: "Summary", micAudioPath: nil, systemAudioPath: nil)
        return (store, id, state)
    }

    private func setCloudRecordName(_ recordName: String, meetingID: Int64, store: DictationStore) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.resolvedDatabaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 4)
        }
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET cloud_record_name = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 5)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (recordName as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, meetingID)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 6)
        }
    }

    private func rawSpeakerStateCount(meetingID: Int64, store: DictationStore) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.resolvedDatabaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT COUNT(*) FROM local_meeting_speaker_state WHERE meeting_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "MeetingSpeakerStoreTests", code: 3)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

extension MeetingSpeakerStoreTests {
    @Test func correctionUsesTheSnapshotThatProducedIt() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let captured = try #require(try store.meetingSpeakerSnapshot(id: id))
        var first = captured.state, stale = captured.state
        let firstRename = first.correct(.rename(state.speakers[0].key, "First"))
        #expect(firstRename)
        let staleRename = stale.correct(.rename(state.speakers[0].key, "Stale"))
        #expect(staleRename)
        #expect(try store.updateMeetingSpeakerState(id: id, state: first, expected: captured) == .updated)
        #expect(try store.updateMeetingSpeakerState(id: id, state: stale, expected: captured) == .conflict)
        let current = try #require(try store.meetingSpeakerSnapshot(id: id))
        var undone = current.state
        let didUndo = undone.correct(.undo)
        #expect(didUndo)
        #expect(try store.updateMeetingSpeakerState(id: id, state: undone, expected: current) == .updated)
        #expect(try store.meeting(id: id)?.rawTranscript == "[00:00:01] Speaker 1: Original words")
    }
}
