import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting speaker Accessibility monitor")
struct MeetingSpeakerAccessibilityMonitorTests {
    @Test func noSystemAudioBreaksContinuityAndRecordsOnlyReasonCounts() async {
        let authorization = UUID()
        let clock = SequenceClock([0, 0.1, nil, 1, 1.1])
        let monitor = MeetingSpeakerAccessibilityMonitor(
            observationLimit: 4,
            reader: { Self.frame() }
        )

        await monitor.recordPoll(authorization: authorization, token: { authorization }, clock: { clock.next() })
        await monitor.recordPoll(authorization: authorization, token: { authorization }, clock: { clock.next() })
        await monitor.recordPoll(authorization: authorization, token: { authorization }, clock: { clock.next() })
        let timeline = await monitor.stop()

        #expect(timeline.observations.count == 2)
        #expect(timeline.observations[0].continuity != timeline.observations[1].continuity)
        #expect(timeline.diagnosticCounts[.noSystemAudio] == 1)
        #expect(timeline.diagnosticSummary.contains("no_system_audio=1"))
    }

    @Test func authorizationRevokedDuringReadCannotPublishFrame() async {
        let authorization = UUID()
        let auth = AuthorizationFixture(authorization)
        let clock = SequenceClock([0, 0.1])
        let reads = ReadCounter()
        let monitor = MeetingSpeakerAccessibilityMonitor(
            observationLimit: 4,
            reader: {
                await reads.increment()
                await auth.revoke()
                return Self.frame()
            }
        )

        await monitor.recordPoll(authorization: authorization, token: { await auth.current() }, clock: { clock.next() })
        await monitor.recordPoll(authorization: authorization, token: { await auth.current() }, clock: { clock.next() })
        let timeline = await monitor.stop()

        #expect(timeline.observations.isEmpty)
        #expect(timeline.diagnosticCounts[.authorizationChanged] == 1)
        let readCount = await reads.value()
        #expect(readCount == 1)
    }

    @Test func observationLimitRetainsLatestFramesInTimeOrder() async {
        let authorization = UUID()
        let clock = SequenceClock([0, 0.1, 1, 1.1, 2, 2.1])
        let monitor = MeetingSpeakerAccessibilityMonitor(
            observationLimit: 2,
            reader: { Self.frame() }
        )

        for _ in 0..<3 {
            await monitor.recordPoll(authorization: authorization, token: { authorization }, clock: { clock.next() })
        }
        let timeline = await monitor.stop()

        #expect(timeline.observations.map(\.time) == [1.1, 2.1])
        #expect(!timeline.incomplete)
        #expect(timeline.observations.last?.frame.active?.name == "Example")
    }

    @Test func observationsRetainOnlyTheActiveParticipantFromEachRoster() async {
        let authorization = UUID()
        let active = MeetingSpeakerParticipant(id: "window/tile/active", name: "Example")
        let roster = (0..<48).map { index in
            MeetingSpeakerParticipant(id: "window/tile/\(index)", name: "Participant \(index)")
        } + [active]
        let monitor = MeetingSpeakerAccessibilityMonitor(
            observationLimit: 2,
            reader: { .init(scope: "window", app: .zoom, participants: roster, activeID: active.id) }
        )
        let clock = SequenceClock([0, 0.1])

        await monitor.recordPoll(authorization: authorization, token: { authorization }, clock: { clock.next() })
        let timeline = await monitor.stop()

        #expect(timeline.observations.first?.frame.participants == [active])
        #expect(timeline.observations.first?.frame.active == active)
    }

    @Test func inFlightFrameCannotCrossASpeakerContinuityBreak() async {
        let authorization = UUID()
        let frameReader = ContinuityBreakingFrameReader()
        let monitor = MeetingSpeakerAccessibilityMonitor(
            observationLimit: 2,
            reader: { await frameReader.read() }
        )
        await frameReader.attach(to: monitor)
        let clock = SequenceClock([0, 0.1])

        await monitor.recordPoll(authorization: authorization, token: { authorization }, clock: { clock.next() })
        let timeline = await monitor.stop()

        #expect(timeline.observations.isEmpty)
        #expect(timeline.diagnosticCounts[.continuityBreak] == 1)
    }

    @Test func scopeChangesAreRecordedWithoutExposingWindowContent() async {
        let authorization = UUID()
        let clock = SequenceClock([0, 0.1, 1, 1.1])
        let frames = FrameSequence([
            Self.frame(scope: "window/layout-a"),
            Self.frame(scope: "window/layout-b")
        ])
        let monitor = MeetingSpeakerAccessibilityMonitor(observationLimit: 4, reader: { await frames.next() })

        await monitor.recordPoll(authorization: authorization, token: { authorization }, clock: { clock.next() })
        await monitor.recordPoll(authorization: authorization, token: { authorization }, clock: { clock.next() })
        let timeline = await monitor.stop()

        #expect(timeline.observations.count == 2)
        #expect(timeline.diagnosticCounts[.scopeChanged] == 1)
        #expect(timeline.diagnosticSummary.contains("scope_changed=1"))
    }

