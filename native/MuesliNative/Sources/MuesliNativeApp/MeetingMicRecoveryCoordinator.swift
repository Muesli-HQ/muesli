import Foundation

enum MeetingMicHealthEpisodeKind: String, Equatable {
    case degraded = "meeting.microphone.degraded"
    case recovered = "meeting.microphone.recovered"
    case unrecovered = "meeting.microphone.unrecovered"
    /// The capture device is muted/zero-gain at the source (user intent), which
    /// presents the same all-zero signature as a broken route. Classified
    /// separately so user intent never triggers recovery work or failure
    /// telemetry, and so production can measure how common it is.
    case userMuted = "meeting.microphone.user_muted"
}

enum MeetingMicHandoffOutcome: String, Equatable {
    case promoted
    case timedOut = "timed_out"
    case failed = "failed"
}

/// Privacy-safe coarse context attached to episode telemetry: no audio, device
/// names, or user content — only enum/classification-level fields.
struct MeetingMicEpisodeContext: Equatable {
    var recorderKind: String?
    var routeCategory: String?
    var selectedInputResolved: Bool?
}

struct MeetingMicHealthEpisodeEvent: Equatable {
    let kind: MeetingMicHealthEpisodeKind
    let episodeID: UUID
    let reason: String
    let state: String
    let durationSeconds: TimeInterval
    let flapCount: Int
    let recoveryAttempts: Int
    let handoffPromotions: Int
    let lastHandoffOutcome: MeetingMicHandoffOutcome?
    /// True when at least one recovery handoff promoted a replacement graph
    /// during this episode before the healthy transition.
    let recoveryCredited: Bool
    let context: MeetingMicEpisodeContext
}

/// Bounded authorization set for episode telemetry callbacks. Sessions emit
/// their terminal event while stopping/discarding — after the controller's
/// active-meeting identity has moved on — and more than one recently stopped
/// meeting can have callbacks queued on the main actor at once, so a single
/// "last stopped" slot is not safe authorization. Membership is by meeting ID,
/// authorized at session creation, with simple FIFO eviction.
struct RecentMeetingIdentityGate {
    private var order: [Int64] = []
    private var members = Set<Int64>()
    private let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    mutating func authorize(_ id: Int64) {
        guard !members.contains(id) else { return }
        members.insert(id)
        order.append(id)
        while order.count > capacity {
            members.remove(order.removeFirst())
        }
    }

    func allows(_ id: Int64) -> Bool {
        members.contains(id)
    }
}

/// Turns the raw mic-health state stream into one episode per degradation and
/// drives bounded same-route recovery attempts while a meeting is degraded.
///
/// Design notes:
/// - Flapping is collapsed into a single episode: a *sustained* healthy period
///   (not one healthy buffer) is required to close an episode as recovered, so
///   a degraded→healthy-blip→degraded route cannot reset the retry budget.
/// - All state commits under a non-recursive lock; injected callbacks run after
///   unlock. Recovery reservations carry a unique token, stored on the episode,
///   revalidated immediately before dispatch and settled on rollback — a
///   callback that closes or replaces the episode invalidates the token.
/// - After finishMeeting(), late snapshots are ignored so a callback enqueued
///   before teardown cannot open a dangling episode.
final class MeetingMicRecoveryCoordinator {
    struct Policy: Equatable {
        /// Minimum wall-clock gap between recovery attempts within an episode.
        var attemptCooldown: TimeInterval = 15
        /// Maximum recovery attempts per episode.
        var maxAttemptsPerEpisode: Int = 3
        /// Continuous healthy delivery required before an episode may close as
        /// recovered. Prevents a single healthy buffer from resetting the
        /// retry budget on a flapping route.
        var sustainedHealthySeconds: TimeInterval = 10

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
        var pendingRecoveryToken: UUID?
        var handoffPromotions: Int
        var lastHandoffOutcome: MeetingMicHandoffOutcome?
        /// First timestamp of the current continuous healthy run, if any.
        var healthySince: Date?
    }

