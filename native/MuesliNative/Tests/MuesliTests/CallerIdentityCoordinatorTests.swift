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
    var holdRollback = false
    private(set) var captureCalls = 0
    private(set) var attaches: [(CallerHandle, Int64)] = []
    private(set) var notified: [Int64] = []
    private(set) var rolledBack: [CallerAttachment] = []
    var rollBackSucceeds = true
    var attachmentRollback: CallerAttachmentRollback = .automaticCallParticipant
    private var attachGate: CheckedContinuation<Void, Never>?
    private var rollbackGate: CheckedContinuation<Void, Never>?
    var isAttachHeld: Bool { attachGate != nil }
    var isRollbackHeld: Bool { rollbackGate != nil }
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
        return .attached(CallerAttachment(
            meetingID: meetingID,
            personID: CallerHandleNormalizer.personID(forKey: handle.key),
            rollback: attachmentRollback
        ))
    }

    func rollBack(_ attachment: CallerAttachment) async -> Bool {
        rolledBack.append(attachment)
        if holdRollback {
            await withCheckedContinuation { rollbackGate = $0 }
        }
        return rollBackSucceeds
    }

    func releaseAttach() {
        attachGate?.resume()
        attachGate = nil
    }

    func releaseRollback() {
        rollbackGate?.resume()
        rollbackGate = nil
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

    func attach(meetingID: Int64) async -> CallerAttachResult {
        attachCalls += 1
        guard !isAttached else { return .alreadyPresentCaller(personID) }
        isAttached = true
        if attachCalls == 1 {
            await withCheckedContinuation { firstAttachGate = $0 }
        }
        return .attached(CallerAttachment(meetingID: meetingID, personID: personID))
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
        enabled: Bool = true,
        didFailRollBack: @escaping @MainActor (CallerAttachment) -> Void = { _ in }
    ) -> CallerIdentityCoordinator {
        CallerIdentityCoordinator(
            isEnabled: { enabled },
            capture: { await source.capture() },
            attach: { handle, meetingID in await source.attach(handle, meetingID) },
            didAttach: { source.record($0.meetingID) },
            rollBack: { attachment in await source.rollBack(attachment) },
            didFailRollBack: didFailRollBack,
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

    @Test("A failed queued caller detach blocks the resumed capture")
    func failedQueuedCallerDetachBlocksResume() async {
        let detaches = CallerDetachTaskRegistry()
        detaches.enqueue(meetingID: 42) { false }
        detaches.enqueue(meetingID: 42) { true }

        #expect(!(await detaches.wait(for: 42)))
    }

    @Test("A caller storage failure is distinct from a missing meeting")
    func attachStorageFailureIsDistinctFromMissingMeeting() {
        #expect(CallerAttachResult.failed != .meetingMissing)
    }

    @Test("Concurrent caller name saves run one at a time")
    func callerNameSaveGateSerializesConcurrentWrites() async {
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
        #expect(operationCount == 2)
    }

    @Test("A newer caller name save runs after the active save")
    func callerNameSaveGateRunsNewerTextAfterActiveSave() async {
        let gate = CallerNameSaveGate()
        let pause = CallerNameSaveTestPause()
        var currentName = "Ann Lee"
        var savedName: String?
        let firstSave = Task { @MainActor in
            await gate.perform {
                let requestedName = currentName
                await pause.wait()
                savedName = requestedName
                return true
            }
        }
        for _ in 0..<10_000 {
            if await pause.isWaiting { break }
            await Task.yield()
        }
        #expect(await pause.isWaiting)

        currentName = "Ann Lee Smith"
        let newerSave = Task { @MainActor in
            await gate.perform {
                savedName = currentName
                return true
            }
        }
        await Task.yield()
        #expect(savedName == nil)

        await pause.release()
        #expect(await firstSave.value)
        #expect(await newerSave.value)
        #expect(savedName == "Ann Lee Smith")
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
            attach: { _, meetingID in await store.attach(meetingID: meetingID) },
            didAttach: { _ in },
            rollBack: { _ in await store.detach(); return true },
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

    @Test("A failed late rollback is recorded for retry")
    func failedLateRollbackIsRecordedForRetry() async {
        let source = ScriptedCallerSource([.identified(phone)])
        source.holdAttach = true
        source.rollBackSucceeds = false
        source.attachmentRollback = .participantAssociation(
            participantIdentifier: "calendar:bob",
            historyWasAdded: false,
            historyWasSuppressed: false
        )
        var retryAttachment: CallerAttachment?
        let coordinator = makeCoordinator(source, didFailRollBack: { attachment in
            retryAttachment = attachment
        })
        let owner = ObjectIdentifier(AttemptToken())

        coordinator.captureSucceeded(owner: owner, meetingID: 42, phoneAppWasFrontmost: true)
        await waitUntil { source.isAttachHeld }
        coordinator.retire(owner: owner)
        source.releaseAttach()
        await coordinator.settleForTesting()

        #expect(source.rolledBack.count == 1)
        #expect(source.rolledBack.first?.personID == CallerHandleNormalizer.personID(forKey: phone.key))
        #expect(source.rolledBack.first?.meetingID == 42)
        #expect(retryAttachment == CallerAttachment(
            meetingID: 42,
            personID: CallerHandleNormalizer.personID(forKey: phone.key),
            rollback: source.attachmentRollback
        ))
    }

    @Test("Failed caller rollbacks for one meeting remain independent")
    func failedCallerRollbacksForOneMeetingRemainIndependent() {
        let registry = FailedCallerRollbackRegistry()
        let first = CallerAttachment(meetingID: 42, personID: UUID())
        let second = CallerAttachment(meetingID: 42, personID: UUID())

        registry.record(first)
        registry.record(second)

        #expect(registry.pending(for: 42) == [first, second])
        #expect(registry.remove(first))
        #expect(registry.pending(for: 42) == [second])
    }

    @Test("A confirmed attach clears stale rollback receipts for the same caller")
    func confirmedAttachClearsStaleRollbackReceipts() {
        let registry = FailedCallerRollbackRegistry()
        let personID = UUID()
        let original = CallerAttachment(
            meetingID: 42,
            personID: personID,
            rollback: .participantAssociation(
                participantIdentifier: "calendar:bob",
                historyWasAdded: true,
                historyWasSuppressed: false
            )
        )
        let refreshed = CallerAttachment(
            meetingID: 42,
            personID: personID,
            rollback: .participantAssociation(
                participantIdentifier: "calendar:bob",
                historyWasAdded: false,
                historyWasSuppressed: false
            )
        )
        registry.record(original)
        registry.record(refreshed)

        #expect(registry.take(matching: CallerAttachment(meetingID: 42, personID: personID)) == original)
        #expect(registry.pending(for: 42).isEmpty)
    }

    @Test("A current lookup confirms a caller left by a failed rollback")
    func currentLookupConfirmsFailedRollbackAttachment() async {
        let handle = phone
        let personID = CallerHandleNormalizer.personID(forKey: handle.key)
        let expected = CallerAttachment(
            meetingID: 42,
            personID: personID,
            rollback: .participantAssociation(
                participantIdentifier: "calendar:bob",
                historyWasAdded: false,
                historyWasSuppressed: false
            )
        )
        let failedRollbacks = FailedCallerRollbackRegistry()
        failedRollbacks.record(expected)
        var candidate: CallerAttachment?
        let coordinator = CallerIdentityCoordinator(
            isEnabled: { true },
            capture: { .identified(handle) },
            attach: { _, _ in .alreadyPresentCaller(personID) },
            didAttach: { _ in },
            didConfirmExistingCaller: { attachment in
                candidate = attachment
                return failedRollbacks.take(matching: attachment)
            },
            rollBack: { _ in false },
            sleep: { _ in }
        )
        let owner = ObjectIdentifier(AttemptToken())

        coordinator.captureSucceeded(owner: owner, meetingID: 42, phoneAppWasFrontmost: true)
        await coordinator.settleForTesting()

        #expect(candidate == CallerAttachment(meetingID: 42, personID: personID))
        #expect(coordinator.retire(owner: owner) == expected)
        #expect(failedRollbacks.pending(for: 42).isEmpty)
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

    @Test("A lookup retired on pause cannot attach a later Phone call after resume")
    func pausedLookupCannotAttachAfterResume() async {
        let resumedPhone = CallerHandleNormalizer.phone("+1 202 555 0199", region: nil)!
        let source = ScriptedCallerSource([.identified(phone), .identified(resumedPhone)])
        source.holdCaptureCall = 0
        let coordinator = makeCoordinator(source)
        let token = AttemptToken()
        let owner = ObjectIdentifier(token)

        coordinator.captureSucceeded(owner: owner, meetingID: 42, phoneAppWasFrontmost: true)
        await waitUntil { source.isCaptureHeld }
        coordinator.retire(owner: owner)
        coordinator.captureSucceeded(owner: owner, meetingID: 42, phoneAppWasFrontmost: true)
        await waitUntil { source.attaches.count == 1 }
        source.releaseCapture()
        await coordinator.settleForTesting()

        #expect(source.attaches.count == 1)
        #expect(source.attaches.first?.0.key == resumedPhone.key)
        #expect(source.notified == [42])
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

        #expect(source.rolledBack.map(\.meetingID) == [9])
        #expect(source.rolledBack.first?.personID == CallerHandleNormalizer.personID(forKey: phone.key))
        #expect(source.notified.isEmpty)
    }

    @Test("Waiting for caller lookups waits for their late rollback")
    func pendingLookupWaitsForLateRollback() async {
        let source = ScriptedCallerSource([.identified(phone)])
        source.holdAttach = true
        source.holdRollback = true
        let coordinator = makeCoordinator(source)
        let owner = ObjectIdentifier(AttemptToken())

        coordinator.captureSucceeded(owner: owner, meetingID: 42, phoneAppWasFrontmost: true)
        await waitUntil { source.isAttachHeld }
        _ = coordinator.retire(owner: owner)
        source.releaseAttach()
        await waitUntil { source.isRollbackHeld }

        var didFinishWaiting = false
        let waitTask = Task { @MainActor in
            await coordinator.waitForPendingLookups()
            didFinishWaiting = true
        }
        await Task.yield()
        #expect(!didFinishWaiting)

        source.releaseRollback()
        await waitTask.value

        #expect(didFinishWaiting)
        #expect(source.rolledBack.map(\.meetingID) == [42])
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
