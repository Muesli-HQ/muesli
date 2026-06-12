import Foundation
import MuesliCore

/// Input signals fed into the detector each evaluation cycle.
struct MeetingSignals {
    let micActive: Bool
    let cameraActive: Bool
    let calendarEvent: CalendarEventContext?
    let runningApps: [RunningAppInfo]
    let activitySnapshot: MeetingActivitySnapshot?

    init(
        micActive: Bool,
        cameraActive: Bool,
        calendarEvent: CalendarEventContext?,
        runningApps: [RunningAppInfo],
        activitySnapshot: MeetingActivitySnapshot? = nil
    ) {
        self.micActive = micActive
        self.cameraActive = cameraActive
        self.calendarEvent = calendarEvent
        self.runningApps = runningApps
        self.activitySnapshot = activitySnapshot
    }
}

/// Calendar event that is currently active or started within 15 minutes.
struct CalendarEventContext {
    let id: String
    let title: String
}

/// A running application on the system.
struct RunningAppInfo {
    let bundleID: String
    let isActive: Bool  // frontmost
}

/// Foreground desktop context captured when evaluating mic/camera activity.
struct MeetingActivitySnapshot: Equatable {
    let bundleID: String
    let appName: String
    let browserURL: String?
}

/// Result when a meeting is detected.
struct MeetingDetection: Equatable {
    let appName: String
    let meetingTitle: String?
    let sourceID: String?

    init(appName: String, meetingTitle: String?, sourceID: String? = nil) {
        self.appName = appName
        self.meetingTitle = meetingTitle
        self.sourceID = sourceID
    }
}

/// Pure detection logic — no system dependencies, fully testable.
/// Evaluates a set of signals and decides whether a meeting is happening.
final class MeetingDetector {

