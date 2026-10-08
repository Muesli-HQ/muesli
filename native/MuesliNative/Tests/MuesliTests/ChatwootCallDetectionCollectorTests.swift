import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Chatwoot production collector")
struct ChatwootCallDetectionCollectorTests {
    @Test func missingPermissionDoesNotPromptOrProduceSnapshot() async {
        let probe = ChatwootCallDetectionFixtureBrowserProbe(.permissionRequired)
        #expect(await observe(probe) == .unavailable(.permissionRequired))
    }

    @Test func noActiveBrowserOrWindowIsNoSource() async {
        let probe = ChatwootCallDetectionFixtureBrowserProbe(.noSource)
        #expect(await observe(probe) == .unavailable(.noSource))
    }

    @Test func unverifiedBrowserUIIsAlwaysUnsupportedEvenWhenFocused() async {
        for bundle in ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.example.other"] {
            let probe = ChatwootCallDetectionFixtureBrowserProbe(.focusedBrowser(bundleID: bundle))
            #expect(await observe(probe) == .unavailable(.unsupported))
        }
    }

    @Test func sourceChangesAndAXTimeoutPropagateWithoutPositiveEvidence() async {
        #expect(await observe(ChatwootCallDetectionFixtureBrowserProbe(.sourceMismatch)) == .unavailable(.sourceMismatch))
        #expect(await observe(ChatwootCallDetectionFixtureBrowserProbe(.timedOut)) == .unavailable(.timedOut))
    }

    @Test func collectorHonorsExpiredDeadlineBeforeReadingOS() async {
        let probe = ChatwootCallDetectionFixtureBrowserProbe(.focusedBrowser(bundleID: "com.google.Chrome"))
        let collector = ChatwootCallDetectionCollector(probe: probe)
        let result = await collector.snapshot(deadline: ContinuousClock().now.advanced(by: .seconds(-1)))
        guard case .unavailable(let reason) = result else { Issue.record("Unexpected snapshot"); return }
        #expect(reason == .timedOut)
        #expect(await probe.readCount == 0)
    }

    private func observe(_ probe: ChatwootCallDetectionFixtureBrowserProbe) async -> CallDetectionResult {
        await ChatwootCallDetectionAdapter(provider: ChatwootCallDetectionCollector(probe: probe),
                                           now: { ChatwootCallDetectionFixture.now }).observe()
    }
}

actor ChatwootCallDetectionFixtureBrowserProbe: ChatwootCallDetectionBrowserProbing {
    let result: ChatwootCallDetectionBrowserProbeResult
    private(set) var readCount = 0
    init(_ result: ChatwootCallDetectionBrowserProbeResult) { self.result = result }
    func probe(deadline: ContinuousClock.Instant) async -> ChatwootCallDetectionBrowserProbeResult {
        readCount += 1
        return result
    }
}