    /// Called after the coordinator's lock is released when a recovery attempt
    /// should start. `.busy` (a handoff is already pending) is back-pressure:
    /// the attempt is refunded but the cooldown timestamp is retained so
    /// refusal cannot churn per-snapshot. `.unavailable` keeps the attempt
    /// counted so the episode cap bounds total requests.
    var recoveryRequest: (String) -> MeetingMicRecoveryRequestResult = { _ in .unavailable }
    /// Called after the coordinator's lock is released.
    var onEpisodeEvent: ((MeetingMicHealthEpisodeEvent) -> Void)?
    /// Coarse, privacy-safe context for telemetry; evaluated at event time.
    var contextProvider: () -> MeetingMicEpisodeContext = { MeetingMicEpisodeContext() }
    /// Evaluated at episode confirmation and at most once per second while
    /// suppressed — never per sample batch. When the capture device is
    /// muted/zero-gain at the source, no recovery episode opens: the all-zero
    /// signature is user intent, not a broken route. Called outside the
    /// coordinator lock (may read device state via HAL).
    var isInputMuted: () -> Bool = { false }
    /// Fired at most once per meeting when confirmed degradation is classified
    /// as user-muted input. Runs after the coordinator lock is released.
    var onUserMuted: (() -> Void)?
    /// While true (a route transition is still settling), recovery dispatches
    /// are deferred: a handoff attempted mid-churn reliably fails its
    /// first-buffer window and piles candidate graphs onto a busy daemon
    /// (measured live during BT connects on macOS 26.5.2).
    var isRouteSettling: () -> Bool = { false }
    /// Scheduler for deferred recovery dispatch; injectable for tests.
    var scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    private let policy: Policy
    private let now: () -> Date
    private let lock = NSLock()
    private var episode: Episode?
    private var previousState: MeetingMicHealthState?
    private var finished = false
    /// True while degradation snapshots are suppressed because the input was
    /// muted at confirmation. Cleared when the input un-mutes or the state
    /// leaves degraded, so a genuinely broken route still opens an episode.
    private var mutedSuppressed = false
    private var mutedSignalEmitted = false
    /// Throttles HAL mute reads to 1Hz while degradation is open but
    /// suppressed; nil while an episode is open (no reads at all then).
    private var lastMuteCheckAt: Date?

    init(policy: Policy = .default, now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.now = now
    }

