import Foundation

public enum MeetingSpeakerApp: String, CaseIterable, Sendable {
    case zoom, teams, meet, slack
    public var tileMarker: String {
        switch self { case .zoom: "zoom participant"; case .teams: "teams participant"
        case .meet: "video tile"; case .slack: "huddle participant" }
    }
}
public enum MeetingSpeakerAccessibilitySamplingPolicy {
    public static let pollInterval = 1.0
    public static let maximumReadDuration = 1.5
    public static let schedulerSlack = 0.25
    public static let maximumVoteGap = pollInterval + maximumReadDuration + schedulerSlack
    public static let maximumObservations = 14_400
    public static let maximumWindowsPerApp = 8
    public static let maximumBrowserWindowsScanned = 24
    public static let totalReadDuration = maximumReadDuration
    public static let perWindowReadDuration = 0.25
}
public enum MeetingSpeakerEvidenceReason: String, CaseIterable, Sendable {
    case clear, rosterOnly, unrecognized, truncated, ambiguous, multipleHosts, multipleWindows, unavailable, windowLimit
}
public enum MeetingSpeakerAccessibilityDiagnosticReason: String, CaseIterable, Sendable {
    case noSystemAudio = "no_system_audio"
    case readOverBudget = "read_over_budget"
    case authorizationChanged = "authorization_changed"
    case clockInvalid = "clock_invalid"
    case continuityBreak = "continuity_break"
    case unrecognizedLayout = "unrecognized_layout"
    case truncatedRead = "truncated_read"
    case ambiguousLayout = "ambiguous_layout"
    case multipleHosts = "multiple_hosts"
    case multipleWindows = "multiple_windows"
    case unavailable = "unavailable"
    case windowLimit = "window_limit"
    case scopeChanged = "scope_changed"
    case rosterOnly = "roster_only"
}
public struct MeetingSpeakerAXNode: Sendable {
    public let id: String
    public let role: String
    public let detail: String
    public let value: String?
    public var children: [Self]
    public init(id: String, role: String, detail: String, value: String? = nil, children: [Self] = []) {
        self.id = id; self.role = role; self.detail = detail; self.value = value; self.children = children
    }
}
public struct MeetingSpeakerAXWindow: Sendable {
    public let scope: String
    public let app: MeetingSpeakerApp
    public let documentURL: String?
    public var root: MeetingSpeakerAXNode
    public var truncated: Bool
    public init(scope: String, app: MeetingSpeakerApp, documentURL: String? = nil, root: MeetingSpeakerAXNode, truncated: Bool = false) {
        self.scope = scope; self.app = app; self.documentURL = documentURL; self.root = root; self.truncated = truncated
    }
}
public struct MeetingSpeakerParticipant: Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct MeetingSpeakerFrame: Sendable {
    public let scope: String
    public let app: MeetingSpeakerApp
    public let participants: [MeetingSpeakerParticipant]
    public let activeID: String?
    public let reason: MeetingSpeakerEvidenceReason
    public let diagnosticReasons: [MeetingSpeakerEvidenceReason]
    public var active: MeetingSpeakerParticipant? {
        reason == .clear ? participants.first { $0.id == activeID } : nil
    }
    public init(scope: String, app: MeetingSpeakerApp, participants: [MeetingSpeakerParticipant] = [], activeID: String? = nil, reason: MeetingSpeakerEvidenceReason = .clear, diagnosticReasons: [MeetingSpeakerEvidenceReason] = []) {
        self.scope = scope; self.app = app; self.participants = participants; self.activeID = activeID; self.reason = reason; self.diagnosticReasons = diagnosticReasons
    }
}

/// Semantic contracts pending validation against real application layouts. Selection/focus is never activity.
public enum MeetingSpeakerSources {
    /// An incomplete Meet scan may hide another active meeting, so it withholds
    /// evidence from every host in the combined observation.
    public static func incompleteMeetScan(scope: String = "") -> MeetingSpeakerFrame {
        .init(scope: scope, app: .meet, reason: .truncated, diagnosticReasons: [.truncated])
    }

