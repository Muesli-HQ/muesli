import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Telegram injected-provider lifecycle")
struct TelegramCallDetectionAdapterTests {
    private typealias F = TelegramCallDetectionFixtures

    private func adapter(_ reads: [TelegramCallDetectionReadResult]) -> TelegramCallDetectionAdapter {
        let provider = TelegramCallDetectionFixtureProvider(reads)
        return TelegramCallDetectionAdapter(snapshotProvider: { await provider.next() }, clock: { F.now })
    }

    @Test func connectedSnapshotPreservesTimeSourceAndEvidence() async throws {
        let value = try F.observation(await adapter([F.read(at: F.now.addingTimeInterval(-2))]).observe())
        #expect(value.service == .telegram)
        #expect(value.source == F.source)
        #expect(value.observedAt == F.now.addingTimeInterval(-2))
        #expect(value.phase == .connected)
        #expect(value.evidence == [.scopedCallControls, .connectedState])
        #expect(value.roster == .unknown)
        #expect(UUID(uuidString: value.callToken) != nil)
    }

    @Test func timestampsRejectStaleFutureAndNonfiniteValues() async {
        for offset in [-5.001, -6, 0.001, 1] {
            #expect(await adapter([F.read(at: F.now.addingTimeInterval(offset))]).observe() == .unavailable(.stale))
        }
        for interval in [Double.infinity, -Double.infinity, Double.nan] {
            #expect(await adapter([F.read(at: Date(timeIntervalSince1970: interval))]).observe() == .unavailable(.stale))
        }
        #expect(await TelegramCallDetectionAdapter(snapshotProvider: { F.read() }, clock: { Date(timeIntervalSince1970: .nan) }).observe() == .unavailable(.stale))
    }

    @Test func exactFreshnessBoundaryIsAcceptedAndClockIsSampledAfterRead() async throws {
        let atBoundary = try F.observation(await adapter([F.read(at: F.now.addingTimeInterval(-5))]).observe())
        #expect(atBoundary.observedAt == F.now.addingTimeInterval(-5))
        let clock = TelegramCallDetectionFixtureClock(F.now)
        let delayed = TelegramCallDetectionAdapter(snapshotProvider: {
            clock.set(F.now.addingTimeInterval(6))
            return F.read()
        }, clock: { clock.now() })
        #expect(await delayed.observe() == .unavailable(.stale))
    }

    @Test func incompleteSnapshotAndCollectorFailuresRemainUnavailable() async {
        #expect(await adapter([F.read(complete: false)]).observe() == .unavailable(.unsupported))
        for reason in [CallDetectionUnavailableReason.noSource, .permissionRequired, .timedOut, .ambiguous, .unsupported, .sourceMismatch] {
            #expect(await adapter([.unavailable(reason)]).observe() == .unavailable(reason))
        }
    }

    @Test func negativeScopedSnapshotsExerciseTheActualInjectedBoundary() async {
        let cases: [(TelegramCallDetectionReadResult, CallDetectionUnavailableReason)] = [
            (F.read([F.surface(scope: .chat)]), .unsupported),
            (F.read([F.surface(scope: .voiceMessageRecording)]), .unsupported),
            (F.read([F.surface(scope: .voiceMessagePlayback)]), .unsupported),
            (F.read([F.surface(controls: [.endCall])]), .unsupported),
            (F.read([F.surface(), F.surface()]), .ambiguous),
            (F.read([F.surface(states: [.connected, .ended])]), .ambiguous),
            (F.read([F.surface(observedSource: F.changedSource(surface: "other-document"))]), .sourceMismatch),
        ]
        for (snapshot, reason) in cases {
            #expect(await adapter([snapshot]).observe() == .unavailable(reason))
        }
    }

    @Test func nonConnectedPhasesNeverSupplyConnectedEvidence() async throws {
        for phase in [CallDetectionPhase.ringing, .connecting, .ended] {
            let value = try F.observation(await adapter([F.read([F.surface(states: [phase])])]).observe())
            #expect(value.phase == phase)
            #expect(!value.evidence.contains(.connectedState))
        }
    }

