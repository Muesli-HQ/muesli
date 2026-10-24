import Foundation

/// Semantic test boundary. These cases are NOT verified WeChat AX identifiers.
/// The production collector never emits a snapshot until a UI schema is validated.
enum WeChatCallDetectionSchema: Sendable, Equatable { case syntheticV1, unverified }
enum WeChatCallDetectionActivity: Sendable, Equatable {
    case idle, voiceNoteRecording, voiceNotePlayback, ringing, connecting, connected, ended, unknown
}
enum WeChatCallDetectionControl: Sendable, Hashable { case endCall, mute }

struct WeChatCallDetectionSurface: Sendable {
    var expectedSource: CallDetectionSource
    var source: CallDetectionSource
    var schema: WeChatCallDetectionSchema
    var activity: WeChatCallDetectionActivity
    var controls: Set<WeChatCallDetectionControl>
    var sessionGeneration: String
    var roster: CallDetectionRoster // opaque IDs supplied by the provider, never display names
}
struct WeChatCallDetectionSnapshot: Sendable {
    let observedAt: Date
    let surfaces: [WeChatCallDetectionSurface]
}
enum WeChatCallDetectionSnapshotResult: Sendable {
    case snapshot(WeChatCallDetectionSnapshot)
    case unavailable(CallDetectionUnavailableReason)
}
protocol WeChatCallDetectionSnapshotProviding: Sendable {
    func snapshot() async -> WeChatCallDetectionSnapshotResult
}
