import Foundation

enum MeetingMicHealthEpisodeKind: String, Equatable {
    case degraded = "meeting.microphone.degraded"
    case recovered = "meeting.microphone.recovered"
    case unrecovered = "meeting.microphone.unrecovered"
}

struct MeetingMicHealthEpisodeEvent: Equatable {
    let kind: MeetingMicHealthEpisodeKind
    let episodeID: UUID
    let reason: String
    let state: String
    let durationSeconds: TimeInterval
    let flapCount: Int
    let recoveryAttempts: Int
}

/// Turns the raw mic-health state stream into one episode per degradation and
/// drives bounded same-route recovery attempts while a meeting is degraded.
///
/// The health tracker can flap between degraded and neutral states within one
/// real incident; this coordinator collapses that into a single episode so
/// telemetry and recovery attempts are episode-scoped instead of per-flap.
final class MeetingMicRecoveryCoordinator {
    struct Policy: Equatable {
        /// Minimum wall-clock gap between recovery attempts within an episode.
        var attemptCooldown: TimeInterval = 15
        /// Maximum recovery attempts per episode.
        var maxAttemptsPerEpisode: Int = 3

        static let `default` = Policy()
    }

    private struct Episode {
        let id: UUID
        let startedAt: Date
        let initialReason: String
        let initialState: MeetingMicHealthState
        var flapCount: Int
        var recoveryAttempts: Int
        var lastAttemptAt: Date?
    }

    /// Called when a recovery attempt should be started. Returns whether a
    /// recovery was actually initiated (false when one is already pending or
    /// the recorder is not in a recoverable state).
    var recoveryRequest: (String) -> Bool = { _ in false }
    var onEpisodeEvent: ((MeetingMicHealthEpisodeEvent) -> Void)?

    private let policy: Policy
    private let now: () -> Date
    private let lock = NSLock()
    private var episode: Episode?
    private var previousState: MeetingMicHealthState?
    /// Set by finishMeeting(). Late health snapshots (e.g. sample callbacks
    /// enqueued before meeting teardown but processed after it) must not open
    /// a fresh episode that would never see a terminal event.
    private var finished = false

    init(policy: Policy = .default, now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.now = now
    }

    func process(_ snapshot: MeetingMicHealthSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let currentState = snapshot.state
        let previous = previousState
        previousState = currentState
        let timestamp = now()

        let isDegraded = Self.isDegraded(currentState)
        if isDegraded, var active = episode {
            // A flap is any state change observed while the episode is open:
            // a return to degradation after a neutral dip, or a change in the
            // degradation mode itself.
            if let previous, previous != currentState {
                active.flapCount += 1
            }
            episode = active
            requestRecoveryIfDueLocked(&active, at: timestamp)
            episode = active
            return
        }
        if isDegraded {
            let reason = snapshot.transitions.last?.reason ?? "unknown"
            var newEpisode = Episode(
                id: UUID(),
                startedAt: timestamp,
                initialReason: reason,
                initialState: currentState,
                flapCount: 0,
                recoveryAttempts: 0,
                lastAttemptAt: nil
            )
            emitLocked(.init(
                kind: .degraded,
                episodeID: newEpisode.id,
                reason: reason,
                state: currentState.rawValue,
                durationSeconds: 0,
                flapCount: 0,
                recoveryAttempts: 0
            ))
            episode = newEpisode
            // Confirmed degradation already waited ~3s inside the tracker;
            // attempt recovery immediately at episode start.
            requestRecoveryLocked(&newEpisode, at: timestamp)
            episode = newEpisode
            return
        }
        if currentState == .healthy, let active = episode {
            episode = nil
            emitLocked(.init(
                kind: .recovered,
                episodeID: active.id,
                reason: active.initialReason,
                state: active.initialState.rawValue,
                durationSeconds: timestamp.timeIntervalSince(active.startedAt),
                flapCount: active.flapCount,
                recoveryAttempts: active.recoveryAttempts
            ))
        }
    }

    /// Call when the meeting stops. An open episode at meeting end is the
    /// terminal condition that warrants an error-level signal. After this,
    /// further snapshots are ignored.
    func finishMeeting() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        guard let active = episode else { return }
        episode = nil
        emitLocked(.init(
            kind: .unrecovered,
            episodeID: active.id,
            reason: active.initialReason,
            state: active.initialState.rawValue,
            durationSeconds: now().timeIntervalSince(active.startedAt),
            flapCount: active.flapCount,
            recoveryAttempts: active.recoveryAttempts
        ))
    }

    var hasActiveEpisode: Bool {
        lock.withLock { episode != nil }
    }

    private static func isDegraded(_ state: MeetingMicHealthState) -> Bool {
        state == .micCallbacksMissing || state == .micAllZeroWhileSystemActive
    }

    private func requestRecoveryIfDueLocked(_ active: inout Episode, at timestamp: Date) {
        guard active.recoveryAttempts < policy.maxAttemptsPerEpisode else { return }
        if let lastAttemptAt = active.lastAttemptAt,
           timestamp.timeIntervalSince(lastAttemptAt) < policy.attemptCooldown {
            return
        }
        requestRecoveryLocked(&active, at: timestamp)
    }

    private func requestRecoveryLocked(_ active: inout Episode, at timestamp: Date) {
        guard active.recoveryAttempts < policy.maxAttemptsPerEpisode else { return }
        let initiated = recoveryRequest(active.initialReason)
        guard initiated else { return }
        active.recoveryAttempts += 1
        active.lastAttemptAt = timestamp
    }

    private func emitLocked(_ event: MeetingMicHealthEpisodeEvent) {
        onEpisodeEvent?(event)
    }
}
