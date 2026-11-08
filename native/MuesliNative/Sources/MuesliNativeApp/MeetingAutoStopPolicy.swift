import Foundation
import CoreGraphics

struct MeetingClamshellMicWarningState {
    private(set) var hasWarned = false

    mutating func update(lidClosed: Bool, effectiveInputIsBuiltIn: Bool?) -> Bool {
        guard lidClosed else { hasWarned = false; return false }
        guard let effectiveInputIsBuiltIn else { return false }
        guard effectiveInputIsBuiltIn else { hasWarned = false; return false }
        guard !hasWarned else { return false }
        return true
    }

    mutating func markShown() { hasWarned = true }
}

enum MeetingLidStopPolicy {
    static func shouldStop(lidClosed: Bool, hasActiveExternalDisplay: Bool?) -> Bool {
        lidClosed && hasActiveExternalDisplay == false
    }

    static func hasActiveExternalDisplay() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).contains {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0
        }
    }
}

enum MeetingSystemStopAction: Equatable {
    case none, cancelPreparation, stopRecording

    static func action(phase: MeetingCapturePhase) -> Self {
        switch phase {
        case .preparing: .cancelPreparation
        case .capturing, .paused: .stopRecording
        case .stopping, .stopped: .none
        }
    }
}

enum MeetingRecordingStartOrigin: Equatable {
    case manual
    case detectedPrompt
    case calendarAutoRecord
    case scheduledMeetingPrompt
    case joinAndRecord
    case calendarRecordingSwitch

    var tracksMeetingSource: Bool {
        switch self {
        case .manual:
            return false
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord, .calendarRecordingSwitch:
            return true
        }
    }

    var signalLossResponse: MeetingSignalLossResponse {
        switch self {
        case .manual:
            return .transcriptInactivity
        case .detectedPrompt:
            return .warnOnly
        case .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord, .calendarRecordingSwitch:
            return .warnOnly
        }
    }

    func signalLossSource(
        explicitSource: MeetingAutoStopSource?,
        recentSource: @autoclosure () -> MeetingAutoStopSource?
    ) -> MeetingAutoStopSource? {
        switch self {
        case .manual:
            return nil
        case .calendarRecordingSwitch:
            return explicitSource
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return explicitSource ?? recentSource()
        }
    }
}

enum MeetingSignalLossResponse: Equatable {
    case none
    case warnOnly
    case transcriptInactivity
}

struct MeetingSignalLossPromptState: Equatable {
    private(set) var isPromptSuppressed = false
    private(set) var isDismissedForRecording = false
    private(set) var lastTranscriptActivityAt: Date?

    static let transcriptQuietPeriod: TimeInterval = 45
    static let notificationDuration: TimeInterval = 30

    var inactivityDeadline: Date? {
        guard canPresentPrompt, let lastTranscriptActivityAt else { return nil }
        return lastTranscriptActivityAt.addingTimeInterval(Self.transcriptQuietPeriod)
    }

    var canPresentPrompt: Bool {
        !isPromptSuppressed && !isDismissedForRecording
    }

    mutating func resetForRecording() {
        isPromptSuppressed = false
        isDismissedForRecording = false
        lastTranscriptActivityAt = nil
    }

    mutating func noteTranscriptActivity(now: Date) {
        lastTranscriptActivityAt = now
    }

