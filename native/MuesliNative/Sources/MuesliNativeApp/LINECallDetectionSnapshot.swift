import Foundation

/// Semantic boundary for a future verified LINE AX mapper. Current positives
/// are synthetic fixtures only; the production collector never asserts a call.
enum LINECallDetectionSurfaceKind: Sendable, Equatable {
    case idle, voiceNoteRecording, voiceNotePlayback, ringing, prejoin, connected
    case ended, settings, deviceTest, callLog, unknown
}
enum LINECallDetectionControl: Sendable, Hashable { case endCall, mute }
struct LINECallDetectionSurface: Sendable {
    let kind: LINECallDetectionSurfaceKind
    /// Must change on every new call or reconnect, even in the same window.
    let callGeneration: String
    let controls: Set<LINECallDetectionControl>
    /// Opaque call-scoped IDs only; visible tiles cannot prove completeness.
    let roster: CallDetectionRoster
}
struct LINECallDetectionSnapshot: Sendable {
    let sourceBeforeRead: CallDetectionSource
    let sourceAfterRead: CallDetectionSource
    /// Original source-read time, including when a provider returns cached data.
    let observedAt: Date
    /// One scoped surface only. Incomplete enumeration must return unavailable.
    let surfaces: [LINECallDetectionSurface]
}
enum LINECallDetectionCollection: Sendable {
    case snapshot(LINECallDetectionSnapshot)
    case unavailable(CallDetectionUnavailableReason)
}
protocol LINECallDetectionSnapshotProviding: Sendable {
    /// Implementations must bound collection, cooperate with cancellation and
    /// return unavailable when source/call generation cannot be established.
    func snapshot() async -> LINECallDetectionCollection
}
