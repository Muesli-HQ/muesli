import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("BrowserMeetingActivityCollector")
struct BrowserMeetingActivityCollectorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func chrome(isActive: Bool) -> RunningAppSnapshot {
        RunningAppSnapshot(
            bundleID: "com.google.Chrome",
            appName: "Chrome",
            processIdentifier: 1234,
            isActive: isActive
        )
    }

    @Test("refresh probes inactive uncached browsers")
    func refreshProbesInactiveUncachedBrowsers() async {
        let collector = BrowserMeetingActivityCollector(
            focusedDocumentURLProvider: { app in
                app.bundleID == "com.google.Chrome" ? "https://meet.google.com/pwm-txwq-txy" : nil
            }
        )

        let meetings = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(meetings.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(meetings.first?.isFocused == false)
    }

    @Test("refresh clears stale cached room when browser no longer reports a meeting URL")
    func refreshClearsStaleCachedRoom() async {
        var focusedURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            focusedDocumentURLProvider: { _ in focusedURL }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in false }
        )

        focusedURL = nil
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptAppleScript: { _ in false }
        )
        let cachedAfterFailedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterFailedRefresh.isEmpty)
    }

    @Test("refresh preserves cache when AppleScript probe is throttled")
    func refreshPreservesCacheWhenAppleScriptProbeIsThrottled() async {
        var activeTabURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            activeBrowserURLProvider: { _ in activeTabURL }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in true }
        )

        activeTabURL = nil
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptAppleScript: { _ in false }
        )
        let cachedAfterSkippedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterSkippedRefresh.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
    }

    @Test("refresh clears cache when AppleScript probe runs and finds no meeting URL")
    func refreshClearsCacheWhenAppleScriptProbeFindsNoMeetingURL() async {
        var activeTabURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            activeBrowserURLProvider: { _ in activeTabURL }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in true }
        )

        activeTabURL = "https://example.com"
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptAppleScript: { _ in true }
        )
        let cachedAfterFailedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterFailedRefresh.isEmpty)
    }

    @Test("non-refresh pass can reuse recent cached browser room")
    func nonRefreshPassCanReuseRecentCachedRoom() async {
        var focusedURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            focusedDocumentURLProvider: { _ in focusedURL }
        )

        _ = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in false }
        )

        focusedURL = nil
        let cached = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(1),
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(cached.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(cached.first?.isFocused == false)
    }
}
