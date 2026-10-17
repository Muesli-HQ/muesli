import Foundation

public struct MeetingSpeakerBacklogDescriptor: Codable, Sendable, Equatable {
    public let id: UUID
    public let channels: Set<MeetingSpeakerKey.Channel>
    public init(id: UUID = UUID(), channels: Set<MeetingSpeakerKey.Channel>) { self.id = id; self.channels = channels }
}
public struct MeetingSpeakerPendingLabeling: Codable, Sendable, Equatable {
    public let audio: MeetingSpeakerBacklogDescriptor
    public var state: MeetingSpeakerState
    public var ownerProfileID: UUID?
    public var accessibilityTimeline: MeetingSpeakerTimeline?
    public var accessibilityAuthorizationID: UUID?
    public init(audio: MeetingSpeakerBacklogDescriptor, state: MeetingSpeakerState, ownerProfileID: UUID? = nil,
                accessibilityTimeline: MeetingSpeakerTimeline? = nil, accessibilityAuthorizationID: UUID? = nil) {
        self.audio = audio; self.state = state; self.ownerProfileID = ownerProfileID
        let hasAuthorizedTimeline = accessibilityTimeline != nil && accessibilityAuthorizationID != nil
        self.accessibilityTimeline = hasAuthorizedTimeline ? accessibilityTimeline?.bounded() : nil
        self.accessibilityAuthorizationID = hasAuthorizedTimeline ? accessibilityAuthorizationID : nil
    }
    public func allowsOwnerProfile(_ profileID: UUID?) -> Bool {
        guard let ownerProfileID else { return false }
        return profileID == ownerProfileID
    }
    public func validatingAccessibilityAuthorization(_ current: UUID?) -> Self {
        guard let captured = accessibilityAuthorizationID, captured != current else { return self }
        var copy = self
        copy.accessibilityTimeline = nil
        copy.accessibilityAuthorizationID = nil
        return copy
    }
    public func prepared(for transcript: String) -> Self? {
        let tail = state.render()
        guard !tail.isEmpty, transcript.utf8.count >= tail.utf8.count,
              Array(transcript.utf8.suffix(tail.utf8.count)) == Array(tail.utf8) else { return nil }
        var copy = self
        copy.state.transcriptPrefix = String(transcript.dropLast(tail.count)) + (state.transcriptPrefix ?? "")
        return copy
    }
}
public enum MeetingSpeakerLabelingStatus: String, Codable, Sendable {
    case pending, running, failed, superseded, recovery, expired
    public var message: String {
        switch self {
        case .pending: "Speaker labels are pending. Transcript and labeling audio are saved."
        case .running: "Speaker labels are being prepared. Transcript and labeling audio are saved."
        case .failed: "Speaker labeling did not finish. The saved transcript and labeling audio are available."
        case .superseded: "The transcript changed. Older labeling results will not replace it."
        case .recovery: "Labeling recovery needs attention. Open the recovery folder to preserve available audio."
        case .expired: "Deferred speaker labeling audio expired after 30 days. The saved transcript is unchanged."
        }
    }
}
public struct MeetingSpeakerLabelingJob: Codable, Sendable {
    public let meetingID: Int64
    public let pending: MeetingSpeakerPendingLabeling
    public let expected: MeetingTranscriptVersion
    public var status: MeetingSpeakerLabelingStatus
    public var statusUpdatedAt: Date?
    public init(meetingID: Int64, pending: MeetingSpeakerPendingLabeling, expected: MeetingTranscriptVersion,
                status: MeetingSpeakerLabelingStatus = .pending, statusUpdatedAt: Date? = nil) {
        self.meetingID = meetingID; self.pending = pending; self.expected = expected
        self.status = status; self.statusUpdatedAt = statusUpdatedAt
    }
}
public struct MeetingSpeakerLabelingAudioReference: Sendable, Equatable {
    public let meetingID: Int64
    public let audioID: UUID
    public init(meetingID: Int64, audioID: UUID) { self.meetingID = meetingID; self.audioID = audioID }
}
extension MeetingSpeakerState {
    /// A fresh inference epoch may change keys, never ASR boundaries or an opaque earlier-session prefix.
    public func relabeling(
        channels: [MeetingSpeakerKey.Channel: [MeetingLiveSpeakerSegment]],
        ownerCluster: String? = nil,
        ownerName: String? = nil,
        ownerProfileID: UUID? = nil
    ) -> Self {
        var result = MeetingSpeakerState(); result.transcriptPrefix = transcriptPrefix
        var identities: [String: MeetingSpeakerKey] = [:]
        for turn in turns {
            let channel = turn.speaker.channel
            let old = speakers.first { $0.key == turn.speaker }
            let active = channels[channel]?.filter { !$0.clusterID.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && max(turn.start, $0.start) < min(turn.end, $0.end) }
            let ids = Set((active ?? []).map(\.clusterID))
            var raw = "source", label = old?.fallbackLabel ?? "Unknown speaker", person = false
            if let active {
                label = "Unknown speaker"
                if ids.count > 1 { raw = "aggregate:mixed"; label = "Multiple speakers" }
                else if let id = ids.first {
                    let sorted = active.sorted { $0.start < $1.start }
                    var end = turn.start, supported = 0.0
                    for part in sorted {
                        let lower = max(max(turn.start, part.start), end), upper = min(turn.end, part.end)
                        supported += max(0, upper - lower); end = max(end, upper)
                    }
                    if turn.end > turn.start, supported / (turn.end - turn.start) >= 0.8 { raw = id; person = true }
                    else { raw = "aggregate:unknown" }
                } else { raw = "aggregate:unknown" }
            }
            let storage = channel.rawValue + "/" + raw
            let key: MeetingSpeakerKey
            if let existing = identities[storage] { key = existing }
            else {
                key = .init(epoch: result.epoch, channel: channel, clusterID: raw); identities[storage] = key
                if person {
                    let rank = result.speakers.filter { $0.key.channel == channel && $0.isAssignable }.count + 1
                    label = channel == .microphone ? "Local speaker \(rank)" : "Speaker \(rank)"
                }
                result.speakers.append(.init(key: key, rank: result.speakers.count + 1, fallbackLabel: label, isAssignable: person || (active == nil && old?.isAssignable == true),
                    isSelf: active == nil && old?.isSelf == true && old?.selfProvenance == nil))
            }
            var copy = turn; copy.speaker = key; result.turns.append(copy)
        }
        result.coalesceAdjacentSameSpeakerTurns()
        if let ownerCluster, let ownerName, let ownerProfileID {
            let key = MeetingSpeakerKey(epoch: result.epoch, channel: .microphone, clusterID: ownerCluster)
            if result.turns.contains(where: { $0.speaker == key }) {
                result.applySelfEvidence(accessibility: [], voice: [key], ownerName: ownerName, profileID: ownerProfileID)
            }
        }
        return result
    }
    public func preservesSpeech(of source: Self) -> Bool {
        guard Array((transcriptPrefix ?? "").utf8) == Array((source.transcriptPrefix ?? "").utf8),
              turns.count <= source.turns.count else { return false }
        var sourceIndex = 0
        for turn in turns {
            guard sourceIndex < source.turns.count else { return false }
            let first = source.turns[sourceIndex]
            guard turn.id == first.id, turn.start == first.start, turn.timestamp == first.timestamp,
                  turn.speaker.channel == first.speaker.channel else { return false }
            var text = first.text
            var end = first.end
            sourceIndex += 1
            while text != turn.text || end != turn.end {
                guard sourceIndex < source.turns.count else { return false }
                let next = source.turns[sourceIndex]
                guard next.speaker.channel == first.speaker.channel,
                      max(0, next.start - end) <= 0.35,
                      (first.sampleTimeOffset ?? 0) == (next.sampleTimeOffset ?? 0),
                      first.sampleEligible != false, next.sampleEligible != false else { return false }
                text = Self.joinSpeech(text, next.text)
                end = max(end, next.end)
                sourceIndex += 1
            }
        }
        return sourceIndex == source.turns.count
    }