    @Test func authorizationCacheLimitsTrustChecksAndSupportsForcedRefresh() {
        var cache = MeetingSpeakerAuthorizationCache()
        var checks = 0
        let first = cache.authorization(enabled: true, now: 10, isTrusted: { checks += 1; return true })
        let cached = cache.authorization(enabled: true, now: 11.5, isTrusted: { checks += 1; return false })
        #expect(first == cached)
        #expect(checks == 1)

        let revoked = cache.authorization(enabled: true, now: 11.5, forceRefresh: true, isTrusted: { checks += 1; return false })
        #expect(revoked == nil)
        #expect(checks == 2)
    }

    @Test func restoredAuthorizationCacheKeepsItsGenerationUntilPermissionChanges() {
        let persistedGeneration = UUID()
        var cache = MeetingSpeakerAuthorizationCache(generation: persistedGeneration, enabled: true, trusted: true)

        #expect(cache.authorization(enabled: true, now: 10, isTrusted: { true }) == persistedGeneration)
        #expect(cache.generation == persistedGeneration)
        #expect(cache.authorization(enabled: true, now: 11, forceRefresh: true, isTrusted: { false }) == nil)
        #expect(cache.generation != persistedGeneration)
    }

    @Test func runningApplicationSnapshotCanBeReadWithoutMainActorRefresh() {
        let store = MeetingSpeakerRunningAppsSnapshotStore()
        let apps = [RunningAppSnapshot(bundleID: "us.zoom.xos", appName: "Zoom", processIdentifier: 10, isActive: true)]

        store.replace(apps)

        #expect(store.snapshot() == apps)
    }

    @Test func runningApplicationSnapshotRemainsActiveUntilEveryOwnerReleasesIt() {
        var owners = RunningApplicationStoreOwners()
        let detectionOwner = UUID()
        let manualRecordingOwner = UUID()

        let acquiredForDetection = owners.acquire(detectionOwner)
        let acquiredForManualRecording = owners.acquire(manualRecordingOwner)
        let keptActiveForManualRecording = owners.release(detectionOwner)
        let releasedAfterManualRecording = owners.release(manualRecordingOwner)
        #expect(acquiredForDetection)
        #expect(!acquiredForManualRecording)
        #expect(!keptActiveForManualRecording)
        #expect(releasedAfterManualRecording)
    }

    @Test func speakerAudioClockIncludesRecordedSamplesAcrossPauseBoundaries() {
        let clock = MeetingSpeakerAudioTimelineClock()
        clock.start()
        #expect(clock.elapsedTimeSeconds(isCapturing: true, now: 1) == nil)

        clock.recordRecordedSamples(16_000, uptime: 1)
        #expect(clock.elapsedTimeSeconds(isCapturing: true, now: 1.1) == 1)

        clock.breakContinuity()
        clock.recordRecordedSamples(800, uptime: 1.2)
        #expect(clock.elapsedTimeSeconds(isCapturing: false, now: 1.2) == nil)

        clock.breakContinuity()
        #expect(clock.elapsedTimeSeconds(isCapturing: true, now: 1.3) == nil)
        clock.recordRecordedSamples(16_000, uptime: 2)
        #expect(clock.elapsedTimeSeconds(isCapturing: true, now: 2.1) == 2.05)
    }

    @Test func speakerAudioClockAdvancesSystemOnlyPaddingWithoutMarkingItAsFreshMicrophoneInput() {
        let clock = MeetingSpeakerAudioTimelineClock()
        clock.start()
        clock.recordRecordedSamples(16_000, uptime: 1)

        clock.breakContinuity()
        clock.advanceTimeline(bySampleCount: 16_000)
        #expect(clock.elapsedTimeSeconds(isCapturing: true, now: 1.1) == nil)

        clock.recordRecordedSamples(800, uptime: 1.2)
        #expect(clock.elapsedTimeSeconds(isCapturing: true, now: 1.3) == 2.05)
    }

    @Test func startupEndingDuringAuthorizationNeverAcquiresRunningApplicationOwner() async {
        let fixture = SpeakerStartupFixture()
        let authorization = UUID()

        let started = await MeetingSpeakerAccessibilityStartup.startIfActive(
            isActive: { fixture.isActive },
            requestAuthorization: {
                fixture.end()
                return authorization
            },
            didAuthorize: { _ in fixture.authorize() },
            acquireOwner: { _ in fixture.acquire() },
            startMonitor: { _ in fixture.startMonitor() },
            release: { fixture.release() }
        )

        #expect(started == nil)
        #expect(!fixture.didAcquireOwner)
        #expect(!fixture.didStartMonitor)
        #expect(fixture.releaseCount == 0)
    }

