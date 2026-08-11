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
///
/// Threading: all state is committed under a non-recursive lock, but the
/// injected callbacks (`recoveryRequest`, `onEpisodeEvent`) always run *after*
/// the lock is released — they may call back into audio infrastructure, and
/// `process()` runs on the real-time sample path. Attempt reservations are
/// made under the lock and rolled back if the request is not initiated.
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

    /// Called after the coordinator's lock is released when a recovery attempt
    /// should be started. Returns whether a recovery was actually initiated
    /// (false when one is already pending or the recorder is not in a
    /// recoverable state); uninitiated attempts are rolled back.
    var recoveryRequest: (String) -> Bool = { _ in false }
    /// Called after the coordinator's lock is released.
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
        var eventToEmit: MeetingMicHealthEpisodeEvent?
        var recoveryReservation: (episodeID: UUID, reason: String, reservedAt: Date)?

        lock.lock()
        if !finished {
            let currentState = snapshot.state
            let previous = previousState
            previousState = currentState
            let timestamp = now()

            let isDegraded = Self.isDegraded(currentState)
            if isDegraded, var active = episode {
                // A flap is any state change observed while the episode is
                // open: a return to degradation after a neutral dip, or a
                // change in the degradation mode itself.
                if let previous, previous != currentState {
                    active.flapCount += 1
                }
                if let reservation = reserveRecoveryIfDueLocked(&active, at: timestamp) {
                    recoveryReservation = reservation
                }
                episode = active
            } else if isDegraded {
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
                // The degraded event reports attempts as of episode start (0);
                // the immediate first attempt is reserved below and reflected
                // in the episode's closing event.
                eventToEmit = MeetingMicHealthEpisodeEvent(
                    kind: .degraded,
                    episodeID: newEpisode.id,
                    reason: reason,
                    state: currentState.rawValue,
                    durationSeconds: 0,
                    flapCount: 0,
                    recoveryAttempts: 0
                )
                // Confirmed degradation already waited ~3s inside the tracker;
                // attempt recovery immediately at episode start.
                recoveryReservation = reserveRecoveryLocked(&newEpisode, at: timestamp)
                episode = newEpisode
            } else if currentState == .healthy, let active = episode {
                episode = nil
                eventToEmit = MeetingMicHealthEpisodeEvent(
                    kind: .recovered,
                    episodeID: active.id,
                    reason: active.initialReason,
                    state: active.initialState.rawValue,
                    durationSeconds: timestamp.timeIntervalSince(active.startedAt),
                    flapCount: active.flapCount,
                    recoveryAttempts: active.recoveryAttempts
                )
            }
        }
        lock.unlock()

        if let eventToEmit {
            onEpisodeEvent?(eventToEmit)
        }
        if let recoveryReservation {
            let initiated = recoveryRequest(recoveryReservation.reason)
            if !initiated {
                rollbackReservationLocked(recoveryReservation)
            }
        }
    }

    /// Call when the meeting stops. An open episode at meeting end is the
    /// terminal condition that warrants an error-level signal. After this,
    /// further snapshots are ignored.
    func finishMeeting() {
        var eventToEmit: MeetingMicHealthEpisodeEvent?
        lock.lock()
        finished = true
        if let active = episode {
            episode = nil
            eventToEmit = MeetingMicHealthEpisodeEvent(
                kind: .unrecovered,
                episodeID: active.id,
                reason: active.initialReason,
                state: active.initialState.rawValue,
                durationSeconds: now().timeIntervalSince(active.startedAt),
                flapCount: active.flapCount,
                recoveryAttempts: active.recoveryAttempts
            )
        }
        lock.unlock()

        if let eventToEmit {
            onEpisodeEvent?(eventToEmit)
        }
    }

    var hasActiveEpisode: Bool {
        lock.withLock { episode != nil }
    }

    private static func isDegraded(_ state: MeetingMicHealthState) -> Bool {
        state == .micCallbacksMissing || state == .micAllZeroWhileSystemActive
    }

    /// Must be called with `lock` held. Reserves an attempt (counted under the
    /// lock so concurrent snapshots cannot double-request); the caller invokes
    /// `recoveryRequest` after unlocking and rolls back if not initiated.
    private func reserveRecoveryIfDueLocked(
        _ active: inout Episode,
        at timestamp: Date
    ) -> (episodeID: UUID, reason: String, reservedAt: Date)? {
        if let lastAttemptAt = active.lastAttemptAt,
           timestamp.timeIntervalSince(lastAttemptAt) < policy.attemptCooldown {
            return nil
        }
        return reserveRecoveryLocked(&active, at: timestamp)
    }

    private func reserveRecoveryLocked(
        _ active: inout Episode,
        at timestamp: Date
    ) -> (episodeID: UUID, reason: String, reservedAt: Date)? {
        guard active.recoveryAttempts < policy.maxAttemptsPerEpisode else { return nil }
        active.recoveryAttempts += 1
        active.lastAttemptAt = timestamp
        return (active.id, active.initialReason, timestamp)
    }

    private func rollbackReservationLocked(_ reservation: (episodeID: UUID, reason: String, reservedAt: Date)) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = episode,
              active.id == reservation.episodeID,
              active.lastAttemptAt == reservation.reservedAt else { return }
        active.recoveryAttempts -= 1
        active.lastAttemptAt = nil
        episode = active
    }
}
