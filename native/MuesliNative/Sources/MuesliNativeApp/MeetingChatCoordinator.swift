import Foundation
import Observation
import MuesliCore

actor MeetingChatWorker {
    let store: MeetingChatStore
    let retrieval: MeetingChatRetrieval
    private var summaryValidation: (turnID: UUID, sourceVersion: Int64)?
    init(databaseURL: URL) { store = .init(databaseURL: databaseURL); retrieval = .init(databaseURL: databaseURL) }
    func interruptPendingTurns() throws { try store.interruptPendingTurns() }
    func createChat(scope: MeetingChatScope, expectedSourceVersion: Int64? = nil) throws -> MeetingChatSession { try store.createSession(scope: scope, title: "New chat", expectedSourceVersion: expectedSourceVersion) }
    func updateSession(id: UUID, title: String? = nil, scope: MeetingChatScope? = nil) throws { try store.updateSession(id: id, title: title, scope: scope) }
    func beginTurn(sessionID: UUID, question: String, scope: MeetingChatScope, config: AppConfig, attemptID: UUID) throws -> MeetingChatTurn {
        try store.beginTurn(sessionID: sessionID, question: question, scope: scope,
            provider: MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend).label,
            model: MeetingTextGenerationClient.model(config), attemptID: attemptID)
    }
    func restartTurn(id: UUID, config: AppConfig) throws -> MeetingChatTurn? {
        try store.restartTurn(id: id, provider: MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend).label, model: MeetingTextGenerationClient.model(config))
    }
    func setTurnState(id: UUID, state: MeetingChatTurnState, error: String? = nil, attemptID: UUID?) throws {
        try store.setTurnState(id: id, state: state, error: error, attemptID: attemptID)
    }
    func deleteChat(id: UUID) throws { try store.deleteSession(id: id) }
    /// History for the sidebar/index plus the requested conversation, read off the main actor.
    func history(selecting sessionID: UUID?) throws -> MeetingChatHistorySnapshot {
        let sessions = try store.sessions()
        let hasChatHistory = try store.hasChatHistory()
        let turns = try sessionID.flatMap { id in sessions.contains { $0.id == id } ? id : nil }
            .map { try store.turns(sessionID: $0) } ?? []
        return .init(sessions: sessions, hasChatHistory: hasChatHistory, turns: turns)
    }
    func hasCompletedAnswer(sessionID: UUID) throws -> Bool {
        try store.turns(sessionID: sessionID).contains { $0.state == .completed && $0.originalAnswer != nil }
    }
    func saveDraft(turnID: UUID, text: String) throws { try store.saveDraft(turnID: turnID, text: text) }
    func warmIndex() throws { try retrieval.prepareIndex() }
    func choices() throws -> [MeetingChatSourceChoice] { try store.sourceChoices() }
    func source(_ id: Int64) throws -> MeetingChatSourceSnapshot? { try store.sourceSnapshots(scope: .init(selection: .meetings([id]))).first }
    func rollingSummary(for turn: MeetingChatTurn) throws -> MeetingChatRollingSummary? {
        try store.rollingSummary(before: turn)
    }
    func saveRollingSummary(_ text: String, coveredTurns: [MeetingChatTurn], turn: MeetingChatTurn) throws -> Bool {
        try store.saveRollingSummary(text: text, coveredTurns: coveredTurns, for: turn)
    }
    func evidence(for turn: MeetingChatTurn) throws -> (MeetingChatEvidence, [MeetingChatTurn]) {
        try Task.checkCancellation()
        let context = try store.historyContext(before: turn)
        let history = context.turns
        // Prior conversation can be transformed without re-reading meetings. Start with
        // no source packet and let the model explicitly search the current scope if it
        // needs new facts. Removing a meeting affects retrieval, not validated history.
        let explicitlyEmpty: Bool
        if case .meetings(let ids) = turn.scope.selection { explicitlyEmpty = ids.isEmpty } else { explicitlyEmpty = false }
        if !history.isEmpty || explicitlyEmpty {
            let eligible = explicitlyEmpty ? [] : try store.sourceChoices().filter { source in
                switch turn.scope.selection {
                case .all: break
                case .folder(let id): if source.folderID != id { return false }
                case .meetings(let ids): if !ids.contains(source.id) { return false }
                }
                return (turn.scope.startDate == nil || source.startDate >= turn.scope.startDate!) &&
                    (turn.scope.endDateExclusive == nil || source.startDate < turn.scope.endDateExclusive!)
            }
            let evidence = MeetingChatEvidence(scope: turn.scope, passages: [], dependencies: context.dependencies,
                coverage: .init(eligibleMeetingCount: eligible.count, evidenceMeetingCount: 0, isPartialRecap: false))
            try store.attachEvidence(turnID: turn.id, dependencies: context.dependencies, attemptID: turn.attemptID)
            return (evidence, history)
        }
        let broadIntent = ["recap", "summar", "decisions", "decide", "next steps", "action items", "follow-up"].contains { turn.question.localizedCaseInsensitiveContains($0) }
        // Every question gets lexical relevance first. Broad vocabulary never disables a topic match.
        let attachedContext: Bool
        if case .meetings(let ids) = turn.scope.selection { attachedContext = !ids.isEmpty } else { attachedContext = false }
        var evidence = try retrieval.retrieve(question: turn.question, scope: turn.scope, priorQuestions: history.map(\.question), includeScopeContext: attachedContext)
        if broadIntent && !attachedContext {
            let representative = try retrieval.retrieve(question: turn.question, scope: turn.scope, broadRecap: true)
            var selected: [MeetingChatPassage] = []; var seen = Set<String>(); var bytes = 0; var packetBytes = 0
            for var passage in evidence.passages where bytes + passage.excerpt.utf8.count <= 6_000 {
                passage.sourceKey = "S\(selected.count + 1)"
                let footprint = MeetingChatPassages.promptByteCount(passage)
                if packetBytes + footprint <= 5_000, seen.insert(passage.id).inserted {
                    selected.append(passage); bytes += passage.excerpt.utf8.count; packetBytes += footprint
                }
            }
            for var passage in representative.passages where bytes + passage.excerpt.utf8.count <= 12_000 {
                passage.sourceKey = "S\(selected.count + 1)"
                let footprint = MeetingChatPassages.promptByteCount(passage)
                if packetBytes + footprint <= 10_000, seen.insert(passage.id).inserted {
                    selected.append(passage); bytes += passage.excerpt.utf8.count; packetBytes += footprint
                }
            }
            for index in selected.indices { selected[index].sourceKey = "S\(index + 1)" }
            let represented = Set(selected.map(\.meetingID))
            evidence = .init(scope: turn.scope, passages: selected,
                dependencies: Array(Set(selected.map { MeetingChatDependency(meetingID: $0.meetingID, revision: $0.revision) })),
                coverage: .init(eligibleMeetingCount: representative.coverage.eligibleMeetingCount, evidenceMeetingCount: represented.count,
                    isPartialRecap: representative.coverage.isPartialRecap || representative.passages.contains { passage in !selected.contains { $0.id == passage.id } }),
                metrics: .init(sourceSnapshotCount: evidence.metrics.sourceSnapshotCount + representative.metrics.sourceSnapshotCount,
                    reindexedMeetingCount: evidence.metrics.reindexedMeetingCount + representative.metrics.reindexedMeetingCount,
                    decodedCandidateCount: evidence.metrics.decodedCandidateCount + representative.metrics.decodedCandidateCount))
        }
        try store.attachEvidence(turnID: turn.id, dependencies: evidence.dependencies, attemptID: turn.attemptID)
        return (evidence, history)
    }
    func execute(_ call: MeetingChatToolCall, turn: MeetingChatTurn, evidence: MeetingChatEvidence, nextSourceKey: Int, native: Bool = false) throws -> (MeetingChatEvidence, Int, Int, Int?) {
        try Task.checkCancellation()
        guard try store.dependenciesAreCurrent(evidence.dependencies) else { throw MeetingChatError.sourceChanged }
        let incoming: [MeetingChatPassage]
        var incomingIsPartialRecap = false
        var nextPage: Int?
        switch call {
        case .search(let query):
            let retrieved = try retrieval.retrieve(question: query, scope: turn.scope)
            incoming = retrieved.passages
            incomingIsPartialRecap = retrieved.coverage.isPartialRecap
        case .browse:
            let retrieved = try retrieval.retrieve(question: turn.question, scope: turn.scope, broadRecap: true)
            incoming = retrieved.passages
            incomingIsPartialRecap = retrieved.coverage.isPartialRecap
        case .read(let key):
            guard let passage = evidence.passages.first(where: { $0.sourceKey == key }),
                let snapshot = try scopedSource(passage.meetingID, scope: turn.scope), snapshot.revision == passage.revision else { throw MeetingChatError.sourceChanged }
            // The capability is an issued source marker, never a model-supplied meeting ID.
            let sameKind = MeetingChatPassages.extract(from: snapshot).filter { $0.kind == passage.kind }
            guard let index = sameKind.firstIndex(where: { $0.id == passage.id }) else { throw MeetingChatError.sourceChanged }
            incoming = Array(sameKind[max(0, index - 2)...min(sameKind.count - 1, index + 2)])
        case .readMeeting(let meetingID, let page):
            guard native else { throw MeetingChatError.invalidResponse }
            guard let snapshot = try scopedSource(meetingID, scope: turn.scope) else { throw MeetingChatError.sourceChanged }
            let pageResult = try Self.meetingPage(snapshot, page: page)
            incoming = pageResult.passages
            nextPage = pageResult.nextPage
            incomingIsPartialRecap = nextPage != nil || page > 0
        }
        var result = evidence
        var selected: [MeetingChatPassage] = []
        var seen = Set<String>(); var bytes = 0
        var nextKey = nextSourceKey
        var omittedForBudget = false
        // An empty refinement does not erase evidence already gathered.
        for var passage in incoming + evidence.passages {
            guard seen.insert(passage.id).inserted else { continue }
            passage.sourceKey = evidence.passages.first(where: { $0.id == passage.id })?.sourceKey ?? "S\(nextKey)"
            let size = MeetingChatPassages.promptByteCount(passage)
            guard bytes + size <= (native ? 200_000 : 10_000) else {
                // A native tool result must never quietly discard earlier pages
                // or claim to have read a full page that the model cannot see.
                if native { throw MeetingChatError.promptTooLarge }
                omittedForBudget = true; continue
            }
            if !evidence.passages.contains(where: { $0.id == passage.id }) { nextKey += 1 }
            bytes += size; selected.append(passage)
        }
        result.passages = selected
        result.dependencies = Array(Set(evidence.dependencies + selected.map { .init(meetingID: $0.meetingID, revision: $0.revision) }))
        result.coverage.evidenceMeetingCount = Set(selected.map(\.meetingID)).count
        // A focused search need not match every eligible meeting. Preserve the
        // retriever's completeness assessment and record actual packet eviction.
        result.coverage.isPartialRecap = evidence.coverage.isPartialRecap || incomingIsPartialRecap || omittedForBudget
        // Attach before the next network call so deletion invalidates every source already disclosed.
        try store.attachEvidence(turnID: turn.id, dependencies: result.dependencies, attemptID: turn.attemptID)
        return (result, nextKey, incoming.count, nextPage)
    }
    private func scopedSource(_ id: Int64, scope: MeetingChatScope) throws -> MeetingChatSourceSnapshot? {
        if case .meetings(let ids) = scope.selection, !ids.contains(id) { return nil }
        let selected = MeetingChatScope(selection: .meetings([id]), startDate: scope.startDate, endDateExclusive: scope.endDateExclusive)
        guard let snapshot = try store.sourceSnapshots(scope: selected).first else { return nil }
        if case .folder(let folderID) = scope.selection, snapshot.folderID != folderID { return nil }
        return snapshot
    }
    /// Stable pages cover every source kind in original order with exact ranges.
    /// Page boundaries reserve room for issued source markers before serialization.
    static func meetingPage(_ source: MeetingChatSourceSnapshot, page: Int) throws -> (passages: [MeetingChatPassage], nextPage: Int?) {
        guard (0..<10_000).contains(page) else { throw MeetingChatError.invalidResponse }
        var currentPage = 0
        var selected: [MeetingChatPassage] = []
        var bytes = 0
        for passage in MeetingChatPassages.extract(from: source) {
            try Task.checkCancellation()
            let size = MeetingChatPassages.promptByteCount(passage) + 16
            guard size <= 40_000 else { throw MeetingChatError.promptTooLarge }
            if bytes + size > 40_000 {
                if currentPage == page { return (selected, page + 1) }
                currentPage += 1
                bytes = 0
            }
            if currentPage == page { selected.append(passage) }
            bytes += size
        }
        guard currentPage == page else { throw MeetingChatError.invalidResponse }
        return (selected, nil)
    }
    func canPublishSummary(turn: MeetingChatTurn) throws -> Bool {
        guard let current = try store.turns(sessionID: turn.sessionID).first(where: { $0.id == turn.id }),
              current.state.isPending, current.attemptID == turn.attemptID else { return false }
        let version = try store.sourceMutationVersion()
        if summaryValidation?.turnID == turn.id, summaryValidation?.sourceVersion == version { return true }
        guard try store.dependenciesAreCurrent(store.dependencies(turnID: turn.id)) else { return false }
        summaryValidation = (turn.id, version)
        return true
    }
    func titleContext(turn: MeetingChatTurn) throws -> (question: String, answer: String)? {
        guard let session = try store.sessions().first(where: { $0.id == turn.sessionID }),
              session.titleIsAutomatic == true, session.generatedTitleTurnID == nil,
              session.scope == turn.scope, turn.ordinal >= session.contextStartOrdinal,
              let latest = try store.turns(sessionID: turn.sessionID).last,
              latest.id == turn.id, latest.attemptID == turn.attemptID, latest.state == .completed,
              let answer = latest.originalAnswer,
              try store.dependenciesAreCurrent(store.dependencies(turnID: turn.id)) else { return nil }
        return (latest.question, answer)
    }
    func saveTitle(turn: MeetingChatTurn, title: String) throws -> Bool {
        guard let attemptID = turn.attemptID else { return false }
        return try store.updateTitleIfAutomatic(turnID: turn.id, attemptID: attemptID, title: title)
    }
    func finish(turn: MeetingChatTurn, answer: MeetingChatAnswer, dependencies: [MeetingChatDependency], isDraft: Bool) throws -> Bool {
        try store.finishTurn(turnID: turn.id, answer: answer.markdown, citations: answer.citations, dependencies: dependencies, coverage: answer.coverage, isDraft: isDraft, attemptID: turn.attemptID)
    }
}

