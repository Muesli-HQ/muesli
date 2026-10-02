import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting hook integration")
struct MeetingHookIntegrationTests {

    @Test("meeting completion dispatches one hook event after persistence succeeds")
    func dispatchesHookAfterPersistence() throws {
        let store = try makeStore()
        let spy = MeetingHookDispatcherSpy()
        let controller = makeController(store: store, dispatcher: spy)

        let persistence = try controller.persistCompletedMeetingResultAndDispatchHook(
            makeMeetingResult(),
            preparedRecordingSave: .none
        )

        #expect(spy.invocations.count == 1)
        #expect(spy.invocations.first?.meetingID == persistence.meetingID)
        #expect(try store.meeting(id: persistence.meetingID) != nil)
    }

    @Test("persisted meeting id is sent to the hook dispatcher")
    func persistedMeetingIDIsSentToHook() throws {
        let store = try makeStore()
        let spy = MeetingHookDispatcherSpy()
        let controller = makeController(store: store, dispatcher: spy)

        let persistence = try controller.persistCompletedMeetingResultAndDispatchHook(
            makeMeetingResult(calendarEventID: "event-123"),
            preparedRecordingSave: .none
        )

        let invocation = try #require(spy.invocations.first)
        #expect(invocation.meetingID == persistence.meetingID)
        #expect(invocation.meetingID > 0)
    }

    @Test("completedAt uses the meeting end time")
    func completedAtUsesMeetingEndTime() throws {
        let store = try makeStore()
        let spy = MeetingHookDispatcherSpy()
        let controller = makeController(store: store, dispatcher: spy)
        let result = makeMeetingResult()

        _ = try controller.persistCompletedMeetingResultAndDispatchHook(
            result,
            preparedRecordingSave: .none
        )

        let invocation = try #require(spy.invocations.first)
        #expect(invocation.completedAt == result.endTime)
    }

    @Test("hook launch failure does not fail meeting persistence")
    func hookLaunchFailureDoesNotFailPersistence() throws {
        let store = try makeStore()
        let supportDirectory = makeTemporaryDirectory()
        let runner = MeetingHookRunner(supportDirectory: supportDirectory)
        let controller = makeController(store: store, dispatcher: runner)
        controller.updateConfig {
            $0.meetingHookEnabled = true
            $0.meetingHookPath = "/definitely/missing/hook.sh"
            $0.meetingHookTimeoutSeconds = 1
        }

        let persistence = try controller.persistCompletedMeetingResultAndDispatchHook(
            makeMeetingResult(),
            preparedRecordingSave: .none
        )

        #expect(try store.meeting(id: persistence.meetingID) != nil)
    }

    @Test("duplicate calendar metadata does not block persistence or hooks")
    func duplicateCalendarMetadataDoesNotBlockPersistence() throws {
        let store = try makeStore()
        let spy = MeetingHookDispatcherSpy()
        let controller = makeController(store: store, dispatcher: spy)
        let now = Date()
        try store.insertMeeting(
            title: "Existing",
            calendarEventID: "duplicate-event",
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Existing transcript",
            formattedNotes: "Existing notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let persistence = try controller.persistCompletedMeetingResultAndDispatchHook(
            makeMeetingResult(calendarEventID: "duplicate-event"),
            preparedRecordingSave: .none
        )

        #expect(try store.meeting(id: persistence.meetingID) != nil)
        #expect(try store.recentMeetings(limit: 10).count == 2)
        #expect(spy.invocations.count == 1)
    }

    @Test("imported audio meeting dispatches one hook event after persistence succeeds")
    func importedMeetingDispatchesHook() throws {
        let store = try makeStore()
        let spy = MeetingHookDispatcherSpy()
        let controller = makeController(store: store, dispatcher: spy)
        let endTime = Date(timeIntervalSince1970: 1_713_961_500)
        var meetingExistedAtDispatch = false
        spy.onDispatch = { invocation in
            meetingExistedAtDispatch = (try? store.meeting(id: invocation.meetingID)) != nil
        }

        let meetingID = try controller.persistImportedAudioMeeting(
            title: "Imported Call Recording",
            calendarEventID: nil,
            startTime: endTime.addingTimeInterval(-300),
            endTime: endTime,
            rawTranscript: "Speaker 1: Discussed the imported call.",
            formattedNotes: "## Summary\nImported recording.",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: nil,
            selectedTemplateName: nil,
            selectedTemplateKind: nil,
            selectedTemplatePrompt: nil
        )

        #expect(spy.invocations.count == 1)
        #expect(spy.invocations.first?.meetingID == meetingID)
        #expect(spy.invocations.first?.completedAt == endTime)
        #expect(meetingExistedAtDispatch)

        let record = try #require(try store.meeting(id: meetingID))
        #expect(record.title == "Imported Call Recording")
        #expect(record.startTime == "2024-04-24T12:20:00Z")
        #expect(record.durationSeconds == 300)
        #expect(record.rawTranscript == "Speaker 1: Discussed the imported call.")
        #expect(record.formattedNotes == "## Summary\nImported recording.")
        #expect(record.source == .audioImport)
    }

