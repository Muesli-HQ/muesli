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

    var elapsedSampleIndex: Int64? { currentChunkStartSampleIndex.map { $0 + currentChunkSampleCount } }
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

    /// Advances later chunk offsets over audio that exists only on the system track.
    /// This changes the next start index without inflating the current mic chunk duration.
    mutating func advanceStart(by sampleCount: Int64) {
        guard sampleCount > 0, let startSampleIndex = currentChunkStartSampleIndex else { return }
        currentChunkStartSampleIndex = startSampleIndex + sampleCount
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

/// Counts each active/pause interval independently so microphone transcript offsets
/// preserve any system-only tail that the combined recording writes before the next interval.
struct MeetingMicrophoneTimelineAlignment: Sendable {
    private var microphoneSampleCount: Int64 = 0
    private var systemSampleCount: Int64 = 0

    mutating func start() {
        microphoneSampleCount = 0
        systemSampleCount = 0
    }

    mutating func appendMicrophoneSamples(_ count: Int) {
        guard count > 0 else { return }
        microphoneSampleCount += Int64(count)
    }

    mutating func appendSystemSamples(_ count: Int) {
        guard count > 0 else { return }
        systemSampleCount += Int64(count)
    }

    /// Returns the system-only padding needed at this pause/resume boundary.
    mutating func closeInterval() -> Int64 {
        let padding = max(0, systemSampleCount - microphoneSampleCount)
        microphoneSampleCount = 0
        systemSampleCount = 0
        return padding
    }
}
