import Foundation

enum MeetingDetectionTrigger: CaseIterable, Equatable {
    case startup
    case fallbackTimer
    case micChanged
    case cameraChanged
    case sensorAttributionChanged
    case audioAttributionChanged
    case workspaceActivated
    case calendarChanged
    case promptStateChanged
    case manualRefresh
}

enum MeetingDetectionMode: Equatable {
    case idle
    case suspicious
}

/// This is derived from the recording controller's authoritative state. It is
/// deliberately not a second, mutable recording state machine.
enum MeetingMonitoringMode: Equatable {
    case discovery
    case sourceLiveness(sessionID: Int64, source: MeetingAutoStopSource)
    case suspended(sessionID: Int64?)

    var performsEvaluation: Bool {
        switch self {
        case .discovery, .sourceLiveness:
            return true
        case .suspended:
            return false
        }
    }

    var allowsFullAudioAttribution: Bool {
        self == .discovery
    }
}

struct MeetingRecordingLifecycleSnapshot: Equatable {
    let phase: MeetingCapturePhase
    let sessionID: Int64?
    let autoStopSource: MeetingAutoStopSource?

    var isRecording: Bool { phase.isRecording }
    var isStarting: Bool { phase == .preparing }

    static let idle = MeetingRecordingLifecycleSnapshot(
        phase: .stopped, sessionID: nil, autoStopSource: nil
    )
}

enum MeetingMonitoringModePolicy {
    static func resolve(_ lifecycle: MeetingRecordingLifecycleSnapshot) -> MeetingMonitoringMode {
        if lifecycle.phase == .stopping {
            return .suspended(sessionID: lifecycle.sessionID)
        }

        guard lifecycle.phase != .stopped else {
            return .discovery
        }

        guard let sessionID = lifecycle.sessionID else {
            return .suspended(sessionID: nil)
        }

        if let source = lifecycle.autoStopSource {
            return .sourceLiveness(sessionID: sessionID, source: source)
        }
        return .suspended(sessionID: sessionID)
    }
}

struct MeetingSignalRefreshState: Equatable {
    var audioAttributionAttempt: MeetingAudioAttributionAttemptState?
    var lastBrowserRefreshAt: Date?
    var lastActiveTabFallbackAttemptAtByBundleID: [String: Date] = [:]
    var lastSuspicionAt: Date?
    var hasMicOrCameraSignal = false
    var hasRecentBrowserMeeting = false
    var hasActiveCandidate = false
    var hasPromptVisible = false
    var hasCalendarEvent = false
    var foregroundIsMeetingCapableApp = false

    var hasObservedActivity: Bool {
        hasMicOrCameraSignal || hasRecentBrowserMeeting || hasPromptVisible
            || hasCalendarEvent || foregroundIsMeetingCapableApp
    }
}

enum MeetingAudioAttributionEpisode: Equatable {
    case attributedMic(bundleIDs: [String])
    case unattributedMic
}

struct MeetingAudioAttributionAttemptState: Equatable {
    let episode: MeetingAudioAttributionEpisode
    let attemptCount: Int
    let lastAttemptAt: Date
    var resolvedCandidate: Bool
}

struct MeetingAudioAttributionEvidence: Equatable {
    let deviceMicActive: Bool
    let selfAudioActivityActive: Bool
    let externalMicBundleIDs: Set<String>

    static let inactive = MeetingAudioAttributionEvidence(
        deviceMicActive: false,
        selfAudioActivityActive: false,
        externalMicBundleIDs: []
    )

    var episode: MeetingAudioAttributionEpisode? {
        if !externalMicBundleIDs.isEmpty {
            return .attributedMic(bundleIDs: externalMicBundleIDs.sorted())
        }
        guard deviceMicActive, !selfAudioActivityActive else { return nil }
        return .unattributedMic
    }
}

struct MeetingSignalRefreshDecision: Equatable {
    let mode: MeetingDetectionMode
    let refreshAudioAttribution: Bool
    let refreshTrackedAudioProcesses: Bool
    let audioAttributionEpisode: MeetingAudioAttributionEpisode?
    let refreshBrowserMeetings: Bool
    let fallbackInterval: TimeInterval
}

struct MeetingSignalRefreshPolicy {
    let idleFallbackInterval: TimeInterval
    let suspiciousFallbackInterval: TimeInterval
    let debounceDelay: TimeInterval
    let suspicionTTL: TimeInterval
    let audioAttributionRetryDelay: TimeInterval
    let maximumAudioAttributionAttempts: Int
    let browserSuspiciousThrottle: TimeInterval
    let browserIdleThrottle: TimeInterval
    let activeTabFallbackThrottle: TimeInterval

    init(
        idleFallbackInterval: TimeInterval = 120,
        suspiciousFallbackInterval: TimeInterval = 3,
        debounceDelay: TimeInterval = 0.5,
        suspicionTTL: TimeInterval = 12,
        audioAttributionRetryDelay: TimeInterval = 3,
        maximumAudioAttributionAttempts: Int = 2,
        browserSuspiciousThrottle: TimeInterval = 3,
        browserIdleThrottle: TimeInterval = 120,
        activeTabFallbackThrottle: TimeInterval = 15
    ) {
        self.idleFallbackInterval = idleFallbackInterval
        self.suspiciousFallbackInterval = suspiciousFallbackInterval
        self.debounceDelay = debounceDelay
        self.suspicionTTL = suspicionTTL
        self.audioAttributionRetryDelay = audioAttributionRetryDelay
        self.maximumAudioAttributionAttempts = maximumAudioAttributionAttempts
        self.browserSuspiciousThrottle = browserSuspiciousThrottle
        self.browserIdleThrottle = browserIdleThrottle
        self.activeTabFallbackThrottle = activeTabFallbackThrottle
    }

