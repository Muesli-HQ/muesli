import Foundation

struct MeetingCandidate: Equatable {
    enum Platform: String, Equatable {
        case googleMeet
        case zoom
        case teams
        case webex
        case facetime
        case slack
        case whatsApp
        case unknown

        var displayName: String {
            switch self {
            case .googleMeet: return "Google Meet"
            case .zoom: return "Zoom"
            case .teams: return "Teams"
            case .webex: return "Webex"
            case .facetime: return "FaceTime"
            case .slack: return "Slack"
            case .whatsApp: return "WhatsApp"
            case .unknown: return "Meeting"
            }
        }
    }

    enum Evidence: String, Hashable {
        case micActive
        case cameraActive
        case browserURL
        case calendarEvent
        case foregroundApp
        case dedicatedApp
        case audioInputProcess
    }

    let id: String
    let platform: Platform
    let appName: String
    let url: String?
    let evidence: Set<Evidence>
    let startedAt: Date
    let meetingTitle: String?
    let sourceBundleID: String?
    let sourcePID: pid_t?
    let suppressionID: String

    init(
        id: String,
        platform: Platform,
        appName: String,
        url: String?,
        evidence: Set<Evidence>,
        startedAt: Date,
        meetingTitle: String?,
        sourceBundleID: String? = nil,
        sourcePID: pid_t? = nil,
        suppressionID: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.appName = appName
        self.url = url
        self.evidence = evidence
        self.startedAt = startedAt
        self.meetingTitle = meetingTitle
        self.sourceBundleID = sourceBundleID
        self.sourcePID = sourcePID
        self.suppressionID = suppressionID ?? id
    }

    var subtitle: String {
        meetingTitle ?? (platform == .unknown ? appName : platform.displayName)
    }

    static func == (lhs: MeetingCandidate, rhs: MeetingCandidate) -> Bool {
        lhs.id == rhs.id
            && lhs.platform == rhs.platform
            && lhs.appName == rhs.appName
            && lhs.url == rhs.url
            && lhs.evidence == rhs.evidence
            && lhs.meetingTitle == rhs.meetingTitle
            && lhs.sourceBundleID == rhs.sourceBundleID
            && lhs.sourcePID == rhs.sourcePID
            && lhs.suppressionID == rhs.suppressionID
    }
}

struct BrowserMeetingContext: Equatable {
    let bundleID: String
    let appName: String
    let pid: pid_t?
    let url: String
    let normalizedID: String
    let platform: MeetingCandidate.Platform
    let isFocused: Bool

    init(
        bundleID: String,
        appName: String,
        pid: pid_t? = nil,
        url: String,
        normalizedID: String,
        platform: MeetingCandidate.Platform,
        isFocused: Bool
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.pid = pid
        self.url = url
        self.normalizedID = normalizedID
        self.platform = platform
        self.isFocused = isFocused
    }
}

struct MeetingSignalSnapshot {
    let micActive: Bool
    let cameraActive: Bool
    let calendarEvent: CalendarEventContext?
    let runningApps: [RunningAppInfo]
    let browserMeetings: [BrowserMeetingContext]
    let audioInputProcesses: [AudioProcessActivity]
    let foregroundBundleID: String?
    let now: Date

    init(
        micActive: Bool,
        cameraActive: Bool,
        calendarEvent: CalendarEventContext?,
        runningApps: [RunningAppInfo],
        browserMeetings: [BrowserMeetingContext],
        audioInputProcesses: [AudioProcessActivity] = [],
        foregroundBundleID: String?,
        now: Date
    ) {
        self.micActive = micActive
        self.cameraActive = cameraActive
        self.calendarEvent = calendarEvent
        self.runningApps = runningApps
        self.browserMeetings = browserMeetings
        self.audioInputProcesses = audioInputProcesses
        self.foregroundBundleID = foregroundBundleID
        self.now = now
    }
}

struct NormalizedMeetingURL: Equatable {
    let id: String
    let url: String
    let platform: MeetingCandidate.Platform
}

enum MeetingURLNormalizer {
    static func normalize(_ rawValue: String) -> NormalizedMeetingURL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased() else {
            return nil
        }

        let path = components.path
        let compactPath = path
            .split(separator: "/")
            .map(String.init)
            .joined(separator: "/")

        if host == "meet.google.com" {
            guard let code = path.split(separator: "/").first.map(String.init),
                  isGoogleMeetCode(code) else { return nil }
            let identity = "meet.google.com/\(code.lowercased())"
            return NormalizedMeetingURL(
                id: "googleMeet:\(identity)",
                url: identity,
                platform: .googleMeet
            )
        }

