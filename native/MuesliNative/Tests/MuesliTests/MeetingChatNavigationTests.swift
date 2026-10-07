import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting chat navigation")
struct MeetingChatNavigationTests {
    private func controllerFixture() throws -> (MuesliController, DictationStore, MeetingChatCitation) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-navigation-\(UUID())")
        let store = DictationStore(databaseURL: directory.appendingPathComponent("test.db")); try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "[00:00:01] You: Launch Friday.", formattedNotes: "## Decision\nLaunch Friday.", micAudioPath: nil, systemAudioPath: nil)
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil), dictationStore: store, configStore: ConfigStore(supportDirectory: directory))
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "Friday", scope: .init())
        return (controller, store, try #require(evidence.passages.first?.citation))
    }
    @Test func entryUsesSingleMeetingScopeAndReturnPreservesComposer() throws {
        let (controller, _, citation) = try controllerFixture()
        controller.showMeetingChat(meetingID: citation.meetingID)
        let chat = controller.meetingChatCoordinator
        #expect(controller.appState.selectedTab == .meetingChat)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
        chat.composerDraft = "Follow-up draft"
        let sessionID = try #require(chat.selectedSessionID)
        controller.showMeetingChatSource(.init(citation: citation, sessionID: sessionID))
        #expect(controller.appState.selectedMeetingID == citation.meetingID)
        #expect(controller.appState.meetingChatDocumentTarget?.showsTranscript == true)
        controller.returnToMeetingChat()
        #expect(chat.selectedSessionID == sessionID)
        #expect(chat.composerDraft == "Follow-up draft")
    }
    @Test func sourceLocatorValidatesOffsetsAndHandlesChangedPassages() throws {
        let (_, _, citation) = try controllerFixture()
        let target = MeetingChatDocumentTarget(citation: citation, sessionID: UUID())
        #expect(target.locate(in: "[00:00:01] You: Launch Friday.") != nil)
        #expect(target.locate(in: "Unrelated new transcript") == nil)
        #expect(target.locate(in: "Preface\n[00:00:01] You: Launch Friday.")?.location == 8)
    }
    @Test func noteCitationTargetsNotesAndMissingMeetingDoesNotNavigate() throws {
        let (controller, store, original) = try controllerFixture()
        var citation = original; citation.kind = .generatedNotes; citation.timestamp = nil
        let target = MeetingChatDocumentTarget(citation: citation, sessionID: UUID())
        #expect(!target.showsTranscript)
        try store.deleteMeeting(id: citation.meetingID)
        controller.showMeetingChatSource(target)
        #expect(controller.appState.meetingChatDocumentTarget == nil)
    }
    @Test func selectionChoicesLoadFullArchiveWithoutTranscriptPayloads() throws {
        let (_, store, _) = try controllerFixture()
        _ = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).prepareIndex()
        let choices = try MeetingChatStore(databaseURL: store.resolvedDatabaseURL).sourceChoices()
        #expect(choices.count == 1)
        #expect(choices.first?.title == "Launch")
    }
}
