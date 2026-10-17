import Foundation
import MuesliCore
import SQLite3
import Testing
@testable import MuesliNativeApp

@Suite("Deferred meeting speaker labels")
struct MeetingDeferredSpeakerTests {
    @Test func deferredSpeakerStartsStayQueuedUntilAudioIsIdle() {
        var queue = MeetingSpeakerLabelingStartQueue()
        queue.enqueue(meetingID: 41, retry: false)

        #expect(queue.takeReady(captureIsActive: true, interactiveAudioIsActive: false).isEmpty)
        #expect(queue.hasPending)
        #expect(queue.takeReady(captureIsActive: false, interactiveAudioIsActive: true).isEmpty)
        #expect(queue.hasPending)

        let ready = queue.takeReady(captureIsActive: false, interactiveAudioIsActive: false)
        #expect(ready.map(\.meetingID) == [41])
        #expect(ready.first?.retry == false)
        #expect(!queue.hasPending)
    }

    @Test func deferredSpeakerStartQueuePreservesAnExplicitRetry() {
        var queue = MeetingSpeakerLabelingStartQueue()
        queue.enqueue(meetingID: 41, retry: false)
        queue.enqueue(meetingID: 41, retry: true)

        let ready = queue.takeReady(captureIsActive: false, interactiveAudioIsActive: false)
        #expect(ready.count == 1)
        #expect(ready.first?.retry == true)
    }

