import Foundation
import Testing
@testable import MuesliNativeApp

/// Compiled synthetic values, not captured Signal AX trees or validated UI profiles.
@Suite("Signal call detection")
struct SignalCallDetectionAdapterTests {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(
        bundle: String = "org.whispersystems.signal-desktop", pid: Int32 = 42,
        launch: String = "process-a", surface: String = "document-a", origin: String? = nil
    ) -> CallDetectionSource {
        .init(bundleID: bundle, processID: pid, processLaunchID: launch, surfaceID: surface, origin: origin)
    }

    private func snapshot(
        source: CallDetectionSource? = nil, age: TimeInterval = 0,
        content: SignalCallDetectionContent = .call,
        connection: SignalCallDetectionConnection = .accepted,
        generation: String = "call-a", hangup: Bool = true, microphone: Bool = true,
        roster: CallDetectionRoster = .unknown
    ) -> SignalCallDetectionSnapshot {
        let identity = source ?? self.source()
        return .init(source: identity, observedAt: instant.addingTimeInterval(-age), profile: .syntheticV1,
                     surfaces: [.init(source: identity, callGeneration: generation, content: content,
                                      connection: connection, hasHangupControl: hangup,
                                      hasMicrophoneControl: microphone, roster: roster)])
    }

    private func adapter(_ values: [SignalCallDetectionSnapshotRead]) -> SignalCallDetectionAdapter {
        let date = instant
        return .init(provider: SignalFixtureProvider(values), now: { date })
    }

    private func observation(_ result: CallDetectionResult) throws -> CallDetectionObservation {
        guard case let .observation(value) = result else {
            Issue.record("Expected scoped connected observation, received \(result)")
            throw SignalFixtureError.unavailable
        }
        return value
    }

    @Test("Only accepted scoped controls yield connected evidence")
    func connected() async throws {
        let result = await adapter([.snapshot(snapshot(age: 2))]).observe()
        let value = try observation(result)
        #expect(value.service == .signal && value.phase == .connected)
        #expect(value.source == source())
        #expect(value.observedAt == instant.addingTimeInterval(-2))
        #expect(value.evidence == [.scopedCallControls, .connectedState])
        #expect(value.roster == .unknown)
        #expect(UUID(uuidString: value.callToken) != nil)
    }

    @Test("Idle and voice message activity never becomes a connected call",
          arguments: [SignalCallDetectionContent.idleChat, .voiceNoteRecording, .voiceNotePlayback])
    func nonCallContent(content: SignalCallDetectionContent) async {
        let result = await adapter([.snapshot(snapshot(content: content))]).observe()
        #expect(result == .unavailable(.noSource))
    }

    @Test("Ringing, prejoin, pending approval and reconnection fail closed despite controls",
          arguments: [SignalCallDetectionConnection.ringing, .prejoin, .pendingApproval,
                      .connecting, .reconnecting, .ended, .unknown])
    func notAccepted(connection: SignalCallDetectionConnection) async {
        let result = await adapter([.snapshot(snapshot(connection: connection))]).observe()
        #expect(result == .unavailable(.noSource))
    }

    @Test("Both controls must belong to the accepted call scope")
    func controlsRequired() async {
        for value in [snapshot(hangup: false), snapshot(microphone: false)] {
            let result = await adapter([.snapshot(value)]).observe()
            #expect(result == .unavailable(.unsupported))
        }
    }

    @Test("Snapshot age is inclusive at five seconds and never admits future data")
    func freshnessProperty() async {
        // Independent boundary table catches widening the interval or taking abs(age).
        for age in [-100.0, -0.001, 0, 0.001, 1, 4.999, 5, 5.001, 6, 100] {
            let result = await adapter([.snapshot(snapshot(age: age))]).observe()
            if age >= 0 && age <= 5 {
                guard case .observation = result else {
                    Issue.record("Fresh snapshot rejected at age \(age)")
                    continue
                }
            } else {
                #expect(result == .unavailable(.stale))
            }
        }
    }

    @Test("Permissions and provider failures cannot reuse a connected session")
    func failuresRotateToken() async throws {
        for reason in [CallDetectionUnavailableReason.permissionRequired, .noSource, .unsupported,
                       .timedOut, .ambiguous, .stale, .sourceMismatch] {
            let detector = adapter([.snapshot(snapshot()), .unavailable(reason), .snapshot(snapshot())])
            let before = try observation(await detector.observe())
            let failure = await detector.observe()
            #expect(failure == .unavailable(reason))
            let after = try observation(await detector.observe())
            #expect(before.callToken != after.callToken)
        }
    }

