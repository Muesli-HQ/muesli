import AppKit
import ApplicationServices
import Foundation

struct RunningAppSnapshot: Sendable {
    let bundleID: String
    let appName: String
    let processIdentifier: pid_t
    let isActive: Bool
}

// Not thread-safe; MeetingSignalCollector owns this collector from a single actor context.
final class BrowserMeetingActivityCollector {
    private let browserBundleIDs = Set(MeetingCandidateResolver.browserApps.keys)
    private let cachedMeetingTTL: TimeInterval
    private let focusedDocumentURLProvider: ((RunningAppSnapshot) -> String?)?
    private let activeBrowserURLProvider: ((String) -> String?)?
    private var cachedMeetings: [String: CachedBrowserMeeting] = [:]

    init(
        cachedMeetingTTL: TimeInterval = 30,
        focusedDocumentURLProvider: ((RunningAppSnapshot) -> String?)? = nil,
        activeBrowserURLProvider: ((String) -> String?)? = nil
    ) {
        self.cachedMeetingTTL = cachedMeetingTTL
        self.focusedDocumentURLProvider = focusedDocumentURLProvider
        self.activeBrowserURLProvider = activeBrowserURLProvider
    }

    func collect(
        runningApps: [RunningAppSnapshot],
        refresh: Bool,
        now: Date = Date(),
        shouldAttemptAppleScript: (String) -> Bool = { _ in true }
    ) async -> [BrowserMeetingContext] {
        let browserApps = runningApps.filter { browserBundleIDs.contains($0.bundleID) }
        let runningBrowserIDs = Set(browserApps.map(\.bundleID))

        pruneCache(runningBrowserIDs: runningBrowserIDs, now: now)
        guard refresh else {
            return cachedContexts(runningApps: browserApps)
        }

        var liveMeetings: [BrowserMeetingContext] = []
        for app in browserApps {
            let probeResult = await probeFocusedMeetingURL(
                for: app,
                shouldAttemptAppleScript: shouldAttemptAppleScript
            )

            guard case .meeting(let normalized) = probeResult else {
                if case .noMeeting = probeResult {
                    cachedMeetings.removeValue(forKey: app.bundleID)
                }
                continue
            }

            let context = BrowserMeetingContext(
                bundleID: app.bundleID,
                appName: app.appName,
                pid: app.processIdentifier,
                url: normalized.url,
                normalizedID: normalized.id,
                platform: normalized.platform,
                isFocused: app.isActive
            )
            cachedMeetings[app.bundleID] = CachedBrowserMeeting(context: context, observedAt: now)
            liveMeetings.append(context)
        }

        // Refresh passes intentionally return only fresh probe results. Skipped
        // probes preserve cache entries for later non-refresh passes.
        return liveMeetings
    }

    private func probeFocusedMeetingURL(
        for app: RunningAppSnapshot,
        shouldAttemptAppleScript: (String) -> Bool
    ) async -> BrowserMeetingURLProbeResult {
        if let focusedDocumentURLProvider {
            guard let rawURL = focusedDocumentURLProvider(app) else {
                return .noMeeting
            }
            return MeetingURLNormalizer.normalize(rawURL).map(BrowserMeetingURLProbeResult.meeting) ?? .noMeeting
        }

        if let rawURL = axDocumentURL(for: app) {
            return MeetingURLNormalizer.normalize(rawURL).map(BrowserMeetingURLProbeResult.meeting) ?? .noMeeting
        }

        // Query the browser's active tab even after another app/overlay becomes
        // frontmost. Strict URL normalization plus resolver media checks keep
        // background meeting tabs from prompting by themselves.
        guard shouldAttemptAppleScript(app.bundleID) else {
            return .skipped
        }
        guard let url = await activeBrowserURLViaAppleScript(bundleID: app.bundleID) else {
            return .noMeeting
        }
        return MeetingURLNormalizer.normalize(url).map(BrowserMeetingURLProbeResult.meeting) ?? .noMeeting
    }

    private func pruneCache(runningBrowserIDs: Set<String>, now: Date) {
        cachedMeetings = cachedMeetings.filter { bundleID, cached in
            runningBrowserIDs.contains(bundleID) && now.timeIntervalSince(cached.observedAt) <= cachedMeetingTTL
        }
    }

    private func cachedContexts(runningApps: [RunningAppSnapshot]) -> [BrowserMeetingContext] {
        cachedMeetings.values.map { cached in
            context(cached.context, runningApps: runningApps)
        }
    }

    private func context(
        _ cached: BrowserMeetingContext,
        runningApps: [RunningAppSnapshot]
    ) -> BrowserMeetingContext {
        let app = runningApps.first { $0.bundleID == cached.bundleID }
        return BrowserMeetingContext(
            bundleID: cached.bundleID,
            appName: app?.appName ?? cached.appName,
            pid: app?.processIdentifier ?? cached.pid,
            url: cached.url,
            normalizedID: cached.normalizedID,
            platform: cached.platform,
            isFocused: app?.isActive ?? false
        )
    }

    private func axDocumentURL(for app: RunningAppSnapshot) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }

        let axWindow = (window as! AXUIElement)
        var documentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &documentRef) == .success,
              let rawURL = documentRef as? String else {
            return nil
        }

        return rawURL
    }

    private func activeBrowserURLViaAppleScript(bundleID: String) async -> String? {
        if let activeBrowserURLProvider {
            return activeBrowserURLProvider(bundleID)
        }

        guard let source = activeBrowserURLAppleScriptSource(bundleID: bundleID) else {
            return nil
        }

        return await Task.detached(priority: .utility) {
            var errorInfo: NSDictionary?
            guard let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue,
                  !output.isEmpty else {
                return nil
            }
            return output
        }.value
    }

    private func activeBrowserURLAppleScriptSource(bundleID: String) -> String? {
        let escapedBundleID = bundleID.replacingOccurrences(of: "\"", with: "\\\"")
        switch bundleID {
        case "com.apple.Safari":
            return """
            tell application id "\(escapedBundleID)"
                if (count of windows) is 0 then return ""
                return URL of current tab of front window
            end tell
            """
        case "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac":
            return """
            tell application id "\(escapedBundleID)"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        default:
            return nil
        }
    }
}

private enum BrowserMeetingURLProbeResult {
    case meeting(NormalizedMeetingURL)
    case noMeeting
    case skipped
}

private struct CachedBrowserMeeting {
    let context: BrowserMeetingContext
    let observedAt: Date
}
