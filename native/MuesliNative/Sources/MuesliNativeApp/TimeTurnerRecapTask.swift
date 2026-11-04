import Foundation
import MuesliCore

/// Daily recap is a task adapter, not a second provider or agent loop. Its read
/// capability is restricted to the sampled sources selected for this generation.
@MainActor
enum TimeTurnerRecapTask {
    struct Read: Equatable {
        let source: String
        let offset: Int
        var signature: String { source + ":" + String(offset) }
    }

    private enum Call { case read(Read), search(TimeTurnerRecapSearch.Query) }

    static let tool = ChatLibraryCall.readDefinition("Read a sampled recap source using its supplied ID as the handle. Start at offset 0 and follow next_offset until null. source_text_complete reports truncation. The packet covers only sampled evidence.")
    static let searchInstructions = """
    Start with the opening sample. If it supports an insight, use it directly. If an excerpt points to another enabled source for a material outcome, your next step is a search_history call. For example, when a proposal says the decision was due in a meeting, search the meeting by topic before writing the recap, even if you could summarize the proposal alone. After an empty search, qualify the proposal and finish unless you have a different concrete lead.
    """

    static func parse(name: String, arguments: String, packet: TimeTurnerRecapPacket) throws -> Read {
        guard name == "read_history", arguments.utf8.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              Set(object.keys) == ["handle", "offset"], let source = object["handle"] as? String,
              packet.sources.contains(where: { $0.id == source }),
              let number = object["offset"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.stringValue == String(number.intValue), number.intValue >= 0 else {
            throw MeetingChatHarnessError.toolProtocol
        }
        return Read(source: source, offset: number.intValue)
    }

    nonisolated static func read(_ call: Read, packet: TimeTurnerRecapPacket, original: MuesliHistorySource? = nil) throws -> MuesliTaskToolOutput {
        guard let source = packet.sources.first(where: { $0.id == call.source }) else { throw MeetingChatHarnessError.toolProtocol }
        // Meeting citations already carry a bounded original passage, not a whole meeting.
        let text = original?.text ?? source.capture?.text ?? source.meeting?.excerpt ?? source.history?.text ?? source.excerpt
        let page = try HistoryTextPage(text, offset: call.offset, maxBytes: 4000)
        let object: [String: Any] = ["handle": source.id, "text": page.text,
            "next_offset": page.nextOffset.map { $0 as Any } ?? NSNull(),
            "coverage": "One source; not complete day or meeting coverage",
            "source_text_complete": page.nextOffset == nil && (original ?? source.history)?.textIsTruncated != true]
        return .init(text: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }

    static func run(packet: TimeTurnerRecapPacket, config: AppConfig,
                    runtime: MuesliTaskRunner.Runtime, template: MuesliHistoryTask = .dailyRecap, query: String = "", sessionID: UUID = UUID(),
                    search: TimeTurnerRecapSearch? = nil, sourcesChanged: @escaping ([TimeTurnerRecapSource]) -> Void = { _ in },
                    validateSources: @escaping () async throws -> Void) async throws -> [TimeTurnerRecapInsight] {
        let isTemplate = template.templatePrompt != nil
        let templateFormat = #"Follow the user-selected template's structure in Markdown. Return JSON {"answer":"Markdown text","sources":["source ID"]}. Cite at least one supplied source for a substantive answer. Return an empty answer and sources if the evidence is insufficient."#
        let format = isTemplate ? templateFormat : TimeTurnerRecap.instructions
        let prompt = try template.loadInstructions()
        var initialUser = packet.user
        if isTemplate {
            initialUser += "\nUSER-SELECTED TEMPLATE: " + String(decoding: try JSONEncoder().encode(prompt), as: UTF8.self)
        }
        initialUser += "\nUSER PROMPT (quoted): " + String(decoding: try JSONEncoder().encode(query), as: UTF8.self)
        let tools = [tool] + (search.map { [$0.definition] } ?? [])
        let instructions = [
            isTemplate ? "Apply the user's selected template to the day's evidence." : prompt,
            search == nil ? nil : searchInstructions,
            "Use read_history to check an issued source when a short excerpt leaves its meaning uncertain. Finish as soon as the evidence supports the recap. If a material question remains unresolved, qualify the insight or omit it.",
            MuesliHistorySkill.evidenceInstructions,
            format
        ].compactMap { $0 }.joined(separator: "\n\n")
        var sources = packet.sources
        var pending: [TimeTurnerRecapSource] = []
        func currentPacket() -> TimeTurnerRecapPacket { .init(sources: sources, user: packet.user) }

        func parseCall(_ name: String, _ arguments: String) throws -> Call {
            if name == "search_history", let search { return .search(try search.parse(arguments)) }
            return .read(try parse(name: name, arguments: arguments, packet: currentPacket()))
        }
        func execute(_ call: Call) async throws -> MuesliTaskToolOutput {
            switch call {
            case .read(let request):
                let current = currentPacket()
                if let search, let history = current.sources.first(where: { $0.id == request.source })?.history, history.textIsTruncated {
                    return try await Task.detached(priority: .utility) {
                        guard let original = try MuesliHistoryReader(databaseURL: search.access.databaseURL)
                            .read(kind: history.kind, id: history.id, fullText: true), original.revision == history.revision
                        else { throw TimeTurnerRecapError.changedSources }
                        return try read(request, packet: current, original: original)
                    }.value
                }
                return try read(request, packet: current)
            case .search(let query):
                guard let search else { throw MeetingChatHarnessError.toolProtocol }
                let matches = try await Task.detached(priority: .utility) { try search.results(for: query) }.value
                try Task.checkCancellation()
                var rows: [[String: String]] = []
                for match in matches {
                    let source: TimeTurnerRecapSource
                    if let existing = (sources + pending).first(where: { $0.identifiesSameRecord(as: match) }) {
                        source = existing
                    } else {
                        source = .init(id: "R" + String(sources.count + pending.count + 1), title: match.title,
                            date: match.date, excerpt: match.excerpt, capture: match.capture, meeting: match.meeting, history: match.history)
                        pending.append(source)
                    }
                    rows.append(["handle": source.id, "title": source.title, "date": source.date.ISO8601Format(), "excerpt": source.excerpt])
                }
                let data = try JSONSerialization.data(withJSONObject: ["results": rows, "coverage": "Up to five matching sources within this recap day."])
                return .init(text: String(decoding: data, as: UTF8.self))
            }
        }
        func accept(_ call: Call, _ received: Bool) {
            guard case .search = call else { return }
            if received, !pending.isEmpty {
                sources.append(contentsOf: pending)
                sourcesChanged(sources)
            }
            pending.removeAll()
        }
        let validate: (String) throws -> [TimeTurnerRecapInsight] = { raw in
            if isTemplate {
                struct Answer: Decodable { let answer: String; let sources: [String] }
                guard let value = try? JSONDecoder().decode(Answer.self, from: Data(raw.utf8)),
                      Set(value.sources).isSubset(of: Set(sources.map(\.id))),
                      value.answer.isEmpty == value.sources.isEmpty else { throw MeetingChatHarnessError.invalidFormat }
                return value.answer.isEmpty ? [] : [.init(section: .work, text: value.answer, sources: value.sources)]
            }
            do { return try TimeTurnerRecap.parse(raw, packet: currentPacket()) }
            catch { throw MeetingChatHarnessError.invalidFormat }
        }
        let repair = "Retrieval is finished. Answer from the evidence already supplied. " + format
        if runtime.generator.supportsNativeTools(config: config) {
            let task = MuesliNativeTask<Call, [TimeTurnerRecapInsight]>(
                instructions: instructions, user: initialUser, tools: tools, maximumOutputTokens: 2000, requiresMeetingAnswerFormat: false,
                parse: parseCall, execute: { call in
                    try await validateSources()
                    return try await execute(call)
                }, accept: accept, validate: validate, repair: { _ in repair }, validateContext: validateSources)
            return try await MuesliTaskRunner.runNative(task, config: config, sessionID: sessionID,
                generator: runtime.generator, budget: runtime.budget)
        }
        var transcript: [[String: String]] = []
        var calls = Set<String>()
        var exhausted = false
        return try await MuesliTaskRunner.runCompatibility(maximumToolCalls: MuesliTaskRunner.maximumToolCalls) { _, correction, toolsAllowed in
            let finalOnly = !toolsAllowed || exhausted || correction != nil || calls.count >= MuesliTaskRunner.maximumToolCalls
            let system = finalOnly ? instructions + "\n" + repair : instructions
            let definitions = String(decoding: try JSONSerialization.data(withJSONObject: tools), as: UTF8.self)
            let searchExample = search == nil ? "" : #" Search example: {"tool":"search_history","kind":"screenHistory","query":"topic"}."#
            let toolGuide = finalOnly ? "" : "\nAvailable tools: " + definitions + "\nReturn exactly one JSON object: a tool call to gather evidence, or the final answer." + searchExample + #" Read example: {"tool":"read_history","handle":"C1","offset":0}."#
            let log = String(decoding: try JSONSerialization.data(withJSONObject: transcript, options: [.sortedKeys]), as: UTF8.self)
            let user = initialUser + "\nQUOTED TOOL HISTORY:\n" + log
            guard MeetingChatContextBudget.estimateTokens(system + toolGuide + user) <= runtime.budget.maximumInputTokens,
                  (system.utf8.count + toolGuide.utf8.count + user.utf8.count) <= MuesliTaskRunner.maximumInputBytes else { throw MeetingChatError.promptTooLarge }
            try await validateSources()
            try Task.checkCancellation()
            let raw = try await runtime.generator.generate(.init(system: system + toolGuide, user: user, config: config,
                maxOutputTokens: min(2000, runtime.budget.maximumOutputTokens), sessionID: sessionID,
                outputTokenLimit: runtime.budget.maximumOutputTokens))
            try Task.checkCancellation()
            try await validateSources()
            guard raw.utf8.count <= 24_000 else { throw MeetingChatHarnessError.oversizedResponse }
            if var object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let name = object.removeValue(forKey: "tool") as? String {
                guard !finalOnly else { throw MeetingChatHarnessError.toolProtocol }
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                let call = try parseCall(name, arguments)
                guard calls.insert(name + arguments).inserted else { throw MeetingChatHarnessError.toolProtocol }
                let result = try await execute(call)
                let entry = ["tool": name, "result": result.text]
                let candidate = String(decoding: try JSONSerialization.data(withJSONObject: transcript + [entry]), as: UTF8.self)
                if MeetingChatContextBudget.estimateTokens(system + toolGuide + initialUser + candidate) + 1024 <= runtime.budget.maximumInputTokens {
                    accept(call, true)
                    transcript.append(entry)
                } else {
                    accept(call, false)
                    exhausted = true
                    // Don't retain a result the selected model cannot receive.
                }
                return .next
            }
            return .finished(try validate(raw))
        }
    }
}
