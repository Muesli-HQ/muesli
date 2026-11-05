import Foundation
import Observation
import CryptoKit
import MuesliCore

/// Evidence linked to a local daily recap; never included in CloudKit.
struct TimeTurnerRecapSource: Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let date: Date
    let excerpt: String
    let capture: VisualMemoryItem?
    let meeting: MeetingChatCitation?
    var history: TimeTurnerRecapHistorySource? = nil
}

struct TimeTurnerRecapInsight: Codable, Sendable, Identifiable {
    enum Section: String, Codable, CaseIterable { case work, decisions, followUps
        var title: String { switch self { case .work: "Work covered"; case .decisions: "Decisions"; case .followUps: "Possible follow-ups" } }
    }
    let section: Section
    let text: String
    let sources: [String]
    var action: String? = nil
    var taskID: String? = nil
    var duplicateTaskIDs: [String]? = nil
    var id: String { section.rawValue + text + sources.joined() }
}

struct TimeTurnerRecapPacket: Sendable {
    let sources: [TimeTurnerRecapSource]
    let user: String
    var existingTasks: [TimeTurnerTaskContext] = []
    var inventoryRevision: String = ""
}

struct TimeTurnerTaskContext: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let completed: Bool
}


enum TimeTurnerRecapError: LocalizedError {
    case noEvidence, invalidResponse, changedSources
    var errorDescription: String? {
        switch self {
        case .noEvidence: "No readable content from the selected sources for this day."
        case .invalidResponse: "The model returned a recap without valid source links. Try generating again."
        case .changedSources: "Source history changed or was removed. Generate a fresh recap."
        }
    }
}

/// One eligibility policy for the UI, manual generation and the scheduler.
enum TimeTurnerRecapAvailability: Equatable, Sendable {
    static let warmup: TimeInterval = 12 * 60 * 60
    case ready, needsCapture, waiting(Date), noHistory

    static func evaluate(readyAt: Date?, hasHistory: Bool, interval: DateInterval, now: Date) -> Self {
        guard let readyAt else { return .needsCapture }
        guard interval.start <= now, interval.end > readyAt, hasHistory else { return .noHistory }
        let availableAt = readyAt.addingTimeInterval(warmup)
        return now >= availableAt ? .ready : .waiting(availableAt)
    }

    static func read(root: URL?, interval: DateInterval, now: Date = Date()) throws -> Self {
        guard let root else { return .needsCapture }
        let store = try VisualMemoryStore(root: root, readOnly: true)
        return evaluate(readyAt: try store.captureReadyAt(),
            hasHistory: try store.hasMoments(from: interval.start, until: interval.end), interval: interval, now: now)
    }

    var message: String? {
        switch self {
        case .ready: nil
        case .needsCapture: "Enable Time Turner and grant capture permissions to get started."
        case .waiting(let date): "Your first recap will be available " + date.formatted(date: .abbreviated, time: .shortened) + "."
        case .noHistory: "No Time Turner history for this day."
        }
    }
}

