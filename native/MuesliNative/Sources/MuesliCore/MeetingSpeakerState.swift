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
    public var paletteIsSelf: Bool? = nil
    public var assignment: MeetingSpeakerAssignment?
    public var mergedInto: MeetingSpeakerKey? = nil
    public var declined: Set<MeetingSpeakerAssignment> = []
    public var history: [MeetingSpeakerAssignment] = []
    public init(key: MeetingSpeakerKey, rank: Int, fallbackLabel: String, isAssignable: Bool = true,
                isSelf: Bool = false, assignment: MeetingSpeakerAssignment? = nil, paletteIsSelf: Bool? = nil) {
        self.key = key; self.rank = rank; self.fallbackLabel = fallbackLabel
        self.isAssignable = isAssignable; self.isSelf = isSelf; self.paletteIsSelf = paletteIsSelf; self.assignment = assignment
    }
}

public struct MeetingSpeakerTurn: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var speaker: MeetingSpeakerKey
    public let timestamp: String
    public let start: Double
    public let end: Double
    public var text: String
    public var sampleEligible: Bool? = nil
    public var originalSpeaker: MeetingSpeakerKey? = nil
    public init(id: UUID = UUID(), speaker: MeetingSpeakerKey, timestamp: String, start: Double, end: Double, text: String) {
        self.id = id; self.speaker = speaker; self.timestamp = timestamp
        self.start = start; self.end = end; self.text = text; self.originalSpeaker = speaker
    }
}

/// Device-local rendering evidence. No voice vectors or address-book identifiers belong here.
public struct MeetingSpeakerState: Codable, Equatable, Sendable {
    /// Reserved prefix for newly escaped labels in timestamped transcript lines.
    public static let transcriptSpeakerLabelMarker = "\u{2063}"
    public let schemaVersion: Int
    public let epoch: UUID
    public var revision: Int64
    public var speakers: [MeetingSpeaker]
    public var turns: [MeetingSpeakerTurn]
    public var correctionHistory: [MeetingSpeakerCorrectionUndo]? = nil
    public init(epoch: UUID = UUID(), revision: Int64 = 0, speakers: [MeetingSpeaker] = [], turns: [MeetingSpeakerTurn] = []) {
        schemaVersion = 1; self.epoch = epoch; self.revision = revision
        self.speakers = speakers; self.turns = turns
    }

