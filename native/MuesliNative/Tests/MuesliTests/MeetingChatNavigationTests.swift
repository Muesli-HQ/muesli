import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting chat navigation")
struct MeetingChatNavigationTests {
    @Test func newDraftsStartEmptyAndOnlyUnusedDraftsFollowMeetingOrFolderContext() async throws {
        let (controller, _, citation) = try controllerFixture()
        let chat = controller.meetingChatCoordinator
        #expect(chat.scope == MeetingChatScopePolicy.empty)
        chat.prepareContextualDraft(scope: .init(selection: .meetings([citation.meetingID])))
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
        chat.prepareContextualDraft(scope: .init(selection: .folder(12)))
        #expect(chat.scope.selection == .folder(12))
        chat.composerDraft = "Keep this folder question"
        let undo = chat.composerUndoIdentity
        chat.prepareContextualDraft(scope: MeetingChatScopePolicy.empty)
        #expect(chat.scope.selection == .folder(12))
        #expect(chat.composerDraft == "Keep this folder question" && chat.composerUndoIdentity == undo)
        chat.composerDraft = ""
        chat.prepareContextualDraft(scope: MeetingChatScopePolicy.empty)
        #expect(chat.scope.selection == .folder(12))
        chat.startDraft()
        #expect(chat.scope == MeetingChatScopePolicy.empty)
        chat.prepareContextualDraft(scope: .init(selection: .meetings([citation.meetingID])))
        await chat.setScope(MeetingChatScopePolicy.empty)
        chat.prepareContextualDraft(scope: .init(selection: .folder(12)))
        #expect(chat.scope == MeetingChatScopePolicy.empty)
        chat.startDraft(scope: .init(selection: .all))
        chat.prepareContextualDraft(scope: .init(selection: .folder(12)))
        #expect(chat.scope.selection == .all)
    }

    @Test func suggestedContextUsesOnlyTheVisibleMeetingOrFolder() {
        func scope(_ tab: DashboardTab, _ navigation: MeetingsNavigationState = .browser,
                   destination: MeetingDetailReturnDestination = .meetings, search: Bool = false, folder: Int64? = 5) -> MeetingChatScope {
            MeetingChatScopePolicy.suggestedScope(tab: tab, navigation: navigation, returnDestination: destination, searchActive: search, folderID: folder)
        }
        #expect(scope(.meetingChat, .document(3)) == MeetingChatScopePolicy.empty)
        #expect(scope(.dictations, .document(3)) == MeetingChatScopePolicy.empty)
        #expect(scope(.timeline, .document(3)) == MeetingChatScopePolicy.empty)
        #expect(scope(.timeline, .document(3), destination: .timeline).selection == .meetings([3]))
        #expect(scope(.meetings, .document(3)).selection == .meetings([3]))
        #expect(scope(.meetings).selection == .folder(5))
        #expect(scope(.meetings, folder: nil) == MeetingChatScopePolicy.empty)
        #expect(scope(.meetings, search: true) == MeetingChatScopePolicy.empty)
        #expect(scope(.timeline, .document(3), search: true).selection == .meetings([3]))
    }

    @Test func futureScopeChangesAreRefusedWithoutLosingDraftOrCreatingATurn() async throws {
        let (controller, _, _) = try controllerFixture()
        let chat = controller.meetingChatCoordinator
        chat.composerDraft = "Keep this question"
        let undo = chat.composerUndoIdentity
        let future = MeetingChatScope(selection: .all, startDate: Date().addingTimeInterval(7 * 86_400))
        #expect(await chat.setScope(future) == nil)
        #expect(chat.selectedSessionID == nil && chat.scope == MeetingChatScopePolicy.empty)
        #expect(chat.composerDraft == "Keep this question" && chat.composerUndoIdentity == undo)
        // A legacy persisted range remains readable, but cannot reach a provider.
        await chat.createChat(scope: future)
        await chat.send(question: "Read meetings", config: AppConfig())
        #expect(!chat.isBusy && chat.turns.isEmpty)
        #expect(chat.errorMessage == MeetingChatScopePolicy.invalidDatesMessage)
    }

