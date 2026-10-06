import Foundation

public enum MeetingChatSelection: Codable, Equatable, Sendable {
    case all
    case folder(Int64)
    case meetings([Int64])
}

public struct MeetingChatScope: Codable, Equatable, Sendable {
    public var selection: MeetingChatSelection
    public var startDate: Date?
    public var endDateExclusive: Date?
    public init(selection: MeetingChatSelection = .all, startDate: Date? = nil, endDateExclusive: Date? = nil) {
        self.selection = selection; self.startDate = startDate; self.endDateExclusive = endDateExclusive
    }
}

public enum MeetingChatTurnState: String, Codable, Sendable {
    case finding, writing, completed, failed, stopped, interrupted, sourceDeleted
    public var isPending: Bool { self == .finding || self == .writing }
}

public enum MeetingChatSourceKind: String, Codable, Sendable {
    case transcript, manualNotes, generatedNotes
    public var label: String {
        switch self { case .transcript: "Transcript"; case .manualNotes: "Written notes"; case .generatedNotes: "Generated notes" }
    }
}

public struct MeetingChatTextRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

public struct MeetingChatDependency: Codable, Equatable, Hashable, Sendable {
    public var meetingID: Int64
    public var revision: String
    public init(meetingID: Int64, revision: String) { self.meetingID = meetingID; self.revision = revision }
}

public struct MeetingChatCitation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sourceKey }
    public var sourceKey: String
    public var meetingID: Int64
    public var title: String
    public var startDate: Date
    public var kind: MeetingChatSourceKind
    public var excerpt: String
    public var range: MeetingChatTextRange
    public var timestamp: String?
    public var revision: String
    public init(sourceKey: String, meetingID: Int64, title: String, startDate: Date, kind: MeetingChatSourceKind,
                excerpt: String, range: MeetingChatTextRange, timestamp: String? = nil, revision: String) {
        self.sourceKey = sourceKey; self.meetingID = meetingID; self.title = title; self.startDate = startDate
        self.kind = kind; self.excerpt = excerpt; self.range = range; self.timestamp = timestamp; self.revision = revision
    }
}

public struct MeetingChatSession: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var scope: MeetingChatScope
    public var createdAt: Date
    public var updatedAt: Date
    public var contextStartOrdinal: Int
}

public struct MeetingChatTurn: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var ordinal: Int
    public var question: String
    public var scope: MeetingChatScope
    public var state: MeetingChatTurnState
    public var originalAnswer: String?
    public var editableDraft: String?
    public var citations: [MeetingChatCitation]
    public var provider: String
    public var model: String
    public var error: String?
    public var coverage: MeetingChatCoverage?
    public var isDraft: Bool = false
}

public struct MeetingChatCoverage: Codable, Equatable, Sendable {
    public var eligibleMeetingCount: Int
    public var evidenceMeetingCount: Int
    public var isPartialRecap: Bool
    public init(eligibleMeetingCount: Int, evidenceMeetingCount: Int, isPartialRecap: Bool) {
        self.eligibleMeetingCount = eligibleMeetingCount; self.evidenceMeetingCount = evidenceMeetingCount
        self.isPartialRecap = isPartialRecap
    }
}

public struct MeetingChatSourceSnapshot: Codable, Sendable {
    public var meetingID: Int64
    public var title: String
    public var startDate: Date
    public var folderID: Int64?
    public var transcript: String
    public var manualNotes: String
    public var generatedNotes: String
    public var participantNames: [String]
    public var revision: String
}

public enum MeetingChatError: Error, LocalizedError {
    case missingSession, invalidResponse, sourceChanged, questionTooLong, promptTooLarge
    public var errorDescription: String? {
        switch self {
        case .missingSession: "This chat is no longer available."
        case .invalidResponse: "The answer did not include usable meeting references. Please retry."
        case .sourceChanged: "A source meeting changed while the answer was being written. Please retry."
        case .questionTooLong: "Keep your question within 2,000 characters."
        case .promptTooLarge: "This context is too large. Choose fewer meetings or start a new chat."
        }
    }
}
