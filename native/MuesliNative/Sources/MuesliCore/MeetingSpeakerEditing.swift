import Foundation

public enum MeetingSpeakerCorrection: Sendable {
    case rename(MeetingSpeakerKey, String), resetName(MeetingSpeakerKey), declineName(MeetingSpeakerKey)
    case addSpeaker(String, MeetingSpeakerKey.Channel)
    case merge(MeetingSpeakerKey, into: MeetingSpeakerKey)
    case reassign(UUID, to: MeetingSpeakerKey), reassignSelection(UUID, NSRange, to: MeetingSpeakerKey)
    case undo
}

public struct MeetingSpeakerKeyChange: Codable, Equatable, Sendable {
    public let turnID: UUID
    public let previousKey: MeetingSpeakerKey
}

public struct MeetingSpeakerSplitUndo: Codable, Equatable, Sendable {
    public let index: Int
    public let original: MeetingSpeakerTurn
    public let replacementIDs: [UUID]
}

public struct MeetingSpeakerCorrectionUndo: Codable, Equatable, Sendable {
    public var speakers: [MeetingSpeaker] = []
    public var addedKeys: [MeetingSpeakerKey] = []
    public var keyChanges: [MeetingSpeakerKeyChange] = []
    public var split: MeetingSpeakerSplitUndo?
}

public struct MeetingSpeakerSampleRange: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public var duration: Double { end - start }
}

extension MeetingSpeakerState {
    public var activeSpeakers: [MeetingSpeaker] { speakers.filter { $0.mergedInto == nil && $0.isAssignable } }
    public var canUndoCorrection: Bool { !(correctionHistory ?? []).isEmpty }

    public func canonicalKey(for key: MeetingSpeakerKey) -> MeetingSpeakerKey? {
        var cursor = key, seen: Set<MeetingSpeakerKey> = []
        while seen.insert(cursor).inserted {
            guard let speaker = speakers.first(where: { $0.key == cursor }) else { return nil }
            guard let target = speaker.mergedInto else { return cursor }
            cursor = target
        }
        return nil
    }