    /// Dedicated meeting apps: running + mic active is a strong enough signal.
    static let dedicatedApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "us.zoom.ZoomPhone": "Zoom Phone",
        "com.apple.FaceTime": "FaceTime",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "net.whatsapp.WhatsApp": "WhatsApp",
    ]

    /// Apps that can host calls, but should not trigger from generic
    /// "running + mic" because they may run in the background without being
    /// the current meeting.
    private static let weakDedicatedAppBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "net.whatsapp.WhatsApp",
    ]

    /// Apps that require process-level audio attribution in the live detector.
    /// The legacy detector has no process attribution signal, so it should not
    /// infer these apps from process presence alone.
    private static let attributedAudioRequiredBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
    ]

    /// Browsers: always running, so require an extra signal
    /// (calendar event or frontmost) to avoid false positives.
    static let browserApps: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.brave.Browser": "Brave",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.apple.Safari": "Safari",
    ]

    /// Bundle ID to exclude from detection (our own app).
    var selfBundleID: String = Bundle.main.bundleIdentifier ?? "com.muesli.app"

    /// How many consecutive idle evaluations before resetting detection state.
    static let idleResetThreshold = 10

    // MARK: - Mutable state

    /// Keys we've already triggered for. Prevents duplicate notifications.
    /// Calendar: "cal:<eventID>", Apps: the bundle ID.
    private(set) var detectedKeys = Set<String>()

    private var suppressUntil: Date?
    private var consecutiveIdleCount = 0

    // MARK: - Evaluate

    /// Returns the current meeting candidate based on system state without
    /// applying deduplication. This is useful for UI that should be derived
    /// from the latest detector state rather than edge-triggered callbacks.
    func currentDetection(_ signals: MeetingSignals, now: Date = Date()) -> MeetingDetection? {
        if let until = suppressUntil, now < until { return nil }
        if !signals.micActive && !signals.cameraActive {
            return browserMeetingDetection(from: signals.activitySnapshot)
        }

        if signals.cameraActive, signals.micActive {
            let (appName, _, sourceID) = bestSnapshot(signals.activitySnapshot) ?? bestApp(from: signals.runningApps)
            if let appName {
                let title = signals.calendarEvent?.title
                return MeetingDetection(appName: appName, meetingTitle: title, sourceID: sourceID)
            }
        }

        guard signals.micActive else { return nil }

        if let cal = signals.calendarEvent {
            let (appName, _, sourceID) = bestSnapshot(signals.activitySnapshot) ?? bestApp(from: signals.runningApps)
            return MeetingDetection(appName: appName ?? "Meeting", meetingTitle: cal.title, sourceID: sourceID)
        }

        if let (appName, _, sourceID) = bestSnapshot(signals.activitySnapshot) {
            return MeetingDetection(appName: appName, meetingTitle: nil, sourceID: sourceID)
        }

        for app in signals.runningApps where app.bundleID != selfBundleID {
            if let name = Self.dedicatedApps[app.bundleID], !Self.isWeakDedicatedApp(app.bundleID) {
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        for app in signals.runningApps where app.bundleID != selfBundleID {
            if let name = Self.browserApps[app.bundleID], app.isActive {
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        for app in signals.runningApps where app.bundleID != selfBundleID {
            if let name = Self.dedicatedApps[app.bundleID],
               Self.isWeakDedicatedApp(app.bundleID),
               !Self.requiresAttributedAudio(app.bundleID) {
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        return nil
    }

    /// Evaluate signals and return a detection if a meeting should be flagged.
    /// Returns nil if no meeting detected or already notified.
    func evaluate(_ signals: MeetingSignals, now: Date = Date()) -> MeetingDetection? {
        // Suppressed?
        if let until = suppressUntil, now < until { return nil }

        // Track idle to reset state after a gap (neither mic nor camera active)
        if !signals.micActive && !signals.cameraActive {
            consecutiveIdleCount += 1
            if consecutiveIdleCount >= Self.idleResetThreshold {
                detectedKeys.removeAll()
            }
            return nil
        }
        consecutiveIdleCount = 0

        // Clean up keys for apps that have quit
        let runningIDs = Set(signals.runningApps.map(\.bundleID))
        detectedKeys = detectedKeys.filter { $0.hasPrefix("cal:") || $0 == "camera" || runningIDs.contains($0) }

        // Priority 0: Camera + mic + meeting app/browser = strong meeting signal.
        // Camera alone is not enough — apps like Photo Booth or scanning can trigger it.
        if signals.cameraActive, signals.micActive, !detectedKeys.contains("camera") {
            let (appName, appBundleID, sourceID) = bestSnapshot(signals.activitySnapshot) ?? bestApp(from: signals.runningApps)
            if appName != nil {
                detectedKeys.insert("camera")
                if let bid = appBundleID { detectedKeys.insert(bid) }
                if let cal = signals.calendarEvent { detectedKeys.insert("cal:\(cal.id)") }
                let title = signals.calendarEvent?.title
                return MeetingDetection(appName: appName ?? "Meeting", meetingTitle: title, sourceID: sourceID)
            }
        }

        // Remaining checks require mic to be active
        guard signals.micActive else { return nil }

        // Priority 1: Calendar event + mic active = meeting (strongest signal)
        if let cal = signals.calendarEvent {
            let key = "cal:\(cal.id)"
            if !detectedKeys.contains(key) {
                detectedKeys.insert(key)
                let (appName, appBundleID, sourceID) = bestSnapshot(signals.activitySnapshot) ?? bestApp(from: signals.runningApps)
                // Also mark the identified app to prevent double-triggering
                if let bid = appBundleID { detectedKeys.insert(bid) }
                return MeetingDetection(appName: appName ?? "Meeting", meetingTitle: cal.title, sourceID: sourceID)
            }
        }

        // Priority 2: Foreground app captured with the mic/camera activity.
        // This is stronger than background process presence and prevents a
        // background call-capable app from labeling an active browser meeting.
        if let (appName, appBundleID, sourceID) = bestSnapshot(signals.activitySnapshot),
           appBundleID.map({ !detectedKeys.contains($0) }) ?? true {
            if let appBundleID { detectedKeys.insert(appBundleID) }
            return MeetingDetection(appName: appName, meetingTitle: nil, sourceID: sourceID)
        }

        // Priority 3: Strong dedicated meeting app + mic active
        for app in signals.runningApps {
            guard app.bundleID != selfBundleID, !detectedKeys.contains(app.bundleID) else { continue }
            if let name = Self.dedicatedApps[app.bundleID], !Self.isWeakDedicatedApp(app.bundleID) {
                detectedKeys.insert(app.bundleID)
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        // Priority 4: Browser frontmost + mic active
        for app in signals.runningApps {
            guard app.bundleID != selfBundleID, !detectedKeys.contains(app.bundleID) else { continue }
            if let name = Self.browserApps[app.bundleID], app.isActive {
                detectedKeys.insert(app.bundleID)
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        // Priority 5: Weak dedicated app + mic active. This still detects
        // WhatsApp calls, but avoids labeling a frontmost browser meeting as WhatsApp.
        for app in signals.runningApps {
            guard app.bundleID != selfBundleID, !detectedKeys.contains(app.bundleID) else { continue }
            guard !hasActiveStrongerDetection() else { continue }
            guard !Self.requiresAttributedAudio(app.bundleID) else { continue }
            if let name = Self.dedicatedApps[app.bundleID], Self.isWeakDedicatedApp(app.bundleID) {
                detectedKeys.insert(app.bundleID)
                return MeetingDetection(appName: name, meetingTitle: nil)
            }
        }

        return nil
    }

    // MARK: - Suppression

    func suppress(for duration: TimeInterval = 120) {
        suppressUntil = Date().addingTimeInterval(duration)
    }

    func suppressWhileActive() {
        suppressUntil = Date.distantFuture
    }

    func resumeAfterCooldown() {
        suppressUntil = Date().addingTimeInterval(15)
    }

    func resetDetections() {
        detectedKeys.removeAll()
        consecutiveIdleCount = 0
    }

    // MARK: - Helpers

    private func bestSnapshot(_ snapshot: MeetingActivitySnapshot?) -> (name: String, bundleID: String?, sourceID: String?)? {
        guard let snapshot, snapshot.bundleID != selfBundleID else { return nil }
        let sourceID = snapshot.browserURL
        if let name = Self.dedicatedApps[snapshot.bundleID],
           !Self.requiresAttributedAudio(snapshot.bundleID) {
            return (name, snapshot.bundleID, sourceID)
        }
        if let name = Self.browserApps[snapshot.bundleID] {
            return (name, snapshot.bundleID, sourceID)
        }
        if let browserURL = snapshot.browserURL, Self.isMeetingURL(browserURL) {
            return (snapshot.appName, snapshot.bundleID, browserURL)
        }
        return nil
    }

    /// Find the best display name and bundle ID from running apps (prefer dedicated, then browser).
    private func bestApp(from apps: [RunningAppInfo]) -> (name: String?, bundleID: String?, sourceID: String?) {
        for app in apps where app.bundleID != selfBundleID {
            if let name = Self.dedicatedApps[app.bundleID], !Self.isWeakDedicatedApp(app.bundleID) {
                return (name, app.bundleID, nil)
            }
        }
        for app in apps where app.bundleID != selfBundleID {
            if let name = Self.browserApps[app.bundleID], app.isActive { return (name, app.bundleID, nil) }
        }
        for app in apps where app.bundleID != selfBundleID {
            if let name = Self.dedicatedApps[app.bundleID],
               !Self.requiresAttributedAudio(app.bundleID) {
                return (name, app.bundleID, nil)
            }
        }
        return (nil, nil, nil)
    }

    private static func isWeakDedicatedApp(_ bundleID: String) -> Bool {
        weakDedicatedAppBundleIDs.contains(bundleID)
    }

    private static func requiresAttributedAudio(_ bundleID: String) -> Bool {
        attributedAudioRequiredBundleIDs.contains(bundleID)
    }

    private func hasActiveStrongerDetection() -> Bool {
        detectedKeys.contains("camera") || detectedKeys.contains { key in
            Self.browserApps.keys.contains(key)
                || (Self.dedicatedApps[key] != nil && !Self.isWeakDedicatedApp(key))
        }
    }

    private func browserMeetingDetection(from snapshot: MeetingActivitySnapshot?) -> MeetingDetection? {
        guard let snapshot,
              snapshot.bundleID != selfBundleID,
              let browserURL = snapshot.browserURL,
              Self.isMeetingURL(browserURL) else { return nil }
        let appName = Self.browserApps[snapshot.bundleID] ?? snapshot.appName
        return MeetingDetection(appName: appName, meetingTitle: nil, sourceID: browserURL)
    }

    static func isMeetingURL(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("meet.google.com")
            || lowercased.contains("zoom.us")
            || lowercased.contains("teams.microsoft.com")
            || lowercased.contains("webex.com")
            || lowercased.contains("facetime.apple.com")
            || lowercased.contains("app.slack.com/huddle/")
    }
}
