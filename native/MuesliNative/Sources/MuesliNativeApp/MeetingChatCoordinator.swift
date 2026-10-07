import Foundation
import Observation
import MuesliCore

private actor MeetingChatWorker {
    let store: MeetingChatStore
    let retrieval: MeetingChatRetrieval
    init(databaseURL: URL) { store = .init(databaseURL: databaseURL); retrieval = .init(databaseURL: databaseURL) }
    func warmIndex() throws { try retrieval.prepareIndex() }
    func evidence(for turn: MeetingChatTurn) throws -> (MeetingChatEvidence, [MeetingChatTurn]) {
        let session = try store.sessions().first { $0.id == turn.sessionID }
        let history = try store.turns(sessionID: turn.sessionID).filter {
            $0.ordinal < turn.ordinal && $0.ordinal >= (session?.contextStartOrdinal ?? 0) && $0.scope == turn.scope && $0.state == .completed
        }
        let broad = ["recap", "summar", "decisions", "next steps", "action items", "follow-up"].contains { turn.question.localizedCaseInsensitiveContains($0) }
        var evidence = try retrieval.retrieve(question: turn.question, scope: turn.scope, priorQuestions: history.map(\.question), broadRecap: broad)
        // Include exactly the history that fits the same budget used by prompt construction.
        var selected: [MeetingChatTurn] = []; var bytes = 0
        for previous in history.reversed() {
            let inherited = try store.dependencies(turnID: previous.id)
            guard try store.dependenciesAreCurrent(inherited) else { continue }
            let block = "Question: \(previous.question)\nHistorical answer (not evidence): \(previous.originalAnswer ?? "")"
            guard bytes + block.utf8.count <= 4_000 else { continue }
            bytes += block.utf8.count; selected.insert(previous, at: 0)
            evidence.dependencies += inherited
        }
        evidence.dependencies = Array(Set(evidence.dependencies))
        try store.attachEvidence(turnID: turn.id, dependencies: evidence.dependencies)
        try store.setTurnState(id: turn.id, state: .writing)
        return (evidence, selected)
    }
    func finish(turn: MeetingChatTurn, answer: MeetingChatAnswer, dependencies: [MeetingChatDependency], isDraft: Bool) throws -> Bool {
        try store.finishTurn(turnID: turn.id, answer: answer.markdown, citations: answer.citations, dependencies: dependencies, coverage: answer.coverage, isDraft: isDraft)
    }
}

@MainActor @Observable
final class MeetingChatCoordinator {
    let store: MeetingChatStore
    @ObservationIgnored private let worker: MeetingChatWorker
    @ObservationIgnored private let generator: any MeetingTextGenerating
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var sessions: [MeetingChatSession] = []
    private(set) var turns: [MeetingChatTurn] = []
    private(set) var selectedSessionID: UUID?
    private(set) var activeRequestID: UUID?
    private(set) var activeTurnID: UUID?
    private var activeSessionID: UUID?
    private(set) var phase = ""
    var composerDraft = ""
    var errorMessage: String?
    var fastAnswers = true
    var scope: MeetingChatScope { sessions.first { $0.id == selectedSessionID }?.scope ?? .init() }
    var isBusy: Bool { activeRequestID != nil }

