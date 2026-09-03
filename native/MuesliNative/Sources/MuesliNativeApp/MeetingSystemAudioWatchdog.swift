import Foundation

enum MeetingSystemAudioHealthKind: String, Equatable {
    case degraded = "meeting.system_audio.degraded"
    case recovered = "meeting.system_audio.recovered"
    case unrecovered = "meeting.system_audio.unrecovered"
}

struct MeetingSystemAudioHealthEvent: Equatable {
    let kind: MeetingSystemAudioHealthKind
    let reason: String
    let durationSeconds: TimeInterval
    let recoveryAttempts: Int
}

/// Manages explicit system-audio capture failure episodes and bounded recovery.
/// A flat IO callback stream is intentionally not treated as failure: healthy
/// global process taps may quiesce while system output is silent, and querying
/// every CoreAudio process to disambiguate that state can itself contend with
/// the daemon. Recovery therefore begins only after the recorder reports
/// positive failure evidence (for example, exhausted HAL rebuild attempts).
///
/// All callbacks fire after internal state commits; injected closures run on
/// the caller's tick context. Time and cadence are injected for tests.
final class MeetingSystemAudioWatchdog {
    struct Policy: Equatable {
        /// Sustained alive ticks required to close an episode as recovered.
        var recoveredAfterTicks: Int = 2
        /// Minimum gap between recovery rebuild attempts.
        var attemptCooldown: TimeInterval = 15
        /// Maximum recovery rebuild attempts per episode.
        var maxAttemptsPerEpisode: Int = 4

        static let `default` = Policy()
    }

    private struct Episode {
        let startedAt: Date
        let initialReason: String
        var recoveryAttempts: Int
        var lastAttemptAt: Date?
        var healthyTicks: Int
        var micBridgeFired: Bool
    }

    /// Evaluated per tick after an explicit failure episode opens. True means
    /// the recorder is running, not rebuilding, and has not marked its capture
    /// graph dead.
    var isCaptureActive: () -> Bool = { false }
    /// While true (meeting paused), ticks are ignored entirely.
    var isPaused: () -> Bool = { false }
    /// While true (a route transition is still settling), retries are paused
    /// so confirmed recovery does not add HAL work during daemon churn.
    var isRouteSettling: () -> Bool = { false }
    /// The mic tracker's last raw-mic callback time, for the blindness bridge.
    var lastMicCallbackAt: () -> Date? = { nil }
    /// Rebuild request; returns whether a rebuild was actually started.
    var recoveryRequest: (String) -> Bool = { _ in false }
    /// Fired once per episode when the tap is dead AND mic callbacks have been
    /// stale beyond the mic tracker's confirmation window — the mic detector is
    /// blind while its system-audio precondition is dead, so the watchdog
    /// bridges it.
    var onMicBlindnessDegradation: ((String) -> Void)?
    var onEpisodeEvent: ((MeetingSystemAudioHealthEvent) -> Void)?

    private let policy: Policy
    private let now: () -> Date
    private let lock = NSLock()
    private var episode: Episode?
    private var finished = false

    init(policy: Policy = .default, now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.now = now
    }

    /// Called by the recorder when a rebuild exhausts its retry budget — the
    /// tap has positively failed. Ignored while paused: a
    /// rejected recovery request must not open an episode or burn budget.
    func noteCaptureFailure(reason: String) {
        var eventToEmit: MeetingSystemAudioHealthEvent?
        var recoveryReason: String?
        lock.lock()
        if !finished, !isPaused(), episode == nil {
            var newEpisode = openEpisodeLocked(reason: reason, at: now())
            eventToEmit = MeetingSystemAudioHealthEvent(
                kind: .degraded,
                reason: reason,
                durationSeconds: 0,
                recoveryAttempts: 0
            )
            // The graph is confirmed dead; rebuild immediately.
            newEpisode.recoveryAttempts += 1
            newEpisode.lastAttemptAt = now()
            episode = newEpisode
            recoveryReason = reason
        }
        lock.unlock()

        if let eventToEmit {
            onEpisodeEvent?(eventToEmit)
        }
        if let recoveryReason {
            let initiated = recoveryRequest(recoveryReason)
            if !initiated {
                refundAttemptLocked(reason: recoveryReason)
            }
        }
    }

