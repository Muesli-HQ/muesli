import Testing
import Foundation
@testable import MuesliNativeApp

// MARK: - URL matcher tests

@Suite("BrowserMeetingURLMatcher")
struct BrowserMeetingURLMatcherTests {

    @Test("matches Google Meet URLs with a path")
    func matchesGoogleMeet() {
        let match = BrowserMeetingURLMatcher.match("https://meet.google.com/abc-defg-hij")
        #expect(match?.platformName == "Google Meet")
        #expect(match?.normalizedURL == "meet.google.com/abc-defg-hij")
    }

    @Test("does not match bare meet.google.com homepage")
    func doesNotMatchGoogleMeetHomepage() {
        #expect(BrowserMeetingURLMatcher.match("https://meet.google.com/") == nil)
        #expect(BrowserMeetingURLMatcher.match("https://meet.google.com") == nil)
    }

    @Test("matches Zoom join URLs only when path contains /wc/")
    func matchesZoomWebClient() {
        let match = BrowserMeetingURLMatcher.match("https://us05web.zoom.us/wc/join/123456789")
        #expect(match?.platformName == "Zoom")
        #expect(match?.normalizedURL.contains("/wc/") == true)
    }

    @Test("does not match arbitrary zoom.us paths")
    func doesNotMatchZoomHomepage() {
        #expect(BrowserMeetingURLMatcher.match("https://zoom.us/") == nil)
        #expect(BrowserMeetingURLMatcher.match("https://zoom.us/pricing") == nil)
    }

    @Test("matches Teams classic URLs")
    func matchesTeamsClassic() {
        let match = BrowserMeetingURLMatcher.match("https://teams.microsoft.com/l/meetup-join/abc")
        #expect(match?.platformName == "Teams")
    }

    @Test("matches Teams personal account URLs")
    func matchesTeamsLive() {
        let match = BrowserMeetingURLMatcher.match("https://teams.live.com/_#/meetup-join/xyz")
        #expect(match?.platformName == "Teams")
    }

    @Test("matches Teams cloud subdomain URLs")
    func matchesTeamsCloud() {
        let match = BrowserMeetingURLMatcher.match("https://teams.cloud.microsoft/l/meetup-join/abc")
        #expect(match?.platformName == "Teams")
    }

    @Test("matches Webex meeting URLs")
    func matchesWebex() {
        let match = BrowserMeetingURLMatcher.match("https://app.webex.com/meet/somebody")
        #expect(match?.platformName == "Webex")
    }

    @Test("returns nil for non-meeting URLs")
    func ignoresOtherURLs() {
        #expect(BrowserMeetingURLMatcher.match("https://example.com/foo") == nil)
        #expect(BrowserMeetingURLMatcher.match("about:blank") == nil)
        #expect(BrowserMeetingURLMatcher.match("") == nil)
    }
}

// MARK: - Poller test harness

@MainActor
private final class BrowserURLPollerTestHarness {
    var config: BrowserURLPollingConfig
    var micOwners: Set<String> = []
    var urlByBundle: [String: String] = [:]
    var permissionByBundle: [String: AutomationPermissionStatus] = [:]
    var emittedSignals: [AutoCaptureSignal] = []
    var sleepInvocations: [Double] = []
    var fetchInvocations: [String] = []
    var permissionInvocations: [String] = []
    private var pendingResumes: [CheckedContinuation<Void, Never>] = []

    private(set) var poller: BrowserURLPoller!

    init(config: BrowserURLPollingConfig) {
        self.config = config
        self.poller = BrowserURLPoller(
            config: { [weak self] in self?.config ?? .disabled },
            signalHandler: { [weak self] signal in self?.emittedSignals.append(signal) },
            micOwnershipProbe: { [weak self] in self?.micOwners ?? [] },
            urlFetcher: { [weak self] bundleID in
                self?.fetchInvocations.append(bundleID)
                return self?.urlByBundle[bundleID]
            },
            permissionProbe: { [weak self] bundleID in
                self?.permissionInvocations.append(bundleID)
                return self?.permissionByBundle[bundleID] ?? .granted
            },
            watchdogInterval: 1.0,
            pollInterval: 0.5,
            sleep: { [weak self] seconds in
                self?.sleepInvocations.append(seconds)
                await withCheckedContinuation { continuation in
                    if let self {
                        self.pendingResumes.append(continuation)
                    } else {
                        continuation.resume()
                    }
                }
            }
        )
    }