    func process(_ snapshot: MeetingMicHealthSnapshot) {
        // State transitions commit under the lock; event construction (which
        // evaluates the injected contextProvider) and all callbacks run after
        // the lock is released.
        struct PendingEvent {
            let kind: MeetingMicHealthEpisodeKind
            let episode: Episode
            let duration: TimeInterval
        }
        var pendingEvent: PendingEvent?
        var recoveryToDispatch: (token: UUID, reason: String)?

        // The mute read (HAL, can block) runs outside the lock, and only when
        // it can change behavior: an open episode never consults it, and
        // suppressed degradation re-reads at most once per second to notice
        // un-muting without polling the HAL per sample batch.
        let degradedNow = Self.isDegraded(snapshot.state)
        var inputMuted = false
        if degradedNow {
            let shouldCheck: Bool = lock.withLock {
                guard episode == nil else { return false }
                if let lastMuteCheckAt,
                   now().timeIntervalSince(lastMuteCheckAt) < 1 { return false }
                lastMuteCheckAt = now()
                return true
            }
            if shouldCheck {
                inputMuted = isInputMuted()
            } else {
                inputMuted = lock.withLock { mutedSuppressed }
            }
        }
        var emitUserMuted = false

        lock.lock()
        if !finished {
            let currentState = snapshot.state
            let previous = previousState
            previousState = currentState
            let timestamp = now()
            if !degradedNow {
                mutedSuppressed = false
            }

            switch (degradedNow, episode != nil) {
            case (true, true):
                var active = episode!
                // A flap is any state change while the episode is open: a
                // return to degradation after a neutral/healthy blip, or a
                // change in degradation mode.
                if let previous, previous != currentState {
                    active.flapCount += 1
                }
                active.healthySince = nil
                if let reservation = reserveRecoveryIfDueLocked(&active, at: timestamp) {
                    recoveryToDispatch = reservation
                }
                episode = active
            case (true, false):
                // Degradation confirmed with no episode open. If the capture
                // device is muted/zero-gain at the source, this is user
                // intent, not a broken route: signal it once and suppress
                // recovery work. If the input un-mutes while still degraded,
                // the route may be genuinely broken — open the episode then.
                if inputMuted {
                    mutedSuppressed = true
                    if !mutedSignalEmitted {
                        mutedSignalEmitted = true
                        emitUserMuted = true
                    }
                } else if mutedSuppressed {
                    // Un-muted while still degraded: now the route may be
                    // genuinely broken — fall through to opening the episode.
                    mutedSuppressed = false
                }
                if !mutedSuppressed {
                    let reason = snapshot.transitions.last?.reason ?? "unknown"
                    var newEpisode = Episode(
                        id: UUID(),
                        startedAt: timestamp,
                        initialReason: reason,
                        initialState: currentState,
                        flapCount: 0,
                        recoveryAttempts: 0,
                        lastAttemptAt: nil,
                        pendingRecoveryToken: nil,
                        handoffPromotions: 0,
                        lastHandoffOutcome: nil,
                        healthySince: nil
                    )
                    // The degraded event reports attempts as of episode start
                    // (0); the immediate first attempt is reserved below and
                    // reflected in the episode's closing event.
                    pendingEvent = PendingEvent(kind: .degraded, episode: newEpisode, duration: 0)
                    // The tracker already confirmed degradation for ~3s;
                    // attempt recovery immediately at episode start.
                    recoveryToDispatch = reserveRecoveryLocked(&newEpisode, at: timestamp)
                    episode = newEpisode
                }
            case (false, true):
                var active = episode!
                if currentState == .healthy {
                    if active.healthySince == nil {
                        active.healthySince = timestamp
                    }
                    if timestamp.timeIntervalSince(active.healthySince!) >= policy.sustainedHealthySeconds {
                        // Sustained healthy delivery: close as recovered. The
                        // retry budget is only released here, never on a blip.
                        episode = nil
                        pendingEvent = PendingEvent(
                            kind: .recovered,
                            episode: active,
                            duration: timestamp.timeIntervalSince(active.startedAt)
                        )
                    } else {
                        episode = active
                    }
                } else {
                    // Neutral state (e.g. waitingForAudio): keep the episode
                    // open without counting anything.
                    episode = active
                }
            case (false, false):
                break
            }
        }
        let dispatch = recoveryToDispatch
        lock.unlock()

        if emitUserMuted {
            onUserMuted?()
        }
        if let pendingEvent {
            onEpisodeEvent?(makeEvent(pendingEvent.kind, episode: pendingEvent.episode, duration: pendingEvent.duration))
        }
        if let dispatch {
            dispatchRecovery(dispatch)
        }
    }

    /// Open an episode from an external detector (e.g. the system-audio
    /// watchdog noticing mic callbacks stalled while the tap is dead — the
    /// health tracker's own precondition is blind in that state). Shares the
    /// same episode lifecycle: no-op when an episode is already open or the
    /// meeting has finished.
    func noteExternalDegradation(reason: String) {
        var pendingEpisode: Episode?
        var recoveryToDispatch: (token: UUID, reason: String)?

        lock.lock()
        if !finished, episode == nil {
            let timestamp = now()
            var newEpisode = Episode(
                id: UUID(),
                startedAt: timestamp,
                initialReason: reason,
                initialState: .micCallbacksMissing,
                flapCount: 0,
                recoveryAttempts: 0,
                lastAttemptAt: nil,
                pendingRecoveryToken: nil,
                handoffPromotions: 0,
                lastHandoffOutcome: nil,
                healthySince: nil
            )
            pendingEpisode = newEpisode
            recoveryToDispatch = reserveRecoveryLocked(&newEpisode, at: timestamp)
            episode = newEpisode
        }
        let dispatch = recoveryToDispatch
        lock.unlock()

        if let pendingEpisode {
            onEpisodeEvent?(makeEvent(.degraded, episode: pendingEpisode, duration: 0))
        }
        if let dispatch {
            dispatchRecovery(dispatch)
        }
    }