    init(databaseURL: URL, generator: any MeetingTextGenerating = MeetingTextGenerationClient()) {
        store = .init(databaseURL: databaseURL); worker = .init(databaseURL: databaseURL); self.generator = generator
        do { try store.interruptPendingTurns(); reload() } catch { errorMessage = error.localizedDescription }
        let worker = worker
        Task { do { try await worker.warmIndex() } catch { /* A query retries index preparation and reports errors. */ } }
    }
    func reload() {
        do {
            sessions = try store.sessions()
            if let id = selectedSessionID, sessions.contains(where: { $0.id == id }) { turns = try store.turns(sessionID: id) }
            else { selectedSessionID = nil; turns = [] }
        } catch { errorMessage = "Could not load meeting chat history." }
    }
    func createChat(scope: MeetingChatScope) {
        do {
            let session = try store.createSession(scope: scope, title: "New chat")
            selectedSessionID = session.id; composerDraft = ""; errorMessage = nil; reload()
        } catch { errorMessage = error.localizedDescription }
    }
    func selectChat(id: UUID) { selectedSessionID = id; composerDraft = ""; errorMessage = nil; reload() }
    func setScope(_ newScope: MeetingChatScope) {
        if selectedSessionID == nil { createChat(scope: newScope); return }
        do { try store.updateSession(id: selectedSessionID!, title: nil, scope: newScope); reload() }
        catch { errorMessage = error.localizedDescription }
    }
    func renameChat(id: UUID, title: String) {
        do { try store.updateSession(id: id, title: title, scope: nil); reload() } catch { errorMessage = error.localizedDescription }
    }
    func send(question: String, config: AppConfig, isDraft: Bool = false) {
        guard !isBusy else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard question.count <= 2_000 else { errorMessage = MeetingChatError.questionTooLong.localizedDescription; return }
        if selectedSessionID == nil { createChat(scope: .init()) }
        guard let id = selectedSessionID else { return }
        do {
            let requestConfig = fastAnswers ? MeetingTextGenerationClient.fastConfiguration(config) : config
            let turn = try store.beginTurn(sessionID: id, question: question, scope: scope,
                provider: MeetingSummaryBackendOption.resolved(requestConfig.meetingSummaryBackend).label, model: MeetingTextGenerationClient.model(requestConfig))
            if turns.isEmpty { try store.updateSession(id: id, title: String(question.prefix(64)), scope: nil) }
            composerDraft = ""; errorMessage = nil; reload(); launch(turn, config: requestConfig, isDraft: isDraft)
        } catch { errorMessage = error.localizedDescription }
    }
    func retry(turnID: UUID, config: AppConfig) {
        guard !isBusy else { return }
        do {
            let requestConfig = fastAnswers ? MeetingTextGenerationClient.fastConfiguration(config) : config
            guard let turn = try store.restartTurn(id: turnID, provider: MeetingSummaryBackendOption.resolved(requestConfig.meetingSummaryBackend).label, model: MeetingTextGenerationClient.model(requestConfig)) else { return }
            reload(); launch(turn, config: requestConfig, isDraft: turn.isDraft)
        } catch { errorMessage = error.localizedDescription }
    }
    private func launch(_ turn: MeetingChatTurn, config: AppConfig, isDraft: Bool) {
        let requestID = UUID(); activeRequestID = requestID; activeTurnID = turn.id; activeSessionID = turn.sessionID; phase = "Finding meeting context"
        let worker = worker; let generator = generator
        tasks[requestID] = Task {
            defer {
                tasks.removeValue(forKey: requestID)
                if activeRequestID == requestID { activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = "" }
                reload()
            }
            do {
                let (evidence, history) = try await worker.evidence(for: turn)
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                phase = "Writing answer"
                let answer: MeetingChatAnswer
                if evidence.passages.isEmpty {
                    answer = .init(markdown: "I couldn’t find supporting information in the selected saved meetings. Try a meeting title, specific term, or a narrower scope.", citations: [], insufficientEvidence: true, coverage: evidence.coverage)
                } else { answer = try await MeetingChatClient.answer(question: turn.question, evidence: evidence, history: history, config: config, generator: generator) }
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                guard try await worker.finish(turn: turn, answer: answer, dependencies: evidence.dependencies, isDraft: isDraft) else { throw MeetingChatError.sourceChanged }
            } catch {
                guard activeRequestID == requestID else { return }
                let stopped = Task.isCancelled || error is CancellationError
                let message = stopped ? nil : (error is MeetingChatError || error is MeetingTextGenerationError ? error.localizedDescription : "Meeting AI request failed. Please retry or check your connection settings.")
                try? store.setTurnState(id: turn.id, state: stopped ? .stopped : .failed, error: message)
            }
        }
    }
    func stop() {
        guard let id = activeRequestID else { return }
        tasks[id]?.cancel()
        if let turnID = activeTurnID { try? store.setTurnState(id: turnID, state: .stopped) }
        activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = ""; reload()
    }
    func deleteChat(id: UUID) {
        if activeSessionID == id { stop() }
        do { try store.deleteSession(id: id); reload() } catch { errorMessage = error.localizedDescription }
    }
    func saveDraft(turnID: UUID, text: String) {
        do { try store.saveDraft(turnID: turnID, text: text); reload() } catch { errorMessage = error.localizedDescription }
    }
    func waitForIdle() async { while let task = tasks.values.first { await task.value } }
}
