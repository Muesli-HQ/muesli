import CloudKit
import Foundation
import Testing
@testable import MuesliNativeApp

private actor ICloudSyncTestSignal {
    private var pendingSignals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        if waiters.isEmpty {
            pendingSignals += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func wait() async {
        if pendingSignals > 0 {
            pendingSignals -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@Suite("iCloud sync callback deadline")
struct ICloudSyncCallbackDeadlineTests {
    @Test("returns a callback result before the deadline")
    func callbackWins() async throws {
        let value: Int = try await ICloudSyncCallbackDeadline.wait(timeout: 0.1) { finish in
            finish(.success(42))
            return nil
        }

        #expect(value == 42)
    }

    @Test("times out and cancels an unfinished CloudKit operation")
    func timeoutCancelsOperation() async {
        let operation = CKFetchRecordsOperation()

        do {
            let _: Int = try await ICloudSyncCallbackDeadline.wait(timeout: 0.01) { _ in
                operation
            }
            Issue.record("Expected the CloudKit callback deadline to expire")
        } catch let error as ICloudSyncDeadlineError {
            #expect(error == .operationTimedOut)
            #expect(operation.isCancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("task cancellation cancels an armed CloudKit operation")
    func taskCancellationCancelsArmedOperation() async {
        let operation = CKFetchRecordsOperation()
        let started = ICloudSyncTestSignal()
        let task = Task<Int, Error> {
            try await ICloudSyncCallbackDeadline.wait(timeout: 10) { _ in
                Task { await started.signal() }
                return operation
            }
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected task cancellation")
        } catch is CancellationError {
            #expect(operation.isCancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("task cancellation before arm cancels the operation when start returns")
    func taskCancellationBeforeArmCancelsReturnedOperation() async {
        let operation = CKFetchRecordsOperation()
        let startEntered = ICloudSyncTestSignal()
        let allowStartToReturn = DispatchSemaphore(value: 0)
        let task = Task<Int, Error> {
            try await ICloudSyncCallbackDeadline.wait(timeout: 10) { _ in
                Task { await startEntered.signal() }
                allowStartToReturn.wait()
                return operation
            }
        }

        await startEntered.wait()
        task.cancel()
        allowStartToReturn.signal()

        do {
            _ = try await task.value
            Issue.record("Expected task cancellation")
        } catch is CancellationError {
            #expect(operation.isCancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("iCloud bridge working copy")
struct ICloudBridgeWorkingCopyTests {
    @Test("distinguishes first-time setup from routine sync")
    func distinguishesSetupFromSync() {
        #expect(ICloudBridgeWorkingCopy.title(isActivationPending: true) == "Setting up private iCloud sync")
        #expect(ICloudBridgeWorkingCopy.title(isActivationPending: false) == "Syncing with private iCloud")
        #expect(ICloudBridgeWorkingCopy.subtitle(isActivationPending: true).contains("Creating the sync channel"))
        #expect(ICloudBridgeWorkingCopy.subtitle(isActivationPending: false).contains("uploading local changes"))
        #expect(ICloudBridgeWorkingCopy.buttonHelp(isActivationPending: true) == "Sync setup is in progress")
        #expect(ICloudBridgeWorkingCopy.buttonHelp(isActivationPending: false) == "Text sync is in progress")
    }
}
