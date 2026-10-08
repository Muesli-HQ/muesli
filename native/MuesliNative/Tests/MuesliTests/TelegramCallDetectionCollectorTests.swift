import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Telegram bounded production capability collection")
struct TelegramCallDetectionCollectorTests {
    private typealias Process = TelegramCallDetectionProcess
    private let target = Process(bundleID: "ru.keepcoder.Telegram", processID: 42, launchID: "fixture-launch")

    @Test func unrelatedAppsAreNotProbedAndNeedNoPermission() async {
        let collector = TelegramCallDetectionCollector(
            inventory: { [Process(bundleID: "unrelated.messenger", processID: 10, launchID: "other")] },
            isTrusted: { Issue.record("Trust read without a target process"); return false },
            probe: { _ in Issue.record("Unrelated app was probed"); return .windows(1) }
        )
        #expect(await collector.collect() == .unavailable(.noSource))
    }

    @Test func permissionsFailWithoutProbingOrPrompting() async {
        let target = target
        let collector = TelegramCallDetectionCollector(inventory: { [target] }, isTrusted: { false }, probe: { _ in
            Issue.record("AX probe executed without trust")
            return .windows(1)
        })
        #expect(await collector.collect() == .unavailable(.permissionRequired))
    }

    @Test func exactSourceBackedReleaseIdentitiesStayUnsupportedWithoutVerifiedUI() async {
        for bundle in ["ru.keepcoder.Telegram", "com.tdesktop.Telegram", "org.telegram.desktop"] {
            let process = Process(bundleID: bundle, processID: 42, launchID: "fixture-launch")
            let collector = TelegramCallDetectionCollector(inventory: { [process] }, isTrusted: { true }, probe: { received in
                #expect(received == process)
                return .windows(2)
            })
            #expect(await collector.collect() == .unavailable(.unsupported))
        }
        for bundle in ["com.tdesktop.TelegramDebug", "ru.keepcoder.Telegram.fake", "ru.keepcoder.Telegram.TelegramShare"] {
            let process = Process(bundleID: bundle, processID: 42, launchID: "fixture-launch")
            let collector = TelegramCallDetectionCollector(inventory: { [process] }, isTrusted: { true }, probe: { _ in
                Issue.record("Unexpected app identity was probed")
                return .windows(1)
            })
            #expect(await collector.collect() == .unavailable(.noSource))
        }
    }

    @Test func multipleProcessesAndMalformedLaunchIdentityFailClosed() async {
        let target = target
        for count in [2, 3, 20] {
            let collector = TelegramCallDetectionCollector(inventory: { Array(repeating: target, count: count) }, isTrusted: { true }, probe: { _ in
                Issue.record("Ambiguous process list was probed")
                return .windows(1)
            })
            #expect(await collector.collect() == .unavailable(.ambiguous))
        }
        for process in [Process(bundleID: target.bundleID, processID: 0, launchID: "launch"),
                        Process(bundleID: target.bundleID, processID: 42, launchID: "")] {
            let collector = TelegramCallDetectionCollector(inventory: { [process] }, isTrusted: { true }, probe: { _ in
                Issue.record("Malformed source was probed")
                return .windows(1)
            })
            #expect(await collector.collect() == .unavailable(.sourceMismatch))
        }
    }

    @Test func processLossPIDReuseAndConcurrentProcessAppearanceInvalidateProbe() async {
        let target = target
        for replacement in [[], [Process(bundleID: target.bundleID, processID: 42, launchID: "reused-pid")],
                            [Process(bundleID: target.bundleID, processID: 43, launchID: target.launchID)],
                            [target, Process(bundleID: "com.tdesktop.Telegram", processID: 43, launchID: "second")]] {
            let inventory = TelegramCallDetectionInventoryFixture([[target], replacement])
            let collector = TelegramCallDetectionCollector(inventory: { await inventory.next() }, isTrusted: { true }, probe: { _ in .windows(1) })
            #expect(await collector.collect() == .unavailable(.sourceMismatch))
        }
    }

    @Test func probeUnavailableAndWindowBoundsCannotBecomeObservations() async {
        let target = target
        for report in [TelegramCallDetectionProbeResult.windows(-1), .windows(0), .windows(8), .windows(9), .windows(1000),
                       .unavailable(.permissionRequired), .unavailable(.timedOut), .unavailable(.sourceMismatch)] {
            let collector = TelegramCallDetectionCollector(inventory: { [target] }, isTrusted: { true }, probe: { _ in report })
            let result = await collector.collect()
            if case .unavailable(let reason) = report { #expect(result == .unavailable(reason)) }
            else { #expect(result == .unavailable(.unsupported)) }
        }
    }
}

private actor TelegramCallDetectionInventoryFixture {
    private var lists: [[TelegramCallDetectionProcess]]
    init(_ lists: [[TelegramCallDetectionProcess]]) { self.lists = lists }
    func next() -> [TelegramCallDetectionProcess] {
        guard !lists.isEmpty else { return [] }
        return lists.removeFirst()
    }
}