    @Test func deferredSpeakerJobsRunOneAtATimeAcrossMeetings() {
        var queue = MeetingSpeakerLabelingStartQueue()
        queue.enqueue(meetingID: 41, retry: false)
        queue.enqueue(meetingID: 42, retry: false)

        let first = queue.takeReady(captureIsActive: false, interactiveAudioIsActive: false)
        #expect(first.map(\.meetingID) == [41])
        #expect(queue.hasPending)

        #expect(queue.takeReady(captureIsActive: false, interactiveAudioIsActive: false,
                                activeMeetingIDs: [41]).isEmpty)
        #expect(queue.hasPending)

        let second = queue.takeReady(captureIsActive: false, interactiveAudioIsActive: false)
        #expect(second.map(\.meetingID) == [42])
        #expect(!queue.hasPending)
    }

    @Test func replacementSpeakerJobWaitsForTheActiveMeetingTaskToFinish() {
        var queue = MeetingSpeakerLabelingStartQueue()
        queue.enqueue(meetingID: 41, retry: false)
        let first = queue.takeReady(captureIsActive: false, interactiveAudioIsActive: false)
        #expect(first.map(\.meetingID) == [41])

        // A new persisted job for this meeting arrives while its prior job owns the task slot.
        queue.enqueue(meetingID: 41, retry: false)
        #expect(queue.takeReady(captureIsActive: false, interactiveAudioIsActive: false,
                                activeMeetingIDs: [41]).isEmpty)
        #expect(queue.hasPending)

        let replacement = queue.takeReady(captureIsActive: false, interactiveAudioIsActive: false)
        #expect(replacement.map(\.meetingID) == [41])
    }

    @Test func replacementSpeakerJobsAreRescheduledAfterTheActiveTaskReleasesItsSlot() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp/MuesliController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let release = try #require(source.range(of: "self.deferredSpeakerTasks[job.meetingID] = nil"))
        let completion = source[release.upperBound...]
        #expect(completion.range(of: "self.startQueuedDeferredSpeakerLabelingIfIdle()") != nil)
    }

    @Test func deferredSpeakerJobsWaitForEveryRunningLabelingTask() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp/MuesliController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "private func startDeferredSpeakerLabeling("))
        let body = source[start.upperBound...]
        let serializationGuard = try #require(body.range(of: "guard deferredSpeakerTasks.isEmpty else"))
        let taskStart = try #require(body.range(of: "deferredSpeakerTasks[job.meetingID] = Task"))

        #expect(serializationGuard.lowerBound < taskStart.lowerBound)
    }

    @Test func unavailableDiarizerDoesNotStageDuplicateBacklogAudio() {
        #expect(!MeetingSpeakerLabelingPolicy.shouldStage(diarizerAvailable: false, sourceCount: 2))
        #expect(MeetingSpeakerLabelingPolicy.shouldStage(diarizerAvailable: true, sourceCount: 2))
        #expect(!MeetingSpeakerLabelingPolicy.shouldStage(diarizerAvailable: true, sourceCount: 0))
    }

    @Test func relabelKeepsBoundariesUnicodeAndPrefix() {
        let source = fixture(), audio = MeetingSpeakerBacklogDescriptor(channels: [.system])
        let pending = MeetingSpeakerPendingLabeling(audio: audio, state: source)
        let full = "Earlier words\n\n" + source.render()
        let prepared = pending.prepared(for: full)!
        let relabeled = prepared.state.relabeling(channels: [.system: [.init(clusterID: "a", start: 0, end: 1), .init(clusterID: "b", start: 1, end: 2)]])
        #expect(relabeled.epoch != source.epoch)
        #expect(relabeled.turns.map(\.id) == source.turns.map(\.id))
        #expect(relabeled.turns.map(\.text) == source.turns.map(\.text))
        #expect(relabeled.turns.map(\.timestamp) == source.turns.map(\.timestamp))
        #expect(relabeled.turns[0].speaker != relabeled.turns[1].speaker)
        #expect(relabeled.render().hasPrefix("Earlier words\n\n"))
        #expect(TranscriptChatMessage.messages(from: relabeled.render(), speakerState: relabeled).contains { $0.text.contains("Earlier words") })
        #expect(pending.prepared(for: "edited") == nil)
    }
    @Test func deferredRelabelHidesSamplesOverlappingOtherChannelSpeech() throws {
        let source = microphoneFixture()
        let relabeled = source.relabeling(channels: [
            .microphone: [.init(clusterID: "local", start: 0, end: 1)],
            .system: [.init(clusterID: "remote", start: 0.5, end: 0.75)]
        ], sampleTimeMappings: [])
        let speaker = try #require(relabeled.activeSpeakers.first)

        #expect(relabeled.sampleRange(for: speaker.key) == nil)
    }
    @Test func deferredRelabelKeepsSafeSamplesAvailable() throws {
        let relabeled = microphoneFixture().relabeling(channels: [
            .microphone: [.init(clusterID: "local", start: 0, end: 1)]
        ], sampleTimeMappings: [])
        let speaker = try #require(relabeled.activeSpeakers.first)

        let sample = try #require(relabeled.sampleRange(for: speaker.key))
        #expect(sample.start == 0)
        #expect(sample.end == 1)
    }
    @Test func deferredRelabelDoesNotReenableOtherIneligibleSamples() throws {
        var source = microphoneFixture()
        source.turns[0].sampleEligible = false
        let relabeled = source.relabeling(channels: [
            .microphone: [.init(clusterID: "local", start: 0, end: 1)]
        ], sampleTimeMappings: [])
        let speaker = try #require(relabeled.activeSpeakers.first)

        #expect(relabeled.turns[0].sampleEligible == false)
        #expect(relabeled.sampleRange(for: speaker.key) == nil)
    }
    @Test func deferredRelabelKeepsSamplesBlockedAcrossInternalPause() throws {
        var source = microphoneFixture()
        source.turns[0].sampleEligible = false
        source.turns[0].sampleIdentityPending = true
        let mappings = [MeetingSpeakerSampleTimeMapping(channel: .microphone, sourceTime: 0.5, recordingTime: 0.75)]
        let pending = MeetingSpeakerPendingLabeling(
            audio: .init(channels: [.microphone]), state: source, sampleTimeMappings: mappings)
        let restored = try JSONDecoder().decode(MeetingSpeakerPendingLabeling.self, from: JSONEncoder().encode(pending))
        #expect(restored.state.turns[0].sampleIdentityPending == true)
        source = restored.state
        source.applySampleTimeMappings(mappings)
        #expect(source.turns[0].sampleEligible == false)
        #expect(source.turns[0].sampleIdentityPending != true)

        let relabeled = source.relabeling(channels: [
            .microphone: [.init(clusterID: "local", start: 0, end: 1)]
        ], sampleTimeMappings: mappings)
        let speaker = try #require(relabeled.activeSpeakers.first)

        #expect(relabeled.turns[0].sampleEligible == false)
        #expect(relabeled.sampleRange(for: speaker.key) == nil)
    }
    @Test func deferredJoinedSampleCannotSpanUntranscribedOtherSpeaker() throws {
        let epoch = UUID()
        let sourceKey = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "source")
        let source = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: sourceKey, rank: 1, fallbackLabel: "Speaker 1")],
            turns: [
                .init(speaker: sourceKey, timestamp: "00:00:00", start: 0, end: 1, text: "First words"),
                .init(speaker: sourceKey, timestamp: "00:00:01", start: 1.2, end: 2, text: "Second words"),
            ])
        let relabeled = source.relabeling(channels: [
            .system: [
                .init(clusterID: "speaker-a", start: 0, end: 1),
                .init(clusterID: "speaker-b", start: 1, end: 1.2),
                .init(clusterID: "speaker-a", start: 1.2, end: 2),
            ]
        ], sampleTimeMappings: [])
        let speaker = try #require(relabeled.activeSpeakers.first)

        #expect(relabeled.turns.count == 1)
        #expect(relabeled.turns[0].sampleEligible == false)
        #expect(relabeled.sampleRange(for: speaker.key) == nil)
    }
    @Test func deferredRelabelMapsOtherChannelSpeechAcrossPauseForSampleSafety() throws {
        let mappings = [
            MeetingSpeakerSampleTimeMapping(channel: .microphone, sourceTime: 3, recordingTime: 3),
            MeetingSpeakerSampleTimeMapping(channel: .system, sourceTime: 1, recordingTime: 3)
        ]
        let epoch = UUID(), microphone = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "source")
        var source = MeetingSpeakerState(
            epoch: epoch,
            speakers: [.init(key: microphone, rank: 1, fallbackLabel: "Microphone")],
            turns: [.init(speaker: microphone, timestamp: "00:00:03", start: 3, end: 4, text: "Spoken words")]
        )
        source.applySampleTimeMappings(mappings)
        let pending = MeetingSpeakerPendingLabeling(
            audio: .init(channels: [.microphone, .system]),
            state: source,
            sampleTimeMappings: mappings
        )
        let restoredPending = try JSONDecoder().decode(
            MeetingSpeakerPendingLabeling.self,
            from: JSONEncoder().encode(pending)
        )
        #expect(restoredPending.sampleTimeMappings == mappings)
        let relabeled = restoredPending.state.relabeling(channels: [
            .microphone: [.init(clusterID: "local", start: 3, end: 4)],
            .system: [.init(clusterID: "remote", start: 1, end: 2)]
        ], sampleTimeMappings: restoredPending.sampleTimeMappings)
        let speaker = try #require(relabeled.activeSpeakers.first)

        #expect(relabeled.sampleRange(for: speaker.key) == nil)
    }
    @Test func relabelCoalescesCompatibleSameSpeakerTurnsWithoutDroppingSpeech() {
        let source = fixture()
        let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source)
        let relabeled = source.relabeling(channels: [.system: [.init(clusterID: "one", start: 0, end: 2)]])
        #expect(relabeled.turns.count == 1)
        #expect(relabeled.turns[0].id == source.turns[0].id)
        #expect(relabeled.turns[0].start == source.turns[0].start)
        #expect(relabeled.turns[0].end == source.turns[1].end)
        #expect(relabeled.turns[0].text == "First 🌿 words Second words")
        #expect(relabeled.preservesSpeech(of: pending.state))

        var dropped = relabeled
        dropped.turns[0].text = "First 🌿 words"
        #expect(!dropped.preservesSpeech(of: pending.state))
    }
    @Test func pendingOwnerAuthorizationIsBoundToItsLocalProfile() throws {
        let profileID = UUID()
        let pending = MeetingSpeakerPendingLabeling(
            audio: .init(channels: [.microphone]),
            state: microphoneFixture(),
            ownerProfileID: profileID
        )
        let decoded = try JSONDecoder().decode(MeetingSpeakerPendingLabeling.self, from: JSONEncoder().encode(pending))
        #expect(decoded.ownerProfileID == profileID)
        #expect(decoded.allowsOwnerProfile(profileID))
        #expect(!decoded.allowsOwnerProfile(UUID()))
        #expect(!decoded.allowsOwnerProfile(nil))

        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MeetingSpeakerPendingLabeling(audio: pending.audio, state: pending.state))) as! [String: Any]
        var legacyWithoutOwnerID = legacy
        legacyWithoutOwnerID.removeValue(forKey: "ownerProfileID")
        let decodedLegacy = try JSONDecoder().decode(MeetingSpeakerPendingLabeling.self, from: JSONSerialization.data(withJSONObject: legacyWithoutOwnerID))
        #expect(decodedLegacy.ownerProfileID == nil)
    }
    @Test func staleSessionAuthorizationCannotAuthorizeADeferredRetry() {
        let profileID = UUID(), token = UUID()
        let pending = MeetingSpeakerPendingLabeling(
            audio: .init(channels: [.microphone]),
            state: microphoneFixture(),
            ownerProfileID: profileID
        )
        let result = MeetingSessionResult(
            title: "Meeting", originalTitle: "Meeting", calendarEventID: nil,
            startTime: Date(), endTime: Date(), durationSeconds: 1,
            rawTranscript: pending.state.render(), formattedNotes: "Notes",
            retainedRecordingURL: nil, retainedRecordingError: nil, systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot,
            pendingSpeakerLabeling: pending,
            ownerRecognitionAuthorization: token
        )
        let revoked = result.validatingOwnerAuthorization(nil)
        #expect(revoked.pendingSpeakerLabeling?.ownerProfileID == nil)
        #expect(revoked.ownerRecognitionAuthorization == nil)
    }
    @Test func deferredRelabelAppliesOnlyProvidedOwnerEvidenceToFreshState() {
        let source = microphoneFixture(), profileID = UUID()
        let channels: [MeetingSpeakerKey.Channel: [MeetingLiveSpeakerSegment]] = [
            .microphone: [.init(clusterID: "owner", start: 0, end: 1)]
        ]
        let named = source.relabeling(
            channels: channels,
            ownerCluster: "owner",
            ownerName: "Enrolled owner",
            ownerProfileID: profileID
        )
        #expect(named.labels[named.turns[0].speaker] == "Enrolled owner (You)")
        #expect(named.voiceProfileID == profileID)
        let generic = source.relabeling(channels: channels)
        #expect(generic.labels[generic.turns[0].speaker] != "Enrolled owner (You)")
        #expect(generic.voiceProfileID == nil)
    }
    @Test func deferredAccessibilityEvidenceSurvivesRetryOnlyForItsAuthorization() throws {
        let epoch = UUID(), sourceKey = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "source")
        let source = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: sourceKey, rank: 1, fallbackLabel: "Speaker 1")],
                                         turns: [.init(speaker: sourceKey, timestamp: "00:00:00", start: 0, end: 2, text: "Spoken words")])
        let person = MeetingSpeakerParticipant(id: "scope/tile", name: "Guest", isSelf: false)
        let inactive = MeetingSpeakerParticipant(id: "scope/other", name: "Other guest", isSelf: false)
        let frame = MeetingSpeakerFrame(scope: "scope", app: .zoom, participants: [person, inactive], activeID: person.id, reason: .clear)
        let timeline = MeetingSpeakerTimeline(observations: (0...4).map {
            .init(time: Double($0) * 0.5, continuity: "one", frame: frame)
        })
        let authorization = UUID()
        let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source,
                                                    accessibilityTimeline: timeline, accessibilityAuthorizationID: authorization)
        let decoded = try JSONDecoder().decode(MeetingSpeakerPendingLabeling.self, from: JSONEncoder().encode(pending))
        #expect(decoded.accessibilityTimeline?.observations.first?.frame.participants == [person])
        let relabeled = decoded.state.relabeling(channels: [.system: [.init(clusterID: "cluster", start: 0, end: 2)]])
        var restored = relabeled
        let activities = restored.turns.map { MeetingSpeakerActivity(key: $0.speaker, start: $0.start, end: $0.end) }
        decoded.accessibilityTimeline?.apply(activities: activities, to: &restored)
        #expect(restored.speakers.first(where: { $0.key == restored.turns[0].speaker })?.assignment ==
                .init(name: "Guest", provenance: .accessibility))
        #expect(decoded.validatingAccessibilityAuthorization(authorization).accessibilityTimeline != nil)
        let revoked = decoded.validatingAccessibilityAuthorization(nil)
        #expect(revoked.accessibilityTimeline == nil)
        #expect(revoked.accessibilityAuthorizationID == nil)
    }
    @Test func durableJobPublishesOnlyAgainstExactSavedGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let source = fixture(), original = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source)
        let full = "Earlier session\n\n" + source.render()
        let pending = try #require(original.prepared(for: full))
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: full, formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil, deferredSpeakerLabeling: pending)
        let job = try #require(try store.meetingSpeakerLabelingJobs().first)
        #expect(job.meetingID == id)
        let new = pending.state.relabeling(channels: [.system: [.init(clusterID: "a", start: 0, end: 2)]])
        #expect(try store.completeMeetingSpeakerLabeling(job: job, state: new) == .updated)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state.epoch == new.epoch)
        #expect(try store.meetingSummaryIsStale(id: id))
        #expect(try store.meetingSpeakerLabelingJobs().isEmpty)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var corrected = snapshot.state
        let didRename = corrected.correct(.rename(corrected.turns[0].speaker, "Manual"))
        #expect(didRename)
        #expect(try store.updateMeetingSpeakerState(id: id, state: corrected, expected: snapshot) == .updated)
        #expect(try store.meeting(id: id)?.rawTranscript.hasPrefix("Earlier session\n\n") == true)
        let second = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: source.render(), formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil, deferredSpeakerLabeling: original)
        let stale = try #require(try store.meetingSpeakerLabelingJobs().first)
        try store.updateMeetingTranscript(id: second, rawTranscript: source.render()) // same-value writes invalidate too
        #expect(try store.meetingSpeakerLabelingJobs().first?.status == .superseded)
        #expect(try store.completeMeetingSpeakerLabeling(job: stale, state: new) == .invalidated)
        #expect(try store.meeting(id: second)?.rawTranscript == source.render())
    }

    @Test func deferredLabelsDoNotStaleAnUnchangedTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "original")
        let source = MeetingSpeakerState(
            epoch: epoch,
            speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
            turns: [.init(speaker: key, timestamp: "00:00:01", start: 0, end: 1, text: "One phrase")]
        )
        let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source)
        let id = try store.insertMeeting(
            title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: source.render(), formattedNotes: "Current summary", micAudioPath: nil, systemAudioPath: nil,
            deferredSpeakerLabeling: pending
        )
        let job = try #require(try store.meetingSpeakerLabelingJobs().first)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        try store.markMeetingSummaryCurrent(id: id, expected: version)
        let labeled = source.relabeling(channels: [:])
        #expect(labeled.epoch != source.epoch)
        #expect(labeled.render() == source.render())

        #expect(try store.completeMeetingSpeakerLabeling(job: job, state: labeled) == .updated)
        #expect(try store.meetingSummaryIsStale(id: id) == false)
    }

    @Test func ownerEvidenceRevocationRetriesAfterConcurrentManualCorrection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let profileID = UUID(), key = MeetingSpeakerKey(epoch: UUID(), channel: .microphone, clusterID: "owner")
        var source = MeetingSpeakerState(epoch: key.epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
                                         turns: [.init(speaker: key, timestamp: "00:00:00", start: 0, end: 1, text: "Words")])
        source.applySelfEvidence(accessibility: [], voice: [key], ownerName: "Enrolled owner", profileID: profileID)
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                                         rawTranscript: source.render(), formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: source, expected: version) == .updated)
        let stale = try #require(try store.meetingSpeakerSnapshot(id: id))
        var manual = stale.state
        let didCorrect = manual.correct(.rename(key, "Manual correction"))
        #expect(didCorrect)
        #expect(try store.updateMeetingSpeakerState(id: id, state: manual, expected: stale) == .updated)

        #expect(try store.removeRevokedOwnerEvidence(id: id, currentProfileID: nil) == .updated)
        let final = try #require(try store.meetingSpeakerSnapshot(id: id)).state
        #expect(final.voiceProfileID == nil)
        #expect(final.speakers.first?.isSelf == false)
        #expect(final.speakers.first?.assignment == .init(name: "Manual correction", provenance: .manual))
    }

    @Test func deletingOrClearingMeetingsRemovesDeferredTranscriptJobs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let state = fixture()
        let first = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                                           rawTranscript: state.render(), formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil,
                                           deferredSpeakerLabeling: MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: state))
        let second = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                                            rawTranscript: state.render(), formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil,
                                            deferredSpeakerLabeling: MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: state))
        #expect(try store.meetingSpeakerLabelingJobs().count == 2)
        try store.deleteMeeting(id: first)
        #expect(try store.meetingSpeakerLabelingJobs().map(\.meetingID) == [second])
        try store.clearMeetings()
        #expect(try store.meetingSpeakerLabelingJobs().isEmpty)
    }

    @Test func expiredFailedSupersededAndStalePendingJobsScrubTranscriptPayloadsButKeepRecentWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let now = Date(timeIntervalSince1970: 2_000_000_000), old = now.addingTimeInterval(-31 * 24 * 60 * 60)
        func makeJob(_ text: String) throws -> (Int64, UUID) {
            let key = MeetingSpeakerKey(epoch: UUID(), channel: .system, clusterID: "source")
            let state = MeetingSpeakerState(epoch: key.epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
                                            turns: [.init(speaker: key, timestamp: "00:00:00", start: 0, end: 1, text: text)])
            let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: state)
            let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: now, endTime: now,
                                             rawTranscript: state.render(), formattedNotes: "Notes", micAudioPath: nil,
                                             systemAudioPath: nil, deferredSpeakerLabeling: pending)
            return (id, pending.audio.id)
        }
        let (failedID, failedJob) = try makeJob("Expired speech payload")
        let (recentID, recentJob) = try makeJob("Recent speech payload")
        let (runningID, runningJob) = try makeJob("Active speech payload")
        let (supersededID, supersededJob) = try makeJob("Superseded speech payload")
        let (pendingID, pendingJob) = try makeJob("Expired pending speech payload")
        let (recentPendingID, recentPendingJob) = try makeJob("Recent pending speech payload")
        _ = [failedID, recentID, runningID, supersededID, pendingID, recentPendingID]
        try store.setMeetingSpeakerLabelingStatus(id: failedJob, status: .failed, at: old)
        try store.setMeetingSpeakerLabelingStatus(id: recentJob, status: .failed, at: now.addingTimeInterval(-60))
        try store.setMeetingSpeakerLabelingStatus(id: runningJob, status: .running, at: old)
        try store.setMeetingSpeakerLabelingStatus(id: supersededJob, status: .superseded, at: old)
        try store.setMeetingSpeakerLabelingStatus(id: pendingJob, status: .pending, at: old)
        try store.setMeetingSpeakerLabelingStatus(id: recentPendingJob, status: .pending, at: now.addingTimeInterval(-60))

        let expired = try store.expireStaleMeetingSpeakerLabelingJobs(now: now)
        #expect(Set(expired.map(\.pending.audio.id)) == Set([failedJob, supersededJob, pendingJob]))
        #expect(expired.allSatisfy { $0.status == .expired && $0.pending.state.turns.isEmpty })
        #expect(expired.allSatisfy { !(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self).contains("speech payload")) })
        let remaining = Dictionary(uniqueKeysWithValues: try store.meetingSpeakerLabelingJobs().map { ($0.pending.audio.id, $0.status) })
        #expect(remaining[recentJob] == .failed)
        #expect(remaining[runningJob] == .running)
        #expect(remaining[failedJob] == .expired)
        #expect(remaining[supersededJob] == .expired)
        #expect(remaining[recentPendingJob] == .pending)
        #expect(remaining[pendingJob] == .expired)
    }

    @Test func repeatedFailureDoesNotExtendTheOriginalRetentionWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let epoch = UUID(), key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "source")
        let state = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
                                        turns: [.init(speaker: key, timestamp: "00:00:00", start: 0, end: 1, text: "Speech")])
        let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: state)
        _ = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: now, endTime: now,
                                    rawTranscript: state.render(), formattedNotes: "Notes", micAudioPath: nil,
                                    systemAudioPath: nil, deferredSpeakerLabeling: pending)
        let firstFailure = now.addingTimeInterval(-31 * 24 * 60 * 60)

        try store.setMeetingSpeakerLabelingStatus(id: pending.audio.id, status: .failed, at: firstFailure)
        try store.setMeetingSpeakerLabelingStatus(id: pending.audio.id, status: .failed, at: now)

        #expect(try store.expireStaleMeetingSpeakerLabelingJobs(now: now).map(\.pending.audio.id) == [pending.audio.id])
    }

    @Test func recoverySnapshotFailsClosedWhenDatabaseReadsFail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = MeetingSpeakerBacklogAudio(root: root.appendingPathComponent("backlog"))

        #expect(throws: (any Error).self) {
            try MeetingSpeakerRecoverySnapshot.load(databaseURL: root, audio: audio)
        }
    }

    @Test func scopedJobReadsAndAudioReferencesDoNotDecodeUnrelatedJobPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let source = fixture()
        func insert(_ title: String) throws -> (Int64, MeetingSpeakerPendingLabeling) {
            let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source)
            let meetingID = try store.insertMeeting(title: title, calendarEventID: nil, startTime: Date(), endTime: Date(),
                                                    rawTranscript: source.render(), formattedNotes: "Notes", micAudioPath: nil,
                                                    systemAudioPath: nil, deferredSpeakerLabeling: pending)
            return (meetingID, pending)
        }
        let (firstMeetingID, firstPending) = try insert("First")
        let (secondMeetingID, secondPending) = try insert("Second")
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let corruptSecondPayload = "UPDATE local_meeting_speaker_jobs SET job_json='invalid' WHERE job_id='\(secondPending.audio.id.uuidString)'"
        #expect(sqlite3_exec(db, corruptSecondPayload, nil, nil, nil) == SQLITE_OK)

        #expect(try store.meetingSpeakerLabelingJob(meetingID: firstMeetingID)?.meetingID == firstMeetingID)
        #expect(try store.meetingSpeakerLabelingJob(audioID: firstPending.audio.id)?.meetingID == firstMeetingID)
        #expect(try store.meetingSpeakerLabelingAudioReferences().map(\.meetingID) == [firstMeetingID, secondMeetingID])
    }

    @Test func authorizationRevocationScrubsPersistedTimelineWithoutDiscardingLabelResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let source = fixture(), participant = MeetingSpeakerParticipant(id: "scope/tile", name: "Guest", isSelf: false)
        let frame = MeetingSpeakerFrame(scope: "scope", app: .zoom, participants: [participant], activeID: participant.id, reason: .clear)
        let timeline = MeetingSpeakerTimeline(observations: (0...3).map { .init(time: Double($0), continuity: "one", frame: frame) })
        let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source,
                                                    accessibilityTimeline: timeline, accessibilityAuthorizationID: UUID())
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                                         rawTranscript: source.render(), formattedNotes: "Notes", micAudioPath: nil,
                                         systemAudioPath: nil, deferredSpeakerLabeling: pending)
        let job = try #require(try store.meetingSpeakerLabelingJobs().first)
        #expect(try store.clearDeferredSpeakerAccessibilityEvidence(except: nil) == 1)
        #expect(try store.meetingSpeakerLabelingJobs().first?.pending.accessibilityTimeline == nil)
        let labeled = source.relabeling(channels: [.system: [.init(clusterID: "labeled", start: 0, end: 2)]])
        #expect(try store.completeMeetingSpeakerLabeling(job: job, state: labeled) == .updated)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state.speakers.allSatisfy { $0.assignment?.provenance != .accessibility } == true)
    }

    @Test func addingSpeakerWhileLabelingIsPendingSupersedesTheOldJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let source = fixture()
        let pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source)
        let id = try store.insertMeeting(
            title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: source.render(), formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil,
            deferredSpeakerLabeling: pending
        )
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: source, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var edited = snapshot.state
        let didAddSpeaker = edited.correct(.addSpeaker("Guest", .system))
        #expect(didAddSpeaker)
        #expect(try store.updateMeetingSpeakerState(id: id, state: edited, expected: snapshot) == .updated)
        let job = try #require(try store.meetingSpeakerLabelingJobs().first)
        let labeled = source.relabeling(channels: [.system: [.init(clusterID: "speaker-a", start: 0, end: 2)]])

        #expect(try store.completeMeetingSpeakerLabeling(job: job, state: labeled) == .invalidated)
        let saved = try #require(try store.meetingSpeakerSnapshot(id: id))
        #expect(saved.state.speakers.contains { $0.assignment?.name == "Guest" })
        #expect(try store.meetingSpeakerLabelingJobs().first?.status == .superseded)
    }

    @Test func backlogFailureDoesNotRollBackCanonicalSpeech() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        _ = try store.meetingSpeakerLabelingJobs()
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TRIGGER fail_backlog BEFORE INSERT ON local_meeting_speaker_jobs BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil) == SQLITE_OK)
        let source = fixture(), pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source)
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: source.render(), formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil, deferredSpeakerLabeling: pending)
        #expect(try store.meeting(id: id)?.rawTranscript == source.render())
        #expect(try store.meetingSpeakerLabelingJobs().isEmpty)
    }
    private func fixture() -> MeetingSpeakerState {
        let epoch = UUID(), keyID = "source"
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: keyID)
        return .init(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Others", isAssignable: false)], turns: [
            .init(speaker: key, timestamp: "00:00:00", start: 0, end: 1, text: "First 🌿 words"),
            .init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Second words")])
    }
    private func microphoneFixture() -> MeetingSpeakerState {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "source")
        return .init(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Microphone")], turns: [
            .init(speaker: key, timestamp: "00:00:00", start: 0, end: 1, text: "Spoken words")])
    }
}

