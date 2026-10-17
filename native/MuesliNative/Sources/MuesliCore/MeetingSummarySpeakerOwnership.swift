import Foundation

/// Immutable prompt data, scoped to one exact canonical transcript. No identity identifiers leave the device.
public struct MeetingSummarySpeakerOwnership: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let speakerLabel: String
        public let mention: String
    }
    public let entries: [Entry]
    private let transcriptDigest: String
    private let modelFacingTranscriptDigest: String
    public init(state: MeetingSpeakerState?, transcript: String) {
        transcriptDigest = MeetingSpeakerState.digest(transcript)
        modelFacingTranscriptDigest = MeetingSpeakerState.digest(MeetingSpeakerState.modelFacingTranscript(transcript))
        guard let state, state.isValid, (state.transcriptPrefix ?? "").isEmpty,
              (state.renderedPrefix ?? "").isEmpty,
              state.matchesTranscript(transcript) else { entries = []; return }
        let used = Set(state.turns.compactMap { state.canonicalKey(for: $0.speaker) })
        let speakers = state.activeSpeakers.filter { used.contains($0.key) && $0.assignment != nil }
        let labels = state.labels
        guard speakers.count <= 64, speakers.allSatisfy({ ($0.assignment?.name.count ?? 0) <= 256 }) else { entries = []; return }
        let counts = Dictionary(grouping: speakers, by: { Self.collision(MeetingSpeakerState.safeLabel($0.assignment?.name ?? "")) }).mapValues(\.count)
        var candidates: [(label: String, name: String)] = []
        for speaker in speakers.sorted(by: { $0.rank < $1.rank }) {
            guard let assignment = speaker.assignment, assignment.provenance != .source else { continue }
            let name = MeetingSpeakerState.safeLabel(assignment.name)
            guard !name.isEmpty, !speaker.declined.contains(assignment), let label = labels[speaker.key] else { continue }
            let reserved = ["you", "others", "microphone", "multiple speakers", "unknown speaker"].contains(Self.collision(name))
            let mentionName = speaker.isSelf && counts[Self.collision(name)] == 1 && !reserved ? name : label
            candidates.append((label, mentionName))
        }
        let mentionCounts = Dictionary(grouping: candidates, by: { Self.collision($0.name) }).mapValues(\.count)
        let result = candidates.map { candidate in
            Entry(speakerLabel: candidate.label, mention: "@" + Self.markdownLiteral(mentionCounts[Self.collision(candidate.name)] == 1 ? candidate.name : candidate.label))
        }
        if let data = try? JSONEncoder().encode(result), data.count <= 16_384 { entries = result } else { entries = [] }
    }
    public init(snapshot: MeetingSpeakerSnapshot?, transcript: String, expected: MeetingTranscriptVersion) {
        self.init(state: snapshot?.version == expected ? snapshot?.state : nil, transcript: transcript)
    }
    public func promptData(for transcript: String) -> String? {
        let digest = MeetingSpeakerState.digest(transcript)
        guard !entries.isEmpty, (digest == transcriptDigest || digest == modelFacingTranscriptDigest) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return nil }
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "&", with: "\\u0026")
        return json.utf8.count <= 16_384 ? json : nil
    }
    private static func collision(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    private static func markdownLiteral(_ value: String) -> String {
        let special = Set("\\`*_{}[]<>()!|")
        return value.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
}
