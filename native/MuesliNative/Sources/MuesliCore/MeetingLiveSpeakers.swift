import Foundation

public struct MeetingLiveSpeakerSegment: Sendable {
    public let clusterID: String
    public let start: Double
    public let end: Double
    public init(clusterID: String, start: Double, end: Double) { self.clusterID = clusterID; self.start = start; self.end = end }
}
public enum MeetingMicrophoneSpeechGate {
    public static func accepts(_ samples: [Float], speechSeconds: Double) -> Bool {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), speechSeconds.isFinite,
              speechSeconds >= 0.5, speechSeconds <= Double(samples.count) / 16_000 else { return false }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        return rms >= 0.003 && Double(samples.filter { abs($0) >= 0.98 }.count) / Double(samples.count) < 0.001
    }
}
public struct MeetingSpeakerAudioWindow: Sendable {
    public let channel: MeetingSpeakerKey.Channel
    public let startSample: Int64
    public let samples: [Float]
    public var start: Double { Double(startSample) / 16_000 }
    public var end: Double { start + Double(samples.count) / 16_000 }
}
public struct MeetingSpeakerCoverageGap: Sendable {
    public let channel: MeetingSpeakerKey.Channel
    public let start: Double
    public let end: Double
}
public struct MeetingLiveSpeakerTurnChange: Equatable, Sendable {
    public let index: Int
    public let turn: MeetingSpeakerTurn
    public let speakerKey: MeetingSpeakerKey
    public let speakerLabel: String
    public let isSelf: Bool
    public let paletteIsSelf: Bool?
    public let isPerson: Bool
}
public struct MeetingLiveSpeakerPresentationUpdate: Sendable {
    public let fromRevision: Int64
    public let state: MeetingSpeakerState
    public let changedTurns: [MeetingLiveSpeakerTurnChange]
}
/// Bounded PCM ownership; callers serialize access. Overload drops only identity evidence.
public struct MeetingSpeakerPCMQueue: Sendable {
    private var partial: [MeetingSpeakerKey.Channel: MeetingSpeakerAudioWindow] = [:]
    private var windows: [MeetingSpeakerAudioWindow] = []
    private var gaps: [MeetingSpeakerKey.Channel: MeetingSpeakerCoverageGap] = [:]
    public var pendingCount: Int { windows.count }
    public init() {}
    public mutating func append(_ samples: [Float], channel: MeetingSpeakerKey.Channel, startSample: Int64) {
        guard channel != .imported, startSample >= 0 else { return }
        var index = 0
        while index < samples.count {
            var current = partial[channel] ?? .init(channel: channel, startSample: startSample + Int64(index), samples: [])
            if current.startSample + Int64(current.samples.count) != startSample + Int64(index) {
                noteGap(current); current = .init(channel: channel, startSample: startSample + Int64(index), samples: [])
            }
            let count = min(80_000 - current.samples.count, samples.count - index)
            var combined = current.samples; combined.append(contentsOf: samples[index..<(index + count)])
            current = .init(channel: channel, startSample: current.startSample, samples: combined); index += count
            if current.samples.count == 80_000 {
                if windows.filter({ $0.channel == channel }).count < 2 { windows.append(current) }
                else { noteGap(current) }
                partial[channel] = nil
            } else { partial[channel] = current }
        }
    }
    public mutating func pop() -> MeetingSpeakerAudioWindow? { windows.isEmpty ? nil : windows.removeFirst() }
    public mutating func resetPartial() -> [MeetingSpeakerCoverageGap] {
        for window in partial.values { noteGap(window) }
        partial.removeAll(); return takeGaps()
    }
    public mutating func takeGaps() -> [MeetingSpeakerCoverageGap] { defer { gaps.removeAll() }; return Array(gaps.values) }
    private mutating func noteGap(_ window: MeetingSpeakerAudioWindow) {
        let previous = gaps[window.channel]
        gaps[window.channel] = .init(channel: window.channel, start: min(previous?.start ?? window.start, window.start), end: max(previous?.end ?? window.end, window.end))
    }
}

