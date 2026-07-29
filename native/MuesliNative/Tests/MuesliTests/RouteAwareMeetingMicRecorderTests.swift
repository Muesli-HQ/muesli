import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("RouteAwareMeetingMicRecorder", .serialized)
struct RouteAwareMeetingMicRecorderTests {
    @Test("default input uses system default recorder")
    func defaultInputUsesSystemDefaultRecorder() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.prepare()
        try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.prepareCalls == 1)
        #expect(system.startCalls == 1)
        #expect(appScoped.prepareCalls == 0)
        #expect(appScoped.startCalls == 0)
    }

    @Test("preferred input uses app scoped recorder")
    func preferredInputUsesAppScopedRecorder() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        recorder.preferredInputDeviceID = 82
        try recorder.prepare()
        try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.prepareCalls == 0)
        #expect(system.startCalls == 0)
        #expect(appScoped.prepareCalls == 1)
        #expect(appScoped.startCalls == 1)
        #expect(appScoped.preferredInputDeviceID == 82)
    }

    @Test("callbacks from inactive recorder are ignored")
    func callbacksFromInactiveRecorderAreIgnored() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        var forwardedSamples: [[Int16]] = []
        var failureCount = 0
        recorder.onRawPCMSamples = { forwardedSamples.append($0) }
        recorder.onRecordingFailed = { _ in failureCount += 1 }

        try recorder.start()
        appScoped.onRawPCMSamples?([1, 2, 3])
        appScoped.onRecordingFailed?(NSError(domain: "RouteAwareMeetingMicRecorderTests", code: 1))
        system.onRawPCMSamples?([4, 5])

        #expect(forwardedSamples == [[4, 5]])
        #expect(failureCount == 0)
    }

    @Test("lifecycle delegates to active recorder and cancels inactive recorder on stop")
    func lifecycleDelegatesToActiveRecorderAndCancelsInactiveRecorderOnStop() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let inactiveCancelled = DispatchSemaphore(value: 0)
        system.onCancel = { inactiveCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        recorder.preferredInputDeviceID = 91

        try recorder.start()
        recorder.pause()
        recorder.resume()
        _ = recorder.stop()

        #expect(appScoped.startCalls == 1)
        #expect(appScoped.pauseCalls == 1)
        #expect(appScoped.resumeCalls == 1)
        #expect(appScoped.stopCalls == 1)
        #expect(inactiveCancelled.wait(timeout: .now() + 5) == .success)
    }

    @Test("diagnostics include active recorder kind and route snapshot")
    func diagnosticsIncludeActiveRecorderKindAndRouteSnapshot() throws {
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let route = MeetingMicRouteDiagnosticsSnapshot(
            outputRouteKind: "headphone-like",
            outputIsAmbiguousBluetooth: false,
            selectedInputDeviceUID: "built-in",
            selectedInputDeviceResolved: true,
            preferredInputDeviceID: 82,
            preferredInputDeviceName: "MacBook Microphone",
            defaultInputDeviceID: 90,
            defaultInputDeviceName: "Headset Mic",
            builtInInputDeviceID: 82,
            systemDefaultInputIsBuiltIn: false
        )
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: appScoped,
            routeSnapshotProvider: { route }
        )
        recorder.preferredInputDeviceID = 82
        try recorder.start()

        let diagnostics = recorder.diagnosticsSnapshot()

        #expect(diagnostics.recorderKind == .appScopedAudioQueue)
        #expect(diagnostics.preferredInputDeviceID == 82)
        #expect(diagnostics.route == route)
    }

    @Test("live route change keeps old recorder until replacement produces audio")
    func liveRouteChangeWaitsForFirstBuffer() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.startCalls == 1 }

        system.onRawPCMSamples?([1])
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.stopCalls == 0)

        appScoped.onRawPCMSamples?([2])
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }
        try await waitUntil { samples == [[1], [2]] }

        #expect(samples == [[1], [2]])
        #expect(system.stopCalls == 1)
        #expect(system.cancelCalls == 1)
    }

    @Test("failed live route change preserves current capture")
    func failedLiveRouteChangePreservesCurrentCapture() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        appScoped.startError = NSError(domain: "test", code: 1)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.cancelCalls == 1 }
        system.onRawPCMSamples?([7])

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.stopCalls == 0)
        #expect(samples == [[7]])
    }

    @Test("active recorder failure rebuilds the same route and recovers on first buffer")
    func activeFailureRebuildsSameRoute() async throws {
        let failed = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: failed,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: { replacement },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var failures = 0
        var samples: [[Int16]] = []
        recorder.onRecordingFailed = { _ in failures += 1 }
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        failed.onRecordingFailed?(NSError(domain: "test", code: 2))

        try await waitUntil { replacement.startCalls == 1 }
        #expect(recorder.isTerminallyFailedForDebug())
        #expect(failures == 1)

        replacement.onRawPCMSamples?([8, 9])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }
        try await waitUntil { samples == [[8, 9]] }

        #expect(samples == [[8, 9]])
        #expect(failed.stopCalls == 1)
    }

    @Test("same route can retry after a terminal recovery failure")
    func sameRouteRetriesAfterTerminalFailure() async throws {
        let initial = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let failedReplacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        failedReplacement.startError = NSError(domain: "test", code: 3)
        let recoveredReplacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        var replacements = [failedReplacement, recoveredReplacement]
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: initial,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: { replacements.removeFirst() },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        try recorder.start()
        initial.onRecordingFailed?(NSError(domain: "test", code: 2))
        try await waitUntil { failedReplacement.cancelCalls == 1 }

        #expect(recorder.isTerminallyFailedForDebug())
        recorder.preferredInputDeviceID = nil
        try await waitUntil { recoveredReplacement.startCalls == 1 }
        recoveredReplacement.onRawPCMSamples?([3, 2, 0])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }
        try await waitUntil { initial.stopCalls == 1 }

        #expect(recoveredReplacement.startCalls == 1)
        #expect(initial.stopCalls == 1)
    }

    @Test("discard returns while a replacement start is blocked")
    func discardDoesNotWaitForBlockedReplacementStart() throws {
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var deliveredSamples: [[Int16]] = []
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(startEntered.wait(timeout: .now() + 5) == .success)

        let startedAt = Date()
        recorder.cancel()
        let elapsed = Date().timeIntervalSince(startedAt)
        allowStart.signal()

        #expect(elapsed < 0.2)
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)
        replacement.onRawPCMSamples?([4, 2])
        #expect(deliveredSamples.isEmpty)
    }

    @Test("stop returns while a replacement start is blocked")
    func stopDoesNotWaitForBlockedReplacementStart() throws {
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        try recorder.start()
        recorder.preferredInputDeviceID = 93
        #expect(startEntered.wait(timeout: .now() + 5) == .success)

        let startedAt = Date()
        _ = recorder.stop()
        let elapsed = Date().timeIntervalSince(startedAt)
        allowStart.signal()

        #expect(elapsed < 0.2)
        #expect(system.stopCalls == 1)
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)
    }

    @Test("handoff timeout runs while replacement start is blocked")
    func handoffTimeoutBoundsBlockedReplacementStart() throws {
        let timeoutScheduler = ManualMeetingMicHandoffTimeoutScheduler()
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 0.05,
            handoffTimeoutScheduler: timeoutScheduler.schedule
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 92
        #expect(startEntered.wait(timeout: .now() + 5) == .success)
        #expect(timeoutScheduler.fireNext())
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)

        system.onRawPCMSamples?([7])
        allowStart.signal()
        replacement.onRawPCMSamples?([9])

        #expect(samples == [[7]])
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
    }

    @Test("rapid route changes reject late callbacks from superseded recorders")
    func rapidRouteChangesRejectSupersededCallbacks() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let first = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let second = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        var replacements = [first, second]
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorderFactory: { replacements.removeFirst() },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { first.startCalls == 1 }
        recorder.preferredInputDeviceID = 92
        try await waitUntil { first.cancelCalls == 1 && second.startCalls == 1 }

        first.onRawPCMSamples?([1])
        system.onRawPCMSamples?([2])
        second.onRawPCMSamples?([3])
        try await waitUntil { recorder.diagnosticsSnapshot().preferredInputDeviceID == 92 }
        try await waitUntil { system.stopCalls == 1 }
        first.onRawPCMSamples?([4])

        #expect(samples == [[2], [3]])
        #expect(system.stopCalls == 1)
    }

    @Test("pause cancels a pending handoff and resume starts a fresh replacement")
    func pauseDuringPendingHandoffStartsFreshReplacementOnResume() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pendingBeforePause = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let replacementAfterResume = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pendingBeforePause,
            appScopedRecorderFactory: { replacementAfterResume },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { pendingBeforePause.startCalls == 1 }

        recorder.pause()
        try await waitUntil { pendingBeforePause.cancelCalls == 1 }
        pendingBeforePause.onRawPCMSamples?([1])
        recorder.resume()
        try await waitUntil { replacementAfterResume.startCalls == 1 }
        pendingBeforePause.onRawPCMSamples?([2])
        replacementAfterResume.onRawPCMSamples?([3])
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }
        try await waitUntil { samples == [[3]] }

        #expect(samples == [[3]])
        #expect(system.pauseCalls == 1)
        #expect(system.resumeCalls == 1)
    }

    @Test("a pending handoff can recover an active recorder failure")
    func activeFailureUsesPendingHandoffForRecovery() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pending = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pending,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var failures = 0
        var samples: [[Int16]] = []
        recorder.onRecordingFailed = { _ in failures += 1 }
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { pending.startCalls == 1 }
        system.onRecordingFailed?(NSError(domain: "test", code: 4))

        #expect(recorder.isTerminallyFailedForDebug())
        pending.onRawPCMSamples?([8])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }
        try await waitUntil { samples == [[8]] }

        #expect(failures == 1)
        #expect(samples == [[8]])
        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
    }

    @Test("stop remains correct when first-buffer promotion is already queued")
    func stopRacingQueuedFirstBufferPromotion() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.stop-first-buffer-race")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pending = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pending,
            lifecycleQueue: lifecycleQueue,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        lifecycleQueue.sync {}

        var queueIsSuspended = true
        lifecycleQueue.suspend()
        defer {
            if queueIsSuspended { lifecycleQueue.resume() }
        }
        pending.onRawPCMSamples?([9])
        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = recorder.stop()
            stopReturned.signal()
        }
        #expect(stopReturned.wait(timeout: .now() + 0.02) == .timedOut)

        lifecycleQueue.resume()
        queueIsSuspended = false
        #expect(stopReturned.wait(timeout: .now() + 5) == .success)
        pending.onRawPCMSamples?([10])

        #expect(samples == [[9]])
        #expect(pending.stopCalls == 1)
        #expect(pending.cancelCalls == 1)
    }

    @Test("discard remains correct when first-buffer promotion is already queued")
    func discardRacingQueuedFirstBufferPromotion() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.discard-first-buffer-race")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pending = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let pendingCancelled = DispatchSemaphore(value: 0)
        pending.onCancel = { pendingCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pending,
            lifecycleQueue: lifecycleQueue,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        lifecycleQueue.sync {}

        var queueIsSuspended = true
        lifecycleQueue.suspend()
        defer {
            if queueIsSuspended { lifecycleQueue.resume() }
        }
        pending.onRawPCMSamples?([9])
        let discardReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            recorder.cancel()
            discardReturned.signal()
        }
        #expect(discardReturned.wait(timeout: .now() + 0.02) == .timedOut)

        lifecycleQueue.resume()
        queueIsSuspended = false
        #expect(discardReturned.wait(timeout: .now() + 5) == .success)
        #expect(pendingCancelled.wait(timeout: .now() + 5) == .success)
        pending.onRawPCMSamples?([10])

        #expect(samples == [[9]])
    }

    @Test("repeated handoff timeouts cannot promote stale recorders")
    func repeatedTimeoutsRecoverWithoutPromotingStaleRecorders() async throws {
        let timeoutScheduler = ManualMeetingMicHandoffTimeoutScheduler()
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let first = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let second = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recovered = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        var replacements = [first, second, recovered]
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorderFactory: { replacements.removeFirst() },
            handoffTimeout: 0.2,
            handoffTimeoutScheduler: timeoutScheduler.schedule
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { first.startCalls == 1 }
        #expect(timeoutScheduler.fireNext())
        try await waitUntil { first.cancelCalls == 1 }
        recorder.preferredInputDeviceID = 92
        try await waitUntil { second.startCalls == 1 }
        #expect(timeoutScheduler.fireNext())
        try await waitUntil { second.cancelCalls == 1 }
        recorder.preferredInputDeviceID = 93
        try await waitUntil { recovered.startCalls == 1 }

        first.onRawPCMSamples?([1])
        second.onRawPCMSamples?([2])
        system.onRawPCMSamples?([3])
        recovered.onRawPCMSamples?([4])
        try await waitUntil { recorder.diagnosticsSnapshot().preferredInputDeviceID == 93 }
        try await waitUntil { samples == [[3], [4]] }

        #expect(samples == [[3], [4]])
        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
    }

    @Test("failed configuration-change restart marks the recorder inactive")
    func failedConfigurationChangeRestartMarksRecorderInactive() {
        var state = StreamingMicRecorderRunState()

        state.markStarted()
        #expect(state.isRunning)
        state.markConfigurationChangeRestartFailed()

        #expect(!state.isRunning)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for asynchronous recorder state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private let disabledMeetingMicHandoffTimeoutScheduler: RouteAwareMeetingMicRecorder.HandoffTimeoutScheduler = {
    _, _ in
}