struct MeetingChatHistorySnapshot: Sendable {
    let sessions: [MeetingChatSession]
    let hasChatHistory: Bool
    let turns: [MeetingChatTurn]
}

/// A rename or delete awaiting the worker. The row stays visible but inert until it settles.
enum MeetingChatPendingMutation: Equatable {
    case renaming, deleting
}

@MainActor @Observable
final class MeetingChatCoordinator {
    let store: MeetingChatStore
    @ObservationIgnored private let worker: MeetingChatWorker
    @ObservationIgnored private let generator: any MeetingTextGenerating
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var titleTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var titleAttempts: [UUID: UUID] = [:]
    @ObservationIgnored private var initialization: Task<Void, Never>?
    /// Each history read gets a generation; only the newest may publish, so a slow
    /// read for an earlier selection can never revert later navigation.
    @ObservationIgnored private var historyGeneration = 0
    @ObservationIgnored private var historyLoad: Task<Void, Never>?
    @ObservationIgnored private var activitySessionID: UUID?
    private var selectionVersion = UUID()
    private(set) var sessions: [MeetingChatSession] = []
    private(set) var hasChatHistory = false
    private(set) var turns: [MeetingChatTurn] = []
    /// The conversation whose turns `turns` holds; differs from the selection while it loads.
    private(set) var turnsSessionID: UUID?
    private var historyReadFailed = false
    private(set) var pendingChatMutations: [UUID: MeetingChatPendingMutation] = [:]
    var isLoadingConversation: Bool { selectedSessionID != nil && turnsSessionID != selectedSessionID }
    private(set) var selectedSessionID: UUID?
    private(set) var activeRequestID: UUID?
    private(set) var activeTurnID: UUID?
    private var activeSessionID: UUID?
    private(set) var phase = ""
    private(set) var activities: [MeetingChatActivity] = []
    private(set) var reasoningIsStreaming = false
    private(set) var reasoningSummaries: [String] = []
    private(set) var activityTurnID: UUID?
    private var composerDrafts: [UUID?: String] = [:]
    private var composerEditVersion = UUID()
    private var untitledComposerUndoIdentity = UUID()
    private var composerUndoIdentities: [UUID: UUID] = [:]
    var composerUndoIdentity: UUID {
        guard let id = selectedSessionID else { return untitledComposerUndoIdentity }
        return composerUndoIdentities[id] ?? id
    }
    private func transferUntitledComposerUndoIdentity(to sessionID: UUID) {
        composerUndoIdentities[sessionID] = untitledComposerUndoIdentity
        untitledComposerUndoIdentity = UUID()
    }
    var composerDraft: String {
        get { composerDrafts[selectedSessionID] ?? "" }
        set { composerDrafts[selectedSessionID] = newValue; composerEditVersion = UUID() }
    }
    var errorMessage: String?
    var scrollAnchors: [UUID: UUID] = [:]
    private(set) var sourceMutationVersion: Int64 = 0
    private(set) var sourceChoices: [MeetingChatSourceChoice] = []
    private var draftScope = MeetingChatScope()
    var scope: MeetingChatScope { sessions.first { $0.id == selectedSessionID }?.scope ?? draftScope }

