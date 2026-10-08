import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("LINE call detection collector")
struct LINECallDetectionCollectorTests {
    @Test func verifiedAppMetadataNeverPretendsToVerifyActiveUI() async {
        let collector = LINECallDetectionCollector(probe: {
            .metadata(.init(bundleID: "jp.naver.line.mac", processID: 42,
                            processLaunchID: "launch-a", windowCount: 1))
        })
        let adapter = LINECallDetectionAdapter(provider: collector)
        #expect(await adapter.observe() == .unavailable(.unsupported))
    }

    @Test func metadataPermissionTimeoutAndAmbiguityFailuresReachAdapter() async {
        for reason in [.noSource, .permissionRequired, .timedOut, .ambiguous, .sourceMismatch] as [CallDetectionUnavailableReason] {
            let collector = LINECallDetectionCollector(probe: { .unavailable(reason) })
            #expect(await LINECallDetectionAdapter(provider: collector).observe() == .unavailable(reason))
        }
    }

    @Test func wrongAppMissingIdentityAndUnboundedWindowsFailClosed() async {
        let cases: [(LINECallDetectionMetadata, CallDetectionUnavailableReason)] = [
            (.init(bundleID: "other.app", processID: 42, processLaunchID: "launch-a", windowCount: 1), .sourceMismatch),
            (.init(bundleID: "jp.naver.line.mac", processID: 0, processLaunchID: "launch-a", windowCount: 1), .sourceMismatch),
            (.init(bundleID: "jp.naver.line.mac", processID: 42, processLaunchID: "", windowCount: 1), .sourceMismatch),
            (.init(bundleID: "jp.naver.line.mac", processID: 42, processLaunchID: "launch-a", windowCount: -1), .unsupported),
            (.init(bundleID: "jp.naver.line.mac", processID: 42, processLaunchID: "launch-a", windowCount: 9), .unsupported),
            (.init(bundleID: "jp.naver.line.mac", processID: 42, processLaunchID: "launch-a", windowCount: 0), .noSource),
        ]
        for (metadata, reason) in cases {
            let collector = LINECallDetectionCollector(probe: { .metadata(metadata) })
            #expect(await LINECallDetectionAdapter(provider: collector).observe() == .unavailable(reason))
        }
    }

    @Test func lateMetadataCannotBecomeFreshEvidence() async {
        let clock = LINECollectorFixtureClock()
        let started = clock.read()
        let collector = LINECallDetectionCollector(probe: {
            clock.set(started.advanced(by: .milliseconds(300)))
            return .metadata(.init(bundleID: "jp.naver.line.mac", processID: 42,
                                   processLaunchID: "launch-a", windowCount: 1))
        }, clock: { clock.read() })
        guard case .unavailable(let reason) = await collector.snapshot() else {
            Issue.record("Over-budget collector returned a snapshot")
            return
        }
        #expect(reason == .timedOut)
    }

    @Test func cancelledCollectorDoesNotReadSource() async {
        // An unexpected source read would expose a missing pre-read cancellation check.
        let collector = LINECallDetectionCollector(probe: {
            Issue.record("Cancelled collector invoked the AX boundary")
            return .metadata(.init(bundleID: "jp.naver.line.mac", processID: 42,
                                   processLaunchID: "launch-a", windowCount: 1))
        })
        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await collector.snapshot()
        }
        guard case .unavailable(let reason) = await read.value else {
            Issue.record("Cancelled collector returned a snapshot")
            return
        }
        #expect(reason == .timedOut)
    }
}

private final class LINECollectorFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    func read() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func set(_ instant: ContinuousClock.Instant) { lock.lock(); defer { lock.unlock() }; self.instant = instant }
}
