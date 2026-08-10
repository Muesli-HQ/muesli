import Foundation

enum MeetingRecordingStartOrigin: Equatable {
    case manual
    case detectedPrompt
    case calendarAutoRecord
    case scheduledMeetingPrompt
    case joinAndRecord

    var enablesMeetingAutoStop: Bool {
        switch self {
        case .manual:
            return false
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return true
        }
    }

    var signalLossResponse: MeetingSignalLossResponse {
        enablesMeetingAutoStop ? .autoStopAfterWarning : .none
    }

    func signalLossSource(
        explicitSource: MeetingAutoStopSource?,
        recentSource: @autoclosure () -> MeetingAutoStopSource?
    ) -> MeetingAutoStopSource? {
        switch self {
        case .manual:
            return nil
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return explicitSource ?? recentSource()
        }
    }
}

enum MeetingSignalLossResponse: Equatable {
    case none
    case warnOnly
    case autoStopAfterWarning
}

struct MeetingSignalLossPromptState: Equatable {
    private(set) var isPromptSuppressed = false
    private(set) var isDismissedForRecording = false

    var canPresentPrompt: Bool {
        !isPromptSuppressed && !isDismissedForRecording
    }

    mutating func resetForRecording() {
        isPromptSuppressed = false
        isDismissedForRecording = false
    }

    mutating func markPromptPresented() {
        isPromptSuppressed = true
    }

    mutating func markSourceRecovered() {
        isPromptSuppressed = false
    }

    mutating func markDismissedByUser() {
        isPromptSuppressed = true
        isDismissedForRecording = true
    }

    mutating func markAutoDismissed() {
        isPromptSuppressed = true
    }
}

struct MeetingAutoStopSource: Equatable {
    let candidateID: String?
    let suppressionID: String?
    let normalizedURL: String?
    let sourceBundleID: String?
    let calendarEventID: String?
    let hasObservedCandidate: Bool

    private init(
        candidateID: String?,
        suppressionID: String?,
        normalizedURL: String?,
        sourceBundleID: String?,
        calendarEventID: String?,
        hasObservedCandidate: Bool
    ) {
        self.candidateID = candidateID
        self.suppressionID = suppressionID
        self.normalizedURL = normalizedURL
        self.sourceBundleID = sourceBundleID
        self.calendarEventID = calendarEventID
        self.hasObservedCandidate = hasObservedCandidate
    }

    init(candidate: MeetingCandidate) {
        self.candidateID = candidate.id
        self.suppressionID = candidate.suppressionID
        self.normalizedURL = candidate.url
        self.sourceBundleID = candidate.sourceBundleID
        self.calendarEventID = candidate.calendarEventID
        self.hasObservedCandidate = true
    }

    init?(meetingURL: URL) {
        guard let normalized = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
            return nil
        }
        self.candidateID = normalized.id
        self.suppressionID = normalized.id
        self.normalizedURL = normalized.url
        self.sourceBundleID = nil
        self.calendarEventID = nil
        self.hasObservedCandidate = false
    }

    func refined(with candidate: MeetingCandidate) -> MeetingAutoStopSource {
        let refinedSuppressionID = candidate.suppressionID == candidate.id
            ? suppressionID ?? candidate.suppressionID
            : candidate.suppressionID
        return MeetingAutoStopSource(
            candidateID: candidateID ?? candidate.id,
            suppressionID: refinedSuppressionID,
            normalizedURL: normalizedURL ?? candidate.url,
            sourceBundleID: sourceBundleID ?? candidate.sourceBundleID,
            calendarEventID: calendarEventID ?? candidate.calendarEventID,
            hasObservedCandidate: true
        )
    }
}

struct MeetingAutoStopTracker: Equatable {
    private(set) var source: MeetingAutoStopSource?
    private(set) var lastSeenAt: Date?
    private var observedBeforeRecordingStarted = false

    var isArmed: Bool {
        source != nil
    }

    mutating func arm(source: MeetingAutoStopSource?) {
        self.source = source
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
    }

    mutating func disarm() {
        source = nil
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
    }