private final class ManualMeetingMicHandoffTimeoutScheduler {
    private let lock = NSLock()
    private var scheduledWorkItems: [DispatchWorkItem] = []

    func schedule(_ delay: TimeInterval, _ workItem: DispatchWorkItem) {
        lock.withLock {
            scheduledWorkItems.append(workItem)
        }
    }

    func fireNext() -> Bool {
        let workItem = lock.withLock { () -> DispatchWorkItem? in
            guard !scheduledWorkItems.isEmpty else { return nil }
            return scheduledWorkItems.removeFirst()
        }
        guard let workItem else { return false }
        workItem.perform()
        return true
    }
}

private final class FakeMeetingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?

    let kind: MeetingMicRecorderKind
    var prepareCalls = 0
    var startCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var startError: Error?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?

    init(kind: MeetingMicRecorderKind) {
        self.kind = kind
    }

    func prepare() throws {
        prepareCalls += 1
    }

    func start() throws {
        startCalls += 1
        onStart?()
        if let startError { throw startError }
    }

    func pause() {
        pauseCalls += 1
    }

    func resume() {
        resumeCalls += 1
    }

    func stop() -> URL? {
        stopCalls += 1
        return nil
    }

    func cancel() {
        cancelCalls += 1
        onCancel?()
    }

    func currentPower() -> Float {
        -80
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: kind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }
}
