import Foundation

/// One typed search boundary; source-owned stores retain deletion and retention responsibility.
/// This first-page API is bounded to 200 hits per source. A durable cross-source cursor is a later UI integration step.
public final class GlobalSearchService: @unchecked Sendable {
    private let index: GlobalSearchIndex
    private let screenHistory: VisualMemoryStore?
    public init(databaseURL: URL, screenHistory: VisualMemoryStore? = nil) throws {
        index = try GlobalSearchIndex(databaseURL: databaseURL)
        self.screenHistory = screenHistory
    }

    public func search(_ query: GlobalSearchQuery, validateDerived: ((GlobalSearchKind, String) throws -> Bool)? = nil) throws -> [GlobalSearchResult] {
        guard !query.kinds.isEmpty, query.from < query.until else { return [] }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096 else { return [] }
        var candidateQuery = query
        candidateQuery.limit = 200
        var results = try index.search(candidateQuery, validateDerived: validateDerived)
        if query.kinds.contains(.screenHistory), let screenHistory {
            let captures = try screenHistory.searchMoments(text: text, from: query.from, until: query.until, app: query.app, limit: 200)
            results += captures.map { item in
                GlobalSearchResult(kind: .screenHistory, sourceID: item.id, date: item.capturedAt,
                    title: item.source, excerpt: Self.excerpt(item.text, matching: text),
                    appName: item.appName ?? item.source.components(separatedBy: " · ").first ?? "",
                    bundleID: item.bundleID, mediaAvailable: item.mediaDeletedAt == nil && (try? screenHistory.url(for: item.path)).map { FileManager.default.fileExists(atPath: $0.path) } == true)
            }
        }
        // BM25 scores from independent corpora cannot be compared. Use shared title-match tiers,
        // then recency and a stable identity. Source-local FTS still bounds the candidate set.
        return Array(results.sorted { lhs, rhs in
            let a = lhs.title.localizedCaseInsensitiveContains(text), b = rhs.title.localizedCaseInsensitiveContains(text)
            if a != b { return a }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }.prefix(max(1, min(200, query.limit))))
    }

    private static func excerpt(_ text: String, matching query: String) -> String {
        let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 240, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "… ") + String(text[start..<end]) + (end == text.endIndex ? "" : " …")
    }
}