    private func makeController(store: DictationStore, dispatcher: MeetingHookDispatching) -> MuesliController {
        MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            meetingHookDispatcher: dispatcher
        )
    }

    @Test("late canonical name and participant edits do not replay completion hooks")
    func lateArchiveEditsDoNotReplayCompletion() async throws {
        let store = try makeStore()
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: store.databasePath().path + suffix)
            }
        }
        let support = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let configStore = ConfigStore(supportDirectory: support)
        var config = AppConfig()
        config.iCloudSyncEnabled = false
        config.autoExportMarkdownEnabled = true
        config.meetingHookEnabled = true
        configStore.save(config)
        let spy = MeetingHookDispatcherSpy()
        let exports = ArchiveAutoExportSpy()
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: support, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: configStore, meetingHookDispatcher: spy,
            meetingMarkdownAutoExporter: exports
        )
        let persistence = try controller.persistCompletedMeetingResultAndDispatchHook(
            makeMeetingResult(), preparedRecordingSave: .none
        )
        let id = persistence.meetingID
        #expect(spy.invocations.count == 1)
        #expect(exports.meetingIDs == [id])
        let canonical = "[12:20:01] Ana Example: Corrected canonical text"
        controller.updateMeetingTranscript(id: id, transcript: canonical)
        try await controller.attachMeetingParticipant(meetingID: id, participant: .init(
            participantIdentifier: "contact:synthetic-card", displayName: "Ana Example"
        ))
        #expect(try await controller.meetingParticipants(meetingID: id).map(\.displayName) == ["Ana Example"])
        try await controller.removeMeetingParticipant(meetingID: id, participantIdentifier: "contact:synthetic-card")
        #expect(try await controller.meetingParticipants(meetingID: id).isEmpty)
        #expect(try store.meeting(id: id)?.rawTranscript == canonical)
        #expect(spy.invocations.count == 1)
        #expect(spy.invocations.first?.meetingID == id)
        #expect(exports.meetingIDs == [id])
        #expect(exports.lookupFailures.isEmpty)

        let event = MeetingHookEvent(
            schemaVersion: 1, event: "meeting.completed", kind: "meeting", id: id,
            completedAt: "2024-04-24T12:25:00Z"
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
        let payload = try #require(object as? [String: Any])
        #expect(Set(payload.keys) == ["schemaVersion", "event", "kind", "id", "completedAt"])
        #expect(payload["schemaVersion"] as? Int == 1)
        #expect(payload["event"] as? String == "meeting.completed")
        #expect(payload["id"] as? Int64 == id)
    }

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-hook-integration-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-hook-support-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMeetingResult(calendarEventID: String? = nil) -> MeetingSessionResult {
        let start = Date(timeIntervalSince1970: 1_713_961_200)
        let end = start.addingTimeInterval(300)
        return MeetingSessionResult(
            title: "Tim V1 Meeting",
            originalTitle: "Meeting",
            calendarEventID: calendarEventID,
            startTime: start,
            endTime: end,
            durationSeconds: end.timeIntervalSince(start),
            rawTranscript: "Discussed action items and follow ups.",
            formattedNotes: "## Summary\nReady for automation.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )
    }
}

private final class ArchiveAutoExportSpy: MeetingMarkdownAutoExporting {
    private(set) var meetingIDs: [Int64] = []
    private(set) var lookupFailures: [Int64] = []

    func exportIfConfigured(meeting: MeetingRecord, config: AppConfig) {
        meetingIDs.append(meeting.id)
    }

    func recordMeetingLookupFailure(meetingID: Int64, error: Error?) {
        lookupFailures.append(meetingID)
    }
}

private final class MeetingHookDispatcherSpy: MeetingHookDispatching {
    struct Invocation {
        let meetingID: Int64
        let completedAt: Date
        let config: AppConfig
    }

    private(set) var invocations: [Invocation] = []
    var onDispatch: ((Invocation) -> Void)?

    func dispatchCompletedMeetingHook(meetingID: Int64, completedAt: Date, config: AppConfig) {
        let invocation = Invocation(meetingID: meetingID, completedAt: completedAt, config: config)
        invocations.append(invocation)
        onDispatch?(invocation)
    }
}
