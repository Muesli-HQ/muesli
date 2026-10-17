import Foundation

struct MeetingChunkTimingSnapshot: Equatable, Sendable {
    let startSampleIndex: Int64
    let sampleCount: Int64

    var startTimeSeconds: TimeInterval {
        Double(startSampleIndex) / Double(MeetingChunkTimingTracker.sampleRate)
    }

    var durationSeconds: TimeInterval {
        Double(sampleCount) / Double(MeetingChunkTimingTracker.sampleRate)
    }
}

struct MeetingChunkTimingTracker: Sendable {
    static let sampleRate = 16_000

    private var currentChunkStartSampleIndex: Int64?
    private var currentChunkSampleCount: Int64 = 0

    var elapsedTimeSeconds: Double? {
        currentChunkStartSampleIndex.map { Double($0 + currentChunkSampleCount) / Double(Self.sampleRate) }
    }

    mutating func start() {
        currentChunkStartSampleIndex = 0
        currentChunkSampleCount = 0
    }

    mutating func append(sampleCount: Int) {
        guard sampleCount > 0, currentChunkStartSampleIndex != nil else { return }
        currentChunkSampleCount += Int64(sampleCount)
    }

    mutating func rotate() -> MeetingChunkTimingSnapshot? {
        guard let currentChunkStartSampleIndex else { return nil }
        let snapshot = MeetingChunkTimingSnapshot(
            startSampleIndex: currentChunkStartSampleIndex,
            sampleCount: currentChunkSampleCount
        )
        self.currentChunkStartSampleIndex = currentChunkStartSampleIndex + currentChunkSampleCount
        currentChunkSampleCount = 0
        return snapshot
    }

    mutating func finish() -> MeetingChunkTimingSnapshot? {
        guard let startSampleIndex = currentChunkStartSampleIndex else { return nil }
        let snapshot = MeetingChunkTimingSnapshot(
            startSampleIndex: startSampleIndex,
            sampleCount: currentChunkSampleCount
        )
        currentChunkStartSampleIndex = nil
        currentChunkSampleCount = 0
        return snapshot
    }

    mutating func discard() {
        currentChunkStartSampleIndex = nil
        currentChunkSampleCount = 0
    }
}
