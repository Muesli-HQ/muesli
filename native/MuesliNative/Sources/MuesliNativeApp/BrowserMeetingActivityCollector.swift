import AppKit
import ApplicationServices
import Foundation

struct RunningAppSnapshot: Sendable {
    let bundleID: String
    let appName: String
    let processIdentifier: pid_t
    let isActive: Bool
}

final class BrowserMeetingActivityCollector {
    private let browserBundleIDs = Set(MeetingCandidateResolver.browserApps.keys)
    // Keep a recently seen meeting URL across tab/app focus dropouts so the
    // resolver does not churn from a room-specific Meet candidate to a generic
    // browser-audio candidate while the same call is still active.
    private let cachedMeetingTTL: TimeInterval = 120
    private var cachedMeetings: [String: CachedBrowserMeeting] = [:]

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
        let browsersToProbe = browserApps.filter { app in
            app.isActive || cachedMeetings[app.bundleID] != nil
        }

        for app in browsersToProbe {
            guard let normalized = await normalizedFocusedURL(
                for: app,
                shouldAttemptAppleScript: shouldAttemptAppleScript
            ) else {
                if app.isActive {
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

        let liveBundleIDs = Set(liveMeetings.map(\.bundleID))

        let cachedOnlyMeetings = cachedMeetings.values
            .filter { !liveBundleIDs.contains($0.context.bundleID) }
            .map { cached in
                context(cached.context, runningApps: browserApps)
            }

        return liveMeetings + cachedOnlyMeetings
    }

    private func normalizedFocusedURL(
        for app: RunningAppSnapshot,
        shouldAttemptAppleScript: (String) -> Bool
    ) async -> NormalizedMeetingURL? {
        if let normalized = normalizedAXDocumentURL(for: app) {
            return normalized
        }

        // Query the browser's active tab even after another app/overlay becomes
        // frontmost. Strict URL normalization plus resolver media checks keep
        // background meeting tabs from prompting by themselves.
        guard shouldAttemptAppleScript(app.bundleID) else { return nil }
        guard let url = await activeBrowserURLViaAppleScript(bundleID: app.bundleID) else {
            return nil
        }
        return MeetingURLNormalizer.normalize(url)
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

    private func normalizedAXDocumentURL(for app: RunningAppSnapshot) -> NormalizedMeetingURL? {
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

        return MeetingURLNormalizer.normalize(rawURL)
    }

    @MainActor
    private func activeBrowserURLViaAppleScript(bundleID: String) -> String? {
        let source: String
        switch bundleID {
        case "com.apple.Safari":
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of current tab of front window
            end tell
            """
        case "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac":
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        default:
            return nil
        }

        var errorInfo: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue,
              !output.isEmpty else {
            return nil
        }
        return output
    }
}

private struct CachedBrowserMeeting {
    let context: BrowserMeetingContext
    let observedAt: Date
}