    @Test("Wrong source and malformed desktop scope fail closed")
    func sourceValidation() async {
        for identity in [source(bundle: "org.whispersystems.signal-desktop.beta"), source(pid: 0),
                         source(launch: ""), source(surface: ""), source(origin: "https://signal.org")] {
            let result = await adapter([.snapshot(snapshot(source: identity))]).observe()
            #expect(result == .unavailable(.sourceMismatch))
        }
        let correct = snapshot()
        let wrongSurface = snapshot(source: source(pid: 43)).surfaces[0]
        let mismatch = SignalCallDetectionSnapshot(source: correct.source, observedAt: instant,
                                                   profile: .syntheticV1, surfaces: [wrongSurface])
        let result = await adapter([.snapshot(mismatch)]).observe()
        #expect(result == .unavailable(.sourceMismatch))
    }

    @Test("Foreign idle and voice-note surfaces invalidate the entire source snapshot")
    func foreignNonCallSurfaces() async {
        let first = snapshot()
        for content in [SignalCallDetectionContent.idleChat, .voiceNoteRecording, .voiceNotePlayback] {
            for foreign in [source(pid: 43), source(surface: "document-b"), source(origin: "https://other.invalid")] {
                let other = snapshot(source: foreign, content: content)
                let mixed = SignalCallDetectionSnapshot(source: first.source, observedAt: instant,
                                                         profile: .syntheticV1, surfaces: first.surfaces + other.surfaces)
                let result = await adapter([.snapshot(mixed)]).observe()
                #expect(result == .unavailable(.sourceMismatch))
            }
        }
    }

    @Test("Multiple call scopes are ambiguous, including a prejoin competitor")
    func ambiguity() async {
        let first = snapshot()
        let second = snapshot(source: source(surface: "document-b"), connection: .prejoin)
        let value = SignalCallDetectionSnapshot(source: first.source, observedAt: instant,
                                               profile: .syntheticV1, surfaces: first.surfaces + second.surfaces)
        let result = await adapter([.snapshot(value)]).observe()
        #expect(result == .unavailable(.ambiguous))
    }

    @Test("Unsupported profiles and oversized inventories cannot yield positives")
    func unsupportedProfile() async {
        let first = snapshot()
        for value in [
            SignalCallDetectionSnapshot(source: first.source, observedAt: instant,
                                        profile: .unsupported, surfaces: first.surfaces),
            SignalCallDetectionSnapshot(source: first.source, observedAt: instant,
                                        profile: .syntheticV1, surfaces: Array(repeating: first.surfaces[0], count: 9))
        ] {
            let result = await adapter([.snapshot(value)]).observe()
            #expect(result == .unavailable(.unsupported))
        }
    }

    @Test("Call tokens persist during connection and rotate for every new scope")
    func tokenLifecycle() async throws {
        let detector = adapter([.snapshot(snapshot()), .snapshot(snapshot()),
                                .snapshot(snapshot(generation: "call-b")),
                                .snapshot(snapshot(source: source(surface: "document-b"))),
                                .snapshot(snapshot(source: source(launch: "process-b"))),
                                .snapshot(snapshot(source: source(pid: 43)))])
        let a = try observation(await detector.observe())
        let stable = try observation(await detector.observe())
        #expect(a.callToken == stable.callToken)
        var previous = stable.callToken
        for _ in 0..<4 {
            let next = try observation(await detector.observe())
            #expect(next.callToken != previous)
            previous = next.callToken
        }
    }

    @Test("Each source component alone rotates the token while call generation stays unchanged")
    func isolatedSourceRotation() async throws {
        for changed in [source(surface: "document-b"), source(launch: "process-b"), source(pid: 43)] {
            let detector = adapter([.snapshot(snapshot()), .snapshot(snapshot(source: changed))])
            let before = try observation(await detector.observe())
            let after = try observation(await detector.observe())
            #expect(before.callToken != after.callToken)
        }
    }

    @Test("Reconnecting and ended states rotate tokens even when generation is reused")
    func reconnect() async throws {
        for connection in [SignalCallDetectionConnection.reconnecting, .ended, .ringing] {
            let detector = adapter([.snapshot(snapshot()), .snapshot(snapshot(connection: connection)),
                                    .snapshot(snapshot())])
            let a = try observation(await detector.observe())
            _ = await detector.observe()
            let b = try observation(await detector.observe())
            #expect(a.callToken != b.callToken)
        }
    }

    @Test("Roster knowledge degrades explicitly, with stable call-local participant IDs")
    func rosterKnowledge() async throws {
        let detector = adapter([.snapshot(snapshot(roster: .complete(["peer-a", "peer-b"]))),
                                .snapshot(snapshot(roster: .partial(["peer-a"]))),
                                .snapshot(snapshot(roster: .unknown)),
                                .snapshot(snapshot(roster: .complete(["peer-a", "peer-b"])))])
        let a = try observation(await detector.observe())
        let b = try observation(await detector.observe())
        let unknown = try observation(await detector.observe())
        let restored = try observation(await detector.observe())
        guard case let .complete(all) = a.roster, case let .partial(part) = b.roster else {
            Issue.record("Roster completeness was invented or lost")
            return
        }
        #expect(all.count == 2 && part.count == 1 && part.isSubset(of: all))
        #expect(all.isDisjoint(with: ["peer-a", "peer-b"]))
        #expect(all.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(unknown.roster == .unknown)
        #expect(restored.roster == a.roster)
        #expect(a.callToken == b.callToken && b.callToken == unknown.callToken)
        #expect(restored.callToken == a.callToken)
    }