    /// Resume the next sleep that's currently waiting. Useful for driving the
    /// watchdog/polling loop forward in deterministic step-by-step fashion.
    func releaseNextSleep() {
        guard !pendingResumes.isEmpty else { return }
        let continuation = pendingResumes.removeFirst()
        continuation.resume()
    }

    /// Resume *all* sleeps currently waiting. Use when you want to flush the
    /// pipeline at the end of a test so dangling tasks don't leak.
    func releaseAllSleeps() {
        let continuations = pendingResumes
        pendingResumes.removeAll()
        continuations.forEach { $0.resume() }
    }

    /// Drain pending sleeps and stop the poller. Call at the end of each test
    /// so the watchdog/polling tasks terminate cleanly before the harness
    /// goes out of scope.
    func tearDown() {
        poller.stop()
        releaseAllSleeps()
    }
}

// MARK: - Poller state-machine tests

@Suite("BrowserURLPoller")
@MainActor
struct BrowserURLPollerTests {

    @Test("starts in watching state when started")
    func startsWatching() {
        let harness = BrowserURLPollerTestHarness(config: .disabled)
        harness.poller.start()
        #expect(harness.poller.state == .watching)
    }

    @Test("idle watchdog tick does not invoke URL fetcher when no browser is enabled")
    func noFetchWhenDisabled() async {
        let harness = BrowserURLPollerTestHarness(config: .disabled)
        harness.poller.start()
        harness.micOwners = ["com.google.Chrome"]
        // Drive one tick — first sleep yields after tickWatchdog runs once
        await Task.yield()
        await Task.yield()
        #expect(harness.fetchInvocations.isEmpty)
        #expect(harness.permissionInvocations.isEmpty)
        harness.tearDown()
    }

