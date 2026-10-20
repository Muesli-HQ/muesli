import CoreAudio
import Foundation
import Testing
import os
@testable import MuesliNativeApp

@Suite("RouteAwareMeetingMicRecorder", .serialized)
struct RouteAwareMeetingMicRecorderTests {
    @Test("promotion requires successful startup AND audio in either order", arguments: [true, false])
    func startupAndAudioRequired(audioFirst: Bool) throws {
        let old = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let candidate = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let lifecycle = DispatchQueue(label: "test.start-gate.lifecycle")
        let worker = DispatchQueue(label: "test.start-gate.worker")
        let cleanup = DispatchQueue(label: "test.start-gate.cleanup")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        candidate.onStart = {
            if audioFirst { candidate.emit([2, 3], at: 100) }
            entered.signal()
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        defer { release.signal(); candidate.onStart = nil }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: old, appScopedRecorder: candidate,
            lifecycleQueue: lifecycle, handoffWorkerQueue: worker, cleanupQueue: cleanup,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        let delivered = OSAllocatedUnfairLock(initialState: [Int16]())
        let outcomes = OSAllocatedUnfairLock(initialState: [MeetingMicHandoffOutcome]())
        recorder.onRawPCMSamples = { audio in delivered.withLock { $0 += audio.samples } }
        recorder.onHandoffOutcome = { outcome in outcomes.withLock { $0.append(outcome) } }
        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(entered.wait(timeout: .now() + 5) == .success)
        lifecycle.sync {}
        old.emit([1], at: 99)
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(delivered.withLock { $0 } == [1])
        #expect(outcomes.withLock { $0 }.isEmpty)
        #expect(!old.invalidatedForTeardown)
        release.signal()
        worker.sync {}; lifecycle.sync {}
        if !audioFirst {
            #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
            #expect(outcomes.withLock { $0 }.isEmpty)
            candidate.emit([2, 3], at: 100)
            lifecycle.sync {}
        }
        recorder.drainAcceptedAudio(); cleanup.sync {}
        candidate.emit([4], at: 102)
        old.emit([99], at: 103)
        #expect(delivered.withLock { $0 } == [1, 2, 3, 4])
        #expect(outcomes.withLock { $0 } == [.promoted])
        #expect(old.stopCalls == 1)
        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        _ = recorder.stop()
        recorder.waitForQuiescence()
    }

    @Test("failed startup cannot promote early or late audio", arguments: [true, false])
    func failedStartupRejectsAudio(audioBeforeFailure: Bool) throws {
        let old = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let candidate = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let lifecycle = DispatchQueue(label: "test.start-failure.lifecycle")
        let worker = DispatchQueue(label: "test.start-failure.worker")
        let cleanup = DispatchQueue(label: "test.start-failure.cleanup")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        candidate.startError = NSError(domain: "test.startup", code: 1)
        candidate.onStart = {
            if audioBeforeFailure { candidate.emit([2], at: 100) }
            entered.signal()
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        defer { release.signal(); candidate.onStart = nil }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: old, appScopedRecorder: candidate,
            lifecycleQueue: lifecycle, handoffWorkerQueue: worker, cleanupQueue: cleanup,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        let delivered = OSAllocatedUnfairLock(initialState: [Int16]())
        let outcomes = OSAllocatedUnfairLock(initialState: [MeetingMicHandoffOutcome]())
        recorder.onRawPCMSamples = { audio in delivered.withLock { $0 += audio.samples } }
        recorder.onHandoffOutcome = { outcome in outcomes.withLock { $0.append(outcome) } }
        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(entered.wait(timeout: .now() + 5) == .success)
        lifecycle.sync {} // Process early-audio promotion while start is still blocked.
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(!old.invalidatedForTeardown)
        release.signal()
        worker.sync {}; lifecycle.sync {}; cleanup.sync {}
        candidate.emit([3], at: 101) // Even a late callback from failed hardware must be rejected.
        lifecycle.sync {}
        recorder.drainAcceptedAudio()
        old.emit([7], at: 102)
        #expect(delivered.withLock { $0 } == [7])
        #expect(outcomes.withLock { $0 } == [.failed])
        #expect(old.stopCalls == 0)
        #expect(!old.invalidatedForTeardown)
        #expect(candidate.cancelCalls == 1)
        _ = recorder.stop()
        recorder.waitForQuiescence()
    }

    @Test("pending startup/audio cannot cross pause, stop, discard or timeout",
          arguments: ["pause", "stop", "discard", "timeout"], [true, false])
    func startupGateRespectsBoundaries(ending: String, audioFirst: Bool) throws {
        let old = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let candidate = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let next = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let lifecycle = DispatchQueue(label: "test.start-boundary.lifecycle")
        let worker = DispatchQueue(label: "test.start-boundary.worker")
        let cleanup = DispatchQueue(label: "test.start-boundary.cleanup")
        let timeouts = ManualMeetingMicHandoffTimeoutScheduler()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        candidate.onStart = {
            if audioFirst { candidate.emit([2], at: 100) }
            entered.signal()
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        defer { release.signal(); candidate.onStart = nil }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: old, appScopedRecorder: candidate,
            appScopedRecorderFactory: { next },
            lifecycleQueue: lifecycle, handoffWorkerQueue: worker, cleanupQueue: cleanup,
            handoffTimeoutScheduler: timeouts.schedule
        )
        let delivered = OSAllocatedUnfairLock(initialState: [Int16]())
        let outcomes = OSAllocatedUnfairLock(initialState: [MeetingMicHandoffOutcome]())
        recorder.onRawPCMSamples = { audio in delivered.withLock { $0 += audio.samples } }
        recorder.onHandoffOutcome = { outcome in outcomes.withLock { $0.append(outcome) } }
        try recorder.start()
        old.emit([1], at: 99)
        recorder.preferredInputDeviceID = 91
        #expect(entered.wait(timeout: .now() + 5) == .success)
        lifecycle.sync {}
        if !audioFirst { release.signal(); worker.sync {}; lifecycle.sync {} }
        switch ending {
        case "pause": recorder.pause()
        case "stop": recorder.invalidateForTeardown(); _ = recorder.stop()
        case "discard": recorder.cancel()
        default: lifecycle.sync { #expect(timeouts.fireNext()) }
        }
        if audioFirst { release.signal() }
        worker.sync {}; lifecycle.sync {}; cleanup.sync {}
        candidate.emit([99], at: 101)
        lifecycle.sync {}
        recorder.waitForQuiescence()
        #expect(delivered.withLock { $0 } == [1])
        #expect(!outcomes.withLock { $0 }.contains(.promoted))
        #expect(candidate.invalidatedForTeardown)
        if ending == "pause" {
            recorder.resume()
            worker.sync {}; lifecycle.sync {}
            next.emit([4], at: 102)
            lifecycle.sync {}; recorder.drainAcceptedAudio(); cleanup.sync {}
            #expect(delivered.withLock { $0 } == [1, 4])
            #expect(outcomes.withLock { $0 } == [.promoted])
        } else if ending == "timeout" {
            #expect(outcomes.withLock { $0 } == [.timedOut])
            old.emit([5], at: 102)
            #expect(delivered.withLock { $0 } == [1, 5])
            #expect(!old.invalidatedForTeardown)
        }
        if ending == "pause" || ending == "timeout" { _ = recorder.stop() }
        recorder.waitForQuiescence()
    }

    @Test("pending overflow cannot promote an already queued first-buffer event")
    func pendingOverflowBeforePromotion() throws {
        let old = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let lifecycle = DispatchQueue(label: "test.pending-budget.lifecycle")
        let worker = DispatchQueue(label: "test.pending-budget.worker")
        let cleanup = DispatchQueue(label: "test.pending-budget.cleanup")
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: old, appScopedRecorder: replacement,
            lifecycleQueue: lifecycle, handoffWorkerQueue: worker, cleanupQueue: cleanup,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var outcomes: [MeetingMicHandoffOutcome] = []
        recorder.onHandoffOutcome = { outcomes.append($0) }
        try recorder.start()
        recorder.preferredInputDeviceID = 91
        lifecycle.sync {}; worker.sync {}
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        lifecycle.async { blocked.signal(); _ = release.wait(timeout: .now() + 5) }
        #expect(blocked.wait(timeout: .now() + 5) == .success)
        replacement.emit(Array(repeating: 1, count: 80_000), at: 0)
        replacement.emit([2], at: 80_000)
        release.signal()
        lifecycle.sync {}; cleanup.sync {}
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(outcomes == [.failed])
        #expect(old.stopCalls == 0)
        #expect(replacement.cancelCalls == 1)
        _ = recorder.stop()
        recorder.waitForQuiescence()
    }

    @Test("replacement delivery does not wait for retirement; retired tails remain rejected", arguments: ["running", "paused", "stopped", "cancelled"])
    func handoffDrainsRetiredTail(ending: String) throws {
        let old = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let lifecycle = DispatchQueue(label: "test.handoff-tail.lifecycle")
        let worker = DispatchQueue(label: "test.handoff-tail.worker")
        let cleanup = DispatchQueue(label: "test.handoff-tail.cleanup")
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: old, appScopedRecorder: replacement,
            lifecycleQueue: lifecycle, handoffWorkerQueue: worker, cleanupQueue: cleanup,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        let deliveriesLock = NSLock()
        var delivered: [Int16] = []
        recorder.onRawPCMSamples = { samples in deliveriesLock.withLock { delivered.append(contentsOf: samples.samples) } }
        let enteredStop = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        old.onStop = {
            enteredStop.signal()
            #expect(releaseStop.wait(timeout: .now() + 10) == .success)
            old.emit([2, 3], at: 100)
        }
        // Even a producer violating its callback contract during cancel must
        // not inherit the accepted-tail entitlement.
        old.onCancel = { old.emit([99]) }
        defer { old.onStop = nil; old.onCancel = nil }
        try recorder.start()
        recorder.preferredInputDeviceID = 91
        lifecycle.sync {}
        worker.sync {}
        replacement.emit([1], at: 102)
        lifecycle.sync {}
        #expect(enteredStop.wait(timeout: .now() + 5) == .success)
        #expect(old.invalidatedForTeardown)
        recorder.drainAcceptedAudio()
        #expect(deliveriesLock.withLock { delivered } == [1])
        switch ending {
        case "paused": recorder.pause()
        case "stopped": recorder.invalidateForTeardown(); _ = recorder.stop()
        case "cancelled": recorder.cancel()
        default: break
        }
        releaseStop.signal()
        cleanup.sync {}
        old.emit([98])
        let expected: [Int16] = [1] // Cancel does not retract audio delivered before it.
        #expect(deliveriesLock.withLock { delivered } == expected)
        if ending == "running" || ending == "paused" { _ = recorder.stop() }
        recorder.waitForQuiescence()
    }

    @Test("Stop forwards the active child's buffered tail, then rejects late delivery")
    func stopDrainsActiveChildOnly() throws {
        let child = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: child)
        var delivered: [Int16] = []
        recorder.onRawPCMSamples = { delivered.append(contentsOf: $0.samples) }
        try recorder.start()
        child.onStop = {
            recorder.invalidateForTeardown()
            child.emit([4, 5])
        }
        defer { child.onStop = nil }
        recorder.invalidateForTeardown()
        _ = recorder.stop()
        child.emit([99])
        #expect(delivered == [4, 5])
    }

    @Test("disconnecting the consumer before teardown discards the buffered tail")
    func discardRejectsBufferedTail() throws {
        let child = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: child)
        var delivered: [Int16] = []
        recorder.onRawPCMSamples = { delivered.append(contentsOf: $0.samples) }
        try recorder.start()
        child.onStop = { child.emit([4, 5]) }
        defer { child.onStop = nil }
        recorder.invalidateForTeardown()
        recorder.onRawPCMSamples = nil
        _ = recorder.stop()
        #expect(delivered.isEmpty)
    }

    @Test("stopping releases the microphone child and its driver ownership")
    func stopReleasesChild() throws {
        weak var child: FakeMeetingMicRecorder?
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorderFactory: {
            let created = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
            child = created
            return created
        })

        try recorder.start()
        #expect(child != nil)
        _ = recorder.stop()
        recorder.waitForQuiescence()

        #expect(child == nil)
    }

