import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Inline Grid call detection")
struct InlineGridCallTests {
    private func resolver() -> MeetingCandidateResolver {
        let resolver = MeetingCandidateResolver()
        resolver.selfBundleID = "com.muesli.app"
        return resolver
    }

    private func snapshot(
        micActive: Bool = false, cameraActive: Bool = false,
        runningApps: [RunningAppInfo] = [], inlineCall: InlineGridCallObservation = .absent,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> MeetingSignalSnapshot {
        MeetingSignalSnapshot(
            micActive: micActive, cameraActive: cameraActive, calendarEvent: nil,
            runningApps: runningApps, browserMeetings: [], foregroundBundleID: nil,
            inlineCall: inlineCall, now: now
        )
    }

    @Test("Inline visible call works muted and gets a fresh identity after leaving")
    func inlineCallLifecycle() {
        let detector = resolver()
        #expect(detector.resolve(snapshot(inlineCall: .unavailable)) == nil)
        let active = snapshot(micActive: false, cameraActive: false, inlineCall: .active(123))
        let first = detector.resolve(active)
        #expect(first?.platform == .inline)
        #expect(first?.sourcePID == 123)
        #expect(first?.sourceBundleID == "chat.inline.InlineMac")
        #expect(first?.evidence.contains(.callWindow) == true)
        #expect(detector.resolve(active)?.id == first?.id)
        let unavailable = snapshot(inlineCall: .unavailable, now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(detector.resolve(unavailable)?.id == first?.id)
        #expect(detector.resolve(snapshot(micActive: false, cameraActive: false, now: Date(timeIntervalSince1970: 1_800_000_101))) == nil)
        let later = snapshot(inlineCall: .active(123), now: Date(timeIntervalSince1970: 1_800_000_102))
        #expect(detector.resolve(later)?.id != first?.id)
    }

    @Test("Inline presence and unrelated microphone do not imply a call")
    func inlinePresenceIsNotCall() {
        #expect(resolver().resolve(snapshot(
            micActive: true, cameraActive: false,
            runningApps: [RunningAppInfo(bundleID: "chat.inline.InlineMac", isActive: true)]
        )) == nil)
    }

    @Test("Inline panel must be on screen and contain the leave control")
    func inlineWindowEvidence() {
        let rect = CGRect(x: 100, y: 200, width: 180, height: 40)
        #expect(InlineGridCallCollector.isCallWindow(title: "Grid Call", bounds: rect, onScreenBounds: [rect], labels: ["Leave room"]))
        #expect(!InlineGridCallCollector.isCallWindow(title: "Grid Call", bounds: rect, onScreenBounds: [], labels: ["Leave room"]))
        #expect(!InlineGridCallCollector.isCallWindow(title: "Grid Call", bounds: rect, onScreenBounds: [rect], labels: []))
        #expect(!InlineGridCallCollector.isCallWindow(title: "Inline", bounds: rect, onScreenBounds: [rect], labels: ["Leave room"]))
        #expect(!InlineGridCallCollector.isCallWindow(title: "Grid Call", bounds: rect, onScreenBounds: [rect.offsetBy(dx: 20, dy: 0)], labels: ["Leave room"]))
    }

}