        if host.hasSuffix("zoom.us") {
            if let meetingID = zoomMeetingID(from: path) {
                let identity = "\(host)/j/\(meetingID)"
                return NormalizedMeetingURL(id: "zoom:\(identity)", url: identity, platform: .zoom)
            }
            let identity = compactIdentity(host: host, path: compactPath)
            return NormalizedMeetingURL(id: "zoom:\(identity)", url: identity, platform: .zoom)
        }

        if host.hasSuffix("teams.microsoft.com") || host == "teams.live.com" {
            let identity = compactIdentity(host: host, path: compactPath)
            return NormalizedMeetingURL(id: "teams:\(identity)", url: identity, platform: .teams)
        }

        if host.hasSuffix("webex.com") {
            let identity = compactIdentity(host: host, path: compactPath)
            return NormalizedMeetingURL(id: "webex:\(identity)", url: identity, platform: .webex)
        }

        if host == "facetime.apple.com" {
            let identity = compactIdentity(host: host, path: compactPath)
            return NormalizedMeetingURL(id: "facetime:\(identity)", url: identity, platform: .facetime)
        }

        if host == "app.slack.com", path.hasPrefix("/huddle/") {
            let identity = compactIdentity(host: host, path: compactPath)
            return NormalizedMeetingURL(id: "slack:\(identity)", url: identity, platform: .slack)
        }

        return nil
    }

    private static func isGoogleMeetCode(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 3,
              parts[1].count == 4,
              parts[2].count == 3 else {
            return false
        }
        return parts.allSatisfy { part in
            part.allSatisfy { $0 >= "a" && $0 <= "z" }
        }
    }

    private static func zoomMeetingID(from path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let joinIndex = parts.firstIndex(of: "j"),
              parts.indices.contains(joinIndex + 1) else { return nil }
        return parts[joinIndex + 1].isEmpty ? nil : parts[joinIndex + 1]
    }

    private static func compactIdentity(host: String, path: String) -> String {
        path.isEmpty ? host : "\(host)/\(path)"
    }
}

final class MeetingCandidateResolver {
    private struct AppAudioSession {
        let id: String
        var lastSeenAt: Date
    }

    static let dedicatedApps: [String: (name: String, platform: MeetingCandidate.Platform)] = [
        "us.zoom.xos": ("Zoom", .zoom),
        "us.zoom.ZoomPhone": ("Zoom Phone", .zoom),
        "com.apple.FaceTime": ("FaceTime", .facetime),
        "com.microsoft.teams2": ("Teams", .teams),
        "com.microsoft.teams": ("Teams", .teams),
        "com.tinyspeck.slackmacgap": ("Slack", .slack),
        "com.webex.meetingmanager": ("Webex", .webex),
        "com.cisco.webexmeetingsapp": ("Webex", .webex),
        "net.whatsapp.WhatsApp": ("WhatsApp", .whatsApp),
    ]

