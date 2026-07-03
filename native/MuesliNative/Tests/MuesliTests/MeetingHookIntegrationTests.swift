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

    @Test("no hook runs when meeting persistence fails")
    func noHookRunsWhenPersistenceFails() throws {
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

        #expect(throws: Error.self) {
            try controller.persistCompletedMeetingResultAndDispatchHook(
                makeMeetingResult(calendarEventID: "duplicate-event"),
                preparedRecordingSave: .none
            )
        }
        #expect(spy.invocations.isEmpty)
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

private final class MeetingHookDispatcherSpy: MeetingHookDispatching {
    struct Invocation {
        let meetingID: Int64
        let completedAt: Date
        let config: AppConfig
    }

    private(set) var invocations: [Invocation] = []

    func dispatchCompletedMeetingHook(meetingID: Int64, completedAt: Date, config: AppConfig) {
        invocations.append(Invocation(meetingID: meetingID, completedAt: completedAt, config: config))
    }
}