    /// Return to the index without discarding per-conversation drafts or stopping a response.
    func showIndex() {
        selectionVersion = UUID()
        selectedSessionID = nil
        turns = []; turnsSessionID = nil
        errorMessage = nil
    }

    /// Opening a composer is not a persisted conversation. The first send registers it.
    func startDraft(scope: MeetingChatScope = .init()) {
        guard !isBusy, !isUpdatingChat else { return }
        selectionVersion = UUID()
        selectedSessionID = nil
        turns = []; turnsSessionID = nil
        draftScope = scope
        composerDraft = ""
        untitledComposerUndoIdentity = UUID()
        errorMessage = nil
    }

    /// Browsing notes may seed an unused draft, never retarget an existing conversation.
    func prepareMeetingDraft(id: Int64) {
        guard selectedSessionID == nil, composerDraft.isEmpty, !isBusy, !isUpdatingChat else { return }
        draftScope = .init(selection: .meetings([id]))
    }
    var isBusy: Bool { activeRequestID != nil }
    private(set) var isUpdatingChat = false

    init(databaseURL: URL, generator: any MeetingTextGenerating = MeetingTextGenerationClient()) {
        store = .init(databaseURL: databaseURL); worker = .init(databaseURL: databaseURL); self.generator = generator
        reload()
        sourceMutationVersion = (try? store.sourceMutationVersion()) ?? 0
        let worker = worker
        initialization = Task {
            do { try await worker.interruptPendingTurns(); await refreshHistory() }
            catch { errorMessage = "Could not recover meeting chat history." }
        }
        Task {
            await initialization?.value
            do { sourceChoices = try await worker.choices() }
            catch { errorMessage = "Could not prepare meeting search. Retry by asking a question." }
        }
    }
    /// Synchronous read for construction and source invalidation, where deleted evidence must
    /// disappear before the caller returns. Navigation and chat mutations use `refreshHistory`.
    func reload() {
        // This read is newer than any worker read still in flight.
        historyGeneration &+= 1
        let requested = selectedSessionID
        do {
            let sessions = try store.sessions()
            let hasChatHistory = try store.hasChatHistory()
            let turns = try requested.flatMap { id in sessions.contains { $0.id == id } ? id : nil }
                .map { try store.turns(sessionID: $0) } ?? []
            publishHistory(.init(sessions: sessions, hasChatHistory: hasChatHistory, turns: turns), requested: requested)
        } catch { failHistoryLoad(requested: requested) }
    }
    /// Reads history on the worker and returns once the newest scheduled read has published.
    func refreshHistory() async {
        scheduleHistoryReload()
        await settleHistory()
    }
    private func settleHistory() async {
        var observed = -1
        while observed != historyGeneration {
            observed = historyGeneration
            await historyLoad?.value
        }
    }
    private func scheduleHistoryReload() {
        historyGeneration &+= 1
        let generation = historyGeneration
        let requested = selectedSessionID
        let worker = worker
        historyLoad = Task { [weak self] in
            let snapshot: MeetingChatHistorySnapshot?
            do { snapshot = try await worker.history(selecting: requested) } catch { snapshot = nil }
            guard let self, self.historyGeneration == generation else { return }
            if let snapshot { self.publishHistory(snapshot, requested: requested) }
            else { self.failHistoryLoad(requested: requested) }
        }
    }
    private func publishHistory(_ snapshot: MeetingChatHistorySnapshot, requested: UUID?) {
        sessions = snapshot.sessions
        hasChatHistory = snapshot.hasChatHistory
        let sessionIDs = Set(sessions.map(\.id))
        composerDrafts = composerDrafts.filter { $0.key == nil || sessionIDs.contains($0.key!) }
        // Navigation that moved on without a read keeps its own (already reset) turns.
        guard selectedSessionID == requested else { return }
        historyReadFailed = false
        if errorMessage == Self.historyReadError || errorMessage == Self.previousAnswersReadError { errorMessage = nil }
        if let id = requested, sessionIDs.contains(id) { turns = snapshot.turns; turnsSessionID = id }
        else { selectedSessionID = nil; turns = []; turnsSessionID = nil }
    }
    private func failHistoryLoad(requested: UUID?) {
        // Index/new-draft navigation may intentionally skip another read. An error
        // from the conversation we left must not appear in that new composer.
        guard selectedSessionID == requested else { return }
        historyReadFailed = true
        errorMessage = Self.historyReadError
        // End the loading state; the conversation stays selected so the user can retry.
        if turnsSessionID != requested { turns = []; turnsSessionID = requested }
    }
    @discardableResult
    func createChat(scope: MeetingChatScope) async -> UUID? {
        guard !isUpdatingChat else { return nil }
        isUpdatingChat = true
        defer { isUpdatingChat = false }
        let version = UUID(); selectionVersion = version
        do {
            let expectedSourceVersion = try store.sourceMutationVersion()
            await initialization?.value
            guard selectionVersion == version, !Task.isCancelled else { return nil }
            let session = try await worker.createChat(scope: scope, expectedSourceVersion: expectedSourceVersion)
            if selectionVersion == version { showCreatedSession(session.id); errorMessage = nil }
            await refreshHistory()
            return session.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    /// A session registered moments ago has no turns, so it is shown without a load.
    private func showCreatedSession(_ id: UUID) {
        selectedSessionID = id; turns = []; turnsSessionID = id
    }
    /// Selection is immediate; the conversation's turns load on the worker. Drafts and scope
    /// are keyed by selection and remain available while it loads.
    func selectChat(id: UUID) {
        guard pendingChatMutations[id] != .deleting else { return }
        selectionVersion = UUID(); errorMessage = nil
        if selectedSessionID != id {
            selectedSessionID = id
            turns = []; turnsSessionID = nil
        }
        scheduleHistoryReload()
    }
    @discardableResult
    func setScope(_ newScope: MeetingChatScope) async -> UUID? {
        if selectedSessionID == nil {
            guard let id = await createChat(scope: newScope) else { return nil }
            adoptUntitledComposerDraft(sessionID: id)
            return id
        }
        guard let id = selectedSessionID, !isUpdatingChat else { return nil }
        isUpdatingChat = true
        defer { isUpdatingChat = false }
        do { try await worker.updateSession(id: id, scope: newScope); await refreshHistory(); return id }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    /// Composer attachments are an explicit scope, never a hint that can widen retrieval.
    @discardableResult
    func addMeetingToScope(id: Int64) async -> Bool {
        await updateMeetingAttachment(id: id, adding: true)
    }
    @discardableResult
    func removeMeetingFromScope(id: Int64) async -> Bool {
        await updateMeetingAttachment(id: id, adding: false)
    }
    private func updateMeetingAttachment(id: Int64, adding: Bool) async -> Bool {
        guard !isBusy, !isUpdatingChat else { return false }
        let target = selectedSessionID
        let expectedSourceVersion: Int64
        do { expectedSourceVersion = try store.sourceMutationVersion() }
        catch { errorMessage = error.localizedDescription; return false }
        let version = selectionVersion
        var attached: [Int64] = []
        if case .meetings(let ids) = scope.selection { attached = ids }
        if !adding && !attached.contains(id) { return false }
        var newScope = scope
        if adding {
            if !attached.contains(id) { attached.append(id) }
            // A chosen meeting must not remain hidden behind an old date filter.
            newScope.startDate = nil; newScope.endDateExclusive = nil
        } else { attached.removeAll { $0 == id } }
        newScope.selection = .meetings(attached)
        isUpdatingChat = true
        defer { isUpdatingChat = false }
        await initialization?.value
        guard selectionVersion == version, !Task.isCancelled else { return false }
        do {
            if adding {
                guard let source = try await worker.source(id),
                      !(source.transcript + source.manualNotes + source.generatedNotes).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "This meeting is no longer available for chat."
                    return false
                }
            }
            guard selectionVersion == version, !Task.isCancelled else { return false }
            if let target {
                try await worker.updateSession(id: target, scope: newScope)
            } else {
                let session = try await worker.createChat(scope: newScope, expectedSourceVersion: expectedSourceVersion)
                // Preserve the untitled composer's latest edits while registration awaits.
                if selectionVersion == version {
                    composerDrafts[session.id] = composerDrafts[nil]
                    composerDrafts[nil] = nil
                    transferUntitledComposerUndoIdentity(to: session.id)
                    showCreatedSession(session.id)
                }
            }
            await refreshHistory()
            guard selectionVersion == version, !Task.isCancelled else { return false }
            errorMessage = nil
            return true
        } catch {
            if selectionVersion == version { errorMessage = error.localizedDescription }
            return false
        }
    }
    func applyPreparedPrompt(_ prompt: MeetingChatPreparedPrompt) async -> Bool {
        let editVersion = composerEditVersion
        let target: UUID?
        if prompt.scope != scope {
            guard let id = await setScope(prompt.scope) else { return false }
            target = id
        } else { target = selectedSessionID }
        guard selectedSessionID == target else { return false }
        // setScope already transfers any edits made during registration.
        guard composerEditVersion == editVersion else { return false }
        composerDraft = prompt.text
        return true
    }
    /// One rename or delete per chat at a time; repeats while the worker is busy are ignored.
    func renameChat(id: UUID, title: String) async {
        guard pendingChatMutations[id] == nil else { return }
        pendingChatMutations[id] = .renaming
        defer { pendingChatMutations[id] = nil }
        cancelTitle(sessionID: id)
        do { try await worker.updateSession(id: id, title: title); await refreshHistory() } catch { errorMessage = error.localizedDescription }
    }
    private static let historyReadError = "Could not load meeting chat history."
    private static let previousAnswersReadError = "Could not read this chat’s previous answers. Please retry. Your question is still in the composer."
    private static let emptyScopeMessage = "Attach a meeting or choose All saved meetings before sending. Your question is still in the composer."
    func send(question: String, config: AppConfig, isDraft: Bool = false, contextWindowTokens: Int? = nil) async {
        guard !isBusy, !isUpdatingChat else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard question.count <= 2_000 else { errorMessage = MeetingChatError.questionTooLong.localizedDescription; return }
        let requestScope = scope
        var explicitlyEmpty = false
        if case .meetings(let ids) = requestScope.selection, ids.isEmpty { explicitlyEmpty = true }
        // Turns decide whether an empty selection is a valid follow-up. When they have not
        // loaded yet, the worker answers below after the request is reserved.
        let historyLoaded = turnsSessionID == selectedSessionID && (selectedSessionID == nil || !historyReadFailed)
        if explicitlyEmpty, historyLoaded,
           !turns.contains(where: { $0.state == .completed && $0.originalAnswer != nil }) {
            errorMessage = Self.emptyScopeMessage
            return
        }
        let requestID = UUID()
        activeRequestID = requestID; phase = "Saving question"
        reasoningSummaries = []; activityTurnID = nil
        let draftKey = selectedSessionID; let submittedDraft = composerDraft
        activeSessionID = draftKey
        defer {
            if activeRequestID == requestID, tasks[requestID] == nil {
                activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = ""
            }
        }
        if explicitlyEmpty, !historyLoaded, let draftKey {
            do {
                let answered = try await worker.hasCompletedAnswer(sessionID: draftKey)
                guard activeRequestID == requestID, !Task.isCancelled else { return }
                guard answered else { errorMessage = Self.emptyScopeMessage; return }
            } catch {
                guard activeRequestID == requestID, !Task.isCancelled else { return }
                errorMessage = Self.previousAnswersReadError
                return
            }
        }
        await initialization?.value
        guard activeRequestID == requestID, !Task.isCancelled else { return }
        var requestSessionID = draftKey
        var submittedDraftKey = draftKey
        if requestSessionID == nil {
            guard selectedSessionID == nil else { return }
            requestSessionID = await createChat(scope: requestScope)
            if let id = requestSessionID {
                submittedDraftKey = id
                // An implicit first send turns the untitled composer into this chat.
                // Move its latest text, including edits or a Stop during registration.
                adoptUntitledComposerDraft(sessionID: id)
            }
        }
        guard activeRequestID == requestID, !Task.isCancelled, let id = requestSessionID else { return }
        activeSessionID = id
        do {
            let requestConfig = config
            let turn = try await worker.beginTurn(sessionID: id, question: question, scope: requestScope, config: requestConfig, attemptID: requestID)
            guard activeRequestID == requestID, !Task.isCancelled else {
                try? await worker.setTurnState(id: turn.id, state: .stopped, attemptID: requestID)
                await refreshHistory(); return
            }
            activeTurnID = turn.id
            guard activeRequestID == requestID, !Task.isCancelled else {
                try? await worker.setTurnState(id: turn.id, state: .stopped, attemptID: requestID)
                await refreshHistory(); return
            }
            // An accepted send is an undo boundary even if the user started a new draft while saving.
            composerUndoIdentities[id] = UUID()
            if composerDrafts[submittedDraftKey] == submittedDraft, submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines) == question { composerDrafts[submittedDraftKey] = nil }
            // Launch takes request ownership before the history read yields.
            errorMessage = nil; launch(turn, config: requestConfig, isDraft: isDraft, contextWindowTokens: contextWindowTokens)
            // Publish the already-persisted turn without waiting behind retrieval.
            // launch first owns cancellation if observation triggers Stop here.
            if selectedSessionID == id, turnsSessionID == id, !turns.contains(where: { $0.id == turn.id }) {
                turns.append(turn)
            }
            await refreshHistory()
        } catch {
            guard activeRequestID == requestID else { return }
            if let turnID = activeTurnID { try? await worker.setTurnState(id: turnID, state: .failed, error: error.localizedDescription, attemptID: requestID) }
            guard activeRequestID == requestID else { return }
            activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = ""
            errorMessage = error.localizedDescription; await refreshHistory()
        }
    }
    /// Registration may finish after refresh invalidated its selection ownership.
    /// Only the session actually showing the composer may take its unsent text.
    func adoptUntitledComposerDraft(sessionID: UUID) {
        guard selectedSessionID == sessionID, composerDrafts[sessionID] == nil else { return }
        composerDrafts[sessionID] = composerDrafts[nil]
        composerDrafts[nil] = nil
        transferUntitledComposerUndoIdentity(to: sessionID)
    }
    func retry(turnID: UUID, config: AppConfig, contextWindowTokens: Int? = nil) async {
        guard !isBusy, !isUpdatingChat else { return }
        if let previous = turns.first(where: { $0.id == turnID }), case .meetings(let ids) = previous.scope.selection, ids.isEmpty,
           !turns.contains(where: { $0.ordinal < previous.ordinal && $0.state == .completed && $0.originalAnswer != nil }) {
            errorMessage = "This question had no meetings attached. Attach a meeting or choose All saved meetings, then send the question again."
            return
        }
        let reservation = UUID(); activeRequestID = reservation; phase = "Saving question"
        reasoningSummaries = []; activityTurnID = nil
        activeSessionID = turns.first(where: { $0.id == turnID })?.sessionID
        defer {
            if activeRequestID == reservation { activeRequestID = nil; activeSessionID = nil; phase = "" }
        }
        do {
            let requestConfig = config
            guard let turn = try await worker.restartTurn(id: turnID, config: requestConfig) else {
                if activeRequestID == reservation { activeRequestID = nil; phase = "" }; return
            }
            guard activeRequestID == reservation, !Task.isCancelled else {
                try? await worker.setTurnState(id: turn.id, state: .stopped, attemptID: turn.attemptID)
                await refreshHistory(); return
            }
            launch(turn, config: requestConfig, isDraft: turn.isDraft, contextWindowTokens: contextWindowTokens)
            await refreshHistory()
        } catch {
            if activeRequestID == reservation { activeRequestID = nil; phase = ""; errorMessage = error.localizedDescription }
        }
    }
    private func launch(_ turn: MeetingChatTurn, config: AppConfig, isDraft: Bool, contextWindowTokens: Int? = nil) {
        cancelTitle(sessionID: turn.sessionID)
        let requestID = turn.attemptID ?? UUID(); activeRequestID = requestID; activeTurnID = turn.id; activeSessionID = turn.sessionID; phase = "Finding meeting context"
        activities = []; reasoningSummaries = []; reasoningIsStreaming = false; activityTurnID = turn.id; activitySessionID = turn.sessionID
        let worker = worker; let generator = generator
        tasks[requestID] = Task {
            defer {
                tasks.removeValue(forKey: requestID)
                if activeRequestID == requestID { activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = ""; reasoningIsStreaming = false }
                scheduleHistoryReload()
            }
            do {
                let (evidence, history) = try await worker.evidence(for: turn)
                let budget = MeetingChatContextBudget(config: config, contextWindowTokens: contextWindowTokens)
                let savedSummary = try await worker.rollingSummary(for: turn)
                let plan = budget.plan(history: history, existingSummaryThroughOrdinal: savedSummary?.throughOrdinal)
                var rollingSummary = savedSummary?.text
                if !plan.olderTurns.isEmpty || rollingSummary.map({ MeetingChatContextBudget.estimateTokens($0) > budget.summaryTokens }) == true {
                    phase = "Updating conversation memory"
                    rollingSummary = try await budget.summarize(olderTurns: plan.olderTurns, previousSummary: rollingSummary,
                        config: config, sessionID: turn.sessionID, generator: generator, validateContext: {
                            guard try await worker.canPublishSummary(turn: turn) else { throw MeetingChatError.sourceChanged }
                        })
                    try Task.checkCancellation()
                    guard activeRequestID == requestID, let summary = rollingSummary else { return }
                    let through = plan.olderTurns.last?.ordinal ?? savedSummary?.throughOrdinal ?? -1
                    let covered = history.filter { $0.ordinal <= through }
                    guard try await worker.saveRollingSummary(summary, coveredTurns: covered, turn: turn) else { throw MeetingChatError.sourceChanged }
                }
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                phase = "Writing answer"
                var nextSourceKey = (evidence.passages.compactMap { Int($0.sourceKey.dropFirst()) }.max() ?? 0) + 1
                let (answer, finalEvidence) = try await MeetingChatClient.run(question: turn.question,
                    evidence: evidence, history: plan.recentTurns, config: config, sessionID: turn.sessionID, generator: generator,
                    execute: { call, current in
                        try Task.checkCancellation()
                        let (result, next, count, nextPage) = try await worker.execute(call, turn: turn, evidence: current, nextSourceKey: nextSourceKey, native: generator.supportsNativeTools(config: config))
                        nextSourceKey = next
                        if self.activeRequestID == requestID, let index = self.activities.indices.last {
                            self.activities[index].output = "\(count) passages returned · \(result.coverage.evidenceMeetingCount) meetings in the current source packet"
                        }
                        return MeetingChatToolResult(evidence: result, matchedPassageCount: count, nextPage: nextPage)
                    }, activity: { call, completed in
                        guard self.activeRequestID == requestID else { return }
                        self.reasoningIsStreaming = false
                        if completed {
                            if let index = self.activities.indices.last { self.activities[index].state = .completed }
                            self.phase = "Writing answer"
                        } else {
                            self.activities.append(.init(title: call.title, detail: call.detail, state: .running))
                            self.phase = call.title
                        }
                    }, progress: { phase in
                        guard self.activeRequestID == requestID else { return }
                        self.reasoningIsStreaming = false
                        self.phase = phase
                    }, rollingSummary: rollingSummary, contextBudget: budget, reasoningSummary: { [weak self] iteration, summary in
                        guard let self, self.activeRequestID == requestID, !Task.isCancelled else { return }
                        // Summaries contain meeting data too. Check persisted invalidation before
                        // displaying a delta, even when the UI has not yet refreshed after deletion.
                        let valid = (try? await worker.canPublishSummary(turn: turn)) == true
                        guard self.activeRequestID == requestID, !Task.isCancelled else { return }
                        guard valid else { self.reasoningSummaries = []; self.stop(); return }
                        while self.reasoningSummaries.count <= iteration { self.reasoningSummaries.append("") }
                        self.reasoningIsStreaming = true
                        self.reasoningSummaries[iteration] = summary
                        self.phase = "Preparing answer"
                    })
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                guard try await worker.finish(turn: turn, answer: answer, dependencies: finalEvidence.dependencies, isDraft: isDraft) else { throw MeetingChatError.sourceChanged }
                guard activeRequestID == requestID, !Task.isCancelled else { return }
                if !answer.insufficientEvidence { scheduleTitle(turn: turn, config: config) }
            } catch {
                guard activeRequestID == requestID else { return }
                let stopped = Task.isCancelled || error is CancellationError
                let message = stopped ? nil : Self.failureMessage(error)
                reasoningIsStreaming = false
                for index in activities.indices where activities[index].state == .running {
                    activities[index].state = stopped ? .cancelled : .failed
                    activities[index].error = message
                }
                try? await worker.setTurnState(id: turn.id, state: stopped ? .stopped : .failed, error: message, attemptID: turn.attemptID)
            }
        }
    }
    private func cancelTitle(sessionID: UUID) {
        titleTasks.removeValue(forKey: sessionID)?.cancel()
        titleAttempts.removeValue(forKey: sessionID)
    }
    private func scheduleTitle(turn: MeetingChatTurn, config: AppConfig) {
        cancelTitle(sessionID: turn.sessionID)
        let token = UUID(); titleAttempts[turn.sessionID] = token
        let worker = worker; let generator = generator
        titleTasks[turn.sessionID] = Task { [weak self] in
            defer {
                if let self, self.titleAttempts[turn.sessionID] == token {
                    self.titleTasks.removeValue(forKey: turn.sessionID)
                    self.titleAttempts.removeValue(forKey: turn.sessionID)
                }
            }
            do {
                guard let exchange = try await worker.titleContext(turn: turn) else { return }
                try Task.checkCancellation()
                let request = try MeetingChatClient.conversationTitleRequest(question: exchange.question, answer: exchange.answer, config: config, sessionID: turn.sessionID)
                guard let raw = try await generator.generateConversationTitle(request),
                      let title = MeetingChatClient.validatedConversationTitle(raw) else { return }
                try Task.checkCancellation()
                guard let self, self.titleAttempts[turn.sessionID] == token else { return }
                if try await worker.saveTitle(turn: turn, title: title) { await self.refreshHistory() }
            } catch {
                // A title is optional metadata. Keep the provisional title and completed answer.
            }
        }
    }
    func waitForTitles() async { while let task = titleTasks.values.first { await task.value } }

    static func failureMessage(_ error: Error) -> String {
        if error is MeetingChatError || error is MeetingChatHarnessError || error is MeetingTextGenerationError || error is MeetingNativeToolTransportError { return error.localizedDescription }
        if error is MeetingChatContextBudget.SummaryError { return "Could not fit conversation memory into this model’s context budget. Try again or choose a model with a larger context window. Your conversation is still saved." }
        if error is ChatGPTAuthError { return "Your ChatGPT connection needs attention. Sign in again in AI Settings, then retry." }
        if case let ChatGPTResponsesError.backendFailed(status, _) = error {
            switch status {
            case 401, 403: return "ChatGPT could not authorize this request. Sign in again in AI Settings, then retry."
            case 429: return "ChatGPT has reached a usage or rate limit. Wait and retry, or choose another provider in AI Settings."
            case 400, 404, 422: return "ChatGPT rejected this request. Check the selected model and reasoning level in AI Settings, then retry."
            case 500...599: return "ChatGPT is temporarily unavailable. Please retry shortly."
            default: return "ChatGPT could not complete this request (HTTP \(status)). Please retry or check AI Settings."
            }
        }
        if let network = error as? URLError {
            if network.code == .timedOut { return "The meeting AI connection timed out. Please retry." }
            return "Could not connect to meeting AI. Check your internet connection and retry."
        }
        return "Meeting AI request failed. Please retry or check your connection settings."
    }
    func stop() {
        reasoningIsStreaming = false
        reasoningSummaries = []; activityTurnID = nil
        guard let id = activeRequestID else { return }
        tasks[id]?.cancel()
        if let turnID = activeTurnID {
            let cleanupID = UUID(); let worker = worker
            tasks[cleanupID] = Task {
                defer { tasks.removeValue(forKey: cleanupID); scheduleHistoryReload() }
                try? await worker.setTurnState(id: turnID, state: .stopped, attemptID: id)
            }
            if let index = turns.firstIndex(where: { $0.id == turnID && $0.state.isPending }) { turns[index].state = .stopped }
        }
        activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = ""
    }
    func deleteChat(id: UUID) async {
        guard pendingChatMutations[id] == nil else { return }
        pendingChatMutations[id] = .deleting
        defer { pendingChatMutations[id] = nil }
        cancelTitle(sessionID: id)
        // Transient tool/reasoning output belongs to the run that produced it.
        if activityTurnID != nil, activitySessionID == id {
            reasoningSummaries = []; activityTurnID = nil
        }
        if activeSessionID == id { stop() }
        do { try await worker.deleteChat(id: id); composerDrafts[id] = nil; composerUndoIdentities[id] = nil; await refreshHistory() } catch { errorMessage = error.localizedDescription }
    }
    func saveDraft(turnID: UUID, text: String) async {
        do { try await worker.saveDraft(turnID: turnID, text: text); await refreshHistory() } catch { errorMessage = error.localizedDescription }
    }
    func refreshChoices() async { do { sourceChoices = try await worker.choices() } catch { errorMessage = error.localizedDescription } }
    func source(_ id: Int64) async -> MeetingChatSourceSnapshot? { try? await worker.source(id) }
    func waitForIdle() async {
        await initialization?.value
        while let task = tasks.values.first { await task.value }
        await settleHistory()
    }
    func refreshForSourceChanges() {
        guard let version = try? store.sourceMutationVersion(), version != sourceMutationVersion else { return }
        sourceMutationVersion = version
        // Invalidate setup ownership too: there may not be a turn/session ID yet.
        selectionVersion = UUID()
        if activeRequestID != nil, activeTurnID == nil { stop() }
        for sessionID in Array(titleTasks.keys) { cancelTitle(sessionID: sessionID) }
        reasoningSummaries = []; activityTurnID = nil
        if let sessionID = activeSessionID, let turnID = activeTurnID {
            let current = try? store.turns(sessionID: sessionID).first { $0.id == turnID }
            if current == nil || current?.state == .sourceDeleted { stop() }
        }
        reload()
        Task { await refreshChoices() }
    }
}