    @Test("a completed handoff releases the retired microphone child")
    func handoffReleasesRetiredChild() throws {
        weak var initial: FakeMeetingMicRecorder?
        weak var replacement: FakeMeetingMicRecorder?
        let lifecycle = DispatchQueue(label: "test.meeting-mic.release.lifecycle")
        let worker = DispatchQueue(label: "test.meeting-mic.release.worker")
        let cleanup = DispatchQueue(label: "test.meeting-mic.release.cleanup")
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorderFactory: {
                let created = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
                initial = created
                return created
            },
            appScopedRecorderFactory: {
                let created = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
                replacement = created
                return created
            },
            lifecycleQueue: lifecycle, handoffWorkerQueue: worker, cleanupQueue: cleanup,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        try recorder.start()
        #expect(recorder.requestHealthRecovery(.init(reason: "test", requiresNonZeroSamples: false)) == .initiated)
        worker.sync {}
        replacement?.emit([1, 2])
        lifecycle.sync {}
        cleanup.sync {}

        #expect(initial == nil)
        #expect(replacement != nil)
        _ = recorder.stop()
        recorder.waitForQuiescence()
        #expect(replacement == nil)
    }

    @Test("stopping releases a pending child before its scheduled timeout")
    func stopReleasesPendingChildBeforeTimeout() throws {
        weak var candidate: FakeMeetingMicRecorder?
        let timeouts = ManualMeetingMicHandoffTimeoutScheduler()
        let worker = DispatchQueue(label: "test.meeting-mic.pending-release.worker")
        let cleanup = DispatchQueue(label: "test.meeting-mic.pending-release.cleanup")
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorderFactory: {
                let created = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
                candidate = created
                return created
            },
            handoffWorkerQueue: worker, cleanupQueue: cleanup,
            handoffTimeoutScheduler: timeouts.schedule
        )
        try recorder.start()
        #expect(recorder.requestHealthRecovery(.init(reason: "test", requiresNonZeroSamples: false)) == .initiated)
        worker.sync {}
        #expect(candidate != nil)

