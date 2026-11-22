import Foundation

/// Shared by local task execution and external agents. Never silently widens an
/// empty source selection. Screen history is always included for these tasks.
public struct MuesliHistoryPacket: Codable, Sendable {
    public let from: Date
    public let until: Date
    public let captures: [VisualMemoryItem]
    public let meetings: [MeetingChatPassage]
    public let history: [MuesliHistorySource]
    public let coverage: String
}

public struct MuesliHistoryAccess: Sendable {
    public let databaseURL: URL
    public let screenRoot: URL?
    public init(databaseURL: URL, screenRoot: URL?) {
        self.databaseURL = databaseURL; self.screenRoot = screenRoot
    }

    /// Bounded, stratified samples across a fixed half-open interval. Search is
    /// applied before sampling; the result never promises exhaustive coverage.
    public func sample(interval: DateInterval, kinds: Set<MuesliHistoryKind>, query: String = "", meetingScope: MeetingChatScope? = nil) throws -> MuesliHistoryPacket {
        guard interval.duration > 0, interval.duration <= 31 * 86400, query.utf8.count <= 300 else {
            throw NSError(domain: "MuesliHistory", code: 2, userInfo: [NSLocalizedDescriptionKey: "Choose a valid interval of at most 31 days and a query of at most 300 bytes."])
        }
        var captures: [VisualMemoryItem] = []
        if let screenRoot {
            let store = try VisualMemoryStore(root: screenRoot, readOnly: true)
            for bucket in 0..<6 {
                try Task.checkCancellation()
                let start = interval.start.addingTimeInterval(interval.duration * Double(bucket) / 6)
                let end = interval.start.addingTimeInterval(interval.duration * Double(bucket + 1) / 6)
                captures += try store.searchMoments(text: query, from: start, until: end, limit: 6)
            }
        }
        let meetingStart = max(interval.start, meetingScope?.startDate ?? interval.start)
        let meetingEnd = min(interval.end, meetingScope?.endDateExclusive ?? interval.end)
        let scope = MeetingChatScope(selection: meetingScope?.selection ?? .all,
            startDate: meetingStart, endDateExclusive: meetingEnd)
        let meetings = kinds.contains(.meetings) && meetingStart < meetingEnd && scope.selection != .meetings([]) ? try MeetingChatRetrieval(databaseURL: databaseURL).retrieve(
            question: query.isEmpty ? "Daily recap" : query,
            scope: scope, broadRecap: query.isEmpty).passages : []
        var history: [MuesliHistorySource] = []
        if !kinds.subtracting([.meetings]).isEmpty {
            let reader = try MuesliHistoryReader(databaseURL: databaseURL)
            for kind in MuesliHistoryKind.allCases where kind != .meetings && kinds.contains(kind) {
                history += try reader.samples(kind: kind, interval: interval, query: query)
            }
        }
        let packet = MuesliHistoryPacket(from: interval.start, until: interval.end,
            captures: captures.sorted { $0.capturedAt < $1.capturedAt }, meetings: meetings, history: history,
            coverage: "Partial samples, not exhaustive history. Chats use conversation update time; messages may be older. Screen history is included even when no captures are available.")
        guard try areCurrent(captures: packet.captures, meetings: packet.meetings.map(\.citation), history: packet.history) else {
            throw GlobalSearchError.changedSources
        }
        return packet
    }

    public func areCurrent(captures: [VisualMemoryItem], meetings: [MeetingChatCitation], history: [MuesliHistorySource]) throws -> Bool {
        if !captures.isEmpty {
            guard let screenRoot else { throw CocoaError(.fileReadNoSuchFile) }
            let store = try VisualMemoryStore(root: screenRoot, readOnly: true)
            for old in captures {
                guard let current = try store.moment(id: old.id), current.text == old.text,
                      current.capturedAt == old.capturedAt, current.source == old.source,
                      current.bundleID == old.bundleID else { return false }
            }
        }
        if !history.isEmpty, try !MuesliHistoryReader(databaseURL: databaseURL).areCurrent(history) { return false }
        guard !meetings.isEmpty else { return true }
        return try MeetingChatStore(databaseURL: databaseURL, readOnly: true).dependenciesAreCurrent(
            meetings.map { MeetingChatDependency(meetingID: $0.meetingID, revision: $0.revision) })
    }
}