    public static func decode(_ window: MeetingSpeakerAXWindow) -> MeetingSpeakerFrame {
        func result(_ reason: MeetingSpeakerEvidenceReason, _ people: [MeetingSpeakerParticipant] = [], _ active: String? = nil) -> MeetingSpeakerFrame {
            .init(scope: window.scope, app: window.app, participants: people, activeID: active, reason: reason)
        }
        guard !window.truncated else { return result(.truncated) }
        if window.app == .meet {
            guard let raw = window.documentURL, let url = URLComponents(string: raw),
                  url.scheme == "https", url.host?.lowercased() == "meet.google.com", !url.path.isEmpty else { return result(.unrecognized) }
        }
        var people: [MeetingSpeakerParticipant] = [], speaking: [String] = [], invalid = false
        func walk(_ node: MeetingSpeakerAXNode) {
            if node.role == "AXGroup", node.detail.lowercased() == window.app.tileMarker {
                let names = node.children.filter { ["participant name", "display name"].contains($0.detail.lowercased()) }
                guard names.count == 1, let raw = names.first?.value else { invalid = true; return }
                let name = MeetingSpeakerState.safeLabel(raw)
                guard !name.isEmpty, name.count <= 120 else { invalid = true; return }
                let statuses = node.children.filter { $0.detail.lowercased() == "speaking status" }
                guard statuses.count <= 1 else { invalid = true; return }
                let id = window.scope + "/" + node.id
                people.append(.init(id: id, name: name))
                if statuses.first?.value == "true" { speaking.append(id) }
            } else { node.children.forEach(walk) }
        }
        walk(window.root)
        guard !invalid, Set(people.map(\.id)).count == people.count, speaking.count <= 1 else { return result(.ambiguous) }
        guard !people.isEmpty else {
            return result(window.app == .meet ? .ambiguous : .unrecognized)
        }
        return result(speaking.isEmpty ? .rosterOnly : .clear, people, speaking.first)
    }
    public static func combine(_ frames: [MeetingSpeakerFrame]) -> MeetingSpeakerFrame {
        let diagnosticReasons = Array(Set(frames.flatMap { frame in
            frame.diagnosticReasons + (frame.reason == .windowLimit ? [.windowLimit] : [])
        }))
        let relevant = frames.filter { $0.reason != .unrecognized }
        guard let first = relevant.first else {
            return .init(scope: "", app: frames.first?.app ?? .zoom, reason: .unrecognized, diagnosticReasons: diagnosticReasons)
        }
        func failure(_ reason: MeetingSpeakerEvidenceReason) -> MeetingSpeakerFrame {
            .init(scope: first.scope, app: first.app, reason: reason, diagnosticReasons: diagnosticReasons)
        }
        if let failed = relevant.first(where: { [.truncated, .unavailable, .ambiguous, .windowLimit].contains($0.reason) }) {
            return failure(failed.reason)
        }
        guard Set(relevant.map(\.app)).count <= 1 else { return failure(.multipleHosts) }
        guard relevant.count == 1 else { return failure(.multipleWindows) }
        return .init(scope: first.scope, app: first.app, participants: first.participants,
            activeID: first.activeID, reason: first.reason, diagnosticReasons: diagnosticReasons)
    }