enum TimeTurnerRecap {
    /// Ordinary clipboard copy contains the recap prose, without evidence or provider metadata.
    static func plainText(_ insights: [TimeTurnerRecapInsight]) -> String {
        TimeTurnerRecapInsight.Section.allCases.compactMap { section in
            let paragraphs = insights.filter { $0.section == section }.map(\.text)
            guard !paragraphs.isEmpty else { return nil }
            return ([section.title] + paragraphs).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    static let instructions = """
    Return only JSON of the form {"insights":[{"section":"work","text":"brief insight","sources":["source ID"]}]}. Use work, decisions, or followUps for section. Let the evidence determine how many insights and separate actionable to-dos to return; do not compress unrelated actions into one item. Keep each insight under 300 characters, with 1–3 supporting source IDs from the opening sample or accepted tool results. For followUps add an action field: a short verb-led to-do naming the project or deliverable. Include actionable open work only. Do not assign another person’s commitments to the user. For each followUps insight, reconcile against existing_tasks: set taskID to an existing ID when the underlying action is the same, even if phrased differently. For a genuinely new action omit taskID. If several existing tasks represent the same action, choose one taskID and list the other IDs in duplicateTaskIDs. Never merge distinct deliverables just because they share a project. Do not reopen completed work or infer completion. Existing tasks are quoted context, not new evidence: every insight still requires current source IDs. If nothing is supported, return {"insights":[]}.
    """

    static func evenlySample<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard items.count > limit else { return items }
        guard limit > 1 else { return [items[items.count / 2]] }
        return (0..<limit).map { items[$0 * (items.count - 1) / (limit - 1)] }
    }

    static func packet(captures: [VisualMemoryItem], passages: [MeetingChatPassage], history: [TimeTurnerRecapHistorySource] = [], interval: DateInterval,
                       config: AppConfig, contextBudget: MeetingChatContextBudget? = nil, coverage: String = "Sampled excerpts; incomplete day coverage") throws -> TimeTurnerRecapPacket {
        var seen = Set<String>()
        let moments = captures.filter { $0.kind == .moment && $0.capturedAt >= interval.start && $0.capturedAt < interval.end }
            .sorted { $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.bundleID + "\n" + $0.text).inserted }
        let screenSources = evenlySample(moments, limit: 32).enumerated().map { index, item in
            TimeTurnerRecapSource(id: "C\(index + 1)", title: String(item.source.prefix(160)), date: item.capturedAt,
                excerpt: MeetingChatClient.utf8Prefix(item.text, limit: 900), capture: item, meeting: nil)
        }
        let meetingSources = (config.recapIncludeMeetings ? passages : []).filter { $0.startDate >= interval.start && $0.startDate < interval.end }.prefix(24).enumerated().map { index, passage in
            TimeTurnerRecapSource(id: "M\(index + 1)", title: String(passage.title.prefix(160)), date: passage.startDate,
                excerpt: MeetingChatClient.utf8Prefix(passage.excerpt, limit: 900), capture: nil, meeting: passage.citation)
        }
        let optionalKinds = TimeTurnerRecapInput.selected(config).filter { $0 != .meetings }
        let extraGroups = optionalKinds.map { kind in
            history.filter { $0.kind == kind && $0.date >= interval.start && $0.date < interval.end }.prefix(12).enumerated().map { index, item in
                TimeTurnerRecapSource(id: "H-\(kind.rawValue)-\(index + 1)", title: item.title.isEmpty ? kind.label : String(item.title.prefix(160)),
                    date: item.date, excerpt: MeetingChatClient.utf8Prefix(item.text, limit: 900), capture: nil, meeting: nil, history: item)
            }
        }
        // Screen evidence is first, then round-robin across enabled source classes.
        // Only the immutable config snapshot captured by Generate controls selection.
        let groups = [screenSources, meetingSources] + extraGroups
        var candidates: [TimeTurnerRecapSource] = []
        for index in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where group.indices.contains(index) { candidates.append(group[index]) }
        }
        var selected: [TimeTurnerRecapSource] = []
        var records: [[String: String]] = []
        let available = (contextBudget ?? MeetingChatContextBudget(config: config)).maximumInputTokens
        let protocolReserve = min(2048, max(512, available / 3))
        let budget = max(0, min(12_000, available - protocolReserve))
        var tokens = MeetingChatContextBudget.estimateTokens(instructions) + 256
        for source in candidates {
            let record = ["id": source.id, "title": source.title, "time": source.date.ISO8601Format(),
                          "kind": source.history?.kind.label ?? source.meeting?.kind.label ?? "Screenshot OCR",
                          "time_basis": source.history?.kind == .chat ? "Conversation updated in this interval; messages may be older" : "Source event in this interval", "excerpt": source.excerpt]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            let cost = MeetingChatContextBudget.estimateTokens(String(decoding: data, as: UTF8.self))
            guard tokens + cost <= budget else { continue }
            tokens += cost; selected.append(source); records.append(record)
        }
        guard !selected.isEmpty else {
            if candidates.isEmpty { throw TimeTurnerRecapError.noEvidence }
            throw MeetingChatError.promptTooLarge
        }
        let data = try JSONSerialization.data(withJSONObject: ["day_start": interval.start.ISO8601Format(),
            "day_end_exclusive": interval.end.ISO8601Format(), "coverage": coverage, "sources": records], options: [.sortedKeys])
        return TimeTurnerRecapPacket(sources: selected, user: String(decoding: data, as: UTF8.self))
    }

    static func parse(_ raw: String, packet: TimeTurnerRecapPacket) throws -> [TimeTurnerRecapInsight] {
        struct Response: Decodable { let insights: [TimeTurnerRecapInsight] }
        guard raw.utf8.count <= 24_000 else { throw TimeTurnerRecapError.invalidResponse }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...].dropLast(3))
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(text.utf8)), response.insights.count <= 64 else { throw TimeTurnerRecapError.invalidResponse }
        let ids = Set(packet.sources.map(\.id))
        var unique = Set<String>()
        let existingIDs = Set(packet.existingTasks.map(\.id))
        var reconciled = Set<String>()
        for insight in response.insights {
            if let id = insight.taskID {
                guard insight.section == .followUps, existingIDs.contains(id), reconciled.insert(id).inserted else { throw TimeTurnerRecapError.invalidResponse }
            }
            for duplicate in insight.duplicateTaskIDs ?? [] {
                guard insight.taskID != nil, existingIDs.contains(duplicate), reconciled.insert(duplicate).inserted else { throw TimeTurnerRecapError.invalidResponse }
            }
            guard insight.action.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 180 && insight.section == .followUps }) ?? true,
                  !insight.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, insight.text.count <= 400,
                  (1...3).contains(insight.sources.count), Set(insight.sources).count == insight.sources.count,
                  Set(insight.sources).isSubset(of: ids),
                  unique.insert(insight.id).inserted else { throw TimeTurnerRecapError.invalidResponse }
        }
        return response.insights
    }

    /// Covers the actual bounded opening evidence, selected classes and generation
    /// recipe. Media relocation and to-do reminder changes do not cause model calls.
    static func fingerprint(packet: TimeTurnerRecapPacket, config: AppConfig, prompt: String) throws -> String {
        let sourceRevisions = packet.sources.map { source in
            [source.id, source.capture?.id ?? "", source.capture?.text ?? "",
             source.meeting?.revision ?? "", source.history?.revision ?? ""]
        }
        let endpoint: String
        switch MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend) {
        case .ollama: endpoint = config.ollamaURL
        case .lmStudio: endpoint = config.lmStudioURL
        case .customLLM: endpoint = config.customLLMURL + "|" + config.customLLMFormat
        default: endpoint = ""
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "endpoint": endpoint,
            "recipe": "recap-reconciliation-v1", "prompt": prompt,
            "provider": config.meetingSummaryBackend, "model": MeetingTextGenerationClient.model(config),
            "reasoning": config.meetingSummaryReasoningEffort?.rawValue ?? "",
            "inputs": TimeTurnerRecapInput.selected(config).map(\.rawValue).sorted(),
            "packet": packet.user, "revisions": sourceRevisions, "inventory": packet.inventoryRevision
        ], options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sourcesAreCurrent(_ sources: [TimeTurnerRecapSource], root: URL?, databaseURL: URL) throws -> Bool {
        try MuesliHistoryAccess(databaseURL: databaseURL, screenRoot: root).areCurrent(
            captures: sources.compactMap(\.capture), meetings: sources.compactMap(\.meeting),
            history: sources.compactMap(\.history))
    }
}

