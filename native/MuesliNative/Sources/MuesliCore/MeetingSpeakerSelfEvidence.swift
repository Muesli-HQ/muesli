import Foundation

extension MeetingSpeakerState {
    /// AX self status names an endpoint. Shared mic ownership additionally requires a unique voice match.
    public mutating func applySelfEvidence(accessibility: Set<MeetingSpeakerKey>, voice: Set<MeetingSpeakerKey>, ownerName: String, profileID: UUID?) {
        let eligible = Set(speakers.filter { $0.key.channel == .microphone && $0.isAssignable && $0.mergedInto == nil }.map(\.key))
        let candidates = voice.intersection(eligible)
        guard profileID != nil, candidates.count == 1, let key = candidates.first,
              accessibility.isEmpty || accessibility.intersection(eligible) == candidates,
              let index = speakers.firstIndex(where: { $0.key == key }), speakers[index].declinedSelf != true else { return }
        let name = Self.safeLabel(ownerName)
        let candidate = MeetingSpeakerAssignment(name: name, provenance: .voice)
        guard !speakers[index].declined.contains(candidate) else { return }
        for i in speakers.indices where speakers[i].key.channel == .microphone { speakers[i].isSelf = false; speakers[i].selfProvenance = nil }
        speakers[index].isSelf = true
        speakers[index].selfProvenance = .voice
        voiceProfileID = profileID
        if !name.isEmpty { assign(candidate, to: key) }
    }
    public mutating func removeSelfEvidence() {
        func scrub(_ speaker: inout MeetingSpeaker) {
            if speaker.selfProvenance != nil { speaker.isSelf = false; speaker.selfProvenance = nil }
            if speaker.assignment?.provenance == .voice { speaker.assignment = nil }
            speaker.history.removeAll { $0.provenance == .voice }
        }
        for index in speakers.indices { scrub(&speakers[index]) }
        if var history = correctionHistory {
            for entry in history.indices { for index in history[entry].speakers.indices { scrub(&history[entry].speakers[index]) } }
            correctionHistory = history
        }
        voiceProfileID = nil
    }
}
