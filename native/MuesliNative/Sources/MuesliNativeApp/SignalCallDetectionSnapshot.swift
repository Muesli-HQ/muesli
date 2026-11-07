import Foundation

/// No macOS AX profile is validated yet. syntheticV1 is exclusively an injected
/// provider format; DOM classes/localization keys are not AX identifiers.
enum SignalCallDetectionProfile: Sendable {
    case syntheticV1, unsupported
}

enum SignalCallDetectionContent: Sendable {
    case call, idleChat, voiceNoteRecording, voiceNotePlayback
}

enum SignalCallDetectionConnection: Sendable {
    // accepted means application acceptance/join, never just group transport
    // Connected. Signal's pending-approval lobby also exposes hangup and mic.
    case accepted, ringing, prejoin, pendingApproval, connecting, reconnecting, ended, unknown
}

struct SignalCallDetectionSurface: Sendable {
    let source: CallDetectionSource
    let callGeneration: String
    let content: SignalCallDetectionContent
    let connection: SignalCallDetectionConnection
    let hasHangupControl: Bool
    let hasMicrophoneControl: Bool
    let roster: CallDetectionRoster
}

struct SignalCallDetectionSnapshot: Sendable {
    let source: CallDetectionSource
    let observedAt: Date
    let profile: SignalCallDetectionProfile
    let surfaces: [SignalCallDetectionSurface]
}

enum SignalCallDetectionSnapshotRead: Sendable {
    case snapshot(SignalCallDetectionSnapshot)
    case unavailable(CallDetectionUnavailableReason)
}

protocol SignalCallDetectionSnapshotProvider: Sendable {
    /// Preserve source read time on cached data; do not refresh it on return.
    /// Source surfaceID and callGeneration must rotate on replacement/rejoin.
    func snapshot(deadline: Date) async -> SignalCallDetectionSnapshotRead
}
