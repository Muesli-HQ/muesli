import Foundation
import MuesliCore

enum MeetingSpeakerIdentityPolicy {
    static func resolve(speakers: [MeetingSpeakerCandidate], participants: [MeetingIdentityParticipant],
                        manual: [MeetingSpeakerKey: MeetingSpeakerAssignment] = [:]) -> [MeetingSpeakerKey: MeetingSpeakerAssignment] {
        var result: [MeetingSpeakerKey: MeetingSpeakerAssignment] = [:]
        let sessions = Dictionary(grouping: speakers, by: { $0.key.session })
        if sessions.count > 1 {
            // Cluster IDs are scoped to a capture. Resume never makes two captures competing voices.
            for session in sessions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                result.merge(resolve(speakers: sessions[session] ?? [], participants: participants, manual: manual)) { first, _ in first }
            }
            allocateLabels(&result, participants: participants)
            return result
        }
        var number = 1
        let ownerCounts = Dictionary(grouping: speakers.filter { $0.evidence == .voiceVerified }, by: { $0.key.source }).mapValues(\.count)
        for speaker in speakers {
            if let assignment = manual[speaker.key], assignment.evidence == .manual {
                result[speaker.key] = assignment
                continue
            }
            let selfEvidence = speaker.evidence == .sourceFallback
                || (speaker.evidence == .voiceVerified && ownerCounts[speaker.key.source] == 1)
            if selfEvidence {
                result[speaker.key] = .init(label: "You", evidence: speaker.evidence, isOwner: true,
                    dependsOnVoice: speaker.evidence == .voiceVerified)
            } else {
                result[speaker.key] = .init(label: "Speaker \(number)", evidence: .unknown)
                number += 1
            }
        }
        let remotePeople = participants.filter { $0.role == .remote }
        let supported = speakers.filter { $0.evidence == .supportedNonOwner && result[$0.key]?.isOwner != true }
        let hasSelf = result.values.contains { $0.isOwner }
        let unresolved = speakers.contains { speaker in
            result[speaker.key]?.isOwner != true && speaker.evidence != .supportedNonOwner
                && result[speaker.key]?.evidence != .manual
        }
        if hasSelf, !unresolved, remotePeople.count == 1, supported.count == 1,
           speakers.filter({ result[$0.key]?.isOwner != true }).count == 1,
           result[supported[0].key]?.evidence != .manual {
            let person = remotePeople[0]
            result[supported[0].key] = .init(label: person.name, evidence: .oneToOne, participantID: person.id,
                dependsOnVoice: result.values.contains { $0.isOwner && $0.dependsOnVoice })
        }
        allocateLabels(&result, participants: participants)
        return result
    }

    private static func allocateLabels(_ result: inout [MeetingSpeakerKey: MeetingSpeakerAssignment], participants: [MeetingIdentityParticipant]) {
        let named = result.filter { !$0.value.isOwner && ($0.value.participantID != nil || $0.value.evidence == .manual) }
        let groups = Dictionary(grouping: named.keys, by: { key in
            named[key]?.participantID.map { "participant:" + $0 } ?? "speaker:" + key.storageID
        })
        var representatives: [String: MeetingSpeakerKey] = [:]
        var names: [MeetingSpeakerKey: String] = [:]
        for (identity, keys) in groups {
            guard let first = keys.sorted().first, let assignment = named[first] else { continue }
            representatives[identity] = first
            names[first] = participants.first(where: { $0.id == assignment.participantID })?.name ?? assignment.label
        }
        let safe = safeLabels(names)
        for (identity, keys) in groups {
            guard let representative = representatives[identity], let label = safe[representative] else { continue }
            for key in keys { result[key]?.label = label }
        }
    }

    static func safeLabels(_ names: [MeetingSpeakerKey: String]) -> [MeetingSpeakerKey: String] {
        var result: [MeetingSpeakerKey: String] = [:]
        var used = Set<String>()
        for key in names.keys.sorted() {
            let text = names[key] ?? "Participant"
            let scalars = text.unicodeScalars.map { scalar -> String in
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
                return String(scalar)
            }.joined()
            var base = scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if base.isEmpty { base = "Participant" }
            if isReserved(base) { base += " (participant)" }
            var label = base
            var suffix = 2
            while used.contains(label.lowercased()) {
                label = "\(base) (\(suffix))"
                suffix += 1
            }
            used.insert(label.lowercased())
            result[key] = label
        }
        return result
    }

    private static func isReserved(_ label: String) -> Bool {
        ["you", "others", "microphone", "multiple speakers", "unknown speaker"].contains(label.lowercased())
            || label.range(of: #"^Speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
