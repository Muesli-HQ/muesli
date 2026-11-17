import Foundation
import Testing
@testable import MuesliNativeApp

/// Explicit deadlines make lifecycle tests deterministic; no wall-clock sleeps.
final class StartupTestScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []
    var count: Int { lock.withLock { work.count } }
    func schedule(_ delay: TimeInterval, _ callback: @escaping @Sendable () -> Void) {
        lock.withLock { work.append(callback) }
    }
    func fire(_ index: Int) { lock.withLock { work[index] }() }
}

final class StartupTestReports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DictationStartupReport] = []
    let arrived = DispatchSemaphore(value: 0)
    var values: [DictationStartupReport] { lock.withLock { storage } }
    func record(_ report: DictationStartupReport) {
        lock.withLock { storage.append(report) }
        arrived.signal()
    }
}

@Suite("DictationStartupWatchdog")
struct DictationStartupWatchdogTests {
    @Test("readiness requires start-return and first-buffer in either order", arguments: [true, false])
    func readiness(bufferFirst: Bool) {
        let scheduler = StartupTestScheduler()
        let watchdog = DictationStartupWatchdog(schedule: scheduler.schedule)
        var reports: [DictationStartupReport] = []
        watchdog.onReport = { reports.append($0) }
        let id = UUID()
        #expect(watchdog.begin(id))
        if bufferFirst {
            #expect(watchdog.firstBuffer(id))
            #expect(reports.isEmpty)
            #expect(watchdog.startReturned(id))
        } else {
            #expect(watchdog.startReturned(id))
            #expect(reports.isEmpty)
            #expect(watchdog.firstBuffer(id))
        }
        #expect(!watchdog.begin(id))
        #expect(!watchdog.firstBuffer(id))
        scheduler.fire(0)
        #expect(reports.map(\.outcome) == [.ready])
        #expect(scheduler.count == 1)
    }

    @Test("warning is nonterminal, emitted once, and a slow start can still become ready")
    func warningThenReady() {
        let scheduler = StartupTestScheduler()
        let watchdog = DictationStartupWatchdog(schedule: scheduler.schedule)
        var reports: [DictationStartupReport] = []
        watchdog.onReport = { reports.append($0) }
        let id = UUID()
        watchdog.begin(id)
        watchdog.firstBuffer(id)
        scheduler.fire(0)
        scheduler.fire(0)
        #expect(watchdog.isPending(id))
        #expect(watchdog.accepts(id))
        #expect(watchdog.startReturned(id))
        #expect(!watchdog.isPending(id))
        #expect(reports.map(\.outcome) == [.warning, .ready])
    }

    @Test("abandonment disarms deadline and old callbacks cannot acknowledge new attempt", arguments: [DictationStartupOutcome.cancelled, .stopped, .failed])
    func replacement(outcome: DictationStartupOutcome) {
        let scheduler = StartupTestScheduler()
        let watchdog = DictationStartupWatchdog(schedule: scheduler.schedule)
        var reports: [DictationStartupReport] = []
        watchdog.onReport = { reports.append($0) }
        let old = UUID(), new = UUID()
        watchdog.begin(old)
        watchdog.finish(old, outcome: outcome)
        watchdog.begin(new)
        scheduler.fire(0)
        #expect(!watchdog.firstBuffer(old))
        #expect(!watchdog.startReturned(old))
        watchdog.startReturned(new)
        scheduler.fire(1)
        #expect(reports.map(\.outcome) == [outcome, .warning])
        #expect(reports.last?.sessionID == new)
    }

    @Test("capture failures retain startup latency without exposing recording duration")
    func recordingDurationIsPrivate() {
        let clock = StartupTestClock()
        let watchdog = DictationStartupWatchdog(now: clock.read, schedule: { _, _ in })
        var reports: [DictationStartupReport] = []
        watchdog.onReport = { reports.append($0) }
        let id = UUID()
        watchdog.begin(id)
        clock.set(10_000_000)
        watchdog.startReturned(id)
        watchdog.firstBuffer(id)
        clock.set(600_000_000_000)
        watchdog.finish(id, outcome: .failed, failureReason: .deviceUnavailable)
        #expect(reports.map(\.elapsedMilliseconds) == [10, 10])
        #expect(reports.last?.eventName == "dictation.microphone.capture.failed")
        #expect(reports.last?.telemetryParameters["startup.failure_reason"] == "device_unavailable")
    }

    @Test("telemetry exposes only finite labels and bounded startup timing")
    func privacyAllowlist() {
        let report = DictationStartupReport(sessionID: UUID(), owner: .computerUse,
            outcome: .warning, phase: .startingRecorder, elapsedMilliseconds: 3_000,
            warningAfterMilliseconds: 3_000,
            context: .init(route: .headphones, input: .explicit))
        #expect(Set(report.telemetryParameters.keys) == Set([
            "startup.schema_version", "startup.owner", "startup.outcome", "startup.phase",
            "startup.elapsed_ms", "startup.warning_after_ms", "startup.failure_reason", "startup.route", "startup.input_selection"
        ]))
        #expect(!report.telemetryParameters.values.contains(report.sessionID.uuidString))
        #expect(report.telemetryParameters["startup.owner"] == "computer_use")
        #expect(report.eventName == "dictation.microphone.startup.warning")
        let scheduler = StartupTestScheduler()
        let watchdog = DictationStartupWatchdog(now: { UInt64.max }, schedule: scheduler.schedule)
        var timed: DictationStartupReport?
        watchdog.onReport = { timed = $0 }
        watchdog.begin(UUID())
        scheduler.fire(0)
        #expect(timed?.elapsedMilliseconds == 0)
        #expect(timed?.warningAfterMilliseconds == 3_000)
        #expect((DictationMicrophoneStartupError.deviceUnavailable as NSError).domain == "MuesliMicrophoneStartup")
    }
}

private final class StartupTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func read() -> UInt64 { lock.withLock { value } }
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
}
