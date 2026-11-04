import Foundation
import Observation
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
    var id: String { section.rawValue + text + sources.joined() }
}

struct TimeTurnerRecapPacket: Sendable {
    let sources: [TimeTurnerRecapSource]
    let user: String
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
    Return only JSON of the form {"insights":[{"section":"work","text":"brief insight","sources":["source ID"]}]}. Use work, decisions, or followUps for section. Return up to 8 insights, each under 300 characters, with 1–3 supporting source IDs from the opening sample or accepted tool results. If nothing is supported, return {"insights":[]}.
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
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(text.utf8)), response.insights.count <= 8 else { throw TimeTurnerRecapError.invalidResponse }
        let ids = Set(packet.sources.map(\.id))
        var unique = Set<String>()
        for insight in response.insights {
            guard !insight.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, insight.text.count <= 400,
                  (1...3).contains(insight.sources.count), Set(insight.sources).count == insight.sources.count,
                  Set(insight.sources).isSubset(of: ids),
                  unique.insert(insight.id).inserted else { throw TimeTurnerRecapError.invalidResponse }
        }
        return response.insights
    }

    static func sourcesAreCurrent(_ sources: [TimeTurnerRecapSource], root: URL?, databaseURL: URL) throws -> Bool {
        try MuesliHistoryAccess(databaseURL: databaseURL, screenRoot: root).areCurrent(
            captures: sources.compactMap(\.capture), meetings: sources.compactMap(\.meeting),
            history: sources.compactMap(\.history))
    }
}

@MainActor @Observable
final class TimeTurnerRecapModel {
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
    var requestID: UUID { attempt }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempt = UUID()

    func cancel(clear: Bool = false) {
        attempt = UUID(); task?.cancel(); task = nil; isGenerating = false; isLoading = false
        if clear { insights = []; sources = []; hasGenerated = false; error = nil; generatedAt = nil; savedKey = nil }
    }

    func generate(day: Date, selection: TimeTurnerRecapSelection? = nil, captures: [VisualMemoryItem]? = nil, root: URL?, databaseURL: URL, config: AppConfig,
                  generator: any MeetingTextGenerating = MeetingTextGenerationClient(),
                  template: MuesliHistoryTask = .dailyRecap, query: String = "", skillPrompt: String? = nil, meetingScope: MeetingChatScope? = nil) {
        cancel(clear: true)
        guard let interval = selection?.interval ?? Calendar.current.dateInterval(of: .day, for: day) else { return }
        guard query.utf8.count <= 300, template.requiresQuery || query.isEmpty, !template.requiresQuery || !(skillPrompt ?? query).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter a project or topic (up to 300 bytes)."; return
        }
        let token = attempt
        let timeZone = selection?.timeZone ?? Calendar.current.timeZone.identifier
        isGenerating = true
        modelLabel = MeetingTextGenerationClient.model(config)
        providerLabel = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend).label
        let privacy = ContentPrivacy.session ?? ContentPrivacy.shared.capture()
        let analytics = AnalyticsAttempt(.recap, model: .summary(config))
        task = Task { [weak self] in
            defer { analytics.finish(Task.isCancelled ? .cancelled : .failed) }
            do {
                let runtime = try await MuesliTaskRunner.prepare(config: config, generator: generator)
                let budget = runtime.budget
                let packet = try await Task.detached(priority: .utility) {
                    let access = MuesliHistoryAccess(databaseURL: databaseURL, screenRoot: root)
                    let sampled = try access.sample(interval: interval, kinds: Set(TimeTurnerRecapInput.selected(config)), query: query, meetingScope: meetingScope)
                    return try TimeTurnerRecap.packet(captures: captures ?? sampled.captures, passages: sampled.meetings,
                        history: sampled.history, interval: interval, config: config, contextBudget: budget)
                }.value
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
                let saved = SavedTimeTurnerRecap(version: 1, dayStart: interval.start, dayEnd: interval.end,
                    timeZone: timeZone, generatedAt: Date(), provider: self.providerLabel, model: self.modelLabel,
                    insights: result, sources: finalSources, includedInputs: TimeTurnerRecapInput.selected(config))
                let persisted = try await Task.detached(priority: .utility) {
                    do {
                        try ContentPrivacy.shared.beginWrite(privacy)
                        defer { ContentPrivacy.shared.endWrite() }
                        try TimeTurnerRetention.save(saved, root: root, databaseURL: databaseURL)
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
                guard let saved = try store.load(key: key) else { return Optional<SavedTimeTurnerRecap>.none }
                guard try TimeTurnerRecap.sourcesAreCurrent(saved.sources, root: root, databaseURL: databaseURL) else {
                    try store.delete(key: key, generatedAt: saved.generatedAt)
                    throw TimeTurnerRecapError.changedSources
                }
                return Optional(saved)
            }.value
            guard attempt == token, !Task.isCancelled else { return }
            if let saved { apply(saved) }
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
