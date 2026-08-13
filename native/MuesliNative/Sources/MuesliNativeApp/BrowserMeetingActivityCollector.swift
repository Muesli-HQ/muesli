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
    private var cachedMeetings: [String: CachedBrowserMeeting] = [:]
    private var activeTabFallbacksAwaitingFreshResult: Set<String> = []

    init(
        cachedMeetingTTL: TimeInterval = 30,
        focusedDocumentURLProvider: ((RunningAppSnapshot) -> String?)? = nil,
        documentURLProbeProvider: ((RunningAppSnapshot) -> BrowserDocumentURLProbeResult)? = nil,
        activeTabURLProvider: ((RunningAppSnapshot) -> String?)? = nil,
        activeTabProbeResultProvider: ((RunningAppSnapshot) -> BrowserActiveTabProbeResult)? = nil,
        activeTabFallbackEnabled: Bool = true
    ) {
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

        let documentURLProbe = documentURLProbeProvider?(app) ?? axDocumentURLProbe(for: app)
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
        let activeTabResult = await activeTabURL(for: app)
        guard case .url(let url) = activeTabResult else {
            if case .timedOut = activeTabResult {
                return observedFocusedNonMeetingDocumentURL ? .noMeeting : .inconclusive
            }
            return .noMeeting
        }
        guard let normalized = MeetingURLNormalizer.normalize(url) else {
            return .noMeeting
        }
        return .meeting(normalized, isFocused: app.isActive)
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

    private static let activeTabFallbackDeadline: TimeInterval = 1.8
    private static let appleEventTicksPerSecond = 60
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

    private static func activeTabURLViaScriptingBridgeSync(for app: RunningAppSnapshot) -> String? {
        // Target the existing process by PID. Bundle-id targets can relaunch a
        // browser after the user quits it, which passive detection must avoid.
        guard browserSupportsScriptingBridgeActiveTab(app.bundleID),
              let browser = SBApplication(processIdentifier: app.processIdentifier),
              browser.isRunning else {
            return nil
        }

        let errorDelegate = BrowserScriptingBridgeErrorDelegate()
        browser.delegate = errorDelegate
        // SBApplication.timeout is in Apple Event ticks (1/60 s). Keep the
        // ScriptingBridge timeout slightly above the 1.8 s outer deadline so
        // the async fallback reports .timedOut before a stalled Apple Event
        // can return nil and clear cache state.
        browser.timeout = Self.scriptingBridgeTimeoutTicks

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