    @Test("Empty complete and invalid rosters remain unknown; new sessions remap IDs")
    func rosterValidation() async throws {
        for roster in [CallDetectionRoster.complete([]), .partial([""]),
                       .complete(Set((0..<129).map { "peer-\($0)" }))] {
            let value = try observation(await adapter([.snapshot(snapshot(roster: roster))]).observe())
            #expect(value.roster == .unknown)
        }
        let detector = adapter([.snapshot(snapshot(roster: .complete(["peer-a"]))),
                                .snapshot(snapshot(generation: "new-call", roster: .complete(["peer-a"])))])
        let before = try observation(await detector.observe())
        let after = try observation(await detector.observe())
        #expect(before.roster != after.roster)
    }

    @Test("Cancellation before observation performs no provider read")
    func preCancelled() async {
        let provider = SignalControlledProvider(.snapshot(snapshot()))
        let date = instant
        let detector = SignalCallDetectionAdapter(provider: provider, now: { date })
        let barrier = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in barrier.stream { break }
            return await detector.observe()
        }
        task.cancel()
        barrier.continuation.finish()
        let result = await task.value
        #expect(result == .unavailable(.timedOut))
        let count = await provider.readCount
        #expect(count == 0)
    }

    @Test("Timeout returns without draining a provider that ignores cancellation")
    func boundedTimeout() async {
        let provider = SignalControlledProvider(.snapshot(snapshot()))
        let date = instant
        let detector = SignalCallDetectionAdapter(provider: provider, now: { date }, timeout: 0.2)
        let clock = ContinuousClock()
        let start = clock.now
        let read = Task { await detector.observe() }
        guard await provider.waitUntilEntered() else {
            Issue.record("Provider did not enter before fixture synchronization deadline")
            await provider.release()
            read.cancel()
            return
        }
        let result = await read.value
        #expect(result == .unavailable(.timedOut))
        #expect(start.duration(to: clock.now) < .seconds(0.75))
        // The timed-out call is still outstanding, so no second native read.
        let overlapping = await detector.observe()
        #expect(overlapping == .unavailable(.ambiguous))
        let count = await provider.readCount
        #expect(count == 1)
        await provider.release()
    }

    @Test("Caller cancellation returns promptly and retains the outstanding read slot")
    func callerCancellation() async {
        let provider = SignalControlledProvider(.snapshot(snapshot()))
        let date = instant
        let detector = SignalCallDetectionAdapter(provider: provider, now: { date })
        let read = Task { await detector.observe() }
        guard await provider.waitUntilEntered() else {
            Issue.record("Provider did not enter before fixture synchronization deadline")
            await provider.release()
            read.cancel()
            return
        }
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        read.cancel()
        let result = await read.value
        #expect(result == .unavailable(.timedOut))
        #expect(cancelledAt.duration(to: clock.now) < .seconds(0.75))
        let overlapping = await detector.observe()
        #expect(overlapping == .unavailable(.ambiguous))
        let count = await provider.readCount
        #expect(count == 1)
        await provider.release()
    }

    @Test("An overlapping request invalidates a pending connected result")
    func pendingOverlap() async throws {
        let provider = SignalControlledProvider(.snapshot(snapshot()))
        let date = instant
        let detector = SignalCallDetectionAdapter(provider: provider, now: { date })
        let read = Task { await detector.observe() }
        guard await provider.waitUntilEntered() else {
            Issue.record("Provider did not enter before fixture synchronization deadline")
            await provider.release()
            read.cancel()
            return
        }
        let overlapping = await detector.observe()
        #expect(overlapping == .unavailable(.ambiguous))
        await provider.release()
        let late = await read.value
        #expect(late == .unavailable(.sourceMismatch))
        let fresh = try observation(await detector.observe())
        #expect(fresh.phase == .connected)
        let count = await provider.readCount
        #expect(count == 2)
    }

    @Test("Freshness is rechecked after the provider returns")
    func freshnessAfterRead() async {
        let provider = SignalControlledProvider(.snapshot(snapshot()))
        let time = SignalFixtureClock(instant)
        let detector = SignalCallDetectionAdapter(provider: provider, now: { time.read() })
        let read = Task { await detector.observe() }
        guard await provider.waitUntilEntered() else {
            Issue.record("Provider did not enter before fixture synchronization deadline")
            await provider.release()
            read.cancel()
            return
        }
        time.advance(by: 5.001)
        await provider.release()
        let result = await read.value
        #expect(result == .unavailable(.stale))
    }

    @Test("Production inventory boundaries fail closed without emitting guessed call evidence")
    func inventoryBoundaries() async {
        let process = SignalCallDetectionProcess(bundleID: "org.whispersystems.signal-desktop",
                                                 processID: 42, launchedAt: instant)
        let date = instant
        let cases: [(SignalInventoryFixture, CallDetectionUnavailableReason)] = [
            (.init(before: [], after: []), .noSource),
            (.init(before: [process], after: [process], trusted: false), .permissionRequired),
            (.init(before: [process, process], after: [process, process]), .ambiguous),
            (.init(before: [process], after: [process], windows: .count(9)), .unsupported),
            (.init(before: [process], after: [process], windows: .count(0)), .noSource),
            (.init(before: [process], after: [], windows: .count(1)), .sourceMismatch),
            (.init(before: [process], after: [process], windows: .unavailable(.timedOut)), .timedOut),
            (.init(before: [process], after: [process], windows: .count(1)), .unsupported),
            (.init(before: [process], after: [process], windows: .count(8)), .unsupported),
            (.init(before: [.init(bundleID: process.bundleID, processID: 42, launchedAt: nil)],
                   after: [process]), .sourceMismatch),
            (.init(before: [process], after: [.init(bundleID: process.bundleID, processID: 42,
                                                   launchedAt: instant.addingTimeInterval(1))]), .sourceMismatch),
            (.init(before: [process], after: [process, process]), .ambiguous),
            (.init(before: [.init(bundleID: "other.app", processID: 42, launchedAt: instant)],
                   after: []), .noSource)
        ]
        for (inventory, expected) in cases {
            let provider = SignalCallDetectionSystemSnapshotProvider(inventory: inventory, now: { date })
            let result = await SignalCallDetectionAdapter(provider: provider, now: { date }).observe()
            #expect(result == .unavailable(expected))
        }
    }
}

