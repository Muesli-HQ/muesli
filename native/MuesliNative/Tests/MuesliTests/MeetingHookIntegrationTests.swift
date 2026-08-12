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
    var onDispatch: ((Invocation) -> Void)?

    func dispatchCompletedMeetingHook(meetingID: Int64, completedAt: Date, config: AppConfig) {
        let invocation = Invocation(meetingID: meetingID, completedAt: completedAt, config: config)
        invocations.append(invocation)
        onDispatch?(invocation)
    }
}
