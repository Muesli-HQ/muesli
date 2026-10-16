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
    private let documentURLProbeProvider: ((RunningAppSnapshot) -> BrowserDocumentURLProbeResult)?
    private let activeTabURLProviderOverride: ((RunningAppSnapshot) -> String?)?
    private let activeTabProbeResultProvider: ((RunningAppSnapshot) -> BrowserActiveTabProbeResult)?
    private let activeTabFallbackEnabled: Bool
    private let allTabURLsProvider: ((RunningAppSnapshot) -> [String]?)?
    private var cachedMeetings: [String: CachedBrowserMeeting] = [:]
    private var activeTabFallbacksAwaitingFreshResult: Set<String> = []

    init(
        cachedMeetingTTL: TimeInterval = 30,
        focusedDocumentURLProvider: ((RunningAppSnapshot) -> String?)? = nil,
        documentURLProbeProvider: ((RunningAppSnapshot) -> BrowserDocumentURLProbeResult)? = nil,
        activeTabURLProvider: ((RunningAppSnapshot) -> String?)? = nil,
        activeTabProbeResultProvider: ((RunningAppSnapshot) -> BrowserActiveTabProbeResult)? = nil,
        activeTabFallbackEnabled: Bool = true,
        allTabURLsProvider: ((RunningAppSnapshot) -> [String]?)? = nil
    ) {
        self.allTabURLsProvider = allTabURLsProvider
        self.cachedMeetingTTL = cachedMeetingTTL
        self.focusedDocumentURLProvider = focusedDocumentURLProvider
        self.documentURLProbeProvider = documentURLProbeProvider
        self.activeTabURLProviderOverride = activeTabURLProvider
        self.activeTabProbeResultProvider = activeTabProbeResultProvider
        self.activeTabFallbackEnabled = activeTabFallbackEnabled
    }

    func collect(
        runningApps: [RunningAppSnapshot],
        refresh: Bool,
        now: Date = Date(),
        scanAllTabsBundleIDs: Set<String> = [],
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
                scansAllTabs: scanAllTabsBundleIDs.contains(app.bundleID),
                shouldAttemptActiveTabFallback: shouldAttemptActiveTabFallback
            )

            switch probeResult {
            case .meeting(let normalized, let isFocused):
                let context = BrowserMeetingContext(
                    bundleID: app.bundleID,
                    appName: app.appName,
                    pid: app.processIdentifier,
                    url: normalized.url,
                    normalizedID: normalized.id,
                    platform: normalized.platform,
                    isFocused: isFocused
                )
                cachedMeetings[app.bundleID] = CachedBrowserMeeting(context: context, observedAt: now)
                activeTabFallbacksAwaitingFreshResult.remove(app.bundleID)
                liveMeetings.append(context)
            case .noMeeting:
                cachedMeetings.removeValue(forKey: app.bundleID)
                activeTabFallbacksAwaitingFreshResult.remove(app.bundleID)
            case .inconclusive:
                activeTabFallbacksAwaitingFreshResult.insert(app.bundleID)
                if let cached = cachedMeetings[app.bundleID] {
                    liveMeetings.append(context(cached.context, runningApps: browserApps))
                }
            case .skipped:
                if activeTabFallbacksAwaitingFreshResult.contains(app.bundleID),
                   let cached = cachedMeetings[app.bundleID] {
                    liveMeetings.append(context(cached.context, runningApps: browserApps))
                }
            }
        }

        // Refresh passes return fresh probe results unless the active-tab
        // fallback is inconclusive. Follow-up throttled skips may reuse the
        // TTL-bound cache only until a fresh active-tab result resolves that
        // inconclusive state.
        return liveMeetings
    }

    private func probeFocusedMeetingURL(
        for app: RunningAppSnapshot,
        scansAllTabs: Bool,
        shouldAttemptActiveTabFallback: (String) -> Bool
    ) async -> BrowserMeetingURLProbeResult {
        var observedFocusedNonMeetingDocumentURL = false
        if let focusedDocumentURLProvider {
            if let rawURL = focusedDocumentURLProvider(app) {
                if let normalized = MeetingURLNormalizer.normalize(rawURL) {
                    return .meeting(normalized, isFocused: app.isActive)
                }
                observedFocusedNonMeetingDocumentURL = true
            }
        }

        let axStartedAt = Date()
        let documentURLProbe = documentURLProbeProvider?(app) ?? axDocumentURLProbe(for: app)
        let axMilliseconds = Int(Date().timeIntervalSince(axStartedAt) * 1_000)
        switch documentURLProbe {
        case .meeting(let normalized, let isFocused):
            return .meeting(normalized, isFocused: app.isActive && isFocused)
        case .nonMeetingDocument(let isFocused):
            if isFocused {
                observedFocusedNonMeetingDocumentURL = true
            }
        case .noDocumentURL:
            break
        }

        guard activeTabFallbackEnabled || activeTabURLProviderOverride != nil || activeTabProbeResultProvider != nil else {
            return observedFocusedNonMeetingDocumentURL ? .noMeeting : .skipped
        }
        guard shouldAttemptActiveTabFallback(app.bundleID) else {
            return observedFocusedNonMeetingDocumentURL ? .noMeeting : .skipped
        }
        let tabStartedAt = Date()
        let activeTabResult = await activeTabURL(for: app)
        let tabMilliseconds = Int(Date().timeIntervalSince(tabStartedAt) * 1_000)
        if axMilliseconds + tabMilliseconds > Self.slowProbeThresholdMilliseconds {
            // The result's case only: an unrelated tab's URL can carry tokens or private search text.
            fputs("[meeting-monitor] browser_probe_slow app=\(app.bundleID) ax_ms=\(axMilliseconds) tab_ms=\(tabMilliseconds) result=\(activeTabResult.logLabel)\n", stderr)
        }
        guard case .url(let url) = activeTabResult else {
            if case .timedOut = activeTabResult {
                // An ordinary focused page rules out a call only when background tabs are not
                // searched; otherwise the timeout skipped the scan that could have found it.
                return observedFocusedNonMeetingDocumentURL && !scansAllTabs ? .noMeeting : .inconclusive
            }
            return .noMeeting
        }
        guard let normalized = MeetingURLNormalizer.normalize(url) else {
            // The browser holds the mic or camera but the front tab is something else: the call
            // is in a background tab or another window.
            guard scansAllTabs else { return .noMeeting }
            switch await meetingURLInAnyTab(for: app) {
            case .found(let background):
                return .meeting(background, isFocused: false)
            case .noCall:
                return .noMeeting
            case .timedOut:
                // The front tab is already known to be ordinary, so that says nothing about
                // the background tabs the scan did not finish reading.
                return .inconclusive
            }
        }
        return .meeting(normalized, isFocused: app.isActive)
    }

    private func meetingURLInAnyTab(for app: RunningAppSnapshot) async -> BackgroundTabScanResult {
        let scanned: [String]?
        if let allTabURLsProvider {
            scanned = allTabURLsProvider(app)
        } else {
            scanned = await Self.allTabURLsViaScriptingBridge(for: app, deadline: Self.allTabsDeadline)
        }
        guard let urls = scanned else { return .timedOut }
        guard let room = urls.lazy.compactMap({ MeetingURLNormalizer.normalizeRoom($0) }).first else { return .noCall }
        return .found(room)
    }

    private func pruneCache(runningBrowserIDs: Set<String>, now: Date) {
        cachedMeetings = cachedMeetings.filter { bundleID, cached in
            runningBrowserIDs.contains(bundleID) && now.timeIntervalSince(cached.observedAt) <= cachedMeetingTTL
        }
        activeTabFallbacksAwaitingFreshResult.formIntersection(cachedMeetings.keys)
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
            isFocused: cached.isFocused && (app?.isActive ?? false)
        )
    }

    private func axDocumentURLProbe(for app: RunningAppSnapshot) -> BrowserDocumentURLProbeResult {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, Self.axMessagingTimeout)
        var observedFocusedNonMeetingDocumentURL = false
        var observedBackgroundNonMeetingDocumentURL = false
        var probedWindowIDs = Set<CFHashCode>()

        if let window = axWindowAttribute(kAXFocusedWindowAttribute, from: axApp) {
            probedWindowIDs.insert(CFHash(window))
            switch documentURLProbe(from: window, isFocused: true) {
            case .meeting(let normalized, let isFocused):
                return .meeting(normalized, isFocused: isFocused)
            case .nonMeetingDocument:
                observedFocusedNonMeetingDocumentURL = true
            case .noDocumentURL:
                break
            }
        }
        if let window = axWindowAttribute(kAXMainWindowAttribute, from: axApp) {
            if probedWindowIDs.insert(CFHash(window)).inserted {
                switch documentURLProbe(from: window, isFocused: false) {
                case .meeting(let normalized, let isFocused):
                    return .meeting(normalized, isFocused: isFocused)
                case .nonMeetingDocument:
                    observedBackgroundNonMeetingDocumentURL = true
                case .noDocumentURL:
                    break
                }
            }
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            if observedFocusedNonMeetingDocumentURL {
                return .nonMeetingDocument(isFocused: true)
            }
            return observedBackgroundNonMeetingDocumentURL ? .nonMeetingDocument(isFocused: false) : .noDocumentURL
        }

        for window in windows {
            guard probedWindowIDs.insert(CFHash(window)).inserted else {
                continue
            }
            switch documentURLProbe(from: window, isFocused: false) {
            case .meeting(let normalized, let isFocused):
                return .meeting(normalized, isFocused: isFocused)
            case .nonMeetingDocument:
                observedBackgroundNonMeetingDocumentURL = true
            case .noDocumentURL:
                continue
            }
        }

        if observedFocusedNonMeetingDocumentURL {
            return .nonMeetingDocument(isFocused: true)
        }
        return observedBackgroundNonMeetingDocumentURL ? .nonMeetingDocument(isFocused: false) : .noDocumentURL
    }

    private func axWindowAttribute(_ attribute: String, from app: AXUIElement) -> AXUIElement? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &windowRef) == .success,
              let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }
        // CFGetTypeID above verifies this bridge before the force cast.
        return (window as! AXUIElement)
    }

    private func documentURLProbe(from window: AXUIElement, isFocused: Bool) -> BrowserDocumentURLProbeResult {
        var documentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentRef) == .success,
              let rawURL = documentRef as? String else {
            return .noDocumentURL
        }

        if let normalized = MeetingURLNormalizer.normalize(rawURL) {
            return .meeting(normalized, isFocused: isFocused)
        }
        return .nonMeetingDocument(isFocused: isFocused)
    }

    private func activeTabURL(for app: RunningAppSnapshot) async -> BrowserActiveTabProbeResult {
        if let activeTabProbeResultProvider {
            return activeTabProbeResultProvider(app)
        }
        if let activeTabURLProviderOverride {
            return activeTabURLProviderOverride(app).map(BrowserActiveTabProbeResult.url) ?? .noURL
        }
        return await Self.activeTabURLViaScriptingBridge(for: app, deadline: Self.activeTabFallbackDeadline)
    }

    private static let slowProbeThresholdMilliseconds = 1_000
    /// Each Accessibility call to a browser may block this long. An unresponsive browser (Arc's
    /// tree is large) otherwise holds every evaluation for seconds, and a prompt or a call-end
    /// waits on the evaluation.
    private static let axMessagingTimeout: Float = 0.4
    private static let activeTabFallbackDeadline: TimeInterval = 1.8
    private static let allTabsDeadline: TimeInterval = 3
    private static let appleEventTicksPerSecond = 60
    private static let allTabsTimeoutTicks = Int((allTabsDeadline * Double(appleEventTicksPerSecond)).rounded(.up)) + 12
    private static let scriptingBridgeTimeoutSlackTicks = 12
    private static let scriptingBridgeTimeoutTicks = Int(
        (activeTabFallbackDeadline * Double(appleEventTicksPerSecond)).rounded(.up)
    ) + scriptingBridgeTimeoutSlackTicks

    private static func activeTabURLViaScriptingBridge(
        for app: RunningAppSnapshot,
        deadline: TimeInterval
    ) async -> BrowserActiveTabProbeResult {
        await withCheckedContinuation { continuation in
            let completion = BrowserActiveTabProbeCompletion(continuation)
            DispatchQueue.global(qos: .utility).async {
                let url = Self.activeTabURLViaScriptingBridgeSync(for: app)
                completion.resume(url.map(BrowserActiveTabProbeResult.url) ?? .noURL)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
                completion.resume(.timedOut)
            }
        }
    }

    /// Every tab URL in every window. The browser's "front window" is not always the one the user
    /// is looking at, and a call can sit in a background tab.
    /// `nil` means the deadline passed before the browser answered.
    private static func allTabURLsViaScriptingBridge(for app: RunningAppSnapshot, deadline: TimeInterval) async -> [String]? {
        await withCheckedContinuation { continuation in
            let completion = BrowserTabListCompletion(continuation)
            DispatchQueue.global(qos: .utility).async {
                completion.resume(Self.allTabURLsViaScriptingBridgeSync(for: app))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
                completion.resume(nil)
            }
        }
    }

    private static func allTabURLsViaScriptingBridgeSync(for app: RunningAppSnapshot) -> [String] {
        guard let browser = scriptingBridgeBrowser(for: app, timeoutTicks: allTabsTimeoutTicks),
              let windows = browser.value(forKey: "windows") as? SBElementArray else {
            return []
        }
        var urls: [String] = []
        for case let window as NSObject in windows {
            // One Apple Event per window returns every tab's URL.
            guard let tabs = window.value(forKey: "tabs") as? SBElementArray,
                  let tabURLs = tabs.value(forKey: "URL") as? [String] else { continue }
            urls.append(contentsOf: tabURLs)
        }
        return urls
    }

    private static func activeTabURLViaScriptingBridgeSync(for app: RunningAppSnapshot) -> String? {
        // SBApplication.timeout is in Apple Event ticks (1/60 s). Keep the
        // ScriptingBridge timeout slightly above the 1.8 s outer deadline so
        // the async fallback reports .timedOut before a stalled Apple Event
        // can return nil and clear cache state.
        guard let browser = scriptingBridgeBrowser(for: app, timeoutTicks: Self.scriptingBridgeTimeoutTicks) else {
            return nil
        }

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

    /// The running browser as a scripting target, or nil when it cannot be asked yet.
    private static func scriptingBridgeBrowser(for app: RunningAppSnapshot, timeoutTicks: Int) -> SBApplication? {
        // Target the existing process by PID. Bundle-id targets can relaunch a
        // browser after the user quits it, which passive detection must avoid.
        guard browserSupportsScriptingBridgeActiveTab(app.bundleID),
              let browser = SBApplication(processIdentifier: app.processIdentifier),
              browser.isRunning else {
            return nil
        }

        // Without consent every event fails, and an event that waits on the dialog times out
        // before anyone can answer it. Ask once with no deadline and skip the lookup until then.
        switch BrowserAutomationPermission.state(bundleID: app.bundleID) {
        case .granted, .unavailable:
            break
        case .undetermined:
            BrowserAutomationPermission.requestOnce(bundleID: app.bundleID)
            return nil
        case .denied:
            return nil
        }

        browser.delegate = BrowserScriptingBridgeErrorDelegate()
        browser.timeout = timeoutTicks
        return browser
    }

    // Keep aligned with MeetingCandidateResolver.browserApps in
    // native/MuesliNative/Sources/MuesliNativeApp/MeetingCandidateResolver.swift.
    // This remains an explicit allowlist because these bundle IDs are known to
    // expose window and active-tab URL fields through ScriptingBridge.
    static let scriptingBridgeActiveTabBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
    ]

    private static func browserSupportsScriptingBridgeActiveTab(_ bundleID: String) -> Bool {
        scriptingBridgeActiveTabBrowserBundleIDs.contains(bundleID)
    }
}

private enum BrowserMeetingURLProbeResult {
    case meeting(NormalizedMeetingURL, isFocused: Bool)
    case noMeeting
    case inconclusive
    case skipped
}

enum BrowserDocumentURLProbeResult {
    case meeting(NormalizedMeetingURL, isFocused: Bool)
    case nonMeetingDocument(isFocused: Bool)
    case noDocumentURL
}

enum BrowserActiveTabProbeResult {
    case url(String)
    case noURL
    case timedOut

    /// The case name without the URL, safe to write to a log.
    var logLabel: String {
        switch self {
        case .url: "url"
        case .noURL: "noURL"
        case .timedOut: "timedOut"
        }
    }
}

/// A slow scan is not proof that no call exists, so a timeout stays apart from an empty result.
enum BackgroundTabScanResult: Equatable {
    case found(NormalizedMeetingURL)
    case noCall
    case timedOut
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

private final class BrowserTabListCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String]?, Never>?

    init(_ continuation: CheckedContinuation<[String]?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: [String]?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }
}

private final class BrowserActiveTabProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BrowserActiveTabProbeResult, Never>?

    init(_ continuation: CheckedContinuation<BrowserActiveTabProbeResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: BrowserActiveTabProbeResult) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }
}