    /// Record the outcome of a recovery handoff (called by the recorder layer).
    /// A promotion during an open episode marks the recovery as creditable if
    /// healthy delivery follows.
    func noteHandoffOutcome(_ outcome: MeetingMicHandoffOutcome) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = episode else { return }
        active.lastHandoffOutcome = outcome
        if outcome == .promoted {
            active.handoffPromotions += 1
        }
        episode = active
    }

    /// Call when the meeting stops. An episode still degraded at meeting end is
    /// the terminal condition that warrants an error-level signal; an episode
    /// with healthy-but-not-yet-sustained delivery closes as recovered. After
    /// this, further snapshots are ignored.
    func finishMeeting() {
        var pendingEvent: (kind: MeetingMicHealthEpisodeKind, episode: Episode, duration: TimeInterval)?
        lock.lock()
        finished = true
        if let active = episode {
            episode = nil
            let timestamp = now()
            let kind: MeetingMicHealthEpisodeKind = active.healthySince != nil ? .recovered : .unrecovered
            pendingEvent = (kind, active, timestamp.timeIntervalSince(active.startedAt))
        }
        lock.unlock()

        if let pendingEvent {
            onEpisodeEvent?(makeEvent(pendingEvent.kind, episode: pendingEvent.episode, duration: pendingEvent.duration))
        }
    }

    var hasActiveEpisode: Bool {
        lock.withLock { episode != nil }
    }

    private static func isDegraded(_ state: MeetingMicHealthState) -> Bool {
        state == .micCallbacksMissing || state == .micAllZeroWhileSystemActive
    }

    /// Builds the event outside the lock: evaluates the injected context
    /// provider without holding coordinator state.
    private func makeEvent(
        _ kind: MeetingMicHealthEpisodeKind,
        episode: Episode,
        duration: TimeInterval
    ) -> MeetingMicHealthEpisodeEvent {
        MeetingMicHealthEpisodeEvent(
            kind: kind,
            episodeID: episode.id,
            reason: episode.initialReason,
            state: episode.initialState.rawValue,
            durationSeconds: duration,
            flapCount: episode.flapCount,
            recoveryAttempts: episode.recoveryAttempts,
            handoffPromotions: episode.handoffPromotions,
            lastHandoffOutcome: episode.lastHandoffOutcome,
            recoveryCredited: episode.handoffPromotions > 0,
            context: contextProvider()
        )
    }

    /// Must be called with `lock` held. Reserves an attempt and issues a unique
    /// token stored on the episode; the token is revalidated at dispatch.
    private func reserveRecoveryIfDueLocked(
        _ active: inout Episode,
        at timestamp: Date
    ) -> (token: UUID, reason: String)? {
        if let lastAttemptAt = active.lastAttemptAt,
           timestamp.timeIntervalSince(lastAttemptAt) < policy.attemptCooldown {
            return nil
        }
        return reserveRecoveryLocked(&active, at: timestamp)
    }

    private func reserveRecoveryLocked(
        _ active: inout Episode,
        at timestamp: Date
    ) -> (token: UUID, reason: String)? {
        guard active.recoveryAttempts < policy.maxAttemptsPerEpisode,
              active.pendingRecoveryToken == nil else { return nil }
        let token = UUID()
        active.recoveryAttempts += 1
        active.lastAttemptAt = timestamp
        active.pendingRecoveryToken = token
        return (token, active.initialReason)
    }

    /// Runs outside the lock. Revalidates the reservation token immediately
    /// before dispatch: an episode that closed or moved on invalidates it.
    /// Defers while a route transition is settling — a handoff mid-churn
    /// reliably fails its first-buffer window.
    private func dispatchRecovery(_ reservation: (token: UUID, reason: String)) {
        if isRouteSettling() {
            scheduleAfter(1) { [weak self] in
                self?.dispatchRecovery(reservation)
            }
            return
        }
        lock.lock()
        guard !finished,
              let active = episode,
              active.pendingRecoveryToken == reservation.token else {
            lock.unlock()
            return
        }
        lock.unlock()

        let result = recoveryRequest(reservation.reason)

        lock.lock()
        if var active = episode, active.pendingRecoveryToken == reservation.token {
            active.pendingRecoveryToken = nil
            if result == .busy {
                // Back-pressure from an in-flight handoff: refund the attempt
                // so it does not burn the episode budget, but KEEP
                // lastAttemptAt so the cooldown still throttles re-dispatch.
                active.recoveryAttempts -= 1
            }
            // .unavailable keeps the attempt counted: the per-episode cap must
            // bound total recovery requests, not only accepted ones.
            episode = active
        }
        lock.unlock()
    }
}
