import Foundation
import Testing
@testable import MuesliNativeApp

// Compiled synthetic values, not captured WeChat AX identifiers or shipped UI support.
enum WeChatCallDetectionFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func source(
        bundleID: String = "com.tencent.xinWeChat", pid: Int32 = 42,
        launch: String = "process-generation-1", surface: String = "document-generation-1",
        origin: String? = nil
    ) -> CallDetectionSource {
        CallDetectionSource(bundleID: bundleID, processID: pid, processLaunchID: launch,
                            surfaceID: surface, origin: origin)
    }
    static func surface(
        activity: WeChatCallDetectionActivity = .connected,
        controls: Set<WeChatCallDetectionControl> = [.endCall, .mute],
        source: CallDetectionSource = source(), generation: String = "session-generation-1",
        roster: CallDetectionRoster = .unknown
    ) -> WeChatCallDetectionSurface {
        WeChatCallDetectionSurface(expectedSource: source, source: source,
                                   schema: .syntheticV1, activity: activity, controls: controls,
                                   sessionGeneration: generation, roster: roster)
    }
    static func snapshot(
        _ surfaces: [WeChatCallDetectionSurface] = [surface()], age: TimeInterval = 0
    ) -> WeChatCallDetectionSnapshotResult {
        .snapshot(WeChatCallDetectionSnapshot(observedAt: now.addingTimeInterval(-age), surfaces: surfaces))
    }
    static func adapter(_ result: WeChatCallDetectionSnapshotResult) -> WeChatCallDetectionAdapter {
        WeChatCallDetectionAdapter(provider: WeChatCallDetectionSequenceProvider([result]), now: { now })
    }
}

actor WeChatCallDetectionSequenceProvider: WeChatCallDetectionSnapshotProviding {
    private var results: [WeChatCallDetectionSnapshotResult]
    init(_ results: [WeChatCallDetectionSnapshotResult]) { self.results = results }
    func snapshot() async -> WeChatCallDetectionSnapshotResult {
        guard !results.isEmpty else { return .unavailable(.noSource) }
        return results.removeFirst()
    }
}

@Suite("WeChat synthetic adapter; native execution pending")
struct WeChatCallDetectionAdapterTests {
    @Test func connectedRequiresScopedControlsAndPreservesSnapshotTime() async throws {
        let result = await WeChatCallDetectionFixtures.adapter(
            WeChatCallDetectionFixtures.snapshot(age: 2)
        ).observe()
        guard case .observation(let observation) = result else {
            Issue.record("Expected connected synthetic observation"); return
        }
        #expect(observation.service == .weChat)
        #expect(observation.phase == .connected)
        #expect(observation.evidence == [.scopedCallControls, .connectedState])
        #expect(observation.observedAt == WeChatCallDetectionFixtures.now.addingTimeInterval(-2))
        #expect(observation.source == WeChatCallDetectionFixtures.source())
        #expect(UUID(uuidString: observation.callToken) != nil)
        #expect(observation.roster == .unknown)
    }

