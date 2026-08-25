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
    @Test("iCloud operations serialize recovery behind active work")
    func iCloudOperationsDoNotOverlap() {
        #expect(MuesliICloudOperationPolicy.startDecision(
            hasSyncTask: false,
            hasSubscriptionTask: false
        ) == .start)
        #expect(MuesliICloudOperationPolicy.startDecision(
            hasSyncTask: true,
            hasSubscriptionTask: false
        ) == .waitForSync)
        #expect(MuesliICloudOperationPolicy.startDecision(
            hasSyncTask: false,
            hasSubscriptionTask: true
        ) == .waitForSubscription)
        #expect(MuesliICloudOperationPolicy.startDecision(
            hasSyncTask: true,
            hasSubscriptionTask: true
        ) == .waitForSubscription)
    }

    @Test("linked device presentation distinguishes iPhone and iPad")
    func linkedDevicePresentationUsesPlatformIdentity() {
        let iPhone = ICloudLinkedDevicePresentation(
            name: "Pranav's iPhone",
            platform: "iOS"
        )
        #expect(iPhone.name == "Pranav's iPhone")
        #expect(iPhone.platformLabel == "iPhone")
        #expect(iPhone.systemImage == "iphone.gen3")

        let iPad = ICloudLinkedDevicePresentation(
            name: "Test iPad",
            platform: "iPadOS"
        )
        #expect(iPad.name == "Test iPad")
        #expect(iPad.platformLabel == "iPad")
        #expect(iPad.systemImage == "ipad")
    }

    @Test("distinguishes first-time setup from routine sync")
    func distinguishesSetupFromSync() {
        #expect(ICloudBridgeWorkingCopy.title(isActivationPending: true) == "Setting up sync")
        #expect(ICloudBridgeWorkingCopy.title(isActivationPending: false) == "Syncing")
        #expect(ICloudBridgeWorkingCopy.subtitle(isActivationPending: true) == "Connecting to iCloud…")
        #expect(ICloudBridgeWorkingCopy.subtitle(isActivationPending: false) == "Uploading and downloading changes…")
        #expect(ICloudBridgeWorkingCopy.buttonHelp(isActivationPending: true) == "Sync setup is in progress")
        #expect(ICloudBridgeWorkingCopy.buttonHelp(isActivationPending: false) == "Text sync is in progress")
    }

    @Test("duplicate enable requests do not restart pending activation")
    func duplicateActivationIsIgnored() {
        #expect(ICloudSyncActivationPolicy.action(
            isEnabled: false,
            isActivationPending: false
        ) == .beginActivation)
        #expect(ICloudSyncActivationPolicy.action(
            isEnabled: false,
            isActivationPending: true
        ) == .ignore)
        #expect(ICloudSyncActivationPolicy.action(
            isEnabled: true,
            isActivationPending: true
        ) == .ignore)
        #expect(ICloudSyncActivationPolicy.action(
            isEnabled: true,
            isActivationPending: false
        ) == .performSync)
    }

    @Test("legacy ambiguity reconnects while a confirmed account mismatch resets")
    func recoveryActionsRespectAccountBoundaryClassification() {
        #expect(ICloudSyncRecoveryPolicy.action(
            for: .needsReconnection,
            supportsLegacyReconnect: true
        ) == .reconnectLegacyLibrary)
        #expect(ICloudSyncRecoveryPolicy.action(
            for: .needsReconnection,
            supportsLegacyReconnect: false
        ) == .resetAccountLink)
        #expect(ICloudSyncRecoveryPolicy.action(for: .needsAccountReplacement) == .resetAccountLink)
        #expect(ICloudSyncRecoveryPolicy.action(for: .active) == nil)
        #expect(ICloudSyncRecoveryPolicy.action(for: .error) == nil)
    }

    @Test("sync setup exposes one next step for each state")
    func syncFlowIsStateDriven() {
        #expect(ICloudSyncFlowPolicy.action(
            for: .notConfigured,
            isEnabled: false,
            hasCompanionDevice: false
        ) == .setUp)
        #expect(ICloudSyncFlowPolicy.action(
            for: .active,
            isEnabled: true,
            hasCompanionDevice: false
        ) == .connectDevice)
        #expect(ICloudSyncFlowPolicy.action(
            for: .active,
            isEnabled: true,
            hasCompanionDevice: false,
            companionDiscoveryState: .waiting
        ) == .waitingForDevice)
        #expect(ICloudSyncFlowPolicy.action(
            for: .active,
            isEnabled: true,
            hasCompanionDevice: false,
            companionDiscoveryState: .timedOut
        ) == .connectDevice)
        #expect(ICloudSyncFlowPolicy.action(
            for: .active,
            isEnabled: true,
            hasCompanionDevice: true,
            companionDiscoveryState: .waiting
        ) == .syncNow)
        #expect(ICloudSyncFlowPolicy.action(
            for: .syncing,
            isEnabled: true,
            hasCompanionDevice: false
        ) == .working)
        #expect(ICloudSyncFlowPolicy.action(
            for: .error,
            isEnabled: true,
            hasCompanionDevice: false
        ) == .continueSetup)
        #expect(ICloudSyncFlowPolicy.action(
            for: .error,
            isEnabled: true,
            hasCompanionDevice: true
        ) == .retry)
    }

    @Test("stale syncing presentation recovers after work has completed")
    func staleSyncingStateRecovers() {
        #expect(ICloudSyncDisplayStatePolicy.state(
            rawState: .syncing,
            isEnabled: true,
            isActivationPending: false,
            isSyncInProgress: false
        ) == .active)
        #expect(ICloudSyncDisplayStatePolicy.state(
            rawState: .syncing,
            isEnabled: true,
            isActivationPending: false,
            isSyncInProgress: true
        ) == .syncing)
        #expect(ICloudSyncDisplayStatePolicy.state(
            rawState: .syncing,
            isEnabled: true,
            isActivationPending: true,
            isSyncInProgress: false
        ) == .syncing)
    }

    @Test("Mac dev builds generate the iOS dev sync scheme")
    func syncQRCodeMatchesBuildLane() {
        #expect(IPhoneBridgeLinks.syncDeepLinkURL(bundleIdentifier: "com.muesli.dev").scheme == "mueslidev")
        #expect(IPhoneBridgeLinks.syncDeepLinkURL(bundleIdentifier: "com.muesli.dev.c").scheme == "mueslidev")
        #expect(IPhoneBridgeLinks.syncDeepLinkURL(bundleIdentifier: "com.muesli.app").scheme == "muesli")
    }

    @Test("QR setup transitions from scanning to syncing before dismissal")
    func syncQRCodeFollowsConnectionProgress() {
        #expect(ICloudSyncQRCodePresentationPolicy.phase(
            isPresented: false,
            hasCompanionDevice: false,
            isSyncInProgress: false
        ) == .hidden)
        #expect(ICloudSyncQRCodePresentationPolicy.phase(
            isPresented: true,
            hasCompanionDevice: false,
            isSyncInProgress: true
        ) == .readyToScan)
        #expect(ICloudSyncQRCodePresentationPolicy.phase(
            isPresented: true,
            hasCompanionDevice: true,
            isSyncInProgress: true
        ) == .syncing)
        #expect(ICloudSyncQRCodePresentationPolicy.phase(
            isPresented: true,
            hasCompanionDevice: true,
            isSyncInProgress: false
        ) == .dismiss)
    }
}