    /// Roll back the attempt count for a rejected request while keeping its
    /// cooldown timestamp for back-pressure.
    private func refundAttemptLocked(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = episode, active.initialReason == reason,
              active.recoveryAttempts > 0 else { return }
        active.recoveryAttempts -= 1
        episode = active
    }

    /// One health evaluation. Called by MeetingSession's timer.
    func tick() {
        var eventToEmit: MeetingSystemAudioHealthEvent?
        var recoveryReason: String?
        var micBridgeReason: String?

        lock.lock()
        if finished || isPaused() || isRouteSettling() {
            lock.unlock()
            return
        }
        guard var active = episode else {
            // No explicit failure evidence: silence, flat callbacks, playback
            // transitions, and unrelated CoreAudio clients are all no-ops.
            lock.unlock()
            return
        }

        let timestamp = now()
        if isCaptureActive() {
            active.healthyTicks += 1
            if active.healthyTicks >= policy.recoveredAfterTicks {
                episode = nil
                eventToEmit = MeetingSystemAudioHealthEvent(
                    kind: .recovered,
                    reason: active.initialReason,
                    durationSeconds: timestamp.timeIntervalSince(active.startedAt),
                    recoveryAttempts: active.recoveryAttempts
                )
            } else {
                episode = active
            }
        } else {
            active.healthyTicks = 0
            if active.recoveryAttempts < policy.maxAttemptsPerEpisode,
               let lastAttemptAt = active.lastAttemptAt,
               timestamp.timeIntervalSince(lastAttemptAt) >= policy.attemptCooldown {
                active.recoveryAttempts += 1
                active.lastAttemptAt = timestamp
                recoveryReason = active.initialReason
            }
            // Blindness bridge: confirmed tap failure + mic stale means the mic
            // tracker may be blind because its system-audio precondition is
            // unavailable. Surface this once per failure episode.
            if !active.micBridgeFired,
               let lastMic = lastMicCallbackAt(),
               timestamp.timeIntervalSince(lastMic) >= 3 {
                active.micBridgeFired = true
                micBridgeReason = "mic_callbacks_stale_while_system_tap_dead"
            }
            episode = active
        }
        lock.unlock()

        if let eventToEmit {
            onEpisodeEvent?(eventToEmit)
        }
        if let recoveryReason {
            // A rejection (paused / rebuild in flight) must not burn the
            // attempt budget; the cooldown timestamp stands either way so a
            // refused request still has back-pressure.
            let initiated = recoveryRequest(recoveryReason)
            if !initiated {
                refundAttemptLocked(reason: recoveryReason)
            }
        }
        if let micBridgeReason {
            onMicBlindnessDegradation?(micBridgeReason)
        }
    }

    /// Call when the meeting stops or is discarded. An open episode is the
    /// terminal (error-level) condition.
    func finishMeeting() {
        var eventToEmit: MeetingSystemAudioHealthEvent?
        lock.lock()
        finished = true
        if let active = episode {
            episode = nil
            eventToEmit = MeetingSystemAudioHealthEvent(
                kind: .unrecovered,
                reason: active.initialReason,
                durationSeconds: now().timeIntervalSince(active.startedAt),
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

    @discardableResult
    private func openEpisodeLocked(reason: String, at timestamp: Date) -> Episode {
        Episode(
            startedAt: timestamp,
            initialReason: reason,
            recoveryAttempts: 0,
            lastAttemptAt: nil,
            healthyTicks: 0,
            micBridgeFired: false
        )
    }
}
