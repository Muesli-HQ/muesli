import Foundation

actor MeetingMediaSessionTracker {
    private struct Session {
        let id: String
        let key: String
        let startedAt: Date
        var lastActiveAt: Date
        var platform: MeetingCandidate.Platform
        var appName: String
        var url: String?
        var meetingTitle: String?
        var evidence: Set<MeetingCandidate.Evidence>
    }

    private let quietWindow: TimeInterval
    private var sessionsByKey: [String: Session] = [:]

    init(quietWindow: TimeInterval = 30) {
        self.quietWindow = quietWindow
    }

    func stabilize(
        candidate: MeetingCandidate?,
        snapshot: MeetingSignalSnapshot
    ) -> MeetingCandidate? {
        pruneExpiredSessions(now: snapshot.now)
        guard let candidate else { return nil }
        guard let key = sessionKey(for: candidate),
              isMediaBacked(candidate, snapshot: snapshot) else {
            return candidate
        }

        let session = updateSession(for: key, with: candidate, now: snapshot.now)
        return MeetingCandidate(
            id: session.id,
            platform: session.platform,
            appName: session.appName,
            url: session.url,
            evidence: session.evidence,
            startedAt: session.startedAt,
            meetingTitle: session.meetingTitle,
            sourceBundleID: candidate.sourceBundleID,
            sourcePID: candidate.sourcePID,
            suppressionID: session.id
        )
    }

    func reset() {
        sessionsByKey = [:]
    }

    private func updateSession(
        for key: String,
        with candidate: MeetingCandidate,
        now: Date
    ) -> Session {
        if var session = sessionsByKey[key],
           now.timeIntervalSince(session.lastActiveAt) <= quietWindow {
            session.lastActiveAt = now
            session.platform = betterPlatform(current: candidate.platform, previous: session.platform)
            session.appName = candidate.appName
            session.url = candidate.url ?? session.url
            session.meetingTitle = candidate.meetingTitle ?? session.meetingTitle
            session.evidence.formUnion(candidate.evidence)
            sessionsByKey[key] = session
            return session
        }

        let session = Session(
            id: "meeting-session:\(key):\(Int(now.timeIntervalSince1970))",
            key: key,
            startedAt: now,
            lastActiveAt: now,
            platform: candidate.platform,
            appName: candidate.appName,
            url: candidate.url,
            meetingTitle: candidate.meetingTitle,
            evidence: candidate.evidence
        )
        sessionsByKey[key] = session
        return session
    }

    private func sessionKey(for candidate: MeetingCandidate) -> String? {
        if let sourceBundleID = candidate.sourceBundleID {
            if MeetingCandidateResolver.browserApps[sourceBundleID] != nil {
                return "browser:\(sourceBundleID)"
            }
            return "app:\(sourceBundleID)"
        }

        if candidate.id.hasPrefix("browser:") || candidate.id.hasPrefix("app:") {
            return candidate.id
        }

        return nil
    }

    private func isMediaBacked(
        _ candidate: MeetingCandidate,
        snapshot: MeetingSignalSnapshot
    ) -> Bool {
        if candidate.evidence.contains(.audioInputProcess)
            || candidate.evidence.contains(.micActive)
            || candidate.evidence.contains(.cameraActive) {
            return true
        }

        guard let sourceBundleID = candidate.sourceBundleID else { return false }
        return snapshot.audioInputProcesses.contains { process in
            process.bundleID == sourceBundleID || process.bundleID.lowercased().hasPrefix("\(sourceBundleID.lowercased()).")
        }
    }

    private func betterPlatform(
        current: MeetingCandidate.Platform,
        previous: MeetingCandidate.Platform
    ) -> MeetingCandidate.Platform {
        current == .unknown ? previous : current
    }

    private func pruneExpiredSessions(now: Date) {
        sessionsByKey = sessionsByKey.filter { _, session in
            now.timeIntervalSince(session.lastActiveAt) <= quietWindow
        }
    }
}