    mutating func observeBeforeRecordingStarted(candidate: MeetingCandidate?) {
        guard let currentSource = source,
              let candidate,
              MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) else {
            return
        }
        source = currentSource.refined(with: candidate)
        observedBeforeRecordingStarted = true
    }

    mutating func markRecordingStarted(now: Date) {
        guard observedBeforeRecordingStarted, lastSeenAt == nil else { return }
        lastSeenAt = now
        observedBeforeRecordingStarted = false
    }

    mutating func observe(
        candidate: MeetingCandidate?,
        now: Date,
        gracePeriod: TimeInterval
    ) -> Bool {
        guard let currentSource = source else {
            return false
        }

        if let candidate,
           MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) {
            source = currentSource.refined(with: candidate)
            lastSeenAt = now
            return false
        }

        guard let lastSeenAt else {
            return false
        }

        return now.timeIntervalSince(lastSeenAt) >= gracePeriod
    }
}

enum MeetingAutoStopPolicy {
    static func matches(candidate: MeetingCandidate, source: MeetingAutoStopSource) -> Bool {
        if let candidateID = source.candidateID, candidate.id == candidateID {
            return true
        }

        if let suppressionID = source.suppressionID, candidate.suppressionID == suppressionID {
            return true
        }

        if let normalizedURL = source.normalizedURL, candidate.url == normalizedURL {
            return true
        }

        if matchesCalendarEventIdentity(candidate: candidate, source: source) {
            return true
        }

        if matchesDedicatedAppIdentity(candidate: candidate, source: source) {
            return true
        }

        return false
    }

    /// Every other identity here describes *how* a meeting is currently being
    /// observed, and each can change while the same call continues: the room
    /// URL is only reported while the call's browser tab is frontmost, and both
    /// the candidate and suppression IDs are audio-session IDs that rotate once
    /// their idle timeout lapses. A recording armed from a calendar event's
    /// join URL then stops matching the very meeting it was started for, and
    /// gets torn down mid-call. The calendar event is the one identity that
    /// stays fixed, so match on it when both sides agree on the event.
    ///
    /// The candidate must also show that a meeting is actually being observed.
    /// `MeetingCandidateResolver.resolve` attributes *any* media activity to the
    /// current calendar event once one exists, and its last fallback returns a
    /// bare `cal:<id>` candidate with no meeting app at all. A calendar entry
    /// that is only a reminder or a placeholder would then hold a recording open
    /// for its whole duration on the strength of unrelated microphone use — a
    /// dictation tool, say. Requiring attributed meeting audio or a room URL
    /// keeps that fallback from standing in for a live call, while every calendar
    /// branch backed by real meeting media still matches.
    private static func matchesCalendarEventIdentity(
        candidate: MeetingCandidate,
        source: MeetingAutoStopSource
    ) -> Bool {
        guard let sourceCalendarEventID = source.calendarEventID else { return false }
        guard candidate.evidence.contains(.audioInputProcess)
            || candidate.evidence.contains(.browserURL) else {
            return false
        }
        return candidate.calendarEventID == sourceCalendarEventID
    }

    /// A dedicated meeting app has no meeting URL, and `MeetingMediaSessionTracker`
    /// mints a new session ID once its quiet window lapses. A call that briefly
    /// stops reporting microphone input — being muted, or a transient input device
    /// reconfiguration — therefore reappears under an ID that can never match the
    /// armed source again, so the still-running meeting gets torn down and cannot
    /// recover. Fall back to the app identity for that case.
    ///
    /// Browsers are excluded: a single browser hosts many unrelated sessions, so
    /// its bundle ID is not a meeting identity.
    private static func matchesDedicatedAppIdentity(
        candidate: MeetingCandidate,
        source: MeetingAutoStopSource
    ) -> Bool {
        guard source.normalizedURL == nil,
              candidate.url == nil,
              let sourceBundleID = source.sourceBundleID,
              MeetingCandidateResolver.browserApps[sourceBundleID] == nil else {
            return false
        }
        return candidate.sourceBundleID == sourceBundleID
    }
}