    @Test func tokenStableDuringCallAndRotatesForEveryScopeChange() async throws {
        let service = adapter([
            F.read(), F.read(), F.read([F.surface(generation: "new-session")]),
            F.read([F.surface(source: F.changedSource(pid: 43))]),
            F.read([F.surface(source: F.changedSource(launch: "new-launch"))]),
            F.read([F.surface(source: F.changedSource(surface: "new-document"))]),
            F.read([F.surface(source: F.changedSource(bundleID: "com.tdesktop.Telegram"))]),
        ])
        let first = try F.observation(await service.observe())
        let second = try F.observation(await service.observe())
        #expect(first.callToken == second.callToken)
        var previous = second.callToken
        for _ in 0..<5 {
            let next = try F.observation(await service.observe())
            #expect(next.callToken != previous)
            previous = next.callToken
        }
    }

    @Test func phasesPreserveIdentityAndEndOrUnavailableGapBreakContinuity() async throws {
        let phases: [CallDetectionPhase] = [.ringing, .connecting, .connected, .connecting, .connected, .ended]
        let lifecycle = adapter(phases.map { F.read([F.surface(states: [$0], roster: .partial(["fixture-member-a"]))]) } + [F.read()])
        let first = try F.observation(await lifecycle.observe())
        for phase in phases.dropFirst() {
            let next = try F.observation(await lifecycle.observe())
            #expect(next.phase == phase)
            #expect(next.callToken == first.callToken)
            #expect(next.roster == first.roster)
        }
        let afterEnd = try F.observation(await lifecycle.observe())
        #expect(afterEnd.callToken != first.callToken)
        for gap in [F.read(at: F.now.addingTimeInterval(-6)), F.read([F.surface(profile: .unverifiedLive)]),
                    .unavailable(.permissionRequired), .unavailable(.ambiguous), .unavailable(.noSource), .unavailable(.timedOut)] {
            let service = adapter([F.read(), gap, F.read()])
            let before = try F.observation(await service.observe())
            _ = await service.observe()
            let after = try F.observation(await service.observe())
            #expect(before.callToken != after.callToken)
        }
    }

    @Test func rosterCompletenessAndOpaqueIDsStayScopedToSession() async throws {
        let service = adapter([
            F.read([F.surface(roster: .partial(["fixture-member-a"]))]),
            F.read([F.surface(roster: .complete(["fixture-member-a", "fixture-member-b"]))]),
            F.read([F.surface(roster: .unknown)]),
            F.read([F.surface(generation: "new-session", roster: .partial(["fixture-member-a"]))]),
        ])
        let partial = try F.observation(await service.observe())
        let complete = try F.observation(await service.observe())
        let unknown = try F.observation(await service.observe())
        let newSession = try F.observation(await service.observe())
        guard case .partial(let firstIDs) = partial.roster,
              case .complete(let allIDs) = complete.roster,
              case .partial(let newIDs) = newSession.roster else {
            Issue.record("Adapter lost the explicitly supplied roster completeness")
            return
        }
        #expect(firstIDs.count == 1 && allIDs.count == 2)
        #expect(firstIDs.isSubset(of: allIDs))
        #expect(allIDs.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(!allIDs.contains("fixture-member-a"))
        #expect(firstIDs.isDisjoint(with: newIDs))
        #expect(unknown.roster == .unknown)
        #expect(partial.callToken == complete.callToken && partial.callToken == unknown.callToken)
        #expect(newSession.callToken != partial.callToken)
    }

    @Test func cumulativeRosterChurnIsBoundedWithoutEviction() async throws {
        let firstIDs = Set((0..<128).map { "fixture-\($0)" })
        let nextIDs = Set((128..<256).map { "fixture-\($0)" })
        let service = adapter([
            F.read([F.surface(roster: .partial(firstIDs))]), F.read([F.surface(roster: .partial(nextIDs))]),
            F.read([F.surface(roster: .partial(["fixture-256"]))]), F.read([F.surface(roster: .partial(firstIDs))]),
        ])
        let first = try F.observation(await service.observe())
        let second = try F.observation(await service.observe())
        #expect(first.callToken == second.callToken)
        #expect(await service.observe() == .unavailable(.unsupported))
        let recovered = try F.observation(await service.observe())
        #expect(recovered.callToken != first.callToken)
    }

    @Test func generatedTimestampAgesCannotRefreshCachedEvidence() async {
        for milliseconds in stride(from: -1000, through: 6000, by: 125) {
            let result = await adapter([F.read(at: F.now.addingTimeInterval(-Double(milliseconds) / 1000))]).observe()
            if case .observation = result { #expect((0...5000).contains(milliseconds)) }
            else { #expect(!(0...5000).contains(milliseconds)) }
        }
    }
}
