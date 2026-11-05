import Foundation
import MuesliCore

/// Immutable bounds for one Generate action, independent of provider or subsequent settings changes.
struct TimeTurnerRecapSearch: Sendable {
    let access: MuesliHistoryAccess
    let interval: DateInterval
    let config: AppConfig
    let meetingScope: MeetingChatScope?

    private var optionalKinds: [GlobalSearchKind: MuesliHistoryKind] {
        let mapping: [GlobalSearchKind: MuesliHistoryKind] = [
            .meeting: .meetings, .dictation: .dictations, .command: .commands,
            .quill: .quill, .cotypist: .cotypist, .chat: .chat
        ]
        return mapping.filter { config[keyPath: $0.value.configKey] }
    }

    var definition: [String: Any] {
        let kinds = Set(optionalKinds.keys).union([.screenHistory]).map(\.rawValue).sorted()
        return ["type": "function", "name": "search_history", "strict": true,
                "description": "Find additional evidence from one enabled source in the selected recap day. Supply a short search phrase. Results are bounded and carry handles for read_history and citations.",
                "parameters": ["type": "object", "additionalProperties": false, "required": ["kind", "query"],
                    "properties": ["kind": ["type": "string", "enum": kinds], "query": ["type": "string", "minLength": 1, "maxLength": 300]]]]
    }

    struct Query {
        let kind: GlobalSearchKind
        let phrase: String
    }

    func parse(_ arguments: String) throws -> Query {
        guard arguments.utf8.count <= 4096,
              let fields = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String],
              Set(fields.keys) == ["kind", "query"], let kind = fields["kind"].flatMap(GlobalSearchKind.init(rawValue:)),
              kind == .screenHistory || optionalKinds[kind] != nil,
              let phrase = fields["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phrase.isEmpty, phrase.utf8.count <= 300 else { throw MeetingChatHarnessError.toolProtocol }
        return Query(kind: kind, phrase: phrase)
    }

    func results(for query: Query) throws -> [TimeTurnerRecapSource] {
        let kind = optionalKinds[query.kind]
        guard query.kind == .screenHistory || kind != nil else { throw MeetingChatHarnessError.toolProtocol }
        let captures: [VisualMemoryItem]
        let passages: [MeetingChatPassage]
        let history: [MuesliHistorySource]
        switch query.kind {
        case .screenHistory:
            guard let root = access.screenRoot else { return [] }
            captures = try VisualMemoryStore(root: root, readOnly: true).searchMoments(
                text: query.phrase, from: interval.start, until: interval.end, limit: 5)
            passages = []
            history = []
        case .dictation, .command, .chat:
            guard let kind else { throw MeetingChatHarnessError.toolProtocol }
            // Indexed Julian dates have floating-point conversion error. Include
            // boundary candidates and apply the exact half-open interval to originals.
            let ids = try GlobalSearchIndex(databaseURL: access.databaseURL).historyIDs(kind: query.kind,
                phrase: query.phrase, from: interval.start.addingTimeInterval(-0.001),
                until: interval.end.addingTimeInterval(0.001), app: nil, after: nil, limit: 10)
            let reader = try MuesliHistoryReader(databaseURL: access.databaseURL)
            history = try ids.compactMap { hit in
                guard let record = try reader.read(kind: kind, id: hit.id, fullText: true),
                      record.date >= interval.start, record.date < interval.end,
                      (record.text + "\n" + record.title).localizedCaseInsensitiveContains(query.phrase) else { return nil }
                // Save only the bounded, revisioned quote used by ordinary recaps.
                return try reader.read(kind: kind, id: hit.id).flatMap { $0.revision == record.revision ? $0 : nil }
            }
            captures = []
            passages = []
        case .meeting, .quill, .cotypist:
            // Recap citations address individual passages, turns and accepted suggestions,
            // whereas a global Quill or Cotypist search result addresses a whole session.
            guard let kind else { throw MeetingChatHarnessError.toolProtocol }
            let scoped = MuesliHistoryAccess(databaseURL: access.databaseURL, screenRoot: nil)
            let matches = try scoped.sample(interval: interval, kinds: [kind], query: query.phrase, meetingScope: meetingScope)
            captures = []
            passages = matches.meetings
            history = matches.history
        case .recap:
            throw MeetingChatHarnessError.toolProtocol
        }
        guard !captures.isEmpty || !passages.isEmpty || !history.isEmpty else { return [] }
        let packet = try TimeTurnerRecap.packet(captures: captures, passages: passages, history: history, interval: interval, config: config)
        return Array(packet.sources.prefix(5))
    }
}

extension TimeTurnerRecapSource {
    func identifiesSameRecord(as other: Self) -> Bool {
        if let capture { return capture.id == other.capture?.id }
        if let history { return history.kind == other.history?.kind && history.id == other.history?.id }
        guard let meeting, let rhs = other.meeting else { return false }
        return meeting.meetingID == rhs.meetingID && meeting.kind == rhs.kind && meeting.range == rhs.range && meeting.revision == rhs.revision
    }
}
