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

/// Watches the system-audio tap's IO heartbeat while a meeting records and
/// drives bounded rebuilds when capture dies without an error — the observed
/// production failure was a route-change rebuild that failed once and stayed
/// dead for the rest of the meeting, silently losing the remote side.
///
/// Liveness is callback delivery, not content: the tap's IO callback fires
/// continuously while the graph runs, even when the room is quiet, so a stall
/// means a dead pipeline. Same role as MeetingMicRecoveryCoordinator, but the
/// tap has binary health and no mute classification (output volume does not
/// affect process-tap content).
///
/// All callbacks fire after internal state commits; injected closures run on
/// the caller's tick context. Time and cadence are injected for tests.
final class MeetingSystemAudioWatchdog {
    struct Policy: Equatable {
        /// Seconds without an IO callback (while recording and not paused)
        /// before the tap is declared dead.
        var stallThreshold: TimeInterval = 2
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

    /// Evaluated per tick: the recorder's monotonic IO heartbeat and whether
    /// capture is active (recording, no rebuild in flight).
    var captureHeartbeat: () -> UInt64 = { 0 }
    var isCaptureActive: () -> Bool = { false }
    /// While true (meeting paused), ticks are ignored entirely.
    var isPaused: () -> Bool = { false }
    /// While true (a route transition is still settling), ticks are ignored:
    /// the old tap's heartbeat stalling mid-transition is expected, and firing
    /// a recovery rebuild into daemon churn reliably fails and amplifies it
    /// (measured live on macOS 26.5.2).
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
    private var lastObservedHeartbeat: UInt64 = 0
    private var lastHeartbeatAdvanceAt: Date?

    init(policy: Policy = .default, now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.now = now
    }

    /// Called by the recorder when a rebuild exhausts its retry budget — the
    /// tap is dead regardless of heartbeat state. Ignored while paused: a
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
        if !finished {
            if isPaused() || isRouteSettling() {
                lock.unlock()
                return
            }
            let timestamp = now()
            // Alive = capture active AND the IO heartbeat advanced recently.
            // Content silence still delivers callbacks; a stall means the
            // pipeline is dead. A rebuild in flight is a known-transient.
            let heartbeat = captureHeartbeat()
            if heartbeat != lastObservedHeartbeat {
                lastObservedHeartbeat = heartbeat
                lastHeartbeatAdvanceAt = timestamp
            }
            let active = isCaptureActive()
            let stalled: Bool
            if !active {
                stalled = true
            } else if let lastAdvance = lastHeartbeatAdvanceAt {
                stalled = timestamp.timeIntervalSince(lastAdvance) >= policy.stallThreshold
            } else {
                // Capture active but no heartbeat ever observed.
                stalled = true
            }
            let alive = active && !stalled

            if alive {
                if var active = episode {
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
                }
            } else if episode == nil {
                episode = openEpisodeLocked(reason: "capture_heartbeat_stalled", at: timestamp)
                eventToEmit = MeetingSystemAudioHealthEvent(
                    kind: .degraded,
                    reason: "capture_heartbeat_stalled",
                    durationSeconds: 0,
                    recoveryAttempts: 0
                )
                // The graph is confirmed dead; rebuild immediately.
                if var active = episode {
                    active.recoveryAttempts += 1
                    active.lastAttemptAt = timestamp
                    episode = active
                    recoveryReason = "capture_heartbeat_stalled"
                }
            } else {
                if var active = episode {
                    active.healthyTicks = 0
                    if active.recoveryAttempts < policy.maxAttemptsPerEpisode,
                       let lastAttemptAt = active.lastAttemptAt,
                       timestamp.timeIntervalSince(lastAttemptAt) >= policy.attemptCooldown {
                        active.recoveryAttempts += 1
                        active.lastAttemptAt = timestamp
                        recoveryReason = active.initialReason
                    }
                    // Blindness bridge: tap dead + mic stale → the mic
                    // tracker cannot see degradation without active system
                    // audio, so surface it here (once per episode).
                    if !active.micBridgeFired,
                       let lastMic = lastMicCallbackAt(),
                       timestamp.timeIntervalSince(lastMic) >= 3 {
                        active.micBridgeFired = true
                        micBridgeReason = "mic_callbacks_stale_while_system_tap_dead"
                    }
                    episode = active
                }
            }
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