public struct MeetingLiveSpeakerRegistry: Sendable {
    public private(set) var state: MeetingSpeakerState
    private struct Range: Sendable { var start: Double; var end: Double }
    private var evidence: [MeetingSpeakerKey.Channel: [MeetingLiveSpeakerSegment]] = [:]
    private var coverage: [MeetingSpeakerKey.Channel: [Range]] = [:]
    private var failures: [MeetingSpeakerKey.Channel: [Range]] = [:]
    private var floor: [MeetingSpeakerKey.Channel: Double] = [:]
    private var processed: [MeetingSpeakerKey.Channel: Double] = [:]
    private var pending: Set<UUID> = []
    private var pendingSince: [UUID: TimeInterval] = [:]
    private var elapsedTime: TimeInterval = 0
    private var changedTurns: [Int: MeetingSpeakerTurn] = [:]
    private var publishedRevision: Int64 = -1
    private var finished = false
    public init(epoch: UUID = UUID()) { state = .init(epoch: epoch) }
    public mutating func append(_ original: MeetingSpeakerTurn, channel: MeetingSpeakerKey.Channel,
                                at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard channel != .imported, original.start.isFinite, original.end.isFinite, original.start >= 0, original.end >= original.start,
              !state.turns.contains(where: { $0.id == original.id }) else { return }
        let startTime = time.isFinite && time >= 0 ? max(elapsedTime, time) : elapsedTime
        elapsedTime = startTime
        let key = placeholder(channel: channel, kind: "pending", label: "Identifying speaker")
        var turn = original; turn.speaker = key; turn.originalSpeaker = key
        state.turns.append(turn); pending.insert(turn.id); pendingSince[turn.id] = startTime; state.revision += 1
        changedTurns[state.turns.count - 1] = turn
        settle()
    }
    public mutating func takePresentationUpdate() -> MeetingLiveSpeakerPresentationUpdate? {
        guard state.revision > publishedRevision else { return nil }
        let fromRevision = publishedRevision
        let changes = changedTurns.keys.sorted().compactMap { index in
            changedTurns[index].map { turn in
                let speaker = state.speakers.first { $0.key == turn.speaker }
                return MeetingLiveSpeakerTurnChange(
                    index: index,
                    turn: turn,
                    speakerKey: turn.speaker,
                    speakerLabel: speaker?.fallbackLabel ?? "Unknown speaker",
                    isSelf: speaker?.isSelf ?? false,
                    paletteIsSelf: speaker?.paletteIsSelf ?? speaker?.isSelf,
                    isPerson: speaker?.isAssignable ?? false
                )
            }
        }
        changedTurns.removeAll(keepingCapacity: true)
        publishedRevision = state.revision
        return .init(fromRevision: fromRevision, state: state, changedTurns: changes)
    }
    public mutating func advanceElapsedTime(to time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        elapsedTime = max(elapsedTime, time); settle()
    }
    public mutating func complete(channel: MeetingSpeakerKey.Channel, start: Double, end: Double, segments: [MeetingLiveSpeakerSegment], failed: Bool = false) {
        guard !finished, start.isFinite, end.isFinite, start >= 0, end > start else { return }
        processed[channel] = max(processed[channel] ?? 0, end)
        if failed { failures[channel, default: []].append(.init(start: start, end: end)) }
        else {
            coverage[channel, default: []].append(.init(start: start, end: end))
            evidence[channel, default: []].append(contentsOf: segments.compactMap {
                guard !$0.clusterID.isEmpty, $0.start.isFinite, $0.end.isFinite else { return nil }
                let lower = max(start, $0.start), upper = min(end, $0.end)
                return upper > lower ? .init(clusterID: $0.clusterID, start: lower, end: upper) : nil
            })
        }
        for ranges in [true, false] {
            let values = ranges ? coverage[channel, default: []] : failures[channel, default: []]
            let merged = union(values)
            if merged.count > 128 {
                floor[channel] = max(floor[channel] ?? 0, merged[merged.count - 128].start)
            }
            let retained = Array(merged.suffix(128))
            if ranges { coverage[channel] = retained } else { failures[channel] = retained }
        }
        if evidence[channel, default: []].count > 100_000 {
            let sorted = evidence[channel, default: []].sorted { $0.end < $1.end }
            let removed = sorted.count - 99_000
            floor[channel] = max(floor[channel] ?? 0, sorted[removed - 1].end)
            evidence[channel] = Array(sorted.dropFirst(removed))
        }
        settle()
    }
    public mutating func finish() { finished = true; settle() }
    public mutating func withholdSamples(channel: MeetingSpeakerKey.Channel, after boundary: Double) {
        guard boundary.isFinite, boundary >= 0 else { return }
        var changed = false
        for index in state.turns.indices {
            let turn = state.turns[index]
            let sourceChannel = turn.originalSpeaker?.channel ?? turn.speaker.channel
            guard sourceChannel == channel, turn.end > boundary, turn.sampleEligible != false else { continue }
            state.turns[index].sampleEligible = false
            changed = true
        }
        if changed { state.revision += 1 }
    }
    private mutating func settle() {
        for index in state.turns.indices where pending.contains(state.turns[index].id) {
            let turn = state.turns[index], channel = turn.speaker.channel
            let expired = elapsedTime >= (pendingSince[turn.id] ?? elapsedTime) + 8
            let ready = (processed[channel] ?? 0) >= turn.end + 1.5
            let gap = turn.start < (floor[channel] ?? 0) || failures[channel, default: []].contains { max(turn.start, $0.start) < min(turn.end, $0.end) }
            guard finished || expired || gap || ready || pending.count > 128 else { continue }
            var key: MeetingSpeakerKey?
            if ready, !gap, covers(turn.start, turn.end, ranges: coverage[channel, default: []]) {
                let active = evidence[channel, default: []].filter { max(turn.start, $0.start) < min(turn.end, $0.end) }
                let ids = Set(active.map(\.clusterID))
                if ids.count > 1 { key = placeholder(channel: channel, kind: "mixed", label: "Multiple speakers") }
                else if let id = ids.first {
                    let supported = union(active.map { .init(start: max(turn.start, $0.start), end: min(turn.end, $0.end)) }).reduce(0) { $0 + $1.end - $1.start }
                    if turn.end > turn.start, supported / (turn.end - turn.start) >= 0.8 {
                        let identity = MeetingSpeakerKey(epoch: state.epoch, channel: channel, clusterID: id)
                        if !state.speakers.contains(where: { $0.key == identity }) {
                            let number = state.speakers.filter { $0.key.channel == channel && $0.isAssignable }.count + 1
                            let label = channel == .microphone ? "Local speaker \(number)" : "Speaker \(number)"
                            state.speakers.append(.init(key: identity, rank: state.speakers.count + 1, fallbackLabel: label))
                        }
                        key = identity
                    }
                }
            } else if ready, !gap, !expired, !finished, pending.count <= 128 { continue }
            state.turns[index].speaker = key ?? placeholder(channel: channel, kind: "source", label: channel == .microphone ? "Microphone" : "Others")
            pending.remove(turn.id); pendingSince.removeValue(forKey: turn.id); state.revision += 1
            changedTurns[index] = state.turns[index]
        }
    }
    private mutating func placeholder(channel: MeetingSpeakerKey.Channel, kind: String, label: String) -> MeetingSpeakerKey {
        let key = MeetingSpeakerKey(epoch: state.epoch, channel: channel, clusterID: "aggregate:\(kind)")
        if !state.speakers.contains(where: { $0.key == key }) { state.speakers.append(.init(key: key, rank: state.speakers.count + 1, fallbackLabel: label, isAssignable: false)) }
        return key
    }
    private func union(_ ranges: [Range]) -> [Range] {
        var result: [Range] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end + 0.001 { result[result.count - 1].end = max(last.end, range.end) }
            else { result.append(range) }
        }
        return result
    }
    private func covers(_ start: Double, _ end: Double, ranges: [Range]) -> Bool {
        union(ranges).contains { $0.start <= start && $0.end >= end }
    }
}