    @Test func dateBoundsAndValidationRespectTodayAndCalendarDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 1, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        #expect(tomorrow.timeIntervalSince(today) == 90_000)
        #expect(MeetingChatScopePolicy.validDates(.init(startDate: today, endDateExclusive: tomorrow), now: now, calendar: calendar))
        #expect(!MeetingChatScopePolicy.validDates(.init(startDate: tomorrow), now: now, calendar: calendar))
        #expect(!MeetingChatScopePolicy.validDates(.init(endDateExclusive: tomorrow.addingTimeInterval(1)), now: now, calendar: calendar))
        #expect(!MeetingChatScopePolicy.validDates(.init(startDate: today, endDateExclusive: today), now: now, calendar: calendar))
        let earlier = try #require(calendar.date(byAdding: .day, value: -10, to: today))
        let choices = [MeetingChatSourceChoice(id: 1, title: "Past", startDate: earlier, folderID: nil),
                       MeetingChatSourceChoice(id: 2, title: "Future", startDate: tomorrow, folderID: nil)]
        #expect(MeetingChatScopePolicy.dateBounds(meetings: choices, now: now, calendar: calendar) == earlier...today)
        #expect(MeetingChatScopePolicy.dateBounds(meetings: [], now: now, calendar: calendar) == today...today)
    }
    @Test func repeatedMeetingEntryPreservesUntitledDraft() async throws {
        let (controller, _, citation) = try controllerFixture()
        controller.showMeetingChat(meetingID: citation.meetingID)
        let chat = controller.meetingChatCoordinator
        chat.composerDraft = "Keep this question"
        let undo = chat.composerUndoIdentity
        controller.showMeetingChat(meetingID: citation.meetingID)
        controller.showMeetingChat(meetingID: citation.meetingID + 1)
        #expect(chat.composerDraft == "Keep this question")
        #expect(chat.composerUndoIdentity == undo)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
    }

    @Test func dateRestrictionsHaveVisibleLabels() {
        #expect(MeetingChatScopePresentation.dateLabel(.init()) == nil)
        let start = Date(timeIntervalSince1970: 100000)
        #expect(MeetingChatScopePresentation.dateLabel(.init(startDate: start))?.hasPrefix("From ") == true)
        #expect(MeetingChatScopePresentation.dateLabel(.init(endDateExclusive: start))?.hasPrefix("Through ") == true)
        #expect(MeetingChatScopePresentation.dateLabel(.init(startDate: start, endDateExclusive: start.addingTimeInterval(86400)))?.contains(" – ") == true)
    }

    private func controllerFixture() throws -> (MuesliController, DictationStore, MeetingChatCitation) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-navigation-\(UUID())")
        let store = DictationStore(databaseURL: directory.appendingPathComponent("test.db")); try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "[00:00:01] You: Launch Friday.", formattedNotes: "## Decision\nLaunch Friday.", micAudioPath: nil, systemAudioPath: nil)
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil), dictationStore: store, configStore: makeTestConfigStore(supportDirectory: directory))
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "Friday", scope: .init())
        return (controller, store, try #require(evidence.passages.first { $0.kind == .transcript }?.citation))
    }
    @Test func openingMeetingComposerDoesNotPersistEmptyChat() async throws {
        let (controller, _, citation) = try controllerFixture()
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        let chat = controller.meetingChatCoordinator
        #expect(chat.selectedSessionID == nil)
        #expect(try chat.store.sessions().isEmpty)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
    }

    @Test func browsingMeetingsPreservesDraftAndEstablishedScope() async throws {
        let (controller, _, citation) = try controllerFixture()
        let chat = controller.meetingChatCoordinator
        chat.prepareMeetingDraft(id: citation.meetingID)
        chat.composerDraft = "An unfinished question"
        let identity = chat.composerUndoIdentity
        chat.prepareMeetingDraft(id: 999)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
        #expect(chat.composerDraft == "An unfinished question")
        #expect(chat.composerUndoIdentity == identity)
        await chat.createChat(scope: chat.scope)
        chat.prepareMeetingDraft(id: 999)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
    }

    @Test func changingUnsentScopePreservesDraftAndUndoHistory() async throws {
        let (controller, _, citation) = try controllerFixture()
        let chat = controller.meetingChatCoordinator
        chat.startDraft()
        chat.composerDraft = "Keep my question while I choose context"
        let identity = chat.composerUndoIdentity
        let id = await chat.setScope(.init(selection: .meetings([citation.meetingID])))
        #expect(id != nil)
        #expect(chat.selectedSessionID == id)
        #expect(chat.composerDraft == "Keep my question while I choose context")
        #expect(chat.composerUndoIdentity == identity)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
    }

    @Test func indexNavigationPreservesConversationDraftAndScope() async throws {
        let (controller, _, citation) = try controllerFixture()
        let chat = controller.meetingChatCoordinator
        await chat.createChat(scope: .init(selection: .meetings([citation.meetingID])))
        let sessionID = try #require(chat.selectedSessionID)
        chat.composerDraft = "An unfinished follow-up"
        let undoIdentity = chat.composerUndoIdentity

        controller.showMeetingChatIndex()
        #expect(controller.appState.selectedTab == .meetingChat)
        #expect(chat.selectedSessionID == nil)
        #expect(chat.turns.isEmpty)
        #expect(chat.sessions.contains { $0.id == sessionID })
        chat.composerDraft = "An unfinished new question"
        controller.showMeetingChatIndex()
        #expect(chat.composerDraft == "An unfinished new question")

        chat.selectChat(id: sessionID)
        #expect(chat.composerDraft == "An unfinished follow-up")
        #expect(chat.composerUndoIdentity == undoIdentity)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
    }

    @Test func entryUsesSingleMeetingScopeAndReturnPreservesComposer() async throws {
        let (controller, _, citation) = try controllerFixture()
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        let chat = controller.meetingChatCoordinator
        #expect(controller.appState.selectedTab == .meetingChat)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
        if chat.selectedSessionID == nil { await chat.createChat(scope: chat.scope) }
        chat.composerDraft = "Follow-up draft"
        let sessionID = try #require(chat.selectedSessionID)
        controller.showMeetingChatSource(.init(citation: citation, sessionID: sessionID))
        #expect(controller.appState.selectedMeetingID == citation.meetingID)
        #expect(controller.appState.meetingChatDocumentTarget?.showsTranscript == true)
        controller.returnToMeetingChat()
        #expect(chat.selectedSessionID == sessionID)
        #expect(chat.composerDraft == "Follow-up draft")
    }
    @Test func sourceLocatorValidatesOffsetsAndHandlesChangedPassages() async throws {
        let (_, _, citation) = try controllerFixture()
        let target = MeetingChatDocumentTarget(citation: citation, sessionID: UUID())
        #expect(target.locate(in: "[00:00:01] You: Launch Friday.") != nil)
        #expect(target.locate(in: "Unrelated new transcript") == nil)
        #expect(target.locate(in: "Preface\n[00:00:01] You: Launch Friday.")?.location == 8)
    }
    @Test func meetingEntryResumesAnchoredChatAndPreservesAdditionalContext() async throws {
        let (controller, store, citation) = try controllerFixture()
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        let chat = controller.meetingChatCoordinator
        if chat.selectedSessionID == nil { await chat.createChat(scope: chat.scope) }
        let sessionID = try #require(chat.selectedSessionID)
        let secondID = try store.insertMeeting(title: "Planning", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "Planning context", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        await chat.setScope(.init(selection: .meetings([citation.meetingID, secondID])))
        chat.composerDraft = "Compare these meetings"
        await chat.createChat(scope: .init())
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        #expect(chat.selectedSessionID == sessionID)
        #expect(chat.scope.selection == .meetings([citation.meetingID, secondID]))
        #expect(chat.composerDraft == "Compare these meetings")
        #expect(chat.sessions.count == 2)
    }

    @Test func meetingEntryDoesNotResumeAnchorWhoseScopeExcludesMeeting() async throws {
        let (controller, _, citation) = try controllerFixture()
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        let chat = controller.meetingChatCoordinator
        await chat.createChat(scope: chat.scope)
        let oldID = try #require(chat.selectedSessionID)
        await chat.setScope(.init(selection: .meetings([])))
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        #expect(chat.selectedSessionID != oldID)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
    }
    @Test func noteCitationTargetsNotesAndMissingMeetingDoesNotNavigate() async throws {
        let (controller, store, original) = try controllerFixture()
        var citation = original; citation.kind = .generatedNotes; citation.timestamp = nil
        let target = MeetingChatDocumentTarget(citation: citation, sessionID: UUID())
        #expect(!target.showsTranscript)
        try store.deleteMeeting(id: citation.meetingID)
        controller.showMeetingChatSource(target)
        #expect(controller.appState.meetingChatDocumentTarget == nil)
    }
    @Test func selectionChoicesLoadFullArchiveWithoutTranscriptPayloads() async throws {
        let (_, store, _) = try controllerFixture()
        _ = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).prepareIndex()
        let choices = try MeetingChatStore(databaseURL: store.resolvedDatabaseURL).sourceChoices()
        #expect(choices.count == 1)
        #expect(choices.first?.title == "Launch")
    }

    @Test func sourceDeletionRefreshesDisplayedAnswersImmediately() async throws {
        let (controller, _, citation) = try controllerFixture()
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        let coordinator = controller.meetingChatCoordinator
        await coordinator.createChat(scope: coordinator.scope)
        let sessionID = try #require(coordinator.selectedSessionID)
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

    @Test func historicalScopeLabelsRetainFolderNameAndBothDateBounds() async throws {
        let (_, store, _) = try controllerFixture()
        let folder = try store.createFolder(name: "Original project")
        let chat = MeetingChatStore(databaseURL: store.resolvedDatabaseURL)
        let scope = MeetingChatScope(selection: .folder(folder), startDate: Date(timeIntervalSince1970: 1_000), endDateExclusive: Date(timeIntervalSince1970: 2_000))
        let session = try chat.createSession(scope: scope, title: "Scope")
        let turn = try chat.beginTurn(sessionID: session.id, question: "Decisions?", scope: scope, provider: "test", model: "test")
        #expect(turn.scopeLabel?.contains("Original project") == true)
        #expect(turn.scopeLabel?.contains("through") == true)
    }

    @Test func sourceReturnRetainsSessionScrollAnchor() async throws {
        let (controller, _, citation) = try controllerFixture()
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        let coordinator = controller.meetingChatCoordinator
        await coordinator.createChat(scope: coordinator.scope)
        let session = try #require(coordinator.selectedSessionID)
        let anchor = UUID()
        coordinator.scrollAnchors[session] = anchor
        controller.showMeetingChatSource(.init(citation: citation, sessionID: session))
        controller.returnToMeetingChat()
        #expect(coordinator.scrollAnchors[session] == anchor)
    }

    @Test func emptyMeetingDetailDoesNotRequireACitationTarget() async throws {
        let (controller, _, _) = try controllerFixture()
        let view = MeetingDetailView(meeting: nil, controller: controller, appState: controller.appState)
        #expect(view.meeting == nil)
    }

    @Test func historyPanelIgnoresBlankChatsAndTracksLastConversationDeletion() async throws {
        let (controller, _, _) = try controllerFixture()
        let coordinator = controller.meetingChatCoordinator
        #expect(!coordinator.hasChatHistory)
        await coordinator.createChat(scope: .init())
        let session = try #require(coordinator.selectedSessionID)
        #expect(!coordinator.hasChatHistory)
        _ = try coordinator.store.beginTurn(sessionID: session, question: "When is launch?", scope: .init(), provider: "test", model: "test")
        coordinator.reload()
        #expect(coordinator.hasChatHistory)
        await coordinator.createChat(scope: .init())
        #expect(coordinator.hasChatHistory)
        await coordinator.deleteChat(id: session)
        #expect(!coordinator.hasChatHistory)
    }
    @Test func firstComposerAttachmentCreatesScopedChatAndPreservesDraft() async throws {
        let (controller, _, citation) = try controllerFixture()
        let chat = controller.meetingChatCoordinator
        chat.composerDraft = "Compare @Launch with the plan"
        #expect(await chat.addMeetingToScope(id: citation.meetingID))
        #expect(chat.selectedSessionID != nil)
        #expect(chat.scope.selection == .meetings([citation.meetingID]))
        #expect(chat.composerDraft == "Compare @Launch with the plan")
        #expect(chat.sessions.first?.anchorMeetingID == citation.meetingID)
    }

    @Test func composerAttachmentsAccumulateDeduplicateAndRemoveWithoutBroadening() async throws {
        let (controller, store, citation) = try controllerFixture()
        let second = try store.insertMeeting(title: "Review", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "Review the launch", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        let chat = controller.meetingChatCoordinator
        #expect(await chat.addMeetingToScope(id: citation.meetingID))
        let session = try #require(chat.selectedSessionID)
        chat.composerDraft = "What changed?"
        #expect(await chat.addMeetingToScope(id: second))
        #expect(await chat.addMeetingToScope(id: second))
        #expect(chat.scope.selection == .meetings([citation.meetingID, second]))
        #expect(try chat.store.sessions(meetingID: second).map(\.id) == [session])
        #expect(await chat.removeMeetingFromScope(id: citation.meetingID))
        #expect(await chat.removeMeetingFromScope(id: second))
        #expect(chat.scope.selection == .meetings([]))
        #expect(chat.selectedSessionID == session)
        #expect(chat.composerDraft == "What changed?")
        #expect(try chat.store.sourceSnapshots(scope: chat.scope).isEmpty)
    }

    @Test func attachmentReplacesBroadFiltersAndStartsNewHistoryBoundary() async throws {
        let (controller, _, citation) = try controllerFixture()
        let chat = controller.meetingChatCoordinator
        await chat.createChat(scope: .init(selection: .all, startDate: Date().addingTimeInterval(86_400)))
        let session = try #require(chat.selectedSessionID)
        let originalScope = chat.scope
        _ = try chat.store.beginTurn(sessionID: session, question: "Existing question", scope: originalScope, provider: "test", model: "test")
        chat.composerDraft = "Now this meeting"
        #expect(await chat.addMeetingToScope(id: citation.meetingID))
        #expect(chat.scope == .init(selection: .meetings([citation.meetingID])))
        #expect(chat.sessions.first?.contextStartOrdinal == 1)
        #expect(try chat.store.turns(sessionID: session).first?.scope == originalScope)
        #expect(chat.composerDraft == "Now this meeting")
    }

    @Test func staleMeetingAttachmentDoesNotMutateScopeOrDraft() async throws {
        let (controller, store, citation) = try controllerFixture()
        let chat = controller.meetingChatCoordinator
        chat.composerDraft = "Ask @Launch"
        try store.deleteMeeting(id: citation.meetingID)
        #expect(await chat.addMeetingToScope(id: citation.meetingID) == false)
        #expect(chat.selectedSessionID == nil)
        #expect(chat.scope.selection == .meetings([]))
        #expect(chat.composerDraft == "Ask @Launch")
        #expect(chat.errorMessage != nil)
    }

}