private enum SignalFixtureError: Error { case unavailable }

private actor SignalFixtureProvider: SignalCallDetectionSnapshotProvider {
    private var values: [SignalCallDetectionSnapshotRead]
    init(_ values: [SignalCallDetectionSnapshotRead]) { self.values = values }
    func snapshot(deadline: Date) async -> SignalCallDetectionSnapshotRead {
        guard !values.isEmpty else { return .unavailable(.noSource) }
        return values.removeFirst()
    }
}

/// Blocks the actual provider boundary, intentionally ignoring cancellation.
/// Later reads are immediate, making slot release and late-result handling visible.
private actor SignalControlledProvider: SignalCallDetectionSnapshotProvider {
    private let value: SignalCallDetectionSnapshotRead
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var watchdog: Task<Void, Never>?
    private(set) var readCount = 0
    init(_ value: SignalCallDetectionSnapshotRead) { self.value = value }
    func snapshot(deadline: Date) async -> SignalCallDetectionSnapshotRead {
        readCount += 1
        if readCount == 1 && !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                // Independent fixture escape hatch: a broken timeout that drains
                // the provider fails its elapsed-time assertion instead of hanging.
                watchdog = Task.detached {
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { return }
                    await self.release()
                }
            }
        }
        return value
    }
    func waitUntilEntered() async -> Bool {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: .seconds(1))
        while continuation == nil && clock.now < limit {
            do { try await Task.sleep(for: .milliseconds(1)) }
            catch { return false }
        }
        return continuation != nil
    }
    func release() {
        released = true
        watchdog?.cancel()
        watchdog = nil
        continuation?.resume()
        continuation = nil
    }
}

private final class SignalFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor SignalInventoryFixture: SignalCallDetectionInventoryReading {
    private let before: [SignalCallDetectionProcess]
    private let after: [SignalCallDetectionProcess]
    private let trusted: Bool
    private let windows: SignalCallDetectionWindowRead
    private var processReads = 0
    init(before: [SignalCallDetectionProcess], after: [SignalCallDetectionProcess],
         trusted: Bool = true, windows: SignalCallDetectionWindowRead = .count(1)) {
        self.before = before; self.after = after; self.trusted = trusted; self.windows = windows
    }
    func processes() async -> [SignalCallDetectionProcess] {
        defer { processReads += 1 }
        return processReads == 0 ? before : after
    }
    func isAccessibilityTrusted() async -> Bool { trusted }
    func windowCount(process: SignalCallDetectionProcess, deadline: Date) async -> SignalCallDetectionWindowRead {
        // Catch accidentally querying a different PID/launch scope through the
        // actual production-provider seam; no AX calls are made by this fixture.
        #expect(process == before.first)
        return windows
    }
}