    func decision(
        trigger: MeetingDetectionTrigger,
        state: MeetingSignalRefreshState,
        monitoringMode: MeetingMonitoringMode,
        audioEvidence: MeetingAudioAttributionEvidence = .inactive,
        suppressAudioAttribution: Bool = false,
        now: Date
    ) -> MeetingSignalRefreshDecision {
        let suspicious = isSuspicious(state: state, now: now)
        let mode: MeetingDetectionMode = suspicious ? .suspicious : .idle
        let fallbackInterval = suspicious ? suspiciousFallbackInterval : idleFallbackInterval
        let audioEpisode = audioEvidence.episode
        let canRefreshAudio = trigger != .audioAttributionChanged
            && !suppressAudioAttribution && monitoringMode.allowsFullAudioAttribution
        let refreshAudioAttribution = canRefreshAudio && shouldRefreshAudioAttribution(
            episode: audioEpisode,
            attempt: state.audioAttributionAttempt,
            now: now
        )
        let refreshTrackedAudioProcesses = canRefreshAudio && !refreshAudioAttribution
            && audioEpisode != nil
            && state.audioAttributionAttempt?.episode == audioEpisode

        return MeetingSignalRefreshDecision(
            mode: mode,
            refreshAudioAttribution: refreshAudioAttribution,
            refreshTrackedAudioProcesses: refreshTrackedAudioProcesses,
            audioAttributionEpisode: audioEpisode,
            refreshBrowserMeetings: monitoringMode.performsEvaluation
                && shouldRefreshBrowserMeetings(trigger: trigger, state: state, mode: mode, now: now),
            fallbackInterval: fallbackInterval
        )
    }

    func allowsActiveTabFallbackProbe(for bundleID: String, state: MeetingSignalRefreshState, now: Date) -> Bool {
        guard let lastAttempt = state.lastActiveTabFallbackAttemptAtByBundleID[bundleID] else { return true }
        return now.timeIntervalSince(lastAttempt) >= activeTabFallbackThrottle
    }

    func audioAttributionAttemptState(
        after decision: MeetingSignalRefreshDecision,
        current: MeetingAudioAttributionAttemptState?,
        resolvedCandidate: Bool,
        now: Date
    ) -> MeetingAudioAttributionAttemptState? {
        guard let episode = decision.audioAttributionEpisode else { return nil }
        if var current, current.episode == episode, resolvedCandidate, !current.resolvedCandidate {
            current.resolvedCandidate = true
            return current
        }
        guard decision.refreshAudioAttribution else {
            // Recording/self-audio/prompt suppression must not consume a new
            // episode that was observed but never attributed.
            return current
        }
        let attemptCount: Int
        if let current, current.episode == episode {
            attemptCount = current.attemptCount + 1
        } else {
            attemptCount = 1
        }
        return MeetingAudioAttributionAttemptState(
            episode: episode,
            attemptCount: attemptCount,
            lastAttemptAt: now,
            resolvedCandidate: resolvedCandidate
        )
    }

    func suspicionDate(
        state: MeetingSignalRefreshState,
        now: Date,
        resolvedCandidate: MeetingCandidate?
    ) -> Date? {
        if resolvedCandidate != nil || state.hasObservedActivity {
            return now
        }

        guard let lastSuspicionAt = state.lastSuspicionAt,
              now.timeIntervalSince(lastSuspicionAt) <= suspicionTTL else {
            return nil
        }
        return lastSuspicionAt
    }

    private func isSuspicious(
        state: MeetingSignalRefreshState,
        now: Date
    ) -> Bool {
        if state.hasActiveCandidate || state.hasObservedActivity {
            return true
        }

        guard let lastSuspicionAt = state.lastSuspicionAt else { return false }
        return now.timeIntervalSince(lastSuspicionAt) <= suspicionTTL
    }

    private func shouldRefreshBrowserMeetings(
        trigger: MeetingDetectionTrigger,
        state: MeetingSignalRefreshState,
        mode: MeetingDetectionMode,
        now: Date
    ) -> Bool {
        if trigger == .startup || trigger == .workspaceActivated || trigger == .calendarChanged {
            return isThrottleExpired(since: state.lastBrowserRefreshAt, throttle: 0, now: now)
        }

        let throttle = mode == .suspicious ? browserSuspiciousThrottle : browserIdleThrottle
        guard mode == .suspicious || trigger == .fallbackTimer || trigger == .manualRefresh else {
            return false
        }
        return isThrottleExpired(since: state.lastBrowserRefreshAt, throttle: throttle, now: now)
    }

    private func shouldRefreshAudioAttribution(
        episode: MeetingAudioAttributionEpisode?,
        attempt: MeetingAudioAttributionAttemptState?,
        now: Date
    ) -> Bool {
        guard let episode else { return false }
        guard let attempt, attempt.episode == episode else { return true }
        guard !attempt.resolvedCandidate,
              attempt.attemptCount < maximumAudioAttributionAttempts else {
            return false
        }
        return now.timeIntervalSince(attempt.lastAttemptAt) >= audioAttributionRetryDelay
    }

    private func isThrottleExpired(since date: Date?, throttle: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= throttle
    }
}
