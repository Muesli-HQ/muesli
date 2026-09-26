import CryptoKit
import Foundation

public enum MeetingSpeakerSource: String, Codable, Hashable, Sendable { case microphone, system, mixed }
public enum MeetingParticipantRole: String, Codable, CaseIterable, Sendable { case owner = "self", remote, unknown }
public enum MeetingSpeakerEvidence: String, Codable, Sendable {
    case unknown, sourceFallback, voiceVerified, supportedNonOwner, oneToOne, manual
}

public struct MeetingSpeakerKey: Codable, Hashable, Sendable, Comparable {
    public let session: UUID
    public let source: MeetingSpeakerSource
    public let clusterID: String
    public init(session: UUID, source: MeetingSpeakerSource, clusterID: String) {
        self.session = session; self.source = source; self.clusterID = clusterID
    }
    public var storageID: String { "\(session.uuidString):\(source.rawValue):\(clusterID)" }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.storageID < rhs.storageID }
}

public struct MeetingSpeakerCandidate: Codable, Equatable, Sendable {
    public let key: MeetingSpeakerKey
    public var evidence: MeetingSpeakerEvidence
    public init(key: MeetingSpeakerKey, evidence: MeetingSpeakerEvidence) { self.key = key; self.evidence = evidence }
}

public struct MeetingIdentityParticipant: Sendable {
    public let id: String
    public let name: String
    public let role: MeetingParticipantRole
    public init(id: String, name: String, role: MeetingParticipantRole) { self.id = id; self.name = name; self.role = role }
}

public struct MeetingSpeakerAssignment: Codable, Equatable, Sendable {
    public var label: String
    public var evidence: MeetingSpeakerEvidence
    public var participantID: String?
    public var isOwner: Bool
    public var dependsOnVoice: Bool
    public var needsParticipantReview: Bool
    public init(label: String, evidence: MeetingSpeakerEvidence, participantID: String? = nil,
                isOwner: Bool = false, dependsOnVoice: Bool = false, needsParticipantReview: Bool = false) {
        self.label = label; self.evidence = evidence; self.participantID = participantID
        self.isOwner = isOwner; self.dependsOnVoice = dependsOnVoice; self.needsParticipantReview = needsParticipantReview
    }
}

public struct MeetingSpeakerSegment: Codable, Equatable, Sendable {
    public let key: MeetingSpeakerKey
    public let start: Double
    public let end: Double
    public let timestamp: String
    public let text: String
    public var leadingText: String? = nil
    public init(key: MeetingSpeakerKey, start: Double, end: Double, timestamp: String, text: String) {
        self.key = key; self.start = start; self.end = end; self.timestamp = timestamp; self.text = text
    }
}

/// Device-local recovery/identity state. Never add this to MeetingRecord, sync, or hook payloads.
public struct MeetingSpeakerState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let session: UUID
    public var segments: [MeetingSpeakerSegment]
    public var candidates: [MeetingSpeakerCandidate]
    public var assignments: [MeetingSpeakerKey: MeetingSpeakerAssignment]
    public var generation: Int64 = 0
    public var lastGeneratedHash = ""
    public var isAuthoritative = true
    public var summaryIsStale = false
    public var voiceGeneration: UInt64?
    public var voiceProfileID: UUID?
    public var literalPrefix = ""
    public var priorAssignments: [[MeetingSpeakerKey: MeetingSpeakerAssignment]] = []

    public init(session: UUID, segments: [MeetingSpeakerSegment], assignments: [MeetingSpeakerKey: MeetingSpeakerAssignment],
                candidates: [MeetingSpeakerCandidate] = [], voiceGeneration: UInt64? = nil) {
        self.session = session; self.segments = segments; self.assignments = assignments
        self.candidates = candidates; self.voiceGeneration = voiceGeneration
    }

    public func renderedTranscript() -> String {
        let lines = segments.enumerated().map { index, segment in
            let label = assignments[segment.key]?.label ?? "Unknown speaker"
            return (segment.leadingText ?? (index == 0 ? "" : "\n")) + "[\(segment.timestamp)] \(label): \(segment.text)"
        }.joined()
        if literalPrefix.isEmpty { return lines }
        if lines.isEmpty { return literalPrefix }
        return literalPrefix + "\n" + lines
    }

    public func appending(prior: MeetingSpeakerState?, priorTranscript: String, separator: String) -> MeetingSpeakerState {
        var combined = self
        if var prior, prior.matches(priorTranscript) {
            if prior.requiresVoiceInvalidation(for: voiceProfileID) {
                prior.invalidateVoiceEvidence()
            }
            if combined.segments.isEmpty { return prior }
            if !prior.segments.isEmpty || !prior.literalPrefix.isEmpty {
                combined.segments[0].leadingText = prior.segments.isEmpty ? String(separator.dropFirst()) : separator
            }
            combined.segments = prior.segments + combined.segments
            combined.literalPrefix = prior.literalPrefix
            combined.candidates = prior.candidates + combined.candidates
            combined.assignments.merge(prior.assignments) { current, _ in current }
            combined.summaryIsStale = prior.summaryIsStale
        } else if !priorTranscript.isEmpty {
            // Edited/legacy speech remains opaque and is never reconstructed from stale segments.
            combined.literalPrefix = priorTranscript
            if !combined.segments.isEmpty { combined.segments[0].leadingText = String(separator.dropFirst()) }
        }
        return combined
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func matches(_ transcript: String) -> Bool {
        isAuthoritative && schemaVersion == 1 && lastGeneratedHash == Self.hash(transcript)
    }

    public func requiresVoiceInvalidation(for profileID: UUID?) -> Bool {
        voiceGeneration != nil && (profileID == nil || voiceProfileID == nil || voiceProfileID != profileID)
    }

    public mutating func markSummaryCurrent(for transcript: String) {
        if renderedTranscript() == transcript { summaryIsStale = false }
    }

    public mutating func invalidateVoiceEvidence() {
        for index in candidates.indices where candidates[index].evidence == .voiceVerified
            || candidates[index].evidence == .supportedNonOwner {
            candidates[index].evidence = .unknown
        }
        for key in assignments.keys where assignments[key]?.dependsOnVoice == true
            && assignments[key]?.evidence != .manual {
            assignments[key] = .init(label: "Unknown speaker", evidence: .unknown)
        }
        voiceGeneration = nil
        voiceProfileID = nil
    }
}

public enum MeetingSpeakerRenderResult: Equatable { case updated, invalidatedByTextEdit }
