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
        guard let key = sessionKey(for: candidate, now: snapshot.now),
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

    private func sessionKey(for candidate: MeetingCandidate, now: Date) -> String? {
        if let sourceBundleID = candidate.sourceBundleID {
            if MeetingCandidateResolver.browserApps[sourceBundleID] != nil {
                if let roomIdentity = roomIdentity(for: candidate) {
                    return "browser:\(sourceBundleID):room:\(roomIdentity)"
                }

                return mostRecentBrowserSessionKey(for: sourceBundleID, now: now)
                    ?? "browser:\(sourceBundleID):media"
            }
            return "app:\(sourceBundleID)"
        }

        if candidate.id.hasPrefix("browser:") || candidate.id.hasPrefix("app:") {
            return candidate.id
        }

        return nil
    }

    private func roomIdentity(for candidate: MeetingCandidate) -> String? {
        guard candidate.evidence.contains(.browserURL) else { return nil }
        if let url = candidate.url, !url.isEmpty { return url }
        if !candidate.id.hasPrefix("browser:"), !candidate.id.hasPrefix("app:") {
            return candidate.id
        }
        return nil
    }

    private func mostRecentBrowserSessionKey(for bundleID: String, now: Date) -> String? {
        let prefix = "browser:\(bundleID):"
        return sessionsByKey.values
            .filter { session in
                session.key.hasPrefix(prefix)
                    && now.timeIntervalSince(session.lastActiveAt) <= quietWindow
            }
            .sorted { lhs, rhs in lhs.lastActiveAt > rhs.lastActiveAt }
            .first?
            .key
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