    /// Filters unrelated browser windows before applying the limit to actual Meet windows.
    /// `nil` means the caller found more relevant Meet windows than the supported limit.
    public static func meetDocumentURLs(_ documents: [String?], maximumRelevantWindows: Int) -> [String]? {
        let meetURLs = documents.compactMap { raw -> String? in
            guard let raw, let url = URLComponents(string: raw), url.scheme == "https",
                  url.host?.lowercased() == "meet.google.com", !url.path.isEmpty else { return nil }
            return raw
        }
        guard meetURLs.count <= max(0, maximumRelevantWindows) else { return nil }
        return meetURLs
    }
}
public struct MeetingSpeakerObservation: Sendable {
    public let time: Double
    public let continuity: String
    public let frame: MeetingSpeakerFrame
    public init(time: Double, continuity: String, frame: MeetingSpeakerFrame) { self.time = time; self.continuity = continuity; self.frame = frame }
}
public struct MeetingSpeakerActivity: Sendable {
    public let key: MeetingSpeakerKey
    public let start: Double
    public let end: Double
    public init(key: MeetingSpeakerKey, start: Double, end: Double) { self.key = key; self.start = start; self.end = end }
}
public struct MeetingSpeakerEvidenceAssignments: Sendable {
    public var names: [MeetingSpeakerKey: MeetingSpeakerAssignment] = [:]
}
public struct MeetingSpeakerTimeline: Sendable {
    public var observations: [MeetingSpeakerObservation]
    /// Caller-supplied global truncation guard. The monitor's bounded ring is intentionally rolling:
    /// expired early frames do not make the retained, ordered window incomplete.
    public var incomplete: Bool
    public var diagnosticCounts: [MeetingSpeakerAccessibilityDiagnosticReason: Int]
    public init(observations: [MeetingSpeakerObservation] = [], incomplete: Bool = false,
                diagnosticCounts: [MeetingSpeakerAccessibilityDiagnosticReason: Int] = [:]) {
        self.observations = observations; self.incomplete = incomplete; self.diagnosticCounts = diagnosticCounts
    }
    public var diagnosticSummary: String {
        MeetingSpeakerAccessibilityDiagnosticReason.allCases.compactMap { reason in
            guard let count = diagnosticCounts[reason], count > 0 else { return nil }
            return "\(reason.rawValue)=\(count)"
        }.joined(separator: ",")
    }
    public func assignments(activities: [MeetingSpeakerActivity]) -> MeetingSpeakerEvidenceAssignments {
        guard !incomplete, observations.count >= 3 else { return .init() }
        let valid = activities.filter { $0.key.channel == .system && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
        let grouped = Dictionary(grouping: valid, by: \.key)
        struct Vote { var seconds = 0.0; var polls: Set<Int> = []; var person: MeetingSpeakerParticipant }
        var winners: [MeetingSpeakerKey: Vote] = [:]
        for (key, chunks) in grouped {
            guard !valid.contains(where: { other in other.key != key && chunks.contains { max($0.start, other.start) < min($0.end, other.end) } }) else { continue }
            var union: [(Double, Double)] = []
            for chunk in chunks.sorted(by: { $0.start < $1.start }) {
                if let last = union.last, chunk.start <= last.1 { union[union.count - 1].1 = max(last.1, chunk.end) }
                else { union.append((chunk.start, chunk.end)) }
            }
            let duration = union.reduce(0) { $0 + $1.1 - $1.0 }
            var votes: [String: Vote] = [:]
            for index in 1..<observations.count {
                let a = observations[index - 1], b = observations[index]
                guard a.time.isFinite, b.time.isFinite, a.time >= 0, b.time > a.time,
                      b.time - a.time <= MeetingSpeakerAccessibilitySamplingPolicy.maximumVoteGap,
                      a.continuity == b.continuity, a.frame.scope == b.frame.scope, a.frame.app == b.frame.app,
                      let person = a.frame.active, person == b.frame.active else { continue }
                let seconds = union.reduce(0) { $0 + max(0, min($1.1, b.time) - max($1.0, a.time)) }
                guard seconds > 0 else { continue }
                var vote = votes[person.id] ?? Vote(person: person)
                vote.seconds += seconds; vote.polls.formUnion([index - 1, index]); votes[person.id] = vote
            }
            let supported = votes.values.reduce(0) { $0 + $1.seconds }
            guard let best = votes.values.max(by: { $0.seconds < $1.seconds }), best.seconds >= 2, best.polls.count >= 3,
                  supported / duration >= 0.60, best.seconds / supported >= 0.85 else { continue }
            winners[key] = best
        }
        let counts = Dictionary(grouping: winners.values, by: { $0.person.id }).mapValues(\.count)
        let displayNameCounts = Dictionary(grouping: winners.values, by: {
            $0.person.name.precomposedStringWithCanonicalMapping.lowercased()
        }).mapValues(\.count)
        var result = MeetingSpeakerEvidenceAssignments()
        for (key, vote) in winners where counts[vote.person.id] == 1
            && displayNameCounts[vote.person.name.precomposedStringWithCanonicalMapping.lowercased()] == 1 {
            result.names[key] = .init(name: vote.person.name, provenance: .accessibility)
        }
        return result
    }
    public func apply(activities: [MeetingSpeakerActivity], to state: inout MeetingSpeakerState) {
        for (key, assignment) in assignments(activities: activities).names { state.assign(assignment, to: key) }
    }

    public func apply(_ assignments: MeetingSpeakerEvidenceAssignments, to state: inout MeetingSpeakerState) {
        for (key, assignment) in assignments.names { state.assign(assignment, to: key) }
    }
}

extension MeetingSpeakerState {
    /// Revocation removes structured overrides, including undo evidence, without touching speech text.
    public mutating func removeAccessibilityAssignments() {
        func scrub(_ speaker: inout MeetingSpeaker) {
            if speaker.assignment?.provenance == .accessibility { speaker.assignment = nil }
            speaker.history.removeAll { $0.provenance == .accessibility }
        }
        for index in speakers.indices { scrub(&speakers[index]) }
        if var history = correctionHistory {
            for entry in history.indices {
                for index in history[entry].speakers.indices { scrub(&history[entry].speakers[index]) }
            }
            correctionHistory = history
        }
    }
}