    func hasRecentTranscriptActivity(now: Date, quietPeriod: TimeInterval) -> Bool {
        guard let lastTranscriptActivityAt else { return false }
        return now.timeIntervalSince(lastTranscriptActivityAt) < quietPeriod
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
    let hasObservedCandidate: Bool
    let requiresExactRoomMatch: Bool

    var assertionTarget: MeetingAssertionTarget? {
        guard hasObservedCandidate, let bundle = sourceBundleID else { return nil }
        let same = MeetingAutoStopPolicy.bundleIDsReferToSameApp
        if same(bundle, "us.zoom.xos") { return .zoom }
        if ["com.microsoft.teams2", "com.microsoft.teams"].contains(where: { same(bundle, $0) }) { return .teams }
        if ["com.webex.meetingmanager", "com.cisco.webexmeetingsapp"].contains(where: { same(bundle, $0) }) { return .webex }
        // A source exists only for an accepted detected or calendar recording.
        // Chromium's assertion is process-wide, so another tab can prolong or
        // be mistaken for this meeting; absence alone never arms the observer.
        guard let root = MeetingCandidateResolver.browserApps.keys.first(where: { same(bundle, $0) }) else { return nil }
        return .browser(bundleID: root)
    }

    private init(
        candidateID: String?,
        suppressionID: String?,
        normalizedURL: String?,
        sourceBundleID: String?,
        hasObservedCandidate: Bool,
        requiresExactRoomMatch: Bool
    ) {
        self.candidateID = candidateID
        self.suppressionID = suppressionID
        self.normalizedURL = normalizedURL
        self.sourceBundleID = sourceBundleID
        self.hasObservedCandidate = hasObservedCandidate
        self.requiresExactRoomMatch = requiresExactRoomMatch
    }

    init(candidate: MeetingCandidate) {
        self.candidateID = candidate.id
        self.suppressionID = candidate.suppressionID
        self.normalizedURL = candidate.url
        self.sourceBundleID = candidate.sourceBundleID
        self.hasObservedCandidate = true
        self.requiresExactRoomMatch = false
    }

    init?(meetingURL: URL, requiresExactRoomMatch: Bool = false) {
        guard let normalized = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
            return nil
        }
        self.candidateID = normalized.id
        self.suppressionID = normalized.id
        self.normalizedURL = normalized.url
        self.sourceBundleID = nil
        self.hasObservedCandidate = false
        self.requiresExactRoomMatch = requiresExactRoomMatch
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
            hasObservedCandidate: true,
            requiresExactRoomMatch: requiresExactRoomMatch
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
    enum CalendarConfirmationAction {
        case transcribeCurrent
        case joinScheduled
    }

    static func calendarConfirmationHasConflictingRoom(candidate: MeetingCandidate?, meetingURL: URL?) -> Bool {
        guard let candidateRoom = candidate?.url,
              let scheduledRoom = meetingURL.flatMap({ MeetingAutoStopSource(meetingURL: $0)?.normalizedURL }) else { return false }
        return candidateRoom != scheduledRoom
    }

    static func calendarConfirmationSource(candidate: MeetingCandidate?, meetingURL: URL?,
                                           action: CalendarConfirmationAction = .transcribeCurrent)
        -> (source: MeetingAutoStopSource?, origin: MeetingRecordingStartOrigin) {
        if action == .joinScheduled {
            return (meetingURL.flatMap { MeetingAutoStopSource(meetingURL: $0, requiresExactRoomMatch: true) },
                    .calendarRecordingSwitch)
        }
        if let candidate {
            return (MeetingAutoStopSource(candidate: candidate), .detectedPrompt)
        }
        if let source = meetingURL.flatMap({ MeetingAutoStopSource(meetingURL: $0, requiresExactRoomMatch: true) }) {
            return (source, .calendarAutoRecord)
        }
        return (nil, .manual)
    }

    static func matches(candidate: MeetingCandidate, source: MeetingAutoStopSource) -> Bool {
        // Missing room evidence permits a media fallback; conflicting room
        // evidence must never extend the original recording, even in one browser.
        if let room = source.normalizedURL, let candidateRoom = candidate.url,
           room != candidateRoom { return false }
        if candidate.id == source.candidateID
            || candidate.suppressionID == source.suppressionID
            || (source.normalizedURL != nil && candidate.url == source.normalizedURL) {
            return true
        }
        // Calendar and join-link sources start with a room URL but no desktop
        // bundle. Allow matching desktop input attribution to refine that source;
        // a running process or a browser URL alone cannot bind it.
        if !source.requiresExactRoomMatch, source.sourceBundleID == nil,
           candidate.url == nil,
           let bundle = candidate.sourceBundleID,
           let prefix = source.candidateID?.split(separator: ":").first,
           [("zoom", "us.zoom.xos"), ("teams", "com.microsoft.teams2"),
            ("teams", "com.microsoft.teams"), ("webex", "com.webex.meetingmanager"),
            ("webex", "com.cisco.webexmeetingsapp")].contains(where: {
                $0.0 == String(prefix) && bundleIDsReferToSameApp(bundle, $0.1)
           }),
           candidate.evidence.contains(.audioInputProcess) {
            return true
        }
        guard let sourceBundle = source.sourceBundleID,
              let candidateBundle = candidate.sourceBundleID,
              bundleIDsReferToSameApp(sourceBundle, candidateBundle) else { return false }
        // Native sources have no room identity. Browser sources need observed
        // media attribution when their room URL is temporarily unavailable.
        return source.normalizedURL == nil
            || (source.hasObservedCandidate && candidate.evidence.contains(.audioInputProcess))
    }

    static func bundleIDsReferToSameApp(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.lowercased()
        let rhs = rhs.lowercased()
        return lhs == rhs || lhs.hasPrefix("\(rhs).") || rhs.hasPrefix("\(lhs).")
    }
}
