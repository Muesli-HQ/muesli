import AppKit
import ApplicationServices
import Foundation
import ScriptingBridge

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
    private let activeTabURLProviderOverride: ((RunningAppSnapshot) -> String?)?
    private let activeTabFallbackEnabled: Bool
    private var cachedMeetings: [String: CachedBrowserMeeting] = [:]

    init(
        cachedMeetingTTL: TimeInterval = 30,
        focusedDocumentURLProvider: ((RunningAppSnapshot) -> String?)? = nil,
        activeTabURLProvider: ((RunningAppSnapshot) -> String?)? = nil,
        activeTabFallbackEnabled: Bool = true
    ) {
        self.cachedMeetingTTL = cachedMeetingTTL
        self.focusedDocumentURLProvider = focusedDocumentURLProvider
        self.activeTabURLProviderOverride = activeTabURLProvider
        self.activeTabFallbackEnabled = activeTabFallbackEnabled
    }

    func collect(
        runningApps: [RunningAppSnapshot],
        refresh: Bool,
        now: Date = Date(),
        shouldAttemptActiveTabFallback: (String) -> Bool = { _ in true }
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
                shouldAttemptActiveTabFallback: shouldAttemptActiveTabFallback
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
        shouldAttemptActiveTabFallback: (String) -> Bool
    ) async -> BrowserMeetingURLProbeResult {
        if let focusedDocumentURLProvider {
            guard let rawURL = focusedDocumentURLProvider(app) else {
                return .noMeeting
            }
            if let normalized = MeetingURLNormalizer.normalize(rawURL) {
                return .meeting(normalized)
            }
        }

        if let normalized = axMeetingURL(for: app) {
            return .meeting(normalized)
        }

        guard activeTabFallbackEnabled || activeTabURLProviderOverride != nil else {
            return .noMeeting
        }
        guard shouldAttemptActiveTabFallback(app.bundleID) else {
            return .skipped
        }
        guard let url = await activeTabURL(for: app) else {
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

    private func axMeetingURL(for app: RunningAppSnapshot) -> NormalizedMeetingURL? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = axWindowAttribute(attribute, from: axApp),
               let normalized = normalizedMeetingURL(from: window) {
                return normalized
            }
        }

        return nil
    }

    private func axWindowAttribute(_ attribute: String, from app: AXUIElement) -> AXUIElement? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &windowRef) == .success,
              let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }
        return (window as! AXUIElement)
    }

    private func normalizedMeetingURL(from window: AXUIElement) -> NormalizedMeetingURL? {
        var documentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentRef) == .success,
              let rawURL = documentRef as? String else {
            return nil
        }

        return MeetingURLNormalizer.normalize(rawURL)
    }

    private func activeTabURL(for app: RunningAppSnapshot) async -> String? {
        if let activeTabURLProviderOverride {
            return activeTabURLProviderOverride(app)
        }
        guard activeTabFallbackEnabled else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            Self.activeTabURLViaScriptingBridge(for: app)
        }.value
    }

    private static func activeTabURLViaScriptingBridge(for app: RunningAppSnapshot) -> String? {
        // Target the existing process by PID. Bundle-id targets can relaunch a
        // browser after the user quits it, which passive detection must avoid.
        guard browserSupportsScriptingBridgeActiveTab(app.bundleID),
              let browser = SBApplication(processIdentifier: app.processIdentifier),
              browser.isRunning else {
            return nil
        }

        let errorDelegate = BrowserScriptingBridgeErrorDelegate()
        browser.delegate = errorDelegate
        browser.timeout = 2

        guard let windows = browser.value(forKey: "windows") as? SBElementArray,
              let frontWindow = windows.firstObject as? NSObject else {
            return nil
        }

        let tabKey = app.bundleID == "com.apple.Safari" ? "currentTab" : "activeTab"
        guard let activeTab = frontWindow.value(forKey: tabKey) as? NSObject else {
            return nil
        }

        return activeTab.value(forKey: "URL") as? String
    }

    private static func browserSupportsScriptingBridgeActiveTab(_ bundleID: String) -> Bool {
        switch bundleID {
        case "com.apple.Safari",
             "com.google.Chrome",
             "com.brave.Browser",
             "company.thebrowser.Browser",
             "com.microsoft.edgemac":
            return true
        default:
            return false
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

private final class BrowserScriptingBridgeErrorDelegate: NSObject, SBApplicationDelegate {
    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        nil
    }
}
