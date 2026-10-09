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

    @Test func sourceDeletionRefreshesDisplayedAnswersImmediately() throws {
        let (controller, _, citation) = try controllerFixture()
        controller.showMeetingChat(meetingID: citation.meetingID)
        let coordinator = controller.meetingChatCoordinator
        let sessionID = coordinator.selectedSessionID!
        let turn = try coordinator.store.beginTurn(sessionID: sessionID, question: "When?", scope: coordinator.scope, provider: "test", model: "test")
        let dependency = MeetingChatDependency(meetingID: citation.meetingID, revision: citation.revision)
        try coordinator.store.attachEvidence(turnID: turn.id, dependencies: [dependency])
        #expect(try coordinator.store.finishTurn(turnID: turn.id, answer: "Friday [[S1]]", citations: [citation], dependencies: [dependency]))
        coordinator.reload()
        #expect(coordinator.turns.first?.originalAnswer != nil)
        controller.deleteMeeting(id: citation.meetingID)
        #expect(coordinator.turns.first?.originalAnswer == nil)
    }

    @Test func transcriptLocatorHandlesChunksAndRepeatedExcerpts() {
        let text = "first chunk second chunk\nnext speaker\nsecond chunk"
        let second = (text as NSString).range(of: "second chunk")
        #expect(MeetingChatDocumentTarget.transcriptMessageID(in: text, range: second) == 0)
        let repeated = (text as NSString).range(of: "second chunk", options: .backwards)
        #expect(MeetingChatDocumentTarget.transcriptMessageID(in: text, range: repeated) == 2)
    }

    @Test func historicalScopeLabelsRetainFolderNameAndBothDateBounds() throws {
        let (_, store, _) = try controllerFixture()
        let folder = try store.createFolder(name: "Original project")
        let chat = MeetingChatStore(databaseURL: store.resolvedDatabaseURL)
        let scope = MeetingChatScope(selection: .folder(folder), startDate: Date(timeIntervalSince1970: 1_000), endDateExclusive: Date(timeIntervalSince1970: 2_000))
        let session = try chat.createSession(scope: scope, title: "Scope")
        let turn = try chat.beginTurn(sessionID: session.id, question: "Decisions?", scope: scope, provider: "test", model: "test")
        #expect(turn.scopeLabel?.contains("Original project") == true)
        #expect(turn.scopeLabel?.contains("through") == true)
    }

    @Test func sourceReturnRetainsSessionScrollAnchor() throws {
        let (controller, _, citation) = try controllerFixture()
        controller.showMeetingChat(meetingID: citation.meetingID)
        let coordinator = controller.meetingChatCoordinator
        let session = coordinator.selectedSessionID!
        let anchor = UUID()
        coordinator.scrollAnchors[session] = anchor
        controller.showMeetingChatSource(.init(citation: citation, sessionID: session))
        controller.returnToMeetingChat()
        #expect(coordinator.scrollAnchors[session] == anchor)
    }
}