private actor BlockedSpeakerLabeling {
    var calls = 0
    var continuation: CheckedContinuation<MeetingSpeakerLabelingTracks, Never>?
    func run() async -> MeetingSpeakerLabelingTracks {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: .init(channels: [:], ownerCluster: nil)); continuation = nil }
}
extension MeetingDeferredSpeakerTests {
    @Test func deadlineReturnsWhileNativeWorkIsBlockedAndRetryJoinsIt() async {
        let service = MeetingSpeakerLabelingService(), gate = BlockedSpeakerLabeling(), id = UUID()
        let first = await service.wait(id: id, timeout: .milliseconds(20), operation: { await gate.run() })
        if case .timedOut = first {} else { Issue.record("Blocked labeling did not time out") }
        #expect(await gate.calls == 1)
        let second = await service.wait(id: id, timeout: .milliseconds(20), retry: true, operation: { await gate.run() })
        if case .timedOut = second {} else { Issue.record("Retry did not join blocked work") }
        #expect(await gate.calls == 1)
        await gate.release()
        let final = await service.wait(id: id, timeout: .seconds(1), operation: { await gate.run() })
        if case .complete = final {} else { Issue.record("Completed task was not reused") }
    }
    @Test func retiringBacklogWaitsForTheActiveAudioReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: source)
        let audio = MeetingSpeakerBacklogAudio(root: root.appendingPathComponent("backlog", isDirectory: true))
        let descriptor = try audio.stage([.system: source])
        let service = MeetingSpeakerLabelingService(), gate = BlockedSpeakerLabeling()
        let reader = Task { await service.wait(id: descriptor.id, operation: { await gate.run() }) }
        while await gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await service.retire(id: descriptor.id, cleanup: { audio.discard(descriptor) })
        #expect(FileManager.default.fileExists(atPath: audio.root.appendingPathComponent(descriptor.id.uuidString).path))
        await gate.release()
        _ = await reader.value
        for _ in 0..<20 where FileManager.default.fileExists(atPath: audio.root.appendingPathComponent(descriptor.id.uuidString).path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!FileManager.default.fileExists(atPath: audio.root.appendingPathComponent(descriptor.id.uuidString).path))
    }
    @Test func privateAudioStagingRejectsSymlinksAndRetainsRecoveryMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.wav")
        try Data([0, 1]).write(to: source)
        let audio = MeetingSpeakerBacklogAudio(root: root.appendingPathComponent("backlog"))
        let descriptor = try audio.stage([.system: source])
        let url = try #require(try audio.urls(descriptor)[.system])
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("recovery.json").path))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: source)
        #expect(throws: (any Error).self) { try audio.urls(descriptor) }
    }
    @Test func failedAudioStagingRemovesItsPartialBacklogFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backlogRoot = root.appendingPathComponent("backlog", isDirectory: true)
        let audio = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [root])
        let missingSource = root.appendingPathComponent("missing.wav")

        #expect(throws: (any Error).self) { try audio.stage([.system: missingSource]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: backlogRoot.path).isEmpty)
    }
    @Test func discardRefusesBacklogRootSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("outside", isDirectory: true)
        let backlogRoot = root.appendingPathComponent("backlog", isDirectory: true)
        let id = UUID()
        let escapedFolder = target.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: escapedFolder, withIntermediateDirectories: true)
        let sentinel = escapedFolder.appendingPathComponent("keep.wav")
        try Data([1, 2, 3]).write(to: sentinel)
        let stagedWav = escapedFolder.appendingPathComponent("system.wav")
        try Data([4, 5, 6]).write(to: stagedWav)
        let descriptor = MeetingSpeakerBacklogDescriptor(id: id, channels: [.system])
        try FileManager.default.createSymbolicLink(at: backlogRoot, withDestinationURL: target)
        let audio = MeetingSpeakerBacklogAudio(root: backlogRoot)

        audio.discard(id: id)

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(FileManager.default.fileExists(atPath: backlogRoot.path))
        #expect(throws: (any Error).self) { try audio.urls(descriptor) }
        let source = root.appendingPathComponent("source.wav")
        try Data([7, 8, 9]).write(to: source)
        #expect(throws: (any Error).self) { try audio.stage([.system: source]) }
    }
    @Test func recoverySourcesSurviveReconstructionAndCanBeDiscarded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("fixture.wav")
        try Data([1, 2, 3]).write(to: source)
        let unrelated = sourceDirectory.appendingPathComponent("unrelated.wav")
        try Data([9]).write(to: unrelated)
        let backlogRoot = root.appendingPathComponent("SpeakerBacklog", isDirectory: true)
        let audio = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [sourceDirectory])
        let meetingID: Int64 = 42

        try audio.recordRecoverySources(meetingID: meetingID, sources: [source])
        let restored = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [sourceDirectory])
        let record = try #require(restored.recoveryRecordsThrowing().first { $0.meetingID == meetingID })
        #expect(record.urls == [source])
        #expect(record.preserves(source))
        #expect(record.preserves(sourceDirectory))
        #expect(!record.preserves(unrelated))
        let manifest = backlogRoot.appendingPathComponent("recovery-sources-\(meetingID).json")
        #expect((try FileManager.default.attributesOfItem(atPath: backlogRoot.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try restored.discardRecoverySources(meetingID: meetingID)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(restored.recoveryRecords().first { $0.meetingID == meetingID } == nil)
    }

    @Test func orphanedStagedRecoveryExpiresAtItsOriginalDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("test.sqlite")
        let store = DictationStore(databaseURL: databaseURL)
        try store.migrateIfNeeded()
        let sourceDirectory = root.appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("fixture.wav")
        try Data([1, 2, 3]).write(to: source)
        let backlogRoot = root.appendingPathComponent("SpeakerBacklog", isDirectory: true)
        let audio = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [sourceDirectory])
        let descriptor = try audio.stage([.system: source])
        let meetingID: Int64 = 77
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let original = try audio.recordRecoveryDescriptor(meetingID: meetingID, descriptor: descriptor, now: createdAt)
        let refreshed = try audio.recordRecoveryDescriptor(
            meetingID: meetingID,
            descriptor: descriptor,
            now: createdAt.addingTimeInterval(24 * 60 * 60)
        )
        let deadline = createdAt.addingTimeInterval(30 * 24 * 60 * 60)

        #expect(original.expiresAt == deadline)
        #expect(refreshed.expiresAt == deadline)

        let snapshot = try MeetingSpeakerRecoverySnapshot.load(
            databaseURL: databaseURL,
            audio: audio,
            now: deadline.addingTimeInterval(1)
        )
        #expect(snapshot.recoveries.isEmpty)
        #expect(snapshot.expiredRecoveries.map(\.meetingID) == [meetingID])

        await MeetingSpeakerLabelingService.shared.retire(id: descriptor.id) {
            try? audio.discardRecoverySources(meetingID: meetingID, fallbackDescriptors: [descriptor])
        }
        #expect(!FileManager.default.fileExists(atPath: backlogRoot.appendingPathComponent(descriptor.id.uuidString).path))
        #expect(try audio.recoveryRecordsThrowing().isEmpty)
    }

    @Test func missingRecoveryAudioDoesNotBlockOtherRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let missingSource = sourceDirectory.appendingPathComponent("missing.wav")
        let survivingSource = sourceDirectory.appendingPathComponent("surviving.wav")
        let orphanedSource = sourceDirectory.appendingPathComponent("orphaned.wav")
        let validSource = sourceDirectory.appendingPathComponent("valid.wav")
        try Data([1]).write(to: missingSource)
        try Data([2]).write(to: survivingSource)
        try Data([3]).write(to: orphanedSource)
        try Data([4]).write(to: validSource)

        let backlogRoot = root.appendingPathComponent("SpeakerBacklog", isDirectory: true)
        let audio = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [sourceDirectory])
        try audio.recordRecoverySources(meetingID: 101, sources: [missingSource, survivingSource])
        try audio.recordRecoverySources(meetingID: 102, sources: [orphanedSource])
        let stagedSource = root.appendingPathComponent("staged.wav")
        try Data([5]).write(to: stagedSource)
        let descriptor = try audio.stage([.system: stagedSource])
        try audio.recordRecoveryDescriptor(meetingID: 103, descriptor: descriptor)
        try audio.recordRecoverySources(meetingID: 104, sources: [validSource])

        try FileManager.default.removeItem(at: missingSource)
        try FileManager.default.removeItem(at: orphanedSource)
        try FileManager.default.removeItem(at: backlogRoot.appendingPathComponent(descriptor.id.uuidString, isDirectory: true))

        let records = try audio.recoveryRecordsThrowing()

        #expect(records.map(\.meetingID) == [101, 102, 103, 104])
        #expect(records.first { $0.meetingID == 101 }?.urls == [survivingSource])
        #expect(records.first { $0.meetingID == 102 }?.hasRecoverableAudio == false)
        #expect(records.first { $0.meetingID == 103 }?.hasRecoverableAudio == false)
        #expect(records.first { $0.meetingID == 104 }?.urls == [validSource])
    }

    @Test func stagedBacklogCanBeDiscardedWhenLabelingJobWasNotSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("fixture.wav")
        try Data([1, 2, 3]).write(to: source)
        let backlogRoot = root.appendingPathComponent("SpeakerBacklog", isDirectory: true)
        let audio = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [sourceDirectory])
        let descriptor = try audio.stage([.system: source])
        let stagedURL = try #require(try audio.urls(descriptor)[.system])
        let meetingID: Int64 = 43

        try audio.recordRecoveryDescriptor(meetingID: meetingID, descriptor: descriptor)
        let restored = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [sourceDirectory])
        let record = try #require(restored.recoveryRecordsThrowing().first { $0.meetingID == meetingID })
        #expect(record.urls.isEmpty)
        #expect(record.stagedDescriptor == descriptor)

        try restored.discardRecoverySources(meetingID: meetingID)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(restored.recoveryRecords().first { $0.meetingID == meetingID } == nil)
    }
    @Test func recoveryManifestRejectsUnapprovedFilesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        let outside = root.appendingPathComponent("outside.wav")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try Data([4]).write(to: outside)
        let audio = MeetingSpeakerBacklogAudio(root: root.appendingPathComponent("SpeakerBacklog"), allowedRecoveryRoots: [allowed])
        #expect(throws: (any Error).self) { try audio.recordRecoverySources(meetingID: 1, sources: [outside]) }

        let link = allowed.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try audio.recordRecoverySources(meetingID: 2, sources: [link]) }
    }
    @Test func recoveryDiscardUsesValidatedInMemorySourcesWhenManifestIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let source = allowed.appendingPathComponent("fixture.wav")
        let unrelated = allowed.appendingPathComponent("unrelated.wav")
        try Data([1]).write(to: source)
        try Data([2]).write(to: unrelated)
        let audio = MeetingSpeakerBacklogAudio(root: root.appendingPathComponent("SpeakerBacklog"), allowedRecoveryRoots: [allowed])

        try audio.discardRecoverySources(meetingID: 9, fallbackSources: [source, root])

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

}