    public var isValid: Bool {
        schemaVersion == 1 && revision >= 0 && Set(speakers.map(\.key)).count == speakers.count
            && Set(turns.map(\.id)).count == turns.count
            && speakers.allSatisfy { $0.key.epoch == epoch && $0.rank > 0 && canonicalKey(for: $0.key) != nil }
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
        let active = speakers.filter { $0.mergedInto == nil }
        var result: [MeetingSpeakerKey: String] = [:]
        var used: Set<String> = []
        // Reserve every generic label as well as requested names before allocating suffixes.
        let reserved = Set((active.map(\.fallbackLabel) + ["You", "Others", "Multiple speakers", "Unknown speaker", "Microphone"]).map(Self.collisionKey))
        let requested = Set(active.compactMap { $0.assignment.map { Self.collisionKey(Self.safeLabel($0.name)) } })
        for speaker in active.sorted(by: { $0.rank == $1.rank ? $0.key.clusterID < $1.key.clusterID : $0.rank < $1.rank }) {
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
        for speaker in speakers where speaker.mergedInto != nil {
            if let key = canonicalKey(for: speaker.key) { result[speaker.key] = result[key] }
        }
        return result
    }

    public func render() -> String {
        let names = labels
        return turns.map {
            Self.renderTranscriptTurn(timestamp: $0.timestamp,
                speaker: names[$0.speaker] ?? "Unknown speaker", text: $0.text)
        }.joined(separator: "\n")
    }

    /// Renders the pre-escaping transcript format used by existing saved meetings.
    public func renderLegacy() -> String {
        let names = labels
        return turns.map {
            Self.renderLegacyTranscriptTurn(timestamp: $0.timestamp,
                speaker: names[$0.speaker] ?? "Unknown speaker", text: $0.text)
        }.joined(separator: "\n")
    }

    public func matchesTranscript(_ transcript: String) -> Bool {
        render() == transcript || renderLegacy() == transcript
    }

    public func matchesTranscriptDigest(_ digest: String) -> Bool {
        Self.digest(render()) == digest || Self.digest(renderLegacy()) == digest
    }

    public static func renderTranscriptTurn(timestamp: String, speaker: String, text: String) -> String {
        let encodedLabel = transcriptLabel(speaker)
        let marker = encodedLabel == speaker ? "" : transcriptSpeakerLabelMarker
        return "[\(timestamp)] \(marker)\(encodedLabel): \(text)"
    }

    public static func renderLegacyTranscriptTurn(timestamp: String, speaker: String, text: String) -> String {
        "[\(timestamp)] \(speaker): \(text)"
    }

    public static func escapedTranscriptSpeakerLabel(_ label: String) -> String {
        transcriptLabel(label)
    }

    /// Adds an invisible in-editor boundary after newly escaped speaker labels.
    public static func transcriptForEditing(_ transcript: String) -> String {
        transcript.components(separatedBy: "\n").map { line in
            guard let parsed = encodedSpeakerLabel(in: line) else { return line }
            return String(line[..<parsed.labelBoundary]) + parsed.label
                + transcriptSpeakerLabelMarker + String(line[parsed.separator...])
        }.joined(separator: "\n")
    }

    /// Restores stored escaping from the editor's invisible speaker boundary.
    public static func storedTranscript(fromEditingTranscript transcript: String) -> String {
        transcript.components(separatedBy: "\n").map { line in
            guard let parsed = editingSpeakerLabel(in: line) else { return line }
            let label = safeLabel(String(line[parsed.labelBoundary..<parsed.marker]))
            let encodedLabel = transcriptLabel(label)
            let marker = encodedLabel == label ? "" : transcriptSpeakerLabelMarker
            return String(line[..<parsed.labelBoundary]) + marker + encodedLabel + String(line[parsed.separator...])
        }.joined(separator: "\n")
    }

    /// Removes the editor's invisible boundary for clipboard output.
    public static func displayTranscript(fromEditingTranscript transcript: String) -> String {
        transcript.components(separatedBy: "\n").map { line in
            guard let parsed = editingSpeakerLabel(in: line) else { return line }
            let label = String(line[parsed.labelBoundary..<parsed.marker])
            return String(line[..<parsed.labelBoundary]) + label + String(line[parsed.separator...])
        }.joined(separator: "\n")
    }

    /// Removes only the escaping added to timestamped speaker labels. Speech text remains byte-for-byte intact.
    public static func modelFacingTranscript(_ transcript: String) -> String {
        transcript.components(separatedBy: "\n").map { line in
            guard let parsed = encodedSpeakerLabel(in: line) else { return line }
            return String(line[..<parsed.labelBoundary]) + parsed.label + String(line[parsed.separator...])
        }.joined(separator: "\n")
    }

    private static func encodedSpeakerLabel(in line: String) -> (labelBoundary: String.Index, separator: String.Index, label: String)? {
        guard let labelBoundary = timestampLabelBoundary(in: line),
              line[labelBoundary...].hasPrefix(transcriptSpeakerLabelMarker) else { return nil }
        let labelStart = line.index(labelBoundary, offsetBy: transcriptSpeakerLabelMarker.count)
        var cursor = labelStart
        var precedingBackslashes = 0
        var separator: String.Index?
        while cursor < line.endIndex {
            if line[cursor] == ":", precedingBackslashes.isMultiple(of: 2) {
                let next = line.index(after: cursor)
                if next < line.endIndex, line[next] == " " { separator = cursor; break }
            }
            precedingBackslashes = line[cursor] == "\\" ? precedingBackslashes + 1 : 0
            cursor = line.index(after: cursor)
        }
        guard let separator else { return nil }
        let encodedLabel = String(line[labelStart..<separator])
        var decoded = ""
        var index = encodedLabel.startIndex
        while index < encodedLabel.endIndex {
            if encodedLabel[index] == "\\" {
                let next = encodedLabel.index(after: index)
                if next < encodedLabel.endIndex, encodedLabel[next] == "\\" || encodedLabel[next] == ":" {
                    decoded.append(encodedLabel[next])
                    index = encodedLabel.index(after: next)
                    continue
                }
            }
            decoded.append(encodedLabel[index])
            index = encodedLabel.index(after: index)
        }
        guard transcriptLabel(decoded) == encodedLabel else { return nil }
        return (labelBoundary, separator, decoded)
    }

    private static func editingSpeakerLabel(in line: String) -> (labelBoundary: String.Index, marker: String.Index, separator: String.Index)? {
        guard let labelBoundary = timestampLabelBoundary(in: line),
              let marker = line[labelBoundary...].firstIndex(of: "\u{2063}") else { return nil }
        let separator = line.index(after: marker)
        guard separator < line.endIndex, line[separator] == ":" else { return nil }
        let body = line.index(after: separator)
        guard body < line.endIndex, line[body] == " " else { return nil }
        return (labelBoundary, marker, separator)
    }

    private static func timestampLabelBoundary(in line: String) -> String.Index? {
        guard line.first == "[", let timestampEnd = line.firstIndex(of: "]") else { return nil }
        let timestamp = line[line.index(after: line.startIndex)..<timestampEnd]
        guard timestamp.count == 8, timestamp.allSatisfy({ $0.isNumber || $0 == ":" }) else { return nil }
        let space = line.index(after: timestampEnd)
        guard space < line.endIndex, line[space] == " " else { return nil }
        let boundary = line.index(after: space)
        return boundary < line.endIndex ? boundary : nil
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func collisionKey(_ label: String) -> String {
        label.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func transcriptLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
    }

    public static func safeLabel(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> String in
            // Foundation's control set includes format characters; retain joiners used by scripts/emoji.
            if scalar.value == 0x200C || scalar.value == 0x200D { return String(scalar) }
            if scalar.value == 0x2063 || CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
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