        _ = recorder.stop()
        cleanup.sync {}
        #expect(candidate == nil)
        // An outstanding deadline is harmless and need not own the driver.
        #expect(timeouts.fireNext())
    }

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
        recorder.onRawPCMSamples = { forwardedSamples.append($0.samples) }
        recorder.onRecordingFailed = { _ in failureCount += 1 }

        try recorder.start()
        appScoped.emit([1, 2, 3])
        appScoped.onRecordingFailed?(NSError(domain: "RouteAwareMeetingMicRecorderTests", code: 1))
        system.emit([4, 5])

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
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.startCalls == 1 }

        system.emit([1])
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.stopCalls == 0)

        appScoped.emit([2])
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }
        try await waitUntil { samples == [[1], [2]] }

        // Audio promotion precedes retirement on the separate cleanup queue.
        try await waitUntil { system.stopCalls == 1 && system.cancelCalls == 1 }
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
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.cancelCalls == 1 }
        system.emit([7])

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
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        failed.onRecordingFailed?(NSError(domain: "test", code: 2))

        try await waitUntil { replacement.startCalls == 1 }
        #expect(recorder.isTerminallyFailedForDebug())
        #expect(failures == 1)

        replacement.emit([8, 9])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }
        try await waitUntil { samples == [[8, 9]] }

        #expect(samples == [[8, 9]])
        // The retired child is stopped on the async cleanup queue after
        // promotion; wait for it rather than asserting synchronously (flakes
        // under CI load otherwise).
        try await waitUntil { failed.stopCalls == 1 }
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
        recoveredReplacement.emit([3, 2, 0])
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
        recorder.onRawPCMSamples = { deliveredSamples.append($0.samples) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(startEntered.wait(timeout: .now() + 5) == .success)

        let startedAt = Date()
        recorder.cancel()
        let elapsed = Date().timeIntervalSince(startedAt)
        allowStart.signal()

        #expect(elapsed < 0.2)
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)
        replacement.emit([4, 2])
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
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        recorder.preferredInputDeviceID = 92
        #expect(startEntered.wait(timeout: .now() + 5) == .success)
        #expect(timeoutScheduler.fireNext())
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)

        system.emit([7])
        allowStart.signal()
        replacement.emit([9])

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
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { first.startCalls == 1 }
        recorder.preferredInputDeviceID = 92
        try await waitUntil { first.cancelCalls == 1 && second.startCalls == 1 }

        first.emit([1])
        system.emit([2])
        second.emit([3])
        try await waitUntil { recorder.diagnosticsSnapshot().preferredInputDeviceID == 92 }
        try await waitUntil { system.stopCalls == 1 }
        first.emit([4])

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
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { pendingBeforePause.startCalls == 1 }

        recorder.pause()
        try await waitUntil { pendingBeforePause.cancelCalls == 1 }
        pendingBeforePause.emit([1])
        recorder.resume()
        try await waitUntil { replacementAfterResume.startCalls == 1 }
        pendingBeforePause.emit([2])
        replacementAfterResume.emit([3])
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
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { pending.startCalls == 1 }
        system.onRecordingFailed?(NSError(domain: "test", code: 4))

        #expect(recorder.isTerminallyFailedForDebug())
        pending.emit([8])
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
        let oldStopEntered = DispatchSemaphore(value: 0)
        let releaseOldStop = DispatchSemaphore(value: 0)
        system.onStop = {
            oldStopEntered.signal()
            #expect(releaseOldStop.wait(timeout: .now() + 5) == .success)
        }
        defer { releaseOldStop.signal(); system.onStop = nil }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pending,
            lifecycleQueue: lifecycleQueue,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        lifecycleQueue.sync {}

        var queueIsSuspended = true
        lifecycleQueue.suspend()
        defer {
            if queueIsSuspended { lifecycleQueue.resume() }
        }
        pending.emit([9])
        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = recorder.stop()
            stopReturned.signal()
        }
        #expect(stopReturned.wait(timeout: .now() + 0.02) == .timedOut)

        lifecycleQueue.resume()
        queueIsSuspended = false
        #expect(stopReturned.wait(timeout: .now() + 5) == .success)
        pending.emit([10])

        #expect(oldStopEntered.wait(timeout: .now() + 5) == .success)
        recorder.drainAcceptedAudio()
        #expect(samples == [[9]]) // Replacement delivery no longer waits for old native stop.
        // Stop deliberately does not wait for the retired graph. Production
        // joins native quiescence separately before closing the session sink.
        let quiesced = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            recorder.waitForQuiescence()
            quiesced.signal()
        }
        #expect(quiesced.wait(timeout: .now() + 0.02) == .timedOut)
        releaseOldStop.signal()
        #expect(quiesced.wait(timeout: .now() + 5) == .success)

        #expect(samples == [[9]])
        #expect(pending.stopCalls == 1)
        #expect(pending.cancelCalls == 1)
    }

    @Test("discard remains correct when first-buffer promotion is already queued")
    func discardRacingQueuedFirstBufferPromotion() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.discard-first-buffer-race")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pending = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let oldStopEntered = DispatchSemaphore(value: 0)
        let releaseOldStop = DispatchSemaphore(value: 0)
        system.onStop = {
            oldStopEntered.signal()
            #expect(releaseOldStop.wait(timeout: .now() + 5) == .success)
        }
        defer { releaseOldStop.signal(); system.onStop = nil }
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
        let deliveryEntered = DispatchSemaphore(value: 0)
        let releaseDelivery = DispatchSemaphore(value: 0)
        let initialReturned = DispatchSemaphore(value: 0)
        recorder.onRawPCMSamples = {
            if $0.samples == [0] {
                deliveryEntered.signal()
                #expect(releaseDelivery.wait(timeout: .now() + 5) == .success)
            } else { samples.append($0.samples) }
        }
        defer { releaseDelivery.signal() }

        try recorder.start()
        DispatchQueue.global().async { system.emit([0]); initialReturned.signal() }
        #expect(deliveryEntered.wait(timeout: .now() + 5) == .success)
        recorder.preferredInputDeviceID = 91
        lifecycleQueue.sync {}

        var queueIsSuspended = true
        lifecycleQueue.suspend()
        defer {
            if queueIsSuspended { lifecycleQueue.resume() }
        }
        pending.emit([9])
        let discardReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            recorder.cancel()
            discardReturned.signal()
        }
        #expect(discardReturned.wait(timeout: .now() + 0.02) == .timedOut)

        lifecycleQueue.resume()
        queueIsSuspended = false
        #expect(discardReturned.wait(timeout: .now() + 5) == .success)
        #expect(oldStopEntered.wait(timeout: .now() + 5) == .success)
        releaseDelivery.signal()
        #expect(initialReturned.wait(timeout: .now() + 5) == .success)
        releaseOldStop.signal()
        recorder.waitForQuiescence()
        #expect(pendingCancelled.wait(timeout: .now() + 5) == .success)
        pending.emit([10])

        #expect(samples.isEmpty) // Discard cancels queued activation, not just late native callbacks.
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
        recorder.onRawPCMSamples = { samples.append($0.samples) }

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

        first.emit([1])
        second.emit([2])
        system.emit([3])
        recovered.emit([4])
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

    @Test("health-triggered recovery switches the default route to the alternate backend")
    func healthTriggeredRecoveryPromotesOnFirstBuffer() async throws {
        let degraded = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: degraded,
            appScopedRecorder: replacement,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0.samples) }

        try recorder.start()
        #expect(recorder.requestHealthRecovery(.init(
            reason: "system_audio_active_with_zero_mic",
            requiresNonZeroSamples: true
        )) == .initiated)
        try await waitUntil { replacement.startCalls == 1 }
        #expect(replacement.preferredInputDeviceID == nil)

        // No samples yet: the degraded graph remains active and un-retired.
        #expect(degraded.stopCalls == 0)

        // An all-zero callback is not evidence that an all-zero failure has
        // recovered, so it must not replace the active graph.
        replacement.emit([0, 0, 0])
        try await Task.sleep(for: .milliseconds(50))
        #expect(degraded.stopCalls == 0)
        #expect(samples.isEmpty)

        replacement.emit([4, 5, 6])
        try await waitUntil { samples == [[4, 5, 6]] }
        try await waitUntil { degraded.stopCalls == 1 && degraded.cancelCalls == 1 }
        #expect(degraded.stopCalls == 1)
        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
    }

    @Test("health-triggered recovery is a no-op when not recording")
    func healthRecoveryIgnoredWhenNotRunning() {
        var factoryCalls = 0
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: {
                factoryCalls += 1
                return FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
            },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        #expect(recorder.requestHealthRecovery(.init(
            reason: "system_audio_active_without_mic_callbacks",
            requiresNonZeroSamples: false
        )) == .unavailable)
        #expect(factoryCalls == 0)
    }

    @Test("a second health recovery request does not stack behind a pending handoff")
    func healthRecoveryDoesNotStackPendingHandoffs() async throws {
        let degraded = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: degraded,
            appScopedRecorder: replacement,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        try recorder.start()
        #expect(recorder.requestHealthRecovery(.init(reason: "first", requiresNonZeroSamples: false)) == .initiated)
        #expect(recorder.requestHealthRecovery(.init(reason: "second", requiresNonZeroSamples: false)) == .busy)
        try await waitUntil { replacement.startCalls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(replacement.startCalls == 1)
    }

    @Test("handoff outcome reports promotion and candidate failure")
    func handoffOutcomeReportsPromotionAndFailure() async throws {
        let failingReplacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        failingReplacement.startError = NSError(domain: "test", code: 7)
        let goodReplacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        var replacements = [failingReplacement, goodReplacement]
        let initial = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: initial,
            appScopedRecorder: replacements.removeFirst(),
            appScopedRecorderFactory: { replacements.removeFirst() },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var outcomes: [MeetingMicHandoffOutcome] = []
        recorder.onHandoffOutcome = { outcomes.append($0) }

        try recorder.start()
        #expect(recorder.requestHealthRecovery(.init(reason: "first attempt", requiresNonZeroSamples: false)) == .initiated)
        try await waitUntil { failingReplacement.cancelCalls == 1 }
        try await waitUntil { outcomes == [.failed] }

        #expect(recorder.requestHealthRecovery(.init(reason: "second attempt", requiresNonZeroSamples: false)) == .initiated)
        try await waitUntil { goodReplacement.startCalls == 1 }
        goodReplacement.emit([1, 2])
        try await waitUntil { outcomes == [.failed, .promoted] }
        try await waitUntil { initial.stopCalls == 1 }
    }

    @Test("stop while a recovery candidate is queued never starts the candidate")
    func stopWithQueuedRecoveryNeverStartsCandidate() throws {
        let prepareStarted = DispatchSemaphore(value: 0)
        let allowPrepare = DispatchSemaphore(value: 0)
        let initial = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let candidate = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        candidate.onPrepareStarted = { prepareStarted.signal() }
        candidate.prepareGate = allowPrepare
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: initial,
            appScopedRecorder: candidate,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        try recorder.start()
        #expect(recorder.requestHealthRecovery(.init(reason: "queued then stopped", requiresNonZeroSamples: false)) == .initiated)
        #expect(prepareStarted.wait(timeout: .now() + 2) == .success)

        // Tear down while the worker is blocked inside candidate.prepare().
        _ = recorder.stop()

        // Teardown must poison the candidate synchronously — before the worker
        // is even released — so no interleaving can start capture afterwards.
        #expect(candidate.invalidatedForTeardown)
        allowPrepare.signal()

        // The worker must not proceed to start() after teardown cleared the
        // pending candidate — capture must never begin after meeting end.
        let quiesced = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { quiesced.signal() }
        #expect(quiesced.wait(timeout: .now() + 2) == .success)
        #expect(candidate.startCalls == 0)
        #expect(candidate.cancelCalls >= 1)
    }


    @Test("timed-out graph retains capacity until native start and cleanup return")
    func timedOutGraphRetainsCapacity() async throws {
        let timeouts = ManualMeetingMicHandoffTimeoutScheduler()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let active = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let candidate = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        candidate.onStart = {
            entered.signal()
            #expect(release.wait(timeout: .now() + 3) == .success)
        }
        candidate.onCancel = { cancelled.signal() }
        let next = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: active, appScopedRecorder: candidate,
            appScopedRecorderFactory: { next }, handoffTimeoutScheduler: timeouts.schedule
        )
        try recorder.start()
        recorder.preferredInputDeviceID = 91
        let startEntered = entered.wait(timeout: .now() + 1) == .success
        #expect(startEntered)
        #expect(timeouts.fireNext())
        #expect(candidate.invalidatedForTeardown)
        let startCancelled = cancelled.wait(timeout: .now() + 1) == .success
        #expect(startCancelled)
        recorder.preferredInputDeviceID = 92
        // Cleanup has returned, but the old start is still inside its driver.
        try await Task.sleep(for: .milliseconds(30))
        #expect(next.prepareCalls == 0)
        release.signal()
        try await waitUntil { next.startCalls == 1 }
        recorder.cancel()
        recorder.waitForQuiescence()
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
    private static let clock = OSAllocatedUnfairLock(initialState: Int64(1_000))
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: ((MicrophoneCaptureAudio) -> Void)?
    func emit(_ samples: [Int16], at frame: Int64? = nil, admitted: Bool = false) {
        let start = frame ?? Self.clock.withLock { value in
            defer { value += Int64(samples.count) }
            return value
        }
        onRawPCMSamples?(MicrophoneCaptureAudio(samples: samples,
            startFrame: start, admitted: admitted))
    }
    var onRecordingFailed: ((Error) -> Void)?
    var onHandoffOutcome: ((MeetingMicHandoffOutcome) -> Void)?

    let kind: MeetingMicRecorderKind
    var prepareCalls = 0
    var startCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var startError: Error?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPrepareStarted: (() -> Void)?
    var prepareGate: DispatchSemaphore?
    var invalidatedForTeardown = false

    init(kind: MeetingMicRecorderKind) {
        self.kind = kind
    }

    func prepare() throws {
        prepareCalls += 1
        onPrepareStarted?()
        prepareGate?.wait()
    }

    func start() throws {
        if invalidatedForTeardown {
            throw NSError(domain: "test", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "invalidated",
            ])
        }
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
        onStop?()
        return nil
    }

    func cancel() {
        cancelCalls += 1
        onCancel?()
    }

    func invalidateForTeardown() {
        invalidatedForTeardown = true
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