    @discardableResult public mutating func correct(_ action: MeetingSpeakerCorrection) -> Bool {
        var undo = MeetingSpeakerCorrectionUndo()
        switch action {
        case .undo:
            guard let last = correctionHistory?.last,
                  last.keyChanges.allSatisfy({ change in turns.contains { $0.id == change.turnID } }) else { return false }
            if let split = last.split {
                guard split.replacementIDs.allSatisfy({ id in turns.contains { $0.id == id } }) else { return false }
                turns.removeAll { split.replacementIDs.contains($0.id) }
                turns.insert(split.original, at: min(split.index, turns.count))
            }
            for change in last.keyChanges {
                if let index = turns.firstIndex(where: { $0.id == change.turnID }) { turns[index].speaker = change.previousKey }
            }
            speakers.removeAll { last.addedKeys.contains($0.key) }
            for speaker in last.speakers {
                if let index = speakers.firstIndex(where: { $0.key == speaker.key }) { speakers[index] = speaker }
            }
            correctionHistory?.removeLast()
            return true
        case .rename(let key, let name):
            guard let speaker = activeSpeakers.first(where: { $0.key == key }) else { return false }
            undo.speakers = [speaker]
            guard assign(.init(name: name, provenance: .manual), to: key) else { return false }
        case .resetName(let key), .declineName(let key):
            guard let index = speakers.firstIndex(where: { $0.key == key && $0.mergedInto == nil && $0.isAssignable }),
                  speakers[index].assignment != nil || speakers[index].selfProvenance != nil else { return false }
            let assignment = speakers[index].assignment
            if case .declineName = action, assignment?.provenance == .manual, speakers[index].selfProvenance == nil { return false }
            undo.speakers = [speakers[index]]
            if speakers[index].selfProvenance != nil {
                speakers[index].isSelf = false; speakers[index].selfProvenance = nil
                if case .declineName = action { speakers[index].declinedSelf = true }
            }
            if case .declineName = action { declineAutomaticName(for: key) }
            else if let assignment { speakers[index].history.append(assignment); speakers[index].assignment = nil }
        case .addSpeaker(let name, let channel):
            guard !Self.safeLabel(name).isEmpty else { return false }
            let rank = (speakers.map(\.rank).max() ?? 0) + 1
            let key = MeetingSpeakerKey(epoch: epoch, channel: channel, clusterID: "manual:\(UUID())")
            speakers.append(.init(key: key, rank: rank, fallbackLabel: "Speaker \(rank)", assignment: .init(name: name, provenance: .manual)))
            undo.addedKeys = [key]
        case .merge(let source, let target):
            guard source != target, let sourceIndex = speakers.firstIndex(where: { $0.key == source && $0.isAssignable && $0.mergedInto == nil }),
                  let targetIndex = speakers.firstIndex(where: { $0.key == target && $0.isAssignable && $0.mergedInto == nil }) else { return false }
            let aliases = speakers.indices.filter { canonicalKey(for: speakers[$0].key) == source }
            let changed = Set(aliases + [sourceIndex, targetIndex])
            undo.speakers = changed.sorted().map { speakers[$0] }
            for index in turns.indices where canonicalKey(for: turns[index].speaker) == source {
                undo.keyChanges.append(.init(turnID: turns[index].id, previousKey: turns[index].speaker))
                if turns[index].originalSpeaker == nil { turns[index].originalSpeaker = turns[index].speaker }
                turns[index].speaker = target
            }
            let previousSource = speakers[sourceIndex]
            if previousSource.isSelf && !speakers[targetIndex].isSelf {
                speakers[targetIndex].paletteIsSelf = speakers[targetIndex].paletteIsSelf ?? speakers[targetIndex].isSelf
                speakers[targetIndex].selfProvenance = previousSource.selfProvenance
            }
            speakers[targetIndex].isSelf = speakers[targetIndex].isSelf || previousSource.isSelf
            speakers[targetIndex].declinedSelf = speakers[targetIndex].declinedSelf == true || previousSource.declinedSelf == true
            speakers[targetIndex].declined.formUnion(previousSource.declined)
            for index in aliases {
                speakers[index].mergedInto = target; speakers[index].isAssignable = false; speakers[index].isSelf = false
            }
        case .reassign(let turnID, let target):
            guard activeSpeakers.contains(where: { $0.key == target }), let index = turns.firstIndex(where: { $0.id == turnID }),
                  turns[index].speaker != target else { return false }
            undo.keyChanges = [.init(turnID: turnID, previousKey: turns[index].speaker)]
            if turns[index].originalSpeaker == nil { turns[index].originalSpeaker = turns[index].speaker }
            turns[index].speaker = target
        case .reassignSelection(let turnID, let selection, let target):
            guard activeSpeakers.contains(where: { $0.key == target }), let index = turns.firstIndex(where: { $0.id == turnID }) else { return false }
            let original = turns[index], count = original.text.utf16.count
            guard original.speaker != target else { return false }
            guard selection.location >= 0, selection.length > 0, selection.location <= count,
                  selection.length <= count - selection.location,
                  let range = Range(selection, in: original.text),
                  (range.lowerBound == original.text.endIndex || original.text.indices.contains(range.lowerBound)),
                  (range.upperBound == original.text.endIndex || original.text.indices.contains(range.upperBound)) else { return false }
            if selection.location == 0 && selection.length == count { return correct(.reassign(turnID, to: target)) }
            let pieces: [(String, MeetingSpeakerKey)] = [(String(original.text[..<range.lowerBound]), original.speaker),
                (String(original.text[range]), target), (String(original.text[range.upperBound...]), original.speaker)]
            var replacements: [MeetingSpeakerTurn] = []
            for (text, key) in pieces where !text.isEmpty {
                var turn = MeetingSpeakerTurn(id: replacements.isEmpty ? original.id : UUID(), speaker: key,
                    timestamp: original.timestamp, start: original.start, end: original.end, text: text)
                turn.sampleEligible = false
                turn.originalSpeaker = original.originalSpeaker ?? original.speaker
                replacements.append(turn)
            }
            undo.split = .init(index: index, original: original, replacementIDs: replacements.map(\.id))
            turns.replaceSubrange(index...index, with: replacements)
        }
        var history = correctionHistory ?? []
        history.append(undo)
        correctionHistory = Array(history.suffix(20))
        return true
    }

    public func matchingTurns(query: String) -> [MeetingSpeakerTurn] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines), names = labels
        return turns.filter { query.isEmpty || $0.text.localizedStandardContains(query) || (names[$0.speaker] ?? "").localizedStandardContains(query) }
    }

    public func sampleRange(for key: MeetingSpeakerKey) -> MeetingSpeakerSampleRange? {
        guard activeSpeakers.contains(where: { $0.key == key }) else { return nil }
        for turn in turns.sorted(by: { $0.start < $1.start }) where canonicalKey(for: turn.speaker) == key && turn.sampleEligible != false {
            let end = min(turn.end, turn.start + 6)
            guard turn.start.isFinite, end.isFinite, turn.start >= 0, end > turn.start else { continue }
            let overlaps = turns.contains { other in
                canonicalKey(for: other.speaker) != key && min(other.end, end) > max(other.start, turn.start)
            }
            if !overlaps { return .init(start: turn.start, end: end) }
        }
        return nil
    }
}
