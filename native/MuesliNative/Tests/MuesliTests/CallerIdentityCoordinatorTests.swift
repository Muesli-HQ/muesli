import Foundation
import MuesliCore
@testable import MuesliNativeApp
import Testing

/// Drives the coordinator's injected capture and sleep so tests can hold a
/// lookup mid-flight, retire the attempt, and then let the lookup finish.
@MainActor
final class ScriptedCallerSource {
    var results: [CallerCaptureResult]
    var holdCaptureCall: Int?
    var holdSleeps = false
    var holdAttach = false
    private(set) var captureCalls = 0
    private(set) var attaches: [(CallerHandle, Int64)] = []
    private(set) var notified: [Int64] = []
    private(set) var rolledBack: [(UUID, Int64)] = []
    private var attachGate: CheckedContinuation<Void, Never>?
    var isAttachHeld: Bool { attachGate != nil }
    private var captureGate: CheckedContinuation<Void, Never>?
    private var sleepGate: CheckedContinuation<Void, Never>?
    var isCaptureHeld: Bool { captureGate != nil }
    var isSleepHeld: Bool { sleepGate != nil }

    init(_ results: [CallerCaptureResult]) {
        self.results = results
    }

    func capture() async -> CallerCaptureResult {
        let call = captureCalls
        captureCalls += 1
        if call == holdCaptureCall {
            await withCheckedContinuation { captureGate = $0 }
        }
        return call < results.count ? results[call] : .unavailable(.noHandle)
    }

    func sleep() async throws {
        if holdSleeps {
            await withCheckedContinuation { sleepGate = $0 }
        }
        try Task.checkCancellation()
    }

    func attach(_ handle: CallerHandle, _ meetingID: Int64) async -> CallerAttachResult {
        attaches.append((handle, meetingID))
        if holdAttach {
            await withCheckedContinuation { attachGate = $0 }
        }
        return .attached(CallerHandleNormalizer.personID(forKey: handle.key))
    }

    func rollBack(_ personID: UUID, _ meetingID: Int64) {
        rolledBack.append((personID, meetingID))
    }

    func releaseAttach() {
        attachGate?.resume()
        attachGate = nil
    }

    func releaseCapture() {
        captureGate?.resume()
        captureGate = nil
    }

    func releaseSleep() {
        sleepGate?.resume()
        sleepGate = nil
    }

    func record(_ meetingID: Int64) {
        notified.append(meetingID)
    }
}

private final class AttemptToken {}

private actor CallerDetachTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ResumedCallerAttachmentStore {
    private let personID: UUID
    private var isAttached = false
    private var captureCalls = 0
    private var attachCalls = 0
    private var firstAttachGate: CheckedContinuation<Void, Never>?

    init(personID: UUID) {
        self.personID = personID
    }

    func recordCapture() {
        captureCalls += 1
    }

    func attach() async -> CallerAttachResult {
        attachCalls += 1
        guard !isAttached else { return .alreadyPresent }
        isAttached = true
        if attachCalls == 1 {
            await withCheckedContinuation { firstAttachGate = $0 }
        }
        return .attached(personID)
    }

    func detach() {
        isAttached = false
    }

    func releaseFirstAttach() {
        firstAttachGate?.resume()
        firstAttachGate = nil
    }

    var snapshot: (captureCalls: Int, attachCalls: Int, isAttached: Bool) {
        (captureCalls, attachCalls, isAttached)
    }
}