    @Test func idleVoiceNotesRingingPrejoinAndEndedNeverHaveConnectedEvidence() async {
        let cases: [(WeChatCallDetectionActivity, CallDetectionPhase)] = [
            (.idle, .unknown), (.voiceNoteRecording, .unknown), (.voiceNotePlayback, .unknown),
            (.ringing, .ringing), (.connecting, .connecting), (.ended, .ended), (.unknown, .unknown)
        ]
        for (activity, phase) in cases {
            let result = await WeChatCallDetectionFixtures.adapter(
                WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(activity: activity)])
            ).observe()
            guard case .observation(let observation) = result else {
                Issue.record("Expected nonconnected synthetic observation for \(activity)"); continue
            }
            #expect(observation.phase == phase)
            #expect(observation.evidence.isEmpty)
        }
    }

    @Test func missingControlsFailClosed() async {
        for controls: Set<WeChatCallDetectionControl> in [[], [.endCall], [.mute]] {
            let result = await WeChatCallDetectionFixtures.adapter(
                WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(controls: controls)])
            ).observe()
            #expect(result == .unavailable(.unsupported))
        }
    }

    @Test func unavailablePermissionAndUnsupportedSchemaArePreserved() async {
        for reason in [CallDetectionUnavailableReason.permissionRequired, .timedOut, .unsupported, .noSource] {
            let result = await WeChatCallDetectionFixtures.adapter(.unavailable(reason)).observe()
            #expect(result == .unavailable(reason))
        }
        var surface = WeChatCallDetectionFixtures.surface()
        surface.schema = .unverified
        let result = await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot([surface])).observe()
        #expect(result == .unavailable(.unsupported))
    }

    @Test func freshnessBoundaryRejectsOldFutureAndNonfiniteTimes() async {
        // Sweeps freshness on both sides of the boundary; literal expected interval is independent.
        for tenth in -10...60 {
            let age = Double(tenth) / 10
            let result = await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot(age: age)).observe()
            if (0...50).contains(tenth) {
                guard case .observation(let observation) = result else {
                    Issue.record("Expected fresh at age \(age)"); continue
                }
                #expect(observation.phase == .connected)
            } else {
                #expect(result == .unavailable(.stale))
            }
        }
        let result = await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot(age: .nan)).observe()
        #expect(result == .unavailable(.stale))
    }

    @Test func emptyOrMultipleCallSurfacesFailClosed() async {
        let empty = await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot([])).observe()
        #expect(empty == .unavailable(.noSource))
        for second in [WeChatCallDetectionActivity.connected, .ringing, .connecting] {
            let ambiguous = await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot([
                WeChatCallDetectionFixtures.surface(), WeChatCallDetectionFixtures.surface(activity: second)
            ])).observe()
            #expect(ambiguous == .unavailable(.ambiguous))
        }
    }

    @Test func sourceMismatchAndMalformedDesktopScopesFailClosed() async {
        let sources = [
            WeChatCallDetectionFixtures.source(bundleID: "com.example.other"),
            WeChatCallDetectionFixtures.source(pid: 0),
            WeChatCallDetectionFixtures.source(launch: ""),
            WeChatCallDetectionFixtures.source(surface: ""),
            WeChatCallDetectionFixtures.source(origin: "https://example.invalid")
        ]
        for source in sources {
            let result = await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot([
                WeChatCallDetectionFixtures.surface(source: source)
            ])).observe()
            #expect(result == .unavailable(.sourceMismatch))
        }
        var mismatched = WeChatCallDetectionFixtures.surface()
        mismatched.source = WeChatCallDetectionFixtures.source(pid: 43)
        let result = await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot([mismatched])).observe()
        #expect(result == .unavailable(.sourceMismatch))
        let noGeneration = await WeChatCallDetectionFixtures.adapter(WeChatCallDetectionFixtures.snapshot([
            WeChatCallDetectionFixtures.surface(generation: "")
        ])).observe()
        #expect(noGeneration == .unavailable(.sourceMismatch))
    }

    @Test func rosterKnowledgeIsNeverUpgradedOrInferredFromControls() async {
        let provider = WeChatCallDetectionSequenceProvider([
            WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(roster: .complete(["opaque-a", "opaque-b"]))]),
            WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(roster: .partial(["opaque-a"]))]),
            WeChatCallDetectionFixtures.snapshot([WeChatCallDetectionFixtures.surface(roster: .unknown)])
        ])
        let adapter = WeChatCallDetectionAdapter(provider: provider, now: { WeChatCallDetectionFixtures.now })
        for expected in [CallDetectionRoster.complete(["opaque-a", "opaque-b"]), .partial(["opaque-a"]), .unknown] {
            let result = await adapter.observe()
            guard case .observation(let observation) = result else { Issue.record("Expected roster observation"); continue }
            #expect(observation.roster == expected)
        }
    }
}