    /// Apps that are call-capable but too noisy for generic "running + mic"
    /// detection. Electron chat apps can keep audio sessions warm while the
    /// user is only messaging, so they need attributed full-duplex audio or a
    /// stronger signal such as a calendar/browser meeting.
    static let weakDedicatedAppBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "net.whatsapp.WhatsApp",
    ]

    private static let fullDuplexAudioRequiredBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
    ]

    static let browserApps: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.brave.Browser": "Brave",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.apple.Safari": "Safari",
    ]

    var selfBundleID: String = Bundle.main.bundleIdentifier ?? "com.muesli.app"
    /// App-audio candidates do not expose a room URL, so their
    /// prompt identity is scoped to a contiguous attributed-audio session.
    private let appAudioSessionIdleTimeout: TimeInterval
    private var appAudioSessions: [String: AppAudioSession] = [:]

    init(appAudioSessionIdleTimeout: TimeInterval = 10) {
        self.appAudioSessionIdleTimeout = appAudioSessionIdleTimeout
    }

    func resolve(_ snapshot: MeetingSignalSnapshot) -> MeetingCandidate? {
        pruneExpiredAppAudioSessions(now: snapshot.now)

        let browserMeeting = bestBrowserMeeting(from: snapshot)

        if let browserMeeting,
           let inputProcess = activeInputProcess(for: browserMeeting.bundleID, in: snapshot) {
            let suppressionID = appAudioSessionID(
                forBundleID: browserMeeting.bundleID,
                prefix: "browser",
                now: snapshot.now
            )
            return candidate(
                id: browserMeeting.normalizedID,
                platform: browserMeeting.platform,
                appName: browserMeeting.appName,
                url: browserMeeting.url,
                title: snapshot.calendarEvent?.title,
                evidence: browserEvidence(from: snapshot, context: browserMeeting, inputProcess: inputProcess),
                sourceBundleID: browserMeeting.bundleID,
                sourcePID: validSourcePID(inputProcess.pid),
                suppressionID: suppressionID,
                now: snapshot.now
            )
        }

        if let browserMeeting,
           browserMeeting.isFocused {
            return candidate(
                id: browserMeeting.normalizedID,
                platform: browserMeeting.platform,
                appName: browserMeeting.appName,
                url: browserMeeting.url,
                title: snapshot.calendarEvent?.title,
                evidence: browserEvidence(from: snapshot, context: browserMeeting, inputProcess: nil),
                sourceBundleID: browserMeeting.bundleID,
                sourcePID: browserMeeting.pid,
                now: snapshot.now
            )
        }

        guard hasMediaActivity(snapshot) else { return nil }

        if let calendarEvent = snapshot.calendarEvent {
            if let browserMeeting {
                let inputProcess = activeInputProcess(for: browserMeeting.bundleID, in: snapshot)
                let suppressionID = inputProcess == nil ? nil : appAudioSessionID(
                    forBundleID: browserMeeting.bundleID,
                    prefix: "browser",
                    now: snapshot.now
                )
                return candidate(
                    id: "cal:\(calendarEvent.id):\(browserMeeting.normalizedID)",
                    platform: browserMeeting.platform,
                    appName: browserMeeting.appName,
                    url: browserMeeting.url,
                    title: calendarEvent.title,
                    evidence: browserEvidence(from: snapshot, context: browserMeeting, inputProcess: inputProcess).union([.calendarEvent]),
                    sourceBundleID: browserMeeting.bundleID,
                    sourcePID: inputProcess.flatMap { validSourcePID($0.pid) } ?? browserMeeting.pid,
                    suppressionID: suppressionID,
                    now: snapshot.now
                )
            }

            if let audioApp = bestMeetingAudioProcess(from: snapshot.audioInputProcesses, includeWeakApps: true) {
                let appSessionID = appAudioSessionID(for: audioApp, now: snapshot.now)
                return candidate(
                    id: "cal:\(calendarEvent.id)",
                    platform: platform(for: audioApp.bundleID) ?? .unknown,
                    appName: audioApp.appName,
                    url: nil,
                    title: calendarEvent.title,
                    evidence: mediaEvidence(from: snapshot).union([.calendarEvent, .audioInputProcess]),
                    sourceBundleID: audioApp.bundleID,
                    sourcePID: validSourcePID(audioApp.pid),
                    suppressionID: appSessionID,
                    now: snapshot.now
                )
            }

            if let browserAudio = bestBrowserAudioProcess(from: snapshot.audioInputProcesses) {
                let sessionID = appAudioSessionID(
                    forBundleID: browserAudio.bundleID,
                    prefix: "browser",
                    now: snapshot.now
                )
                return candidate(
                    id: "cal:\(calendarEvent.id)",
                    platform: .unknown,
                    appName: browserAudio.appName,
                    url: nil,
                    title: calendarEvent.title,
                    evidence: browserMediaEvidence(from: snapshot, browserBundleID: browserAudio.bundleID).union([.calendarEvent]),
                    sourceBundleID: browserAudio.bundleID,
                    sourcePID: validSourcePID(browserAudio.process.pid),
                    suppressionID: sessionID,
                    now: snapshot.now
                )
            }

            let app = bestApp(from: snapshot.runningApps, includeWeakApps: true)
            return candidate(
                id: "cal:\(calendarEvent.id)",
                platform: app?.platform ?? .unknown,
                appName: app?.name ?? "Meeting",
                url: nil,
                title: calendarEvent.title,
                evidence: mediaEvidence(from: snapshot).union([.calendarEvent]),
                sourceBundleID: app?.bundleID,
                sourcePID: nil,
                now: snapshot.now
            )
        }

        if let browserAudio = bestBrowserAudioProcess(from: snapshot.audioInputProcesses) {
            let sessionID = appAudioSessionID(
                forBundleID: browserAudio.bundleID,
                prefix: "browser",
                now: snapshot.now
            )
            return candidate(
                id: sessionID,
                platform: .unknown,
                appName: browserAudio.appName,
                url: nil,
                title: nil,
                evidence: browserMediaEvidence(from: snapshot, browserBundleID: browserAudio.bundleID),
                sourceBundleID: browserAudio.bundleID,
                sourcePID: validSourcePID(browserAudio.process.pid),
                suppressionID: sessionID,
                now: snapshot.now
            )
        }

        if let audioApp = bestMeetingAudioProcess(from: snapshot.audioInputProcesses, includeWeakApps: true) {
            let platform = platform(for: audioApp.bundleID) ?? .unknown
            let appSessionID = appAudioSessionID(for: audioApp, now: snapshot.now)
            return candidate(
                id: appSessionID,
                platform: platform,
                appName: audioApp.appName,
                url: nil,
                title: nil,
                evidence: mediaEvidence(from: snapshot).union([.audioInputProcess, .dedicatedApp]),
                sourceBundleID: audioApp.bundleID,
                sourcePID: validSourcePID(audioApp.pid),
                suppressionID: appSessionID,
                now: snapshot.now
            )
        }

        if let app = bestApp(from: snapshot.runningApps, includeWeakApps: false) {
            return candidate(
                id: "app:\(app.bundleID)",
                platform: app.platform,
                appName: app.name,
                url: nil,
                title: nil,
                evidence: mediaEvidence(from: snapshot).union([.dedicatedApp]),
                sourceBundleID: app.bundleID,
                sourcePID: nil,
                now: snapshot.now
            )
        }

        if let foregroundBrowser = snapshot.runningApps.first(where: {
            $0.bundleID == snapshot.foregroundBundleID && Self.browserApps[$0.bundleID] != nil
        }), let appName = Self.browserApps[foregroundBrowser.bundleID] {
            return candidate(
                id: "browser:\(foregroundBrowser.bundleID)",
                platform: .unknown,
                appName: appName,
                url: nil,
                title: nil,
                evidence: mediaEvidence(from: snapshot).union([.foregroundApp]),
                sourceBundleID: foregroundBrowser.bundleID,
                sourcePID: nil,
                now: snapshot.now
            )
        }

        return nil
    }

    private func bestBrowserMeeting(from snapshot: MeetingSignalSnapshot) -> BrowserMeetingContext? {
        snapshot.browserMeetings.sorted { lhs, rhs in
            if lhs.isFocused != rhs.isFocused { return lhs.isFocused && !rhs.isFocused }
            if lhs.platform != rhs.platform { return lhs.platform == .googleMeet }
            return lhs.appName < rhs.appName
        }.first
    }

    private func bestApp(
        from apps: [RunningAppInfo],
        includeWeakApps: Bool
    ) -> (bundleID: String, name: String, platform: MeetingCandidate.Platform)? {
        for app in apps.sorted(by: { $0.isActive && !$1.isActive }) where app.bundleID != selfBundleID {
            guard let match = Self.dedicatedApps[app.bundleID] else { continue }
            if !includeWeakApps && Self.weakDedicatedAppBundleIDs.contains(app.bundleID) { continue }
            if Self.fullDuplexAudioRequiredBundleIDs.contains(app.bundleID) { continue }
            return (app.bundleID, match.name, match.platform)
        }
        return nil
    }

    private func bestMeetingAudioProcess(
        from processes: [AudioProcessActivity],
        includeWeakApps: Bool
    ) -> AudioProcessActivity? {
        let candidates = processes.filter { process in
            guard process.bundleID != selfBundleID else { return false }
            guard Self.dedicatedApps[process.bundleID] != nil else { return false }
            if !Self.weakDedicatedAppBundleIDs.contains(process.bundleID) {
                return true
            }
            guard includeWeakApps else { return false }
            guard Self.fullDuplexAudioRequiredBundleIDs.contains(process.bundleID) else {
                return true
            }
            return process.isRunningOutput
        }

        return candidates.sorted { lhs, rhs in
            let lhsWeak = Self.weakDedicatedAppBundleIDs.contains(lhs.bundleID)
            let rhsWeak = Self.weakDedicatedAppBundleIDs.contains(rhs.bundleID)
            if lhsWeak != rhsWeak { return !lhsWeak && rhsWeak }
            return lhs.appName < rhs.appName
        }.first
    }

    private func bestBrowserAudioProcess(
        from processes: [AudioProcessActivity]
    ) -> (process: AudioProcessActivity, bundleID: String, appName: String)? {
        let candidates = processes.compactMap { process -> (process: AudioProcessActivity, bundleID: String, appName: String)? in
            guard process.bundleID != selfBundleID,
                  let browserBundleID = browserBundleID(for: process.bundleID),
                  let appName = Self.browserApps[browserBundleID] else {
                return nil
            }
            return (process, browserBundleID, appName)
        }

        return candidates.sorted { lhs, rhs in
            if lhs.bundleID != rhs.bundleID { return lhs.appName < rhs.appName }
            let lhsExact = lhs.process.bundleID == lhs.bundleID
            let rhsExact = rhs.process.bundleID == rhs.bundleID
            if lhsExact != rhsExact { return lhsExact && !rhsExact }
            return lhs.process.appName < rhs.process.appName
        }.first
    }

    private func browserBundleID(for processBundleID: String) -> String? {
        if Self.browserApps[processBundleID] != nil { return processBundleID }
        return Self.browserApps.keys.first { browserBundleID in
            isHelperBundleID(processBundleID, for: browserBundleID)
        }
    }

    private func browserEvidence(
        from snapshot: MeetingSignalSnapshot,
        context: BrowserMeetingContext,
        inputProcess: AudioProcessActivity?
    ) -> Set<MeetingCandidate.Evidence> {
        var evidence = mediaEvidence(from: snapshot)
        evidence.insert(.browserURL)
        if context.isFocused { evidence.insert(.foregroundApp) }
        if inputProcess != nil { evidence.insert(.audioInputProcess) }
        return evidence
    }

    private func browserMediaEvidence(
        from snapshot: MeetingSignalSnapshot,
        browserBundleID: String
    ) -> Set<MeetingCandidate.Evidence> {
        var evidence = mediaEvidence(from: snapshot)
        evidence.insert(.audioInputProcess)
        if snapshot.foregroundBundleID == browserBundleID {
            evidence.insert(.foregroundApp)
        }
        return evidence
    }

    private func mediaEvidence(from snapshot: MeetingSignalSnapshot) -> Set<MeetingCandidate.Evidence> {
        var evidence = Set<MeetingCandidate.Evidence>()
        if snapshot.micActive { evidence.insert(.micActive) }
        if snapshot.cameraActive { evidence.insert(.cameraActive) }
        return evidence
    }

    private func hasMediaActivity(_ snapshot: MeetingSignalSnapshot) -> Bool {
        snapshot.micActive || snapshot.cameraActive || !snapshot.audioInputProcesses.isEmpty
    }

    private func activeInputProcess(
        for bundleID: String,
        in snapshot: MeetingSignalSnapshot
    ) -> AudioProcessActivity? {
        snapshot.audioInputProcesses.first {
            $0.bundleID == bundleID || isHelperBundleID($0.bundleID, for: bundleID)
        }
    }

    private func isHelperBundleID(_ helperBundleID: String, for parentBundleID: String) -> Bool {
        helperBundleID.lowercased().hasPrefix("\(parentBundleID.lowercased()).")
    }

    private func platform(for bundleID: String) -> MeetingCandidate.Platform? {
        Self.dedicatedApps[bundleID]?.platform
    }

    private func validSourcePID(_ pid: pid_t) -> pid_t? {
        pid > 0 ? pid : nil
    }

    private func appAudioSessionID(for process: AudioProcessActivity, now: Date) -> String {
        appAudioSessionID(forBundleID: process.bundleID, prefix: "app", now: now)
    }

    private func appAudioSessionID(forBundleID key: String, prefix: String, now: Date) -> String {
        if var session = appAudioSessions[key],
           now.timeIntervalSince(session.lastSeenAt) <= appAudioSessionIdleTimeout {
            session.lastSeenAt = now
            appAudioSessions[key] = session
            return session.id
        }

        let sessionStartedAt = Int(now.timeIntervalSince1970)
        let session = AppAudioSession(
            id: "\(prefix):\(key):session:\(sessionStartedAt)",
            lastSeenAt: now
        )
        appAudioSessions[key] = session
        return session.id
    }

    private func pruneExpiredAppAudioSessions(now: Date) {
        appAudioSessions = appAudioSessions.filter { _, session in
            now.timeIntervalSince(session.lastSeenAt) <= appAudioSessionIdleTimeout
        }
    }

    private func candidate(
        id: String,
        platform: MeetingCandidate.Platform,
        appName: String,
        url: String?,
        title: String?,
        evidence: Set<MeetingCandidate.Evidence>,
        sourceBundleID: String?,
        sourcePID: pid_t?,
        suppressionID: String? = nil,
        now: Date
    ) -> MeetingCandidate {
        MeetingCandidate(
            id: id,
            platform: platform,
            appName: appName,
            url: url,
            evidence: evidence,
            startedAt: now,
            meetingTitle: title,
            sourceBundleID: sourceBundleID,
            sourcePID: sourcePID,
            suppressionID: suppressionID
        )
    }
}
