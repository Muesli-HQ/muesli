import Foundation
import CryptoKit

/// Keys are meaningful only in one inference epoch. Labels and ranks never identify a person.
public struct MeetingSpeakerKey: Codable, Hashable, Sendable {
    public enum Channel: String, Codable, Sendable { case microphone, system, imported }
    public let epoch: UUID
    public let channel: Channel
    public let clusterID: String
    public init(epoch: UUID, channel: Channel, clusterID: String) {
        self.epoch = epoch; self.channel = channel; self.clusterID = clusterID
    }
}

public struct MeetingSpeakerAssignment: Codable, Hashable, Sendable {
    public enum Provenance: String, Codable, Sendable { case manual, accessibility, voice, source }
    public let name: String
    public let provenance: Provenance
    public init(name: String, provenance: Provenance) { self.name = name; self.provenance = provenance }
}

public struct MeetingSpeaker: Codable, Equatable, Sendable, Identifiable {
    public var id: MeetingSpeakerKey { key }
    public let key: MeetingSpeakerKey
    public let rank: Int
    public let fallbackLabel: String
    public var isAssignable: Bool
    public var isSelf: Bool
    public var assignment: MeetingSpeakerAssignment?
    public var declined: Set<MeetingSpeakerAssignment> = []
    public var history: [MeetingSpeakerAssignment] = []
    public init(key: MeetingSpeakerKey, rank: Int, fallbackLabel: String, isAssignable: Bool = true,
                isSelf: Bool = false, assignment: MeetingSpeakerAssignment? = nil) {
        self.key = key; self.rank = rank; self.fallbackLabel = fallbackLabel
        self.isAssignable = isAssignable; self.isSelf = isSelf; self.assignment = assignment
    }
}

public struct MeetingSpeakerTurn: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var speaker: MeetingSpeakerKey
    public let timestamp: String
    public let start: Double
    public let end: Double
    public var text: String
    public init(id: UUID = UUID(), speaker: MeetingSpeakerKey, timestamp: String, start: Double, end: Double, text: String) {
        self.id = id; self.speaker = speaker; self.timestamp = timestamp
        self.start = start; self.end = end; self.text = text
    }
}

/// Device-local rendering evidence. No voice vectors or address-book identifiers belong here.
public struct MeetingSpeakerState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let epoch: UUID
    public var revision: Int64
    public var speakers: [MeetingSpeaker]
    public var turns: [MeetingSpeakerTurn]
    public init(epoch: UUID = UUID(), revision: Int64 = 0, speakers: [MeetingSpeaker] = [], turns: [MeetingSpeakerTurn] = []) {
        schemaVersion = 1; self.epoch = epoch; self.revision = revision
        self.speakers = speakers; self.turns = turns
    }

    public var isValid: Bool {
        schemaVersion == 1 && revision >= 0 && Set(speakers.map(\.key)).count == speakers.count
            && Set(turns.map(\.id)).count == turns.count
            && speakers.allSatisfy { $0.key.epoch == epoch && $0.rank > 0 }
            && turns.allSatisfy { turn in
                turn.speaker.epoch == epoch && speakers.contains { $0.key == turn.speaker }
                    && turn.start.isFinite && turn.end.isFinite && turn.start >= 0 && turn.end >= turn.start
                    && turn.timestamp.count == 8 && turn.timestamp.allSatisfy { $0.isNumber || $0 == ":" }
            }
    }

    @discardableResult public mutating func assign(_ candidate: MeetingSpeakerAssignment, to key: MeetingSpeakerKey) -> Bool {
        guard let index = speakers.firstIndex(where: { $0.key == key && $0.isAssignable }) else { return false }
        if candidate.provenance != .manual {
            guard speakers[index].assignment?.provenance != .manual,
                  !speakers[index].declined.contains(candidate) else { return false }
        }
        guard !Self.safeLabel(candidate.name).isEmpty else { return false }
        if let previous = speakers[index].assignment { speakers[index].history.append(previous) }
        speakers[index].assignment = candidate
        return true
    }

    public mutating func declineAutomaticName(for key: MeetingSpeakerKey) {
        guard let index = speakers.firstIndex(where: { $0.key == key }),
              let previous = speakers[index].assignment, previous.provenance != .manual else { return }
        speakers[index].declined.insert(previous)
        speakers[index].history.append(previous)
        speakers[index].assignment = nil
    }

    public var labels: [MeetingSpeakerKey: String] {
        var result: [MeetingSpeakerKey: String] = [:]
        var used: Set<String> = []
        // Reserve every generic label as well as requested names before allocating suffixes.
        let reserved = Set((speakers.map(\.fallbackLabel) + ["You", "Others", "Multiple speakers", "Unknown speaker", "Microphone"]).map(Self.collisionKey))
        let requested = Set(speakers.compactMap { $0.assignment.map { Self.collisionKey(Self.safeLabel($0.name)) } })
        for speaker in speakers.sorted(by: { $0.rank == $1.rank ? $0.key.clusterID < $1.key.clusterID : $0.rank < $1.rank }) {
            let base = speaker.assignment.map { Self.safeLabel($0.name) }.flatMap { $0.isEmpty ? nil : $0 } ?? speaker.fallbackLabel
            var label = base
            var suffix = 2
            let namedReserved = speaker.assignment != nil && reserved.contains(Self.collisionKey(base))
            if namedReserved || used.contains(Self.collisionKey(label)) {
                repeat {
                    label = "\(base) (\(suffix))"; suffix += 1
                } while used.contains(Self.collisionKey(label)) || requested.contains(Self.collisionKey(label)) || reserved.contains(Self.collisionKey(label))
            }
            used.insert(Self.collisionKey(label)); result[speaker.key] = label
        }
        return result
    }

    public func render() -> String {
        let names = labels
        return turns.map { "[\($0.timestamp)] \(names[$0.speaker] ?? "Unknown speaker"): \($0.text)" }.joined(separator: "\n")
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func collisionKey(_ label: String) -> String {
        label.precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func safeLabel(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> String in
            // Foundation's control set includes format characters; retain joiners used by scripts/emoji.
            if scalar.value == 0x200C || scalar.value == 0x200D { return String(scalar) }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { return " " }
            return String(scalar)
        }.joined()
        return scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct MeetingTranscriptVersion: Equatable, Sendable {
    public let generation: Int64
    public let digest: String
    public init(generation: Int64, digest: String) { self.generation = generation; self.digest = digest }
}

public struct MeetingSpeakerSnapshot: Sendable {
    public let state: MeetingSpeakerState
    public let version: MeetingTranscriptVersion
    public let summaryIsStale: Bool
    public init(state: MeetingSpeakerState, version: MeetingTranscriptVersion, summaryIsStale: Bool) {
        self.state = state; self.version = version; self.summaryIsStale = summaryIsStale
    }
}

public enum MeetingSpeakerWriteResult: Equatable, Sendable { case updated, invalidated, conflict }
