import Foundation

/// Shared observation boundary for desktop and browser call adapters.
/// Detection does not authorize recording. See docs/call-detection.md.
enum CallDetectionService: String, Sendable, Equatable {
    case signal, telegram, line, weChat, chatwoot
}
struct CallDetectionSource: Sendable, Equatable {
    let bundleID: String
    let processID: Int32
    let processLaunchID: String
    let surfaceID: String // browser document generation, not only window/tab
    let origin: String? // normalized origin only; nil for desktop apps
}
enum CallDetectionPhase: Sendable, Equatable {
    case ringing, connecting, connected, ended, unknown
}
enum CallDetectionEvidence: String, Sendable, Hashable {
    case scopedCallControls, connectedState, attributedAudioInput, verifiedBrowserOrigin
}
enum CallDetectionRoster: Sendable, Equatable {
    case unknown
    case partial(Set<String>)
    case complete(Set<String>)
}
struct CallDetectionObservation: Sendable, Equatable {
    let service: CallDetectionService
    let source: CallDetectionSource
    let callToken: String
    let observedAt: Date // source snapshot time, never parse/return time
    let phase: CallDetectionPhase
    let evidence: Set<CallDetectionEvidence>
    let roster: CallDetectionRoster
}
enum CallDetectionUnavailableReason: String, Sendable, Equatable {
    case noSource, permissionRequired, unsupported, timedOut, ambiguous, stale, sourceMismatch
}
enum CallDetectionResult: Sendable, Equatable {
    case observation(CallDetectionObservation)
    case unavailable(CallDetectionUnavailableReason)
}
protocol CallDetectionAdapter: Sendable {
    var service: CallDetectionService { get }
    func observe() async -> CallDetectionResult
}