    @Test("watchdog ignores mic owners that aren't enabled in config")
    func watchdogIgnoresDisabledBrowsers() async {
        // Only Chrome enabled in config, but Edge owns the mic.
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(chrome: true))
        harness.micOwners = [BrowserURLPollingConfig.edgeBundleID]
        harness.poller.start()
        await Task.yield()
        await Task.yield()
        #expect(harness.fetchInvocations.isEmpty)
        harness.tearDown()
    }

    @Test("watchdog starts polling when an enabled browser owns the mic")
    func watchdogStartsPolling() async {
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(chrome: true))
        harness.urlByBundle[BrowserURLPollingConfig.chromeBundleID] = "https://meet.google.com/abc-defg-hij"
        harness.micOwners = [BrowserURLPollingConfig.chromeBundleID]
        harness.poller.start()
        // Yield enough for the watchdog tick to fire and start polling.
        for _ in 0..<6 { await Task.yield() }
        if case .polling(let bundleID) = harness.poller.state {
            #expect(bundleID == BrowserURLPollingConfig.chromeBundleID)
        } else {
            Issue.record("expected polling state, got \(harness.poller.state)")
        }
        #expect(harness.fetchInvocations.contains(BrowserURLPollingConfig.chromeBundleID))
        #expect(harness.emittedSignals.count == 1)
        #expect(harness.emittedSignals.first?.bundleID == BrowserURLPollingConfig.chromeBundleID)
        harness.tearDown()
    }

    @Test("does not re-emit the same URL on subsequent polls")
    func suppressesDuplicateEmission() async {
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(chrome: true))
        harness.urlByBundle[BrowserURLPollingConfig.chromeBundleID] = "https://meet.google.com/abc-defg-hij"
        harness.micOwners = [BrowserURLPollingConfig.chromeBundleID]
        harness.poller.start()
        for _ in 0..<8 { await Task.yield() }
        let firstCount = harness.emittedSignals.count
        // Release one polling sleep so pollOnce runs again with the same URL.
        harness.releaseNextSleep()
        for _ in 0..<8 { await Task.yield() }
        #expect(harness.emittedSignals.count == firstCount)
        harness.tearDown()
    }

    @Test("polling stops when mic released")
    func pollingStopsWhenMicReleased() async {
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(chrome: true))
        harness.urlByBundle[BrowserURLPollingConfig.chromeBundleID] = "https://meet.google.com/abc-defg-hij"
        harness.micOwners = [BrowserURLPollingConfig.chromeBundleID]
        harness.poller.start()
        for _ in 0..<6 { await Task.yield() }
        // Confirm we entered polling
        if case .polling = harness.poller.state {} else {
            Issue.record("expected polling state before release")
        }

        // Mic released, watchdog ticks next iteration.
        harness.micOwners = []
        harness.releaseNextSleep()
        for _ in 0..<8 { await Task.yield() }
        // Now watchdog tick should have detected absence and reverted state.
        #expect(harness.poller.state == .watching)
        harness.tearDown()
    }

    @Test("denied permission suspends polling and records state")
    func permissionDeniedSuspendsPolling() async {
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(chrome: true))
        harness.urlByBundle[BrowserURLPollingConfig.chromeBundleID] = "https://meet.google.com/abc-defg-hij"
        harness.permissionByBundle[BrowserURLPollingConfig.chromeBundleID] = .denied
        harness.micOwners = [BrowserURLPollingConfig.chromeBundleID]
        harness.poller.start()
        for _ in 0..<8 { await Task.yield() }
        if case .suspendedPermissionDenied(let bundleID) = harness.poller.state {
            #expect(bundleID == BrowserURLPollingConfig.chromeBundleID)
        } else {
            Issue.record("expected suspended_permission_denied, got \(harness.poller.state)")
        }
        // No AppleScript URL was emitted because the denial blocked the fetch.
        #expect(harness.emittedSignals.isEmpty)
        harness.tearDown()
    }

    @Test("notDetermined permission allows polling to proceed (system will prompt)")
    func notDeterminedProceedsWithFetch() async {
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(safari: true))
        harness.urlByBundle[BrowserURLPollingConfig.safariBundleID] = "https://teams.microsoft.com/l/meetup-join/abc"
        harness.permissionByBundle[BrowserURLPollingConfig.safariBundleID] = .notDetermined
        harness.micOwners = [BrowserURLPollingConfig.safariBundleID]
        harness.poller.start()
        for _ in 0..<8 { await Task.yield() }
        #expect(harness.emittedSignals.count == 1)
        #expect(harness.emittedSignals.first?.bundleID == BrowserURLPollingConfig.safariBundleID)
        harness.tearDown()
    }

    @Test("stop cancels all polling tasks")
    func stopCancelsPolling() async {
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(chrome: true))
        harness.urlByBundle[BrowserURLPollingConfig.chromeBundleID] = "https://meet.google.com/abc-defg-hij"
        harness.micOwners = [BrowserURLPollingConfig.chromeBundleID]
        harness.poller.start()
        for _ in 0..<6 { await Task.yield() }
        harness.poller.stop()
        #expect(harness.poller.state == .stopped)
        harness.tearDown()
    }

    @Test("non-meeting URLs are ignored")
    func ignoresNonMeetingURLs() async {
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(chrome: true))
        harness.urlByBundle[BrowserURLPollingConfig.chromeBundleID] = "https://github.com/anthropics/claude-code"
        harness.micOwners = [BrowserURLPollingConfig.chromeBundleID]
        harness.poller.start()
        for _ in 0..<8 { await Task.yield() }
        #expect(harness.emittedSignals.isEmpty)
        harness.tearDown()
    }

    @Test("instrumentation counter reflects AppleScript invocations")
    func instrumentationCounter() async {
        let harness = BrowserURLPollerTestHarness(config: BrowserURLPollingConfig(chrome: true))
        harness.urlByBundle[BrowserURLPollingConfig.chromeBundleID] = "https://meet.google.com/abc-defg-hij"
        harness.micOwners = [BrowserURLPollingConfig.chromeBundleID]
        harness.poller.start()
        for _ in 0..<8 { await Task.yield() }
        #expect(harness.poller.appleScriptInvocations >= 1)

        // When nothing is enabled, the counter should stay put because no
        // AppleScript is invoked.
        let idleHarness = BrowserURLPollerTestHarness(config: .disabled)
        idleHarness.micOwners = [BrowserURLPollingConfig.chromeBundleID]
        idleHarness.poller.start()
        for _ in 0..<8 { await Task.yield() }
        #expect(idleHarness.poller.appleScriptInvocations == 0)

        harness.tearDown()
        idleHarness.tearDown()
    }
}

