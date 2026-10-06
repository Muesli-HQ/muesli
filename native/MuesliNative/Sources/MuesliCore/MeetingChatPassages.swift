import Foundation

public struct MeetingChatPassage: Codable, Identifiable, Sendable {
    public var id: String
    public var sourceKey: String
    public var meetingID: Int64
    public var title: String
    public var startDate: Date
    public var kind: MeetingChatSourceKind
    public var excerpt: String
    public var range: MeetingChatTextRange
    public var timestamp: String?
    public var revision: String
    public var citation: MeetingChatCitation {
        .init(sourceKey: sourceKey, meetingID: meetingID, title: title, startDate: startDate, kind: kind,
              excerpt: excerpt, range: range, timestamp: timestamp, revision: revision)
    }
}

public struct MeetingChatEvidence: Sendable {
    public var scope: MeetingChatScope
    public var passages: [MeetingChatPassage]
    public var dependencies: [MeetingChatDependency]
    public var coverage: MeetingChatCoverage
    public var metrics: MeetingChatRetrievalMetrics
    public init(scope: MeetingChatScope, passages: [MeetingChatPassage], dependencies: [MeetingChatDependency], coverage: MeetingChatCoverage, metrics: MeetingChatRetrievalMetrics = .init()) {
        self.scope = scope; self.passages = passages; self.dependencies = dependencies; self.coverage = coverage
        self.metrics = metrics
    }
}

/// Work counters contain no meeting content and let tests prove that warm queries avoid source scans.
public struct MeetingChatRetrievalMetrics: Sendable {
    public var sourceSnapshotCount: Int
    public var reindexedMeetingCount: Int
    public var decodedCandidateCount: Int
    public init(sourceSnapshotCount: Int = 0, reindexedMeetingCount: Int = 0, decodedCandidateCount: Int = 0) {
        self.sourceSnapshotCount = sourceSnapshotCount; self.reindexedMeetingCount = reindexedMeetingCount
        self.decodedCandidateCount = decodedCandidateCount
    }
}

public enum MeetingChatPassages {
    public static func extract(from source: MeetingChatSourceSnapshot) -> [MeetingChatPassage] {
        var passages: [MeetingChatPassage] = []
        for (kind, text) in [(MeetingChatSourceKind.transcript, source.transcript), (.manualNotes, source.manualNotes), (.generatedNotes, source.generatedNotes)] {
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: kind == .transcript ? .byLines : .byParagraphs) { _, range, _, _ in
                var lower = range.lowerBound; var upper = range.upperBound
                while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
                while lower < upper, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
                let line = String(text[lower..<upper])
                let timestamp: String?
                if kind == .transcript, let match = line.range(of: #"^\[\d{2}:\d{2}:\d{2}\]"#, options: .regularExpression) {
                    timestamp = String(line[match].dropFirst().dropLast())
                } else { timestamp = nil }
                while lower < upper {
                    let start = lower; var bytes = 0
                    while lower < upper {
                        let next = text.index(after: lower)
                        let size = text[lower..<next].utf8.count
                        if bytes > 0 && bytes + size > 1_500 { break }
                        bytes += size; lower = next
                    }
                    let span = NSRange(start..<lower, in: text)
                    let excerpt = String(text[start..<lower])
                    passages.append(.init(id: "\(source.meetingID):\(kind.rawValue):\(span.location)", sourceKey: "", meetingID: source.meetingID,
                        title: source.title, startDate: source.startDate, kind: kind, excerpt: excerpt,
                        range: .init(location: span.location, length: span.length), timestamp: timestamp, revision: source.revision))
                }
            }
        }
        return passages
    }
}