    private mutating func coalesceAdjacentSameSpeakerTurns() {
        guard let first = turns.first else { return }
        var merged = [first]
        for turn in turns.dropFirst() {
            guard let previous = merged.last,
                  previous.speaker == turn.speaker,
                  max(0, turn.start - previous.end) <= 0.35,
                  (previous.sampleTimeOffset ?? 0) == (turn.sampleTimeOffset ?? 0),
                  previous.sampleEligible != false, turn.sampleEligible != false else {
                merged.append(turn)
                continue
            }
            var combined = MeetingSpeakerTurn(
                id: previous.id, speaker: previous.speaker, timestamp: previous.timestamp,
                start: previous.start, end: max(previous.end, turn.end),
                text: Self.joinSpeech(previous.text, turn.text)
            )
            combined.sampleEligible = previous.sampleEligible == false || turn.sampleEligible == false ? false : nil
            combined.sampleTimeOffset = previous.sampleTimeOffset
            combined.originalSpeaker = previous.originalSpeaker
            merged[merged.count - 1] = combined
        }
        turns = merged
    }

    private static func joinSpeech(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        guard let last = lhs.last, let first = rhs.first else { return lhs + rhs }
        if last.isWhitespace || first.isWhitespace || first.isPunctuation { return lhs + rhs }
        return lhs + " " + rhs
    }
}