// MARK: - BrowserURLPollingConfig tests

@Suite("BrowserURLPollingConfig")
struct BrowserURLPollingConfigTests {

    @Test("defaults to all-off")
    func defaultsAllOff() {
        let config = BrowserURLPollingConfig()
        #expect(config.anyEnabled == false)
        #expect(config.chrome == false)
        #expect(config.edge == false)
        #expect(config.brave == false)
        #expect(config.arc == false)
        #expect(config.safari == false)
    }

    @Test("anyEnabled reflects per-flag state")
    func anyEnabledReflectsFlags() {
        #expect(BrowserURLPollingConfig(chrome: true).anyEnabled)
        #expect(BrowserURLPollingConfig(safari: true).anyEnabled)
        #expect(BrowserURLPollingConfig(edge: true, arc: true).anyEnabled)
        #expect(BrowserURLPollingConfig.disabled.anyEnabled == false)
    }

    @Test("isEnabled maps bundle IDs to flags")
    func isEnabledMapping() {
        let config = BrowserURLPollingConfig(chrome: true, safari: true)
        #expect(config.isEnabled(forBundleID: BrowserURLPollingConfig.chromeBundleID))
        #expect(config.isEnabled(forBundleID: BrowserURLPollingConfig.safariBundleID))
        #expect(!config.isEnabled(forBundleID: BrowserURLPollingConfig.edgeBundleID))
        #expect(!config.isEnabled(forBundleID: "com.example.unknown"))
    }

    @Test("Codable round-trips through snake_case JSON")
    func codableRoundTrip() throws {
        let original = BrowserURLPollingConfig(chrome: true, edge: false, brave: true, arc: false, safari: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        // The struct uses property names verbatim as JSON keys (already short).
        #expect(json.contains("\"chrome\":true"))
        #expect(json.contains("\"brave\":true"))
        #expect(json.contains("\"safari\":true"))

        let decoded = try JSONDecoder().decode(BrowserURLPollingConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("decodes missing fields with defaults")
    func decodesMissingFields() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BrowserURLPollingConfig.self, from: json)
        #expect(decoded == .disabled)
    }
}

// MARK: - AutoCaptureConfig browserUrlPolling integration

@Suite("AutoCaptureConfig.browserUrlPolling")
struct AutoCaptureConfigBrowserURLPollingTests {

    @Test("AutoCaptureConfig defaults browserUrlPolling to disabled")
    func defaultsDisabled() {
        #expect(AutoCaptureConfig().browserUrlPolling == .disabled)
    }

    @Test("AutoCaptureConfig encodes browser_url_polling as nested object")
    func encodesNestedKey() throws {
        var config = AutoCaptureConfig()
        config.browserUrlPolling = BrowserURLPollingConfig(chrome: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(config)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"browser_url_polling\""))
    }

    @Test("AutoCaptureConfig decodes pre-v1 configs (missing browser_url_polling)")
    func decodesPreV1Configs() throws {
        let preV1 = """
        {
          "enabled": true,
          "start_delay_seconds": 3
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AutoCaptureConfig.self, from: preV1)
        #expect(decoded.browserUrlPolling == .disabled)
        #expect(decoded.enabled == true)
        #expect(decoded.startDelaySeconds == 3)
    }
}
