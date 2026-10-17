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
        return (controller, store, try #require(evidence.passages.first { $0.kind == .transcript }?.citation))
    }

    @Test func speakerLoadKeyTracksMeetingPresentationInputs() {
        let initial = MeetingSpeakerLoadKey(
            id: 1,
            transcript: "Transcript",
            notes: "Notes",
            status: .completed,
            summaryFreshnessRevision: 0
        )
        let refreshed = MeetingSpeakerLoadKey(
            id: 1,
            transcript: "Transcript",
            notes: "Notes",
            status: .completed,
            summaryFreshnessRevision: 1
        )

        #expect(initial == MeetingSpeakerLoadKey(
            id: 1,
            transcript: "Transcript",
            notes: "Notes",
            status: .completed,
            summaryFreshnessRevision: 0
        ))
        #expect(initial != MeetingSpeakerLoadKey(
            id: 1,
            transcript: "Changed transcript",
            notes: "Notes",
            status: .completed,
            summaryFreshnessRevision: 0
        ))
        #expect(initial != MeetingSpeakerLoadKey(
            id: 1,
            transcript: "Transcript",
            notes: "Changed notes",
            status: .completed,
            summaryFreshnessRevision: 0
        ))
        #expect(initial != MeetingSpeakerLoadKey(
            id: 1,
            transcript: "Transcript",
            notes: "Notes",
            status: .processing,
            summaryFreshnessRevision: 0
        ))
        #expect(initial != refreshed)
    }

    @Test func summaryFreshnessRevisionsAreScopedToChangedMeetings() {
        let appState = AppState()

        #expect(appState.meetingSummaryFreshnessRevision(for: 1) == 0)
        #expect(appState.meetingSummaryFreshnessRevision(for: 2) == 0)

        appState.noteMeetingSummaryFreshnessChanged(for: [1])

        #expect(appState.meetingSummaryFreshnessRevision(for: 1) == 1)
        #expect(appState.meetingSummaryFreshnessRevision(for: 2) == 0)

        appState.noteMeetingSummaryFreshnessChanged(for: [1, 2])

        #expect(appState.meetingSummaryFreshnessRevision(for: 1) == 2)
        #expect(appState.meetingSummaryFreshnessRevision(for: 2) == 1)

        appState.removeMeetingSummaryFreshnessRevisions(for: [1])
        #expect(appState.meetingSummaryFreshnessRevision(for: 1) == 0)
        #expect(appState.meetingSummaryFreshnessRevision(for: 2) == 1)

        appState.clearMeetingSummaryFreshnessRevisions()
        #expect(appState.meetingSummaryFreshnessRevision(for: 2) == 0)
    }

    @Test func delayedFreshnessNotificationsIgnoreMissingAndDeletedMeetings() {
        let appState = AppState()

        appState.noteMeetingSummaryFreshnessChanged(
            for: [1, 2, 3],
            existingMeetingIDs: [2, 3],
            deletedMeetingIDs: [3]
        )

        #expect(appState.meetingSummaryFreshnessRevision(for: 1) == 0)
        #expect(appState.meetingSummaryFreshnessRevision(for: 2) == 1)
        #expect(appState.meetingSummaryFreshnessRevision(for: 3) == 0)
    }

    @Test func selectedMeetingRemainsInFreshnessObservationSetOutsideBrowserRows() {
        let appState = AppState()
        appState.selectedMeetingID = 42

        #expect(appState.meetingSummaryFreshnessObservedMeetingIDs() == [42])
    }

    @Test func unreadSummaryFreshnessDoesNotCarryBetweenMeetings() {
        var presentation = MeetingSummaryFreshnessPresentationState()

        presentation.update(meetingID: 1, summaryIsStale: true)
        presentation.update(meetingID: 1, summaryIsStale: nil)
        #expect(presentation.isStale)

        presentation.update(meetingID: 2, summaryIsStale: nil)
        #expect(presentation.meetingID == 2)
        #expect(!presentation.isStale)
    }

    @Test func entryUsesSingleMeetingScopeAndReturnPreservesComposer() async throws {
        let (controller, _, citation) = try controllerFixture()
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
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
    @Test func sourceLocatorValidatesOffsetsAndHandlesChangedPassages() async throws {
        let (_, _, citation) = try controllerFixture()
        let target = MeetingChatDocumentTarget(citation: citation, sessionID: UUID())
        #expect(target.locate(in: "[00:00:01] You: Launch Friday.") != nil)
        #expect(target.locate(in: "Unrelated new transcript") == nil)
        #expect(target.locate(in: "Preface\n[00:00:01] You: Launch Friday.")?.location == 8)
    }

    @Test func citationDisplaysDecodeNewLabelsWithoutChangingLookupExcerpt() {
        let stored = MeetingSpeakerState.renderTranscriptTurn(
            timestamp: "00:00:01", speaker: "Team: Example", text: "Ship Friday."
        )
        let citation = MeetingChatCitation(
            sourceKey: "S1", meetingID: 1, title: "Launch", startDate: Date(), kind: .transcript,
            excerpt: stored, range: .init(location: 0, length: (stored as NSString).length),
            timestamp: "00:00:01", revision: "r1"
        )
        let target = MeetingChatDocumentTarget(citation: citation, sessionID: UUID())
        let readable = "[00:00:01] Team: Example: Ship Friday."
        let passage = MeetingChatSourceGroup.Passage(number: 1, citation: citation)

        #expect(MeetingChatDocumentTarget.readableExcerpt(citation.excerpt) == readable)
        #expect(passage.preview == readable)
        #expect(target.locate(in: stored) != nil)
        #expect(citation.excerpt == stored)
    }

    @Test func meetingEntryResumesAnchoredChatAndPreservesAdditionalContext() async throws {
        let (controller, store, citation) = try controllerFixture()
        await controller.showMeetingChat(meetingID: citation.meetingID)?.value
        let chat = controller.meetingChatCoordinator
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

    @Test func syncedRenamedSpeakerLabelsStayOutOfTranscriptSpeech() {
        let messages = TranscriptChatMessage.messages(from: "[00:00:01] Project lead: Let's begin\nProject lead: An unformatted line")

        #expect(messages.count == 2)
        #expect(messages[0].speaker == "Project lead")
        #expect(messages[0].text == "Let's begin")
        #expect(messages[1].speaker == nil)
        #expect(messages[1].text == "Project lead: An unformatted line")
    }

    @Test func structuredTranscriptCitationUsesTurnIDsAcrossEmbeddedNewlines() {
        let epoch = UUID()
        let first = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "first")
        let second = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "second")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: first, rank: 1, fallbackLabel: "Speaker 1"),
                       .init(key: second, rank: 2, fallbackLabel: "Speaker 2")],
            turns: [.init(speaker: first, timestamp: "00:00:01", start: 1, end: 2, text: "A\nB"),
                    .init(speaker: second, timestamp: "00:00:03", start: 3, end: 4, text: "C")])
        let transcript = state.render()
        let bRange = (transcript as NSString).range(of: "B")
        let cRange = (transcript as NSString).range(of: "C")

        let turnRanges = MeetingChatDocumentTarget.transcriptMessageRanges(in: transcript, speakerState: state)
        #expect(MeetingChatDocumentTarget.transcriptMessageID(
            in: transcript,
            range: bRange,
            messageRanges: turnRanges
        ) == 0)
        #expect(MeetingChatDocumentTarget.transcriptMessageID(
            in: transcript,
            range: cRange,
            messageRanges: turnRanges
        ) == 1)

        #expect(MeetingChatDocumentTarget.transcriptMessageID(in: transcript, range: bRange, speakerState: state) == 0)
        #expect(MeetingChatDocumentTarget.transcriptMessageID(in: transcript, range: cRange, speakerState: state) == 1)
    }

    @Test func structuredTranscriptCitationMatchesEscapedColonNames() {
        let epoch = UUID()
        let first = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "first")
        let second = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "second")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: first, rank: 1, fallbackLabel: "Speaker 1",
                             assignment: .init(name: "Team: Example", provenance: .manual)),
                       .init(key: second, rank: 2, fallbackLabel: "Speaker 2")],
            turns: [.init(speaker: first, timestamp: "00:00:01", start: 1, end: 2, text: "First passage"),
                    .init(speaker: second, timestamp: "00:00:03", start: 3, end: 4, text: "Second passage")])
        let transcript = state.render()
        let nsTranscript = transcript as NSString
        let firstRange = nsTranscript.range(of: "First passage")
        let secondRange = nsTranscript.range(of: "Second passage")

        #expect(MeetingChatDocumentTarget.transcriptMessageID(in: transcript, range: firstRange, speakerState: state) == 0)
        #expect(MeetingChatDocumentTarget.transcriptMessageID(in: transcript, range: secondRange, speakerState: state) == 1)
    }

    @Test func legacyTranscriptCitationUsesTurnIDsAcrossEmbeddedNewlines() {
        let epoch = UUID()
        let first = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "first")
        let second = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "second")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: first, rank: 1, fallbackLabel: "Speaker 1",
                             assignment: .init(name: "Team: Example", provenance: .manual)),
                       .init(key: second, rank: 2, fallbackLabel: "Speaker 2")],
            turns: [.init(speaker: first, timestamp: "00:00:01", start: 1, end: 2, text: "A\nB"),
                    .init(speaker: second, timestamp: "00:00:03", start: 3, end: 4, text: "C")])
        let transcript = state.renderLegacy()
        let cRange = (transcript as NSString).range(of: "C")

        #expect(MeetingChatDocumentTarget.transcriptMessageID(in: transcript, range: cRange, speakerState: state) == 1)
        let messages = TranscriptChatMessage.messages(from: transcript, speakerState: state)
        #expect(messages.count == 2)
        #expect(messages[0].speaker == "Team: Example")
        #expect(messages[0].text == "A\nB")
    }

    @Test func transcriptCitationWaitsForItsMessageRowToLoad() {
        let message = TranscriptChatMessage(id: 1, timestamp: nil, speaker: "Speaker 2", text: "Target passage")

        #expect(MeetingChatDocumentTarget.loadedTranscriptScrollTarget(messages: [], highlightedMessageID: 1) == nil)
        #expect(MeetingChatDocumentTarget.loadedTranscriptScrollTarget(messages: [message], highlightedMessageID: 1) == 1)
    }

    @Test func transcriptLoadingIsNotReportedAsMissingContent() {
        #expect(MeetingTranscriptContentState(hasLoaded: false, messageCount: 0) == .loading)
        #expect(MeetingTranscriptContentState(hasLoaded: true, messageCount: 0) == .empty)
        #expect(MeetingTranscriptContentState(hasLoaded: true, messageCount: 1) == .messages)
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
        let session = coordinator.selectedSessionID!
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
        #expect(chat.scope.selection == .all)
        #expect(chat.composerDraft == "Ask @Launch")
        #expect(chat.errorMessage != nil)
    }

}