private actor CallerNameSaveTestPause {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Caller identity coordinator")
@MainActor
struct CallerIdentityCoordinatorTests {
    private let phone = CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!

    private func makeCoordinator(
        _ source: ScriptedCallerSource,
        enabled: Bool = true
    ) -> CallerIdentityCoordinator {
        CallerIdentityCoordinator(
            isEnabled: { enabled },
            capture: { await source.capture() },
            attach: { handle, meetingID in await source.attach(handle, meetingID) },
            didAttach: { source.record($0) },
            rollBack: { personID, meetingID in await source.rollBack(personID, meetingID) },
            sleep: { _ in try await source.sleep() }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    @Test("A resumed capture waits until the previous caller detach finishes")
    func resumedCaptureWaitsForPriorDetach() async {
        let detaches = CallerDetachTaskRegistry()
        let gate = CallerDetachTestGate()
        var detachFinished = false
        var captureStarted = false

        detaches.enqueue(meetingID: 42) {
            await gate.wait()
            detachFinished = true
            return true
        }
        for _ in 0..<10_000 {
            if await gate.isWaiting { break }
            await Task.yield()
        }

        let capture = Task { @MainActor in
            let didDetach = await detaches.wait(for: 42)
            captureStarted = true
            return didDetach
        }
        await Task.yield()
        #expect(!captureStarted)

        await gate.open()
        #expect(await capture.value)
        #expect(detachFinished)
        #expect(captureStarted)
    }

    @Test("Concurrent caller name saves do not overlap")
    func callerNameSaveGateCoalescesConcurrentWrites() async {
        let gate = CallerNameSaveGate()
        let pause = CallerNameSaveTestPause()
        var operationCount = 0
        let firstSave = Task { @MainActor in
            await gate.perform {
                operationCount += 1
                await pause.wait()
                return true
            }
        }
        for _ in 0..<10_000 {
            if await pause.isWaiting { break }
            await Task.yield()
        }
        #expect(await pause.isWaiting)

        let overlappingSave = Task { @MainActor in
            await gate.perform {
                operationCount += 1
                return true
            }
        }
        await Task.yield()

        #expect(operationCount == 1)
        await pause.release()
        #expect(await firstSave.value)
        #expect(await overlappingSave.value)
        #expect(operationCount == 1)
    }

    @Test("A late rollback cannot remove the resumed capture's caller")
    func lateRollbackDoesNotRemoveResumedCallersAttachment() async {
        let id = CallerHandleNormalizer.personID(forKey: phone.key)
        let handle = phone
        let store = ResumedCallerAttachmentStore(personID: id)
        let coordinator = CallerIdentityCoordinator(
            isEnabled: { true },
            capture: {
                await store.recordCapture()
                return .identified(handle)
            },
            attach: { _, _ in await store.attach() },
            didAttach: { _ in },
            rollBack: { _, _ in await store.detach() },
            sleep: { _ in }
        )
        let discardedOwner = ObjectIdentifier(AttemptToken())
        let resumedOwner = ObjectIdentifier(AttemptToken())

        coordinator.captureSucceeded(owner: discardedOwner, meetingID: 42, phoneAppWasFrontmost: true)
        for _ in 0..<10_000 {
            if await store.snapshot.attachCalls > 0 { break }
            await Task.yield()
        }
        _ = coordinator.retire(owner: discardedOwner)
        coordinator.captureSucceeded(owner: resumedOwner, meetingID: 42, phoneAppWasFrontmost: true)
        for _ in 0..<10_000 {
            if await store.snapshot.captureCalls == 2 { break }
            await Task.yield()
        }
        #expect(await store.snapshot.captureCalls == 2)
        #expect(await store.snapshot.attachCalls == 1)

        await store.releaseFirstAttach()
        await coordinator.settleForTesting()
        let snapshot = await store.snapshot
        #expect(snapshot.captureCalls == 2)
        #expect(snapshot.attachCalls == 2)
        #expect(snapshot.isAttached)
    }

    @Test("Nothing runs while the setting is off")
    func disabledDoesNothing() async {
        let source = ScriptedCallerSource([.identified(phone)])
        let coordinator = makeCoordinator(source, enabled: false)
        coordinator.captureSucceeded(owner: ObjectIdentifier(AttemptToken()), meetingID: 1, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()
        #expect(source.captureCalls == 0)
    }

    @Test("A concurrent Phone call is not linked when another app is frontmost")
    func onlyPhoneFrontmostStartsCallerLookup() async {
        let source = ScriptedCallerSource([.identified(phone)])
        let coordinator = makeCoordinator(source)
        coordinator.captureSucceeded(
            owner: ObjectIdentifier(AttemptToken()),
            meetingID: 1,
            phoneAppWasFrontmost: false
        )
        await coordinator.settleForTesting()
        #expect(source.captureCalls == 0)
        #expect(source.attaches.isEmpty)
    }

    @Test("A result attaches to the recording that started the lookup")
    func identifiedAttachesToOwnMeeting() async {
        let source = ScriptedCallerSource([.identified(phone)])
        source.holdCaptureCall = 0
        let coordinator = makeCoordinator(source)
        let first = AttemptToken()
        let second = AttemptToken()

        coordinator.captureSucceeded(owner: ObjectIdentifier(first), meetingID: 1, phoneAppWasFrontmost: true)
        await waitUntil { source.isCaptureHeld }
        coordinator.captureSucceeded(owner: ObjectIdentifier(second), meetingID: 2, phoneAppWasFrontmost: true)
        source.releaseCapture()
        await coordinator.settleForTesting()

        #expect(source.attaches.map(\.1) == [1])
        #expect(source.attaches.first?.0 == phone)
        #expect(source.notified == [1])
    }

    @Test("A missing caller is retried until one is shown")
    func retriesThenIdentifies() async {
        let source = ScriptedCallerSource([.unavailable(.noHandle), .unavailable(.noActiveCall), .identified(phone)])
        let coordinator = makeCoordinator(source)
        coordinator.captureSucceeded(owner: ObjectIdentifier(AttemptToken()), meetingID: 7, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()
        #expect(source.captureCalls == 3)
        #expect(source.attaches.map(\.1) == [7])
    }

    @Test("Lookups stop after three attempts")
    func stopsAfterThreeAttempts() async {
        let source = ScriptedCallerSource([.unavailable(.incomplete), .unavailable(.noHandle), .unavailable(.noHandle), .identified(phone)])
        let coordinator = makeCoordinator(source)
        coordinator.captureSucceeded(owner: ObjectIdentifier(AttemptToken()), meetingID: 7, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()
        #expect(source.captureCalls == 3)
        #expect(source.attaches.isEmpty)
    }

    @Test("Stopping before a retry prevents reading the next call")
    func stopBeforeRetryPreventsAttach() async {
        let source = ScriptedCallerSource([.unavailable(.noHandle), .identified(phone)])
        source.holdSleeps = true
        let coordinator = makeCoordinator(source)
        let token = AttemptToken()

        coordinator.captureSucceeded(owner: ObjectIdentifier(token), meetingID: 1, phoneAppWasFrontmost: true)
        await waitUntil { source.isSleepHeld }
        coordinator.retire(owner: ObjectIdentifier(token))
        source.releaseSleep()
        await coordinator.settleForTesting()

        #expect(source.captureCalls == 1)
        #expect(source.attaches.isEmpty)
    }

    @Test("A lookup that finishes after its recording ended is dropped")
    func captureReturningAfterRetireIsDropped() async {
        let source = ScriptedCallerSource([.identified(phone)])
        source.holdCaptureCall = 0
        let coordinator = makeCoordinator(source)
        let token = AttemptToken()

        coordinator.captureSucceeded(owner: ObjectIdentifier(token), meetingID: 1, phoneAppWasFrontmost: true)
        await waitUntil { source.isCaptureHeld }
        coordinator.retire(owner: ObjectIdentifier(token))
        source.releaseCapture()
        await coordinator.settleForTesting()

        #expect(source.attaches.isEmpty)
        #expect(source.notified.isEmpty)
    }

    @Test("Resuming a meeting is a new capture attempt")
    func resumeIsNewAttempt() async {
        let source = ScriptedCallerSource([.identified(phone), .identified(phone)])
        let coordinator = makeCoordinator(source)
        coordinator.captureSucceeded(owner: ObjectIdentifier(AttemptToken()), meetingID: 3, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()
        coordinator.captureSucceeded(owner: ObjectIdentifier(AttemptToken()), meetingID: 3, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()
        #expect(source.captureCalls == 2)
        #expect(source.attaches.map(\.1) == [3, 3])
    }

    @Test("Ambiguous callers and missing permission stop without attaching", arguments: [
        CallerCaptureResult.ambiguous,
        .permissionRequired,
        .unavailable(.appNotRunning),
    ])
    func terminalResultsStop(_ result: CallerCaptureResult) async {
        let source = ScriptedCallerSource([result, .identified(phone)])
        let coordinator = makeCoordinator(source)
        coordinator.captureSucceeded(owner: ObjectIdentifier(AttemptToken()), meetingID: 1, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()
        #expect(source.captureCalls == 1)
        #expect(source.attaches.isEmpty)
    }

    @Test("Finished lookups are not retained")
    func finishedLookupsAreReleased() async {
        let source = ScriptedCallerSource([.identified(phone)])
        let coordinator = makeCoordinator(source)
        coordinator.captureSucceeded(owner: ObjectIdentifier(AttemptToken()), meetingID: 1, phoneAppWasFrontmost: true)
        await waitUntil { source.notified == [1] && coordinator.pendingLookupCount == 0 }
        #expect(source.notified == [1])
        #expect(coordinator.pendingLookupCount == 0)
    }

    @Test("Retiring an attempt reports the caller it attached")
    func retireReportsTheAttemptsAttachment() async {
        let source = ScriptedCallerSource([.identified(phone)])
        let coordinator = makeCoordinator(source)
        let token = AttemptToken()
        coordinator.captureSucceeded(owner: ObjectIdentifier(token), meetingID: 4, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()

        let attachment = coordinator.retire(owner: ObjectIdentifier(token))
        #expect(attachment == CallerAttachment(meetingID: 4, personID: CallerHandleNormalizer.personID(forKey: phone.key)))
        #expect(coordinator.retire(owner: ObjectIdentifier(token)) == nil)
    }

    @Test("An attach that lands after its recording ended is rolled back")
    func attachFinishingAfterRetireIsRolledBack() async {
        let source = ScriptedCallerSource([.identified(phone)])
        source.holdAttach = true
        let coordinator = makeCoordinator(source)
        let token = AttemptToken()

        coordinator.captureSucceeded(owner: ObjectIdentifier(token), meetingID: 9, phoneAppWasFrontmost: true)
        await waitUntil { source.isAttachHeld }
        #expect(coordinator.retire(owner: ObjectIdentifier(token)) == nil)
        source.releaseAttach()
        await coordinator.settleForTesting()

        #expect(source.rolledBack.map(\.1) == [9])
        #expect(source.rolledBack.first?.0 == CallerHandleNormalizer.personID(forKey: phone.key))
        #expect(source.notified.isEmpty)
    }

    @Test("Turning the setting off cancels every lookup")
    func retireAllCancels() async {
        let source = ScriptedCallerSource([.identified(phone)])
        source.holdCaptureCall = 0
        let coordinator = makeCoordinator(source)
        coordinator.captureSucceeded(owner: ObjectIdentifier(AttemptToken()), meetingID: 1, phoneAppWasFrontmost: true)
        await waitUntil { source.isCaptureHeld }
        coordinator.retireAll()
        source.releaseCapture()
        await coordinator.settleForTesting()
        #expect(source.attaches.isEmpty)
    }

    @Test("Turning the setting off returns attached callers for rollback")
    func retireAllReturnsAttachments() async {
        let source = ScriptedCallerSource([.identified(phone)])
        let coordinator = makeCoordinator(source)
        let token = AttemptToken()
        coordinator.captureSucceeded(owner: ObjectIdentifier(token), meetingID: 2, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()

        let attachments = coordinator.retireAll()

        #expect(attachments == [CallerAttachment(
            meetingID: 2,
            personID: CallerHandleNormalizer.personID(forKey: phone.key)
        )])
    }
}