    @Test func startupGateRetainsAuthorizationAfterEnding() {
        let gate = MeetingSpeakerAccessibilityStartupGate()
        let authorization = UUID()

        #expect(gate.currentAuthorization == nil)
        #expect(gate.authorize(authorization))
        #expect(gate.currentAuthorization == authorization)
        #expect(gate.end() == authorization)
        #expect(gate.currentAuthorization == authorization)
        #expect(!gate.isActive)
    }

    @Test func startupReleasesOwnerWhenShutdownWinsDuringAcquisition() async {
        let fixture = SpeakerStartupFixture()
        let authorization = UUID()

        let started = await MeetingSpeakerAccessibilityStartup.startIfActive(
            isActive: { fixture.isActive },
            requestAuthorization: { authorization },
            didAuthorize: { _ in fixture.authorize() },
            acquireOwner: { _ in
                fixture.acquire()
                fixture.end()
            },
            startMonitor: { _ in fixture.startMonitor() },
            release: { fixture.release() }
        )

        #expect(started == nil)
        #expect(fixture.didAcquireOwner)
        #expect(!fixture.didStartMonitor)
        #expect(fixture.releaseCount == 1)
    }

    @Test func startupStopsMonitorAndReleasesOwnerWhenShutdownWinsDuringStart() async {
        let fixture = SpeakerStartupFixture()
        let authorization = UUID()

        let started = await MeetingSpeakerAccessibilityStartup.startIfActive(
            isActive: { fixture.isActive },
            requestAuthorization: { authorization },
            didAuthorize: { _ in fixture.authorize() },
            acquireOwner: { _ in fixture.acquire() },
            startMonitor: { _ in
                fixture.startMonitor()
                fixture.end()
            },
            release: { fixture.release() }
        )

        #expect(started == nil)
        #expect(fixture.didAcquireOwner)
        #expect(fixture.didStartMonitor)
        #expect(fixture.releaseCount == 1)
    }

    @Test func repeatedAccessibilityElementsAreSkippedWithoutMarkingTheReadTruncated() {
        #expect(MeetingSpeakerAXTraversalDecision.evaluate(remaining: 2, depth: 1,
            alreadyVisited: true, withinDeadline: true) == .skipDuplicate)
        #expect(MeetingSpeakerAXTraversalDecision.evaluate(remaining: 0, depth: 1,
            alreadyVisited: false, withinDeadline: true) == .truncated)
    }

    private static func frame(scope: String = "window") -> MeetingSpeakerFrame {
        .init(scope: scope, app: .zoom,
            participants: [.init(id: "window/tile", name: "Example")], activeID: "window/tile")
    }
}

private actor FrameSequence {
    private var frames: [MeetingSpeakerFrame]

    init(_ frames: [MeetingSpeakerFrame]) { self.frames = frames }
    func next() -> MeetingSpeakerFrame { frames.isEmpty ? .init(scope: "", app: .zoom, reason: .unavailable) : frames.removeFirst() }
}

private actor ContinuityBreakingFrameReader {
    private var monitor: MeetingSpeakerAccessibilityMonitor?

    func attach(to monitor: MeetingSpeakerAccessibilityMonitor) { self.monitor = monitor }

    func read() async -> MeetingSpeakerFrame {
        await monitor?.breakContinuity()
        return .init(scope: "window", app: .zoom,
            participants: [.init(id: "window/tile", name: "Example")], activeID: "window/tile")
    }
}

private actor ReadCounter {
    private var reads = 0
    func increment() { reads += 1 }
    func value() -> Int { reads }
}

private actor AuthorizationFixture {
    private var authorization: UUID?

    init(_ authorization: UUID) { self.authorization = authorization }
    func current() -> UUID? { authorization }
    func revoke() { authorization = nil }
}

private final class SpeakerStartupFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var acquired = false
    private var started = false
    private var releases = 0

    var isActive: Bool { lock.withLock { active } }
    var didAcquireOwner: Bool { lock.withLock { acquired } }
    var didStartMonitor: Bool { lock.withLock { started } }
    var releaseCount: Int { lock.withLock { releases } }

    func end() { lock.withLock { active = false } }
    func authorize() -> Bool { lock.withLock { active } }
    func acquire() { lock.withLock { acquired = true } }
    func startMonitor() { lock.withLock { started = true } }
    func release() { lock.withLock { releases += 1 } }
}

private final class SequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double?]

    init(_ values: [Double?]) { self.values = values }

    func next() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}