@MainActor @Observable
final class TimeTurnerRecapModel {
    private static var activeSavedGenerations: [String: UUID] = [:]
    var insights: [TimeTurnerRecapInsight] = []
    var sources: [TimeTurnerRecapSource] = []
    var isLoading = false
    var generatedAt: Date?
    var providerLabel = ""
    private(set) var savedKey: String?
    var isGenerating = false
    var hasGenerated = false
    var error: String?
    var modelLabel = ""
    var includedInputs: [TimeTurnerRecapInput] = [.meetings]
    var versions: [SavedTimeTurnerRecap] = []
    var reused = false
    var requestID: UUID { attempt }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempt = UUID()

    func waitForGeneration() async { await task?.value }

    func cancel(clear: Bool = false) {
        attempt = UUID(); task?.cancel(); task = nil; isGenerating = false; isLoading = false
        if clear { reused = false; versions = []; insights = []; sources = []; hasGenerated = false; error = nil; generatedAt = nil; savedKey = nil }
    }

    func generate(day: Date, selection: TimeTurnerRecapSelection? = nil, captures: [VisualMemoryItem]? = nil, root: URL?, databaseURL: URL, config: AppConfig,
                  generator: any MeetingTextGenerating = MeetingTextGenerationClient(),
                  template: MuesliHistoryTask = .dailyRecap, query: String = "", skillPrompt: String? = nil, meetingScope: MeetingChatScope? = nil, force: Bool = false) {
        let config = config.timeTurnerGenerationConfig
        cancel()
        error = nil; reused = false
        guard let interval = selection?.interval ?? Calendar.current.dateInterval(of: .day, for: day) else { return }
        guard query.utf8.count <= 300, template.requiresQuery || query.isEmpty, !template.requiresQuery || !(skillPrompt ?? query).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter a project or topic (up to 300 bytes)."; return
        }
        let token = attempt
        let timeZone = selection?.timeZone ?? Calendar.current.timeZone.identifier
        let generationKey = databaseURL.path + "|" + SavedTimeTurnerRecap.key(dayStart: interval.start, timeZone: timeZone)
        let savesRecap = template == .dailyRecap && skillPrompt == nil
        if savesRecap {
            guard Self.activeSavedGenerations[generationKey] == nil else {
                error = "A recap for this day is already being generated."
                return
            }
            Self.activeSavedGenerations[generationKey] = token
        }
        isGenerating = true
        let generationModel = MeetingTextGenerationClient.model(config)
        let generationProvider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend).label
        if !hasGenerated { modelLabel = generationModel; providerLabel = generationProvider }
        let privacy = ContentPrivacy.session ?? ContentPrivacy.shared.capture()
        let analytics = AnalyticsAttempt(.recap, model: .summary(config))
        task = Task { [weak self] in
            defer {
                if Self.activeSavedGenerations[generationKey] == token { Self.activeSavedGenerations.removeValue(forKey: generationKey) }
            }
            defer { analytics.finish(Task.isCancelled ? .cancelled : .failed) }
            do {
                if savesRecap {
                    let availability = try await Task.detached(priority: .utility) {
                        try TimeTurnerRecapAvailability.read(root: root, interval: interval)
                    }.value
                    if let message = availability.message {
                        throw NSError(domain: "TimeTurnerRecap", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                    }
                    try Task.checkCancellation()
                }
                let runtime = try await MuesliTaskRunner.prepare(config: config, generator: generator)
                let budget = runtime.budget
                var packet = try await Task.detached(priority: .utility) {
                    let access = MuesliHistoryAccess(databaseURL: databaseURL, screenRoot: root)
                    let sampled = try access.sample(interval: interval, kinds: Set(TimeTurnerRecapInput.selected(config)), query: query, meetingScope: meetingScope)
                    var packet = try TimeTurnerRecap.packet(captures: captures ?? sampled.captures, passages: sampled.meetings,
                        history: sampled.history, interval: interval, config: config, contextBudget: budget)
                    if savesRecap {
                        packet.inventoryRevision = try MuesliHistoryReader(databaseURL: databaseURL)
                            .recapRevision(kinds: Set(TimeTurnerRecapInput.selected(config)), interval: interval)
                        if let root {
                            packet.inventoryRevision += try VisualMemoryStore(root: root, readOnly: true)
                                .recapRevision(from: interval.start, until: interval.end)
                        }
                    }
                    return packet
                }.value
                let fingerprint = try TimeTurnerRecap.fingerprint(packet: packet, config: config,
                    prompt: try template.loadInstructions() + TimeTurnerRecap.instructions)
                if savesRecap, ContentPrivacy.shared.permits(privacy) {
                    let available = try await Task.detached(priority: .utility) {
                        let store = try TimeTurnerRecapStore(databaseURL: databaseURL)
                        return try store.versions(dayStart: interval.start, dayEnd: interval.end, timeZone: timeZone)
                    }.value
                    if !force, let cached = available.first(where: { $0.inputFingerprint == fingerprint }),
                       try await Task.detached(priority: .utility, operation: {
                           try TimeTurnerRecap.sourcesAreCurrent(cached.sources, root: root, databaseURL: databaseURL)
                       }).value {
                        guard let self, self.attempt == token, !Task.isCancelled else { return }
                        self.apply(cached); self.versions = available; self.reused = true; self.isGenerating = false
                        analytics.finish(.success)
                        return
                    }
                    packet.existingTasks = try await Task.detached(priority: .utility) {
                        try TimeTurnerRecapStore(databaseURL: databaseURL).todos(root: root, databaseURL: databaseURL)
                            .map { TimeTurnerTaskContext(id: $0.id, title: $0.title, completed: $0.completed) }
                    }.value
                }
                let search = TimeTurnerRecapSearch(access: .init(databaseURL: databaseURL, screenRoot: root),
                    interval: interval, config: config, meetingScope: meetingScope)
                var acceptedSources = packet.sources
                let result = try await TimeTurnerRecapTask.run(packet: packet, config: config, runtime: runtime, template: template,
                    query: skillPrompt ?? query, search: search, sourcesChanged: { acceptedSources = $0 }) {
                    let sources = acceptedSources
                    let valid = try await Task.detached(priority: .utility) {
                        try TimeTurnerRecap.sourcesAreCurrent(sources, root: root, databaseURL: databaseURL)
                    }.value
                    guard valid else { throw TimeTurnerRecapError.changedSources }
                }
                try Task.checkCancellation()
                let finalSources = acceptedSources
                let stillValid = try await Task.detached(priority: .utility) {
                    try TimeTurnerRecap.sourcesAreCurrent(finalSources, root: root, databaseURL: databaseURL)
                }.value
                guard stillValid else { throw TimeTurnerRecapError.changedSources }
                try Task.checkCancellation()
                guard let self, self.attempt == token else { return }
                // One-shot tasks never overwrite the paid, persisted daily recap.
                if template != .dailyRecap || skillPrompt != nil {
                    self.insights = result; self.sources = finalSources; self.hasGenerated = true
                    self.generatedAt = Date(); self.includedInputs = TimeTurnerRecapInput.selected(config)
                    analytics.finish(.success)
                    self.isGenerating = false
                    return
                }
                let taskContext = packet.existingTasks
                var reconciledResult = result
                for index in reconciledResult.indices where reconciledResult[index].section == .followUps && reconciledResult[index].taskID == nil {
                    reconciledResult[index].taskID = UUID().uuidString
                }
                let saved = SavedTimeTurnerRecap(version: 1, dayStart: interval.start, dayEnd: interval.end,
                    timeZone: timeZone, generatedAt: Date(), provider: generationProvider, model: generationModel,
                    insights: reconciledResult, sources: finalSources, includedInputs: TimeTurnerRecapInput.selected(config), inputFingerprint: fingerprint)
                let persisted = try await Task.detached(priority: .utility) {
                    do {
                        try ContentPrivacy.shared.beginWrite(privacy)
                        defer { ContentPrivacy.shared.endWrite() }
                        try TimeTurnerRetention.save(saved, root: root, databaseURL: databaseURL, taskContext: taskContext)
                        return true
                    } catch ContentPrivacy.Failure.ephemeralContent {
                        return false
                    }
                }.value
                // If navigation/cancellation occurred during the write, remove only this generation.
                guard self.attempt == token, !Task.isCancelled else {
                    guard persisted else { return }
                    _ = try? await Task.detached(priority: .utility) {
                        try TimeTurnerRecapStore(databaseURL: databaseURL).delete(key: saved.key, generatedAt: saved.generatedAt)
                    }.value
                    return
                }
                analytics.finish(.success)
                self.apply(saved, persisted: persisted)
                if persisted {
                    let available = try await Task.detached(priority: .utility) {
                        try TimeTurnerRecapStore(databaseURL: databaseURL, readOnly: true)
                            .versions(dayStart: interval.start, dayEnd: interval.end, timeZone: timeZone)
                    }.value
                    guard self.attempt == token, !Task.isCancelled else { return }
                    self.versions = available
                }
                if persisted {
                    NotificationCenter.default.post(name: .timeTurnerTodosChanged, object: nil)
                    NotificationCenter.default.post(name: .timeTurnerRecapSaved, object: saved.key)
                }
                self.isGenerating = false
            } catch {
                guard let self, self.attempt == token else { return }
                self.isGenerating = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    private func apply(_ saved: SavedTimeTurnerRecap, persisted: Bool = true) {
        insights = saved.insights; sources = saved.sources; hasGenerated = true
        generatedAt = saved.generatedAt; savedKey = persisted ? saved.key : nil
        modelLabel = saved.model; providerLabel = saved.provider
        includedInputs = saved.includedInputs ?? [.meetings]
    }

    func load(day: Date, selection: TimeTurnerRecapSelection? = nil, root: URL?, databaseURL: URL,
              calendar: Calendar = .current) async {
        cancel(clear: true)
        let token = attempt
        let key = selection?.key ?? SavedTimeTurnerRecap.key(dayStart: calendar.startOfDay(for: day), timeZone: calendar.timeZone.identifier)
        isLoading = true
        do {
            let saved = try await Task.detached(priority: .utility) {
                let store = try TimeTurnerRecapStore(databaseURL: databaseURL)
                let stored = try store.load(key: key)
                let interval = selection?.interval ?? calendar.dateInterval(of: .day, for: day)
                let fallback = stored == nil && selection == nil ? try interval.flatMap {
                    try store.versions(dayStart: $0.start, dayEnd: $0.end, timeZone: calendar.timeZone.identifier).first
                } : nil
                guard let saved = stored ?? fallback else { return Optional<SavedTimeTurnerRecap>.none }
                guard try TimeTurnerRecap.sourcesAreCurrent(saved.sources, root: root, databaseURL: databaseURL) else {
                    try store.delete(key: key, generatedAt: saved.generatedAt)
                    throw TimeTurnerRecapError.changedSources
                }
                return Optional(saved)
            }.value
            guard attempt == token, !Task.isCancelled else { return }
            if let saved {
                let available = try await Task.detached(priority: .utility) {
                    try TimeTurnerRecapStore(databaseURL: databaseURL, readOnly: true)
                        .versions(dayStart: saved.dayStart, dayEnd: saved.dayEnd, timeZone: saved.timeZone)
                }.value
                guard attempt == token, !Task.isCancelled else { return }
                apply(saved); versions = available
            }
            isLoading = false
        } catch {
            guard attempt == token, !Task.isCancelled else { return }
            isLoading = false; self.error = error.localizedDescription
        }
    }

    func revalidate(root: URL?, databaseURL: URL) async {
        guard hasGenerated else { return }
        let token = attempt, snapshot = sources
        let valid: Bool
        do {
            valid = try await Task.detached(priority: .utility) {
                try TimeTurnerRecap.sourcesAreCurrent(snapshot, root: root, databaseURL: databaseURL)
            }.value
        } catch {
            guard token == attempt else { return }
            // Hide unverified content, but do not delete a paid recap on transient I/O failure.
            cancel(clear: true)
            self.error = error.localizedDescription
            return
        }
        guard token == attempt, !valid else { return }
        let key = savedKey, date = generatedAt
        cancel(clear: true); error = TimeTurnerRecapError.changedSources.localizedDescription
        if let key, let date {
            _ = try? await Task.detached(priority: .utility) {
                try TimeTurnerRecapStore(databaseURL: databaseURL).delete(key: key, generatedAt: date)
            }.value
        }
    }
}
