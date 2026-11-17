import Foundation

/// A failed read is not proof that a source was deleted. Never publish unverified text.
public enum GlobalSearchRead<Value> {
    case available(Value)
    case missing
    case unavailable

    public static func perform(_ read: () throws -> Value?) throws -> Self {
        try Task.checkCancellation()
        do {
            let value = try read()
            try Task.checkCancellation()
            return value.map(Self.available) ?? .missing
        } catch is CancellationError { throw CancellationError() }
        catch GlobalSearchError.changedSources { throw GlobalSearchError.changedSources }
        catch { try Task.checkCancellation(); return .unavailable }
    }

    public func value(for kinds: Set<GlobalSearchKind>) throws -> Value? {
        switch self {
        case .available(let value): return value
        case .missing: return nil
        case .unavailable: throw GlobalSearchError.unavailableSources(kinds)
        }
    }
}
extension GlobalSearchRead: Sendable where Value: Sendable {}

/// Completeness is explicit, including when there are zero verified matches.
public struct GlobalSearchResponse: Sendable {
    public var results: [GlobalSearchResult]
    public var unavailableKinds: Set<GlobalSearchKind>
    public init(results: [GlobalSearchResult] = [], unavailableKinds: Set<GlobalSearchKind> = []) {
        self.results = results; self.unavailableKinds = unavailableKinds
    }
    public func matches() throws -> [GlobalSearchResult] {
        if results.isEmpty, !unavailableKinds.isEmpty { throw GlobalSearchError.unavailableSources(unavailableKinds) }
        return results
    }
}

/// One typed search boundary; source-owned stores retain deletion and retention responsibility.
/// This first-page API is bounded to 200 validated hits per source. A durable cross-source cursor is a later UI integration step.
public final class GlobalSearchService: @unchecked Sendable {
    private let databaseURL: URL
    private var index: GlobalSearchIndex?
    private let lock = NSRecursiveLock()
    private let screenHistory: VisualMemoryStore?
    public init(databaseURL: URL, screenHistory: VisualMemoryStore? = nil) throws {
        self.databaseURL = databaseURL
        self.screenHistory = screenHistory
    }

    public func search(_ query: GlobalSearchQuery, screenHistoryStore: VisualMemoryStore? = nil, validateDerived: ((GlobalSearchKind, String) throws -> Bool)? = nil) throws -> [GlobalSearchResult] {
        try searchResponse(query, screenHistoryStore: screenHistoryStore, validateDerived: validateDerived).matches()
    }

    /// Source queries and evidence reads share the same failure boundary. Only
    /// cancellation and repeated concurrent-source mutations abort federation.
    public func searchResponse(_ query: GlobalSearchQuery, screenHistoryStore: VisualMemoryStore? = nil,
                               validateDerived: ((GlobalSearchKind, String) throws -> Bool)? = nil) throws -> GlobalSearchResponse {
        lock.lock(); defer { lock.unlock() }
        guard !query.kinds.isEmpty, query.from < query.until else { return .init() }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || query.person != nil), text.utf8.count <= 4096 else { return .init() }
        var candidateQuery = query
        candidateQuery.limit = query.person == nil ? 200 : query.limit
        var results: [GlobalSearchResult] = []
        var unavailable: Set<GlobalSearchKind> = []
        let mainKinds = query.person == nil ? query.kinds.subtracting([.screenHistory]) : query.kinds.intersection([.meeting])
        if !mainKinds.isEmpty {
            let mainRead = try GlobalSearchRead<[GlobalSearchResult]>.perform {
                if index == nil { index = try GlobalSearchIndex(databaseURL: databaseURL) }
                let validator: ((GlobalSearchKind, String) throws -> Bool)? = validateDerived.map { validate in
                    { kind, id in
                        switch try GlobalSearchRead<Bool>.perform({ try validate(kind, id) }) {
                        case .available(let valid): return valid
                        case .missing: return false
                        case .unavailable: unavailable.insert(kind); return false
                        }
                    }
                }
                return try index!.search(candidateQuery, validateDerived: validator)
            }
            switch mainRead {
            case .available(let matches): results = matches
            case .missing: break
            case .unavailable: unavailable.formUnion(mainKinds); index = nil
            }
        }
        if query.person == nil, query.kinds.contains(.screenHistory), let screenHistory = screenHistoryStore ?? screenHistory {
            let screenRead = try GlobalSearchRead<[VisualMemoryItem]>.perform {
                try screenHistory.searchMoments(text: text, from: query.from, until: query.until, app: query.app, limit: 200)
            }
            if case .unavailable = screenRead { unavailable.insert(.screenHistory) }
            if case .available(let captures) = screenRead {
                results += captures.map { item in
                    GlobalSearchResult(kind: .screenHistory, sourceID: item.id, date: item.capturedAt,
                        title: item.source, excerpt: Self.excerpt(item.text, matching: text),
                        appName: item.includedApps?.map(\.name).joined(separator: ", ") ?? item.appName ?? item.source.components(separatedBy: " · ").first ?? "",
                        bundleID: item.bundleID, mediaAvailable: item.mediaDeletedAt == nil && (try? screenHistory.url(for: item.path)).map { FileManager.default.fileExists(atPath: $0.path) } == true)
                }
            }
        }
        // Person queries are paginated by the index; preserve its order across page boundaries.
        if query.person != nil {
            return GlobalSearchResponse(results: results, unavailableKinds: unavailable)
        }
        // BM25 scores from independent corpora cannot be compared. Use shared title-match tiers,
        // then recency and a stable identity. Source-local FTS still bounds the candidate set.
        return GlobalSearchResponse(results: Array(results.sorted { lhs, rhs in
            let a = lhs.title.localizedCaseInsensitiveContains(text), b = rhs.title.localizedCaseInsensitiveContains(text)
            if a != b { return a }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }.prefix(max(1, min(200, query.limit)))), unavailableKinds: unavailable)
    }

    private static func excerpt(_ text: String, matching query: String) -> String {
        let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 240, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "… ") + String(text[start..<end]) + (end == text.endIndex ? "" : " …")
    }
}
